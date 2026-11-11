#!/usr/bin/env python3
"""Test the real local host scheduler with a deterministic synthetic file adapter.

No source PDFs, credentials, application configuration, or live archive are used.
This checks scheduling and API behavior; it does not benchmark PDF reader speed.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ADAPTER = r'''[CmdletBinding()]param([string]$AppRoot,[string]$InputPath,[string]$OutputPath,[string]$ProgressPath='', [string]$CancelPath='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$stream=[Console]::OpenStandardInput();$reader=New-Object IO.StreamReader($stream,(New-Object Text.UTF8Encoding($false)),$true,4096)
try{$request=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
$action=[string]$request.action;$statePath=Join-Path $AppRoot 'Data/sim.json'
function State {if([IO.File]::Exists($statePath)){return ([IO.File]::ReadAllText($statePath)|ConvertFrom-Json)};return [pscustomobject]@{count=0;revision=0;limit=8;delayMs=800}}
function Snapshot {$s=State;return [pscustomobject]@{archiveRoot=(Join-Path $AppRoot 'Reports');marker=$s.revision;analysis=[pscustomobject]@{pending=[math]::Max(0,$s.limit-$s.count)};setupComplete=$false}}
function Event([string]$Kind){
    $limit=$null;if($null -ne $request.PSObject.Properties['analysisLimit']){$limit=$request.analysisLimit}
    $row=[pscustomobject]@{action=$action;kind=$Kind;analysisLimit=$limit;passwordPresent=($null -ne $request.PSObject.Properties['password'])}
    [IO.File]::AppendAllText((Join-Path $AppRoot 'events.jsonl'),(($row|ConvertTo-Json -Compress)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
}
Event 'start'
switch($action){
    'Snapshot'{$value=[pscustomobject]@{snapshot=(Snapshot)}}
    'Analyze'{
        if($null -eq $request.PSObject.Properties['id'] -and $request.analysisLimit -ne 1){throw 'Expected one PDF per background chunk.'}
        $s=State;$duration=[int]$s.delayMs
        for($elapsed=0;$elapsed -lt $duration;$elapsed+=50){
            if($ProgressPath){[IO.File]::WriteAllText($ProgressPath,'{"stage":"Analyzing","completed":0,"total":1,"percent":0}',(New-Object Text.UTF8Encoding($false)))}
            Start-Sleep -Milliseconds 50
            if($CancelPath -and [IO.File]::Exists($CancelPath)){break}
        }
        $stopped=($CancelPath -and [IO.File]::Exists($CancelPath));$s=State;$previous=$s.count
        if(-not $stopped){$s.count++;$s.revision++;[IO.File]::WriteAllText($statePath,($s|ConvertTo-Json -Compress))}
        $value=[pscustomobject]@{cancelled=[bool]$stopped;snapshot=(Snapshot);result=[pscustomobject]@{Analyzed=$(if($stopped){0}else{1});Failed=0;Cached=$previous;Pending=[math]::Max(0,$s.limit-$s.count);AnalyzedIds=@();Summary=[pscustomobject]@{Cancelled=[bool]$stopped}}}
    }
    'Approve'{Start-Sleep -Milliseconds 150;$s=State;$s.revision+=100;[IO.File]::WriteAllText($statePath,($s|ConvertTo-Json -Compress));$value=[pscustomobject]@{snapshot=(Snapshot);message='saved'}}
    'Trends'{$value=[pscustomobject]@{series=@();filter=[string]$request.metric}}
    'Diagnostics'{Start-Sleep -Milliseconds 150;$value=[pscustomobject]@{message='logs ready'}}
    default{$value=[pscustomobject]@{snapshot=(Snapshot)}}
}
Event 'end'
$bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(([pscustomobject]@{success=$true;value=$value}|ConvertTo-Json -Depth 12 -Compress))
$stream=[Console]::OpenStandardOutput();try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush()}finally{$stream.Dispose()}
'''


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
    summary = {'passed': False, 'syntheticOnly': True, 'scope': 'Real host scheduler with a deterministic PowerShell adapter; no real PDF reader speed claim.'}
    try:
        def until(predicate, seconds=45):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                value = predicate()
                if value:
                    return value
                time.sleep(.05)
            raise AssertionError('Timed out waiting for a scheduler checkpoint')

        until(lambda: (base / 'Data/web-ready.json').exists())
        config = json.loads((base / 'Data/web-ready.json').read_text(encoding='utf-8-sig'))

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
        background = call('/api/actions', {'action': 'Analyze', 'password': 'synthetic-must-not-retain'})['id']
        until(lambda: job(background)['status'] == 'running')
        until(lambda: (base / 'events.jsonl').exists() and '"action":"Analyze","kind":"start"' in (base / 'events.jsonl').read_text(encoding='utf-8'))
        try:
            call('/api/actions', {'action': 'Analyze'})
            raise AssertionError('A second background job was allowed to bypass the pause control')
        except urllib.error.HTTPError as error:
            assert error.code == 409
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
        call('/api/jobs/' + background + '/cancel', {})
        stopped = until(lambda: terminal(background))
        assert stopped['status'] == 'cancelled' and stopped['completed'] >= 3 and stopped['total'] == 8, stopped
        events = [json.loads(line) for line in (base / 'events.jsonl').read_text(encoding='utf-8').splitlines()]
        assert all(not event['passwordPresent'] and event['analysisLimit'] == 1 for event in events if event['action'] == 'Analyze')
        active = None
        for event in events:
            if event['action'] not in ('Analyze', 'Approve'):
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
        checks.append('A bulk action stops after twenty actual PDFs and reports the remaining work')
        (base / 'Data/sim.json').write_text(json.dumps({'count': 0, 'revision': 0, 'limit': 25, 'delayMs': 50}), encoding='utf-8')
        continuous = call('/api/actions', {'action': 'AnalyzeBacklog', 'scope': 'all'})['id']
        drained = until(lambda: terminal(continuous), seconds=120)
        assert drained['status'] == 'completed' and drained['completed'] == 25 and drained['total'] == 25, drained
        assert drained['result']['result']['Pending'] == 0
        assert any(event['action'] == 'SyncLibrary' for event in [json.loads(line) for line in (base / 'events.jsonl').read_text(encoding='utf-8').splitlines()])
        checks.append('An explicitly started backlog continues beyond twenty and synchronizes readable folders')
        (base / 'Data/sim.json').write_text(json.dumps({'count': 20, 'revision': 0, 'limit': 25, 'delayMs': 1000}), encoding='utf-8')
        final = call('/api/actions', {'action': 'Analyze'})['id']
        until(lambda: job(final)['status'] == 'running')
        call('/api/actions', {'action': 'Shutdown'})
        process.wait(timeout=45)
        assert process.returncode == 0
        checks.append('Shutdown cancels background reading at a safe checkpoint and leaves no running helper')
        summary['passed'] = True
    except Exception as error:
        summary['error'] = str(error)
    finally:
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
