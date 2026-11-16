#!/usr/bin/env python3
"""Test the real local host scheduler with a deterministic synthetic file adapter.

No source PDFs, credentials, application configuration, or live archive are used.
This checks scheduling and API behavior; it does not benchmark PDF reader speed.
"""
import argparse
import ctypes
import hashlib
import io
import zipfile
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import traceback
import urllib.error
import urllib.request

ADAPTER = r'''[CmdletBinding()]param([string]$AppRoot,[string]$InputPath,[string]$OutputPath,[string]$ProgressPath='', [string]$CancelPath='', [switch]$IsolatedPdfRead)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$stream=[Console]::OpenStandardInput();$reader=New-Object IO.StreamReader($stream,(New-Object Text.UTF8Encoding($false)),$true,4096)
try{$request=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
$action=[string]$request.action;$statePath=Join-Path $AppRoot 'Data/sim.json'
function State {
    $s=if([IO.File]::Exists($statePath)){[IO.File]::ReadAllText($statePath)|ConvertFrom-Json}else{[pscustomobject]@{count=0;revision=0;limit=8;delayMs=800}}
    foreach($name in @('setupComplete','autoAnalyze','autoUpdateOnOpen','freezeRead')){if($null -eq $s.PSObject.Properties[$name]){$s|Add-Member $name $false}}
    if($null -eq $s.PSObject.Properties['coreRevision']){$s|Add-Member coreRevision 0};return $s
}
function Save($s){[IO.File]::WriteAllText($statePath,($s|ConvertTo-Json -Compress))}
function Snapshot {$s=State;return [pscustomobject]@{archiveRoot=(Join-Path $AppRoot 'Reports');marker=$s.revision;analysis=[pscustomobject]@{pending=[math]::Max(0,$s.limit-$s.count);backlogPending=[math]::Max(0,$s.limit-$s.count)};setupComplete=[bool]$s.setupComplete;settings=[pscustomobject]@{autoAnalyze=[bool]$s.autoAnalyze;autoUpdateOnOpen=[bool]$s.autoUpdateOnOpen;monitorMinutes=0}}}
function Event([string]$Kind){
    $limit=$null;if($null -ne $request.PSObject.Properties['analysisLimit']){$limit=$request.analysisLimit}
    $row=[pscustomobject]@{action=$action;kind=$Kind;analysisLimit=$limit;passwordPresent=($null -ne $request.PSObject.Properties['password']);hasSnapshot=($Kind -eq 'end' -and $null -ne $value.PSObject.Properties['snapshot']);isolatedPdfRead=[bool]$IsolatedPdfRead}
    [IO.File]::AppendAllText((Join-Path $AppRoot 'events.jsonl'),(($row|ConvertTo-Json -Compress)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
}
Event 'start'
switch($action){
    'Snapshot'{$value=[pscustomobject]@{snapshot=(Snapshot)}}
    'AnalysisPlan'{
        $s=State;$ids=@();for($n=$s.count+1;$n -le $s.limit;$n++){$ids+=$n.ToString('x64')}
        $value=[pscustomobject]@{plan=[pscustomobject]@{recordIds=$ids;pending=$ids.Count;total=$s.limit;cached=$s.count;revision=[string]$s.coreRevision};snapshotDeferred=$true;cancelled=$false}
    }
    'Analyze'{
        if($null -eq $request.PSObject.Properties['id'] -and $request.analysisLimit -ne 1){throw 'Expected one PDF per background chunk.'}
        $s=State;$duration=[int]$s.delayMs
        if($s.freezeRead){
            $childInfo=New-Object Diagnostics.ProcessStartInfo;$childInfo.FileName=(Get-Process -Id $PID).Path;$childInfo.Arguments='-NoLogo -NoProfile -Command "Start-Sleep -Seconds 300"';$childInfo.UseShellExecute=$false;$childInfo.CreateNoWindow=$true
            $child=[Diagnostics.Process]::Start($childInfo);[IO.File]::WriteAllText((Join-Path $AppRoot 'Data/unresponsive-child.pid'),[string]$child.Id);$child.Dispose()
        }
        for($elapsed=0;$elapsed -lt $duration;$elapsed+=50){
            if($ProgressPath){[IO.File]::WriteAllText($ProgressPath,'{"stage":"Analyzing","completed":0,"total":1,"percent":0}',(New-Object Text.UTF8Encoding($false)))}
            Start-Sleep -Milliseconds 50
            if(-not $s.freezeRead -and $CancelPath -and [IO.File]::Exists($CancelPath)){break}
        }
        $stopped=($CancelPath -and [IO.File]::Exists($CancelPath));$s=State;$previous=$s.count;$changed=@()
        if(-not $stopped){$s.count++;$s.revision++;Save $s;$changed=@($s.count.ToString('x64'))}
        $value=[pscustomobject]@{cancelled=[bool]$stopped;snapshotDeferred=$true;libraryDeferred=$true;analysisRevision=[string]$s.coreRevision;result=[pscustomobject]@{Performance=[pscustomobject]@{InlinePdfReads=$(if($IsolatedPdfRead){1}else{0})};Analyzed=$(if($stopped){0}else{1});Failed=0;Cached=0;Pending=0;AnalyzedIds=$changed;Summary=[pscustomobject]@{Cancelled=[bool]$stopped}}}
    }
    'SyncLibrary'{$value=[pscustomobject]@{snapshot=(Snapshot);cancelled=$false}}
    'Approve'{Start-Sleep -Milliseconds 150;$s=State;$s.revision+=100;$s.coreRevision++;Save $s;$value=[pscustomobject]@{snapshot=(Snapshot);message='saved'}}
    'Refresh'{$value=[pscustomobject]@{snapshot=(Snapshot);message='refreshed'}}
    'Settings'{$s=State;if($null -ne $request.PSObject.Properties['autoAnalyze']){$s.autoAnalyze=[bool]$request.autoAnalyze};$s.coreRevision++;Save $s;$value=[pscustomobject]@{snapshot=(Snapshot);message='settings saved'}}
    'Trends'{$value=[pscustomobject]@{series=@();filter=[string]$request.metric}}
    'Diagnostics'{Start-Sleep -Milliseconds 150;$value=[pscustomobject]@{message='logs ready'}}
    default{$value=[pscustomobject]@{snapshot=(Snapshot)}}
}
Event 'end'
$bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(([pscustomobject]@{success=$true;value=$value}|ConvertTo-Json -Depth 12 -Compress))
$stream=[Console]::OpenStandardOutput();try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush()}finally{$stream.Dispose()}
'''



def process_alive(pid):
    if os.name == 'nt':
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.restype = ctypes.c_void_p
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return ctypes.get_last_error() == 5
        try:
            status = ctypes.c_ulong()
            return bool(kernel.GetExitCodeProcess(ctypes.c_void_p(handle), ctypes.byref(status))) and status.value == 259
        finally:
            kernel.CloseHandle(ctypes.c_void_p(handle))
    try:
        stat = Path('/proc') / str(pid) / 'stat'
        if stat.exists() and stat.read_text().split(') ', 1)[1].startswith('Z'):
            return False
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def read_ready_json(path, expected_pid=None):
    """Observe a completed readiness record, within the caller's existing timeout.

    Windows creates the private ready file before applying its ACL and writing
    JSON. Existence alone therefore cannot establish that startup is ready.
    The copied reader barrier has the same write-completion boundary.
    """
    try:
        value = json.loads(path.read_text(encoding='utf-8-sig'))
    except (FileNotFoundError, PermissionError, json.JSONDecodeError):
        return None
    if not isinstance(value, dict):
        return None
    if expected_pid is not None and value.get('pid') != expected_pid:
        return None
    return value


def run_real_reader_checks(args):
    """A copied production reader pauses after fresh membership/hash validation.

    The barrier belongs only to the disposable synthetic fixture. Production
    reader guards, cancellation, cache writes and archive lock run unchanged.
    """
    product = Path(__file__).resolve().parents[2]
    root = Path(tempfile.mkdtemp(prefix='CTQA-Real-Background-Synthetic-')) / 'Workspace'
    process = None
    config = None
    result = {'syntheticOnly': True, 'checks': []}
    try:
        setup = [args.powershell, '-NoLogo', '-NoProfile', '-File', str(product / 'Tests/Web/New-WebFixture.ps1'), '-FixtureRoot', str(root), '-ProductRoot', str(product)]
        completed = subprocess.run(setup, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        if completed.returncode:
            raise AssertionError('The disposable real-reader fixture could not be prepared')
        settings = root / 'Config/Settings.local.json'
        value = json.loads(settings.read_text(encoding='utf-8-sig'))
        value.update(AutoAnalyze=False, AutoUpdateOnOpen=False, MonitorMinutes=0, PdfReaderMode='Standard')
        settings.write_text(json.dumps(value), encoding='utf-8-sig')
        reader_path = root / 'App/PdfReader.psm1'
        source = reader_path.read_text(encoding='utf-8-sig')
        needle = '        $engineTimer=[Diagnostics.Stopwatch]::StartNew()'
        barrier = """        $testRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../Data'));$testHold=Join-Path $testRoot 'reader-hold';$testReached=Join-Path $testRoot 'reader-reached.json'
        if([IO.File]::Exists($testHold)){
            $inline=($null -ne $Progress -and $Progress.ContainsKey('ReaderProcessIsolated') -and [bool]$Progress.ReaderProcessIsolated)
            [IO.File]::WriteAllText($testReached,('{"inline":'+$inline.ToString().ToLowerInvariant()+'}'))
            while([IO.File]::Exists($testHold) -and -not (Test-QaReaderCancel $Progress)){Start-Sleep -Milliseconds 50}
            if(Test-QaReaderCancel $Progress){throw [OperationCanceledException]::new('Synthetic checkpoint cancellation.')}
        }
"""
        assert needle in source
        reader_path.write_text(source.replace(needle, barrier + needle, 1), encoding='utf-8-sig', newline='\r\n')
        state_path = root / 'Data/.ctqa/state.json'
        state = json.loads(state_path.read_text(encoding='utf-8-sig'))
        protected = {state_path: hashlib.sha256(state_path.read_bytes()).hexdigest()}
        for row in state['Records']:
            for field in ['SourcePath', 'DestinationPath']:
                path = Path(row[field])
                protected[path] = hashlib.sha256(path.read_bytes()).hexdigest()
        command = ([args.dotnet, str(Path(args.host).resolve())] if args.host.lower().endswith('.dll') else [str(Path(args.host).resolve())])
        process = subprocess.Popen(command + ['--root', str(root), '--powershell', args.powershell, '--no-browser'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        def until(predicate, seconds=60):
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                found = predicate()
                if found:
                    return found
                time.sleep(.05)
            raise AssertionError('The real-reader checkpoint did not complete')
        ready_path = root / 'Data/web-ready.json'
        config = until(lambda: read_ready_json(ready_path, process.pid))
        def call(path, body=None, binary=False):
            request = urllib.request.Request(config['url'] + path, json.dumps(body).encode() if body is not None else None, headers={'X-Qa-Session': config['token'], 'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=20) as response:
                return response.read() if binary else json.load(response)
        def snapshot():
            try:
                return call('/api/snapshot')
            except urllib.error.HTTPError as error:
                if error.code != 503:
                    raise
        def job(identity):
            return next(row for row in call('/api/jobs')['jobs'] if row['id'] == identity)
        def terminal(identity):
            row = job(identity)
            return row if row['status'] in ['completed', 'cancelled', 'failed'] else None
        first = until(snapshot)
        assert len(first['records']) >= 2
        hold = root / 'Data/reader-hold'
        reached = root / 'Data/reader-reached.json'
        hold.write_text('synthetic reader checkpoint')
        identity = call('/api/actions', {'action': 'AnalyzeBacklog', 'scope': 'all'})['id']
        marker = until(lambda: read_ready_json(reached))
        assert marker['inline'] is True
        call('/api/jobs/' + identity + '/pause', {'paused': True})
        export_id = call('/api/actions', {'action': 'Export', 'ids': [first['records'][0]['id']]})['id']
        hold.unlink()
        paused = until(lambda: (row if (row := job(identity))['paused'] else None))
        exported = until(lambda: terminal(export_id))
        assert paused['completed'] == 1 and exported['status'] == 'completed'
        exported_bytes = call(exported['result']['downloadUrl'], binary=True)
        with zipfile.ZipFile(io.BytesIO(exported_bytes)) as archive:
            pdf_names = [name for name in archive.namelist() if name.lower().endswith('.pdf')]
            assert archive.testzip() is None and len(pdf_names) == 1
            original_export = next(row for row in state['Records'] if row['Id'] == first['records'][0]['id'])
            assert hashlib.sha256(archive.read(pdf_names[0])).hexdigest().upper() == original_export['Hash'].upper()
        foreground_snapshot = call('/api/snapshot')
        newly_read = [row for row in foreground_snapshot['records'] if row['content']['status'] != 'NotRead']
        assert len(newly_read) == 1
        visible_read = newly_read[0]
        old_read = next(row for row in first['records'] if row['id'] == visible_read['id'])
        assert visible_read['content']['reader']['name'] == 'Standard' and visible_read['content']['readPages'] > 0
        assert visible_read['stamp'] != old_read['stamp']
        cache_folder = root / 'Data/.ctqa/analysis'
        before_cache = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in cache_folder.glob('*.json')}
        assert len(before_cache) == 1
        warm_id = call('/api/actions', {'action': 'Analyze', 'id': visible_read['id']})['id']
        warm = until(lambda: terminal(warm_id))
        assert warm['status'] == 'completed' and warm['result']['result']['Analyzed'] == 0 and warm['result']['result']['Cached'] == 1
        assert warm['performance']['workerStarts'] == 1 and warm['performance']['inlinePdfReads'] == 0
        assert warm['result']['result']['Performance']['InlinePdfReads'] == 0 and warm['result']['result']['Performance']['CacheWrites'] == 0
        assert before_cache == {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in cache_folder.glob('*.json')}
        result['warmCacheDoesNotCountAsParsing'] = True
        result['foregroundSnapshotIncludesCompletedReading'] = True
        result['exactExportedPDFBytesPreserved'] = True
        result['checks'].append('The real reader yields after one verified PDF so a queued foreground Export completes while reading is paused')
        reached.unlink()
        hold.write_text('synthetic reader cancellation checkpoint')
        call('/api/jobs/' + identity + '/pause', {'paused': False})
        until(reached.exists)
        call('/api/jobs/' + identity + '/cancel', {})
        stopped = until(lambda: terminal(identity))
        assert stopped['status'] == 'cancelled' and stopped['completed'] == 1
        assert stopped['total'] == len(first['records']) and stopped['result']['result']['Pending'] == len(first['records']) - 1
        assert stopped['performance']['inlinePdfReads'] == 2
        assert before_cache == {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in cache_folder.glob('*.json')}
        stopped_snapshot = call('/api/snapshot')
        assert next(row for row in stopped_snapshot['records'] if row['id'] == visible_read['id'])['stamp'] == visible_read['stamp']
        assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in protected.items())
        hold.unlink()
        result['checks'].append('Cancelling an in-flight real reader preserves the first cache, all pending reports, original PDF bytes and clinical state')
        unread = next(row for row in call('/api/snapshot')['records'] if row['content']['status'] == 'NotRead')
        channel = root / 'Data/.web-jobs/request-spoof'
        channel.mkdir(parents=True)
        payload = {'action': 'Analyze', 'id': unread['id'], 'IsolatedPdfRead': True, 'ReaderProcessIsolated': True}
        cli = [args.powershell, '-NoLogo', '-NoProfile', '-File', str(root / 'App/WebWorker.ps1'), '-AppRoot', str(root), '-InputPath', 'stdin', '-OutputPath', 'stdout', '-ProgressPath', str(channel / 'progress.json'), '-CancelPath', str(channel / 'cancel')]
        spoof = subprocess.run(cli, input=json.dumps(payload).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=100)
        if not spoof.stdout.strip():
            raise AssertionError('The synthetic spoof transport returned empty JSON; exit=' + str(spoof.returncode) + '; stderr=' + spoof.stderr.decode('utf-8-sig', errors='replace')[-1000:])
        envelope = json.loads(spoof.stdout.decode('utf-8-sig'))
        assert spoof.returncode == 0 and envelope['success']
        performance = envelope['value']['result']['Performance']
        assert performance['InlinePdfReads'] == 0 and performance['NestedReaderStarts'] == 1
        result['checks'].append('Request JSON cannot enable the command-line-only direct-reader optimization')
        result.update(successfulReadsBeforeCancellation=1, failedReadsBeforeCancellation=0, originalsUnchanged=True)
        call('/api/actions', {'action': 'Shutdown'})
        process.wait(timeout=45)
        return result
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=15)
        shutil.rmtree(root.parent, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True, help='Built CTQa.Host.exe or CTQa.Host.dll')
    parser.add_argument('--dotnet', default='dotnet', help='dotnet executable when --host is a DLL')
    parser.add_argument('--powershell', default=os.environ.get('CTQA_TEST_POWERSHELL') or
                        (str(Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe')
                         if os.name == 'nt' else 'pwsh'))
    parser.add_argument('--output', default='')
    args = parser.parse_args()
    base = Path(tempfile.mkdtemp(prefix='CTQA-Background-Synthetic-'))
    (base / 'App/Web').mkdir(parents=True)
    (base / 'Data').mkdir()
    (base / 'App/Web/index.html').write_text('Synthetic scheduler test', encoding='utf-8')
    (base / 'App/Web/trends.js').write_text('// Synthetic trend asset', encoding='utf-8')
    (base / 'App/WebWorker.ps1').write_bytes(b'\xef\xbb\xbf' + ADAPTER.replace('\n', '\r\n').encode('utf-8'))
    command = ([args.dotnet, str(Path(args.host).resolve())] if args.host.lower().endswith('.dll')
               else [str(Path(args.host).resolve())])
    command += ['--root', str(base), '--powershell', args.powershell, '--no-browser']
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    checks = []
    child_pid = None
    summary = {'passed': False, 'syntheticOnly': True, 'scope': 'Real host scheduling with a deterministic PowerShell adapter, copied production-reader pause/export/cancel checks, and an actual 90-second helper deadline. Generated PDFs only; no reader speed claim.'}
    try:
        def until(predicate, seconds=45):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                value = predicate()
                if value:
                    return value
                time.sleep(.05)
            raise AssertionError('Timed out waiting for a scheduler checkpoint')

        config = until(lambda: read_ready_json(base / 'Data/web-ready.json', process.pid))

        def call(path, data=None):
            request = urllib.request.Request(config['url'] + path,
                json.dumps(data).encode() if data is not None else None,
                headers={'X-Qa-Session': config['token'], 'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=15) as response:
                return json.load(response)

        def saved():
            try:
                return call('/api/snapshot')
            except urllib.error.HTTPError as error:
                if error.code == 503:
                    return None
                raise

        def job(identity):
            return next(x for x in call('/api/jobs')['jobs'] if x['id'] == identity)

        def terminal(identity):
            value = job(identity)
            return value if value['status'] in ('completed', 'failed', 'cancelled') else None

        until(saved)
        background = call('/api/actions', {'action': 'Analyze', 'password': 'synthetic-must-not-retain', 'IsolatedPdfRead': False, 'ReaderProcessIsolated': False})['id']
        until(lambda: job(background)['status'] == 'running')
        until(lambda: (base / 'events.jsonl').exists() and '"action":"Analyze","kind":"start"' in (base / 'events.jsonl').read_text(encoding='utf-8'))
        try:
            call('/api/actions', {'action': 'Analyze'})
            raise AssertionError('A second background job was allowed to bypass the pause control')
        except urllib.error.HTTPError as error:
            assert error.code == 409
        first_read = next(x for x in [json.loads(line) for line in (base / 'events.jsonl').read_text(encoding='utf-8').splitlines()] if x['action'] == 'Analyze' and x['kind'] == 'start')
        assert first_read['isolatedPdfRead'] is True
        checks.append('Duplicate background reads are rejected without blocking foreground controls')
        call('/api/jobs/' + background + '/pause', {'paused': True})
        paused = until(lambda: (value if (value := job(background))['paused'] else None))
        assert paused['background'] and paused['pausable'] and paused['pauseRequested'], paused
        assert paused['completed'] == 1 and paused['total'] == 8, paused
        checks.append('Pause finishes the current PDF and preserves a cumulative 1/8 checkpoint')
        before = (base / 'events.jsonl').read_text(encoding='utf-8').count('"action":"Analyze","kind":"start"')
        time.sleep(.5)
        assert (base / 'events.jsonl').read_text(encoding='utf-8').count('"action":"Analyze","kind":"start"') == before
        checks.append('Paused reading launches no additional PDF helper')
        foreground = call('/api/actions', {'action': 'Approve'})['id']
        until(lambda: terminal(foreground))
        assert job(foreground)['status'] == 'completed'
        assert saved()['marker'] == 101 and job(background)['paused']
        checks.append('Foreground Approve completes while paused and its latest snapshot is retained')
        assert call('/api/trends?metric=noise')['filter'] == 'noise'
        with urllib.request.urlopen(config['url'] + '/trends.js', timeout=15) as asset:
            assert asset.status == 200
        checks.append('Independent Trends data and static asset routes are available during reading')
        call('/api/jobs/' + background + '/pause', {'paused': False})
        until(lambda: job(background)['completed'] >= 2)
        until(lambda: job(background)['stage'] == 'Analyzing')
        foreground = call('/api/actions', {'action': 'Approve'})['id']
        until(lambda: terminal(foreground))
        assert job(foreground)['status'] == 'completed' and job(background)['completed'] < 8
        checks.append('A foreground action queued during a PDF runs before the archive batch completes')
        until(lambda: job(background)['completed'] >= 3)
        until(lambda: sum(json.loads(line)['action'] == 'Analyze' and json.loads(line)['kind'] == 'start' for line in (base / 'events.jsonl').read_text(encoding='utf-8').splitlines()) > job(background)['completed'])
        call('/api/jobs/' + background + '/cancel', {})
        stopped = until(lambda: terminal(background))
        assert stopped['status'] == 'cancelled' and stopped['completed'] >= 3 and stopped['total'] == 8, stopped
        events = [json.loads(line) for line in (base / 'events.jsonl').read_text(encoding='utf-8').splitlines()]
        assert all(not event['passwordPresent'] and event['analysisLimit'] == 1 for event in events if event['action'] == 'Analyze')
        active = None
        for event in events:
            if event['action'] not in ('Analyze', 'Approve', 'SyncLibrary'):
                continue
            if event['kind'] == 'start':
                assert active is None, (active, event)
                active = event['action']
            else:
                assert active == event['action'], (active, event)
                active = None
        checks.append('One-PDF requests are sanitized, mutations stay serialized, and cancel preserves cumulative work')
        (base / 'Data/sim.json').write_text(json.dumps({'count': 0, 'revision': 0, 'limit': 25, 'delayMs': 50}), encoding='utf-8')
        bounded = call('/api/actions', {'action': 'Analyze'})['id']
        complete = until(lambda: terminal(bounded), seconds=90)
        assert complete['status'] == 'completed' and complete['completed'] == 20 and complete['total'] == 20 and complete['percent'] == 100, complete
        assert complete['result']['result']['Pending'] == 5
        assert complete['performance']['planBuilds'] == 1 and complete['performance']['processedReports'] == 20, complete
        checks.append('A bulk action stops after twenty actual PDFs and reports the remaining work')
        (base / 'Data/sim.json').write_text(json.dumps({'count': 0, 'revision': 0, 'limit': 25, 'delayMs': 50}), encoding='utf-8')
        trace_start = len((base / 'events.jsonl').read_text(encoding='utf-8').splitlines())
        continuous = call('/api/actions', {'action': 'AnalyzeBacklog', 'scope': 'all'})['id']
        drained = until(lambda: terminal(continuous), seconds=120)
        assert drained['status'] == 'completed' and drained['completed'] == 25 and drained['total'] == 25, drained
        assert drained['result']['result']['Pending'] == 0
        assert drained['performance']['planBuilds'] == 2, drained
        assert drained['performance']['processedReports'] == 25, drained
        trace = [json.loads(line) for line in (base / 'events.jsonl').read_text(encoding='utf-8').splitlines()[trace_start:]]
        completed_steps = [event for event in trace if event['action'] == 'Analyze' and event['kind'] == 'end']
        assert len(completed_steps) == 25 and all(not event['hasSnapshot'] for event in completed_steps)
        assert not any(event['action'] == 'Snapshot' for event in trace)
        assert drained['performance']['fullSnapshots'] == sum(event['action'] == 'SyncLibrary' and event['kind'] == 'end' for event in trace)
        summary['syntheticAdapterJobMetrics'] = drained['performance']
        checks.append('A 25-PDF job reuses two plans and keeps PDF steps separate from overview checkpoints')
        assert any(event['action'] == 'SyncLibrary' for event in [json.loads(line) for line in (base / 'events.jsonl').read_text(encoding='utf-8').splitlines()])
        checks.append('An explicitly started backlog continues beyond twenty and synchronizes readable folders')
        # Enabling automatic reading is a settings decision, not opening a chart.
        (base / 'Data/sim.json').write_text(json.dumps({'count': 0, 'revision': 0, 'limit': 25, 'delayMs': 500, 'setupComplete': True, 'autoAnalyze': False}), encoding='utf-8')
        refresh = call('/api/actions', {'action': 'Refresh'})['id']
        until(lambda: terminal(refresh))
        time.sleep(.3)
        assert not any(x['automatic'] and x['status'] in ('queued', 'running') for x in call('/api/jobs')['jobs'])
        checks.append('AutoAnalyze false keeps an eligible archive manual')
        previous = {x['id'] for x in call('/api/jobs')['jobs']}
        settings = call('/api/actions', {'action': 'Settings', 'autoAnalyze': True})['id']
        until(lambda: terminal(settings))
        automatic = until(lambda: next((x for x in call('/api/jobs')['jobs'] if x['id'] not in previous and x['automatic']), None))
        until(lambda: job(automatic['id'])['completed'] >= 1)
        call('/api/jobs/' + automatic['id'] + '/cancel', {})
        until(lambda: terminal(automatic['id']))
        assert call('/api/jobs')['automaticReadingStopped'] is True
        refresh = call('/api/actions', {'action': 'Refresh'})['id']
        until(lambda: terminal(refresh))
        time.sleep(.3)
        assert call('/api/jobs')['automaticReadingStopped'] is True
        assert not any(x['background'] and x['status'] in ('queued', 'running') for x in call('/api/jobs')['jobs'])
        checks.append('Stop intent persists across Refresh independently of cooldown')
        # Reopen with AutoAnalyze enabled and check-on-open enabled. A Refresh must
        # complete before automatic reading starts, without an Analyze UI action.
        call('/api/actions', {'action': 'Shutdown'})
        process.wait(timeout=45)
        (base / 'Data/sim.json').write_text(json.dumps({'count': 0, 'revision': 0, 'limit': 3, 'delayMs': 300, 'setupComplete': True, 'autoAnalyze': True, 'autoUpdateOnOpen': True}), encoding='utf-8')
        event_start = len((base / 'events.jsonl').read_text(encoding='utf-8').splitlines())
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        config = until(lambda: read_ready_json(base / 'Data/web-ready.json', process.pid))
        startup = until(lambda: next((x for x in call('/api/jobs')['jobs'] if x['automatic'] and x['action'] == 'AnalyzeBacklog'), None))
        startup_done = until(lambda: terminal(startup['id']))
        assert startup_done['status'] == 'completed' and startup_done['completed'] == 3, startup_done
        recent = [json.loads(line) for line in (base / 'events.jsonl').read_text(encoding='utf-8').splitlines()[event_start:]]
        refresh_end = next(i for i, x in enumerate(recent) if x['action'] == 'Refresh' and x['kind'] == 'end')
        plan_start = next(i for i, x in enumerate(recent) if x['action'] == 'AnalysisPlan' and x['kind'] == 'start')
        assert refresh_end < plan_start
        checks.append('App reopen automatically reads eligible backlog after initial Refresh')
        (base / 'Data/sim.json').write_text(json.dumps({'count': 20, 'revision': 0, 'limit': 25, 'delayMs': 1000}), encoding='utf-8')
        final = call('/api/actions', {'action': 'Analyze'})['id']
        until(lambda: job(final)['status'] == 'running')
        call('/api/actions', {'action': 'Shutdown'})
        process.wait(timeout=45)
        assert process.returncode == 0
        checks.append('Shutdown cancels background reading at a safe checkpoint and leaves no running helper')
        real = run_real_reader_checks(args)
        summary['realReaderChecks'] = real
        checks.extend(real['checks'])
        (base / 'Data/sim.json').write_text(json.dumps({'count': 0, 'revision': 0, 'limit': 1, 'delayMs': 180000, 'freezeRead': True}), encoding='utf-8')
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        config = until(lambda: read_ready_json(base / 'Data/web-ready.json', process.pid))
        until(saved)
        frozen = call('/api/actions', {'action': 'Analyze'})['id']
        child_file = base / 'Data/unresponsive-child.pid'
        until(child_file.exists)
        child_pid = int(child_file.read_text())
        assert process_alive(child_pid)
        deadline_start = time.monotonic()
        until(lambda: not process_alive(child_pid), seconds=105)
        observed_deadline = time.monotonic() - deadline_start
        # Metadata cleanup has its own bound; it is not part of the parser's
        # hard deadline. Observe the actual child-tree exit before awaiting it.
        assert observed_deadline < 100
        timed_out = until(lambda: terminal(frozen), seconds=90)
        assert timed_out['status'] == 'failed' and '90-second' in timed_out['error'], timed_out
        assert timed_out['completed'] == 0 and timed_out['total'] == 1
        assert call('/api/jobs')['automaticReadingStopped'] is True
        summary['unresponsiveReaderDeadline'] = {'limitSeconds': 90, 'observedAfterChildStartedSeconds': round(observed_deadline, 3), 'helperTreeStopped': True, 'interruptedReportStillPending': True, 'automaticRestartSuppressed': True}
        checks.append('An unresponsive one-PDF helper is stopped at its 90-second deadline with its child tree, pending count and Stop intent preserved')
        call('/api/actions', {'action': 'Shutdown'})
        process.wait(timeout=45)
        summary['passed'] = True
    except Exception as error:
        summary['error'] = str(error)
        summary['errorType'] = type(error).__name__
        summary['errorTrace'] = traceback.format_exc()
    finally:
        if child_pid is not None and process_alive(child_pid):
            if os.name == 'nt':
                subprocess.run(['taskkill', '/F', '/T', '/PID', str(child_pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            else:
                os.kill(child_pid, 15)
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=15)
        summary['checks'] = checks
        summary['checkCount'] = len(checks)
        if process.returncode:
            summary['hostOutput'] = process.stdout.read().decode('utf-8', errors='replace')[-2000:]
            summary['hostError'] = process.stderr.read().decode('utf-8', errors='replace')[-2000:]
        if args.output:
            output = Path(args.output).resolve()
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
        print(json.dumps(summary, indent=2))
        shutil.rmtree(base, ignore_errors=True)
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
