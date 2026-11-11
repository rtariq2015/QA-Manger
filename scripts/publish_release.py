"""GitHub Actions release publisher. Requires an explicit tracked publish request."""
import hashlib,json,os,re,subprocess
from pathlib import Path

root=Path(__file__).resolve().parents[1]
request=json.loads((root/'Release/Publish.json').read_text())
version=request['Version'];tested=request['ValidatedCommit'];run_id=request['ValidatedRunId']
assert re.fullmatch(r'\d{1,3}\.\d{1,3}\.\d{1,3}',version)
assert re.fullmatch(r'[0-9a-f]{40}',tested) and isinstance(run_id,int)
repo=os.environ['GITHUB_REPOSITORY'];head=os.environ['GITHUB_SHA'];tag='v'+version
assert repo=='rtariq2015/QA-Manger'
run=json.loads(subprocess.check_output(['gh','api',f'repos/{repo}/actions/runs/{run_id}'],text=True))
assert run['status']=='completed' and run['conclusion']=='success' and run['head_sha']==tested,'The recorded Windows validation did not pass for the expected source.'
assert run['path']=='.github/workflows/windows-validation.yml'
paths=['App','Host','Config','Tests/*.ps1','Tests/Web','Start CT QA Manager.cmd','Update CT QA Manager.cmd','Apply CT QA Network Update.cmd','Export CT QA Diagnostics.cmd','scripts/build_release.py','scripts/build_app_python.py','scripts/build_python_probe.py','.github/workflows/windows-validation.yml']
subprocess.run(['git','diff','--exit-code',tested,head,'--',*paths],cwd=root,check=True)
assert '<Version>'+version+'</Version>' in (root/'Host/CTQa.Host.csproj').read_text(),'Release version does not match the host.'
subprocess.run(['gh','run','download',str(run_id),'--repo',repo,'--name','portable-web-host','--dir',str(root/'App/Host')],check=True)
subprocess.run(['gh','run','download',str(run_id),'--repo',repo,'--name','portable-python-runtime','--dir',str(root/'App/Python')],check=True)
assert not (root/'Config/NetworkProfile.local.json').exists(),'Private profiles must never enter a release build.'
out=root/'artifacts/release';out.mkdir(parents=True,exist_ok=True)
subprocess.run(['python3','scripts/build_release.py','--version',version,'--output-dir',str(out)],cwd=root,check=True)
preview=out/f'CT_QA_Manager_Pro_v{version}_Preview.html'
subprocess.run(['python3','scripts/build_preview.py','--version',version,'--include-details','--output',str(preview)],cwd=root,check=True)
files=[out/f'CT_QA_Manager_Pro_v{version}_{kind}.zip' for kind in ['Portable','Update','Upgrade']]+[preview]
assert all(p.is_file() for p in files)
checks=out/'SHA256SUMS.txt';checks.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in files));files.append(checks)
base=f'https://github.com/{repo}/releases/download/{tag}/'
notes=out/'Release-notes.md'
notes.write_text(f'''Choose the download for your task:

- **[Full portable program — new installation]({base}CT_QA_Manager_Pro_v{version}_Portable.zip)**: Extract the complete folder and run **Start CT QA Manager.cmd**. This is the clean program package, without development files or archived reports.
- **[Update ZIP — use inside the app]({base}CT_QA_Manager_Pro_v{version}_Update.zip)**: In version 5.3.0 or later, open **Settings → Program updates**, choose/drop this ZIP, then install and restart. Your reports and settings stay in place.
- **[One-time upgrade — version 5.2 and earlier]({base}CT_QA_Manager_Pro_v{version}_Upgrade.zip)**: Use this package to move from 5.2 or earlier to the new bundled Python reader. Extract separately, close the existing program, run **Install update.cmd**, and select the existing program folder. It also includes **Export diagnostics.cmd**, which can export scrubbed logs while the existing app is open.
- **[Visual preview]({base}{preview.name})**: Actual offline browser screens using synthetic demonstration data.
- **[SHA-256 checksums]({base}SHA256SUMS.txt)**.

Version 5.5.0 makes the filing target explicit: **Approve as Daily**, **Approve as Monthly** or **Approve as Other**. When no reliable proposal exists, choose a type first. Processed exceptions are grouped by scanner, supported layout, reason and proposed type. Select up to **50** reports, inspect the Daily/Monthly/Other breakdown, then keep their individual suggestions or choose one explicit type. Grouped approval/disapproval uses one durable save; any stale, changed or invalid member rejects the selection before any labels are changed. **Undo batch** restores the group together after a restart, provided its members still match. These actions organize files and do not create clinical approval or a scanner PASS. Original PDFs, previous reviews and clinical archive history remain preserved.

**Trends** expands to seven metric families: water CT, image noise, slice thickness, light marker alignment, external light marker, topogram position, and sagittal/coronal alignment. The new alignment values use mm with their printed bounds and source pages. Sagittal and coronal axes remain separate; absent acquisition systems/slices are not invented. Recognition requires the supported complete current body, matching footers and bounded printed tables. Strict historical and suspected reference documents remain excluded. MTF, contrast and table-position printed outcomes remain available in Report contents; their additional numeric column contexts are not flattened into these graphs.

The expandable **Daily report calendar** uses the existing cached overview and starts no PDF scan. It follows each scanner schedule, activation date and excluded dates, keeps future dates neutral, and opens exact-day Daily reports with matching export filters. Scanner names have consistent accent colors across the workspaces, while status text remains visible.

The separate **Folders** workspace opens the ordinary Report Library, exports the complete saved folder library with an offline HTML summary and CSV, or creates a full backup. The folder structure is scanner → year → month → Daily / Monthly / Other. Managers can browse the extracted PDFs without the app. Full-library export keeps its own scope and does not replace filtered Export selections. Save full backups on approved separate storage.

Routine Automatic filing and cached readings remain included. Complete supported Basic reports use inferred Daily labels; Extended reports use inferred Monthly; individual/combined IEC reports retain an available existing grouping. Saved decisions, explicit titles, Undo, conflicts and scanner overrides retain priority. Waiting for reading remains separate from processed exceptions. Appropriate older Monthly measurement caches receive one bounded capability upgrade; supported existing HU/slice values remain usable.

The background reader retains a disposable per-PDF helper and removes the redundant nested read process. Each selected PDF still receives fresh archive-membership, direct-path, byte-hash and metadata checks. A hard per-read deadline stops an unresponsive helper tree and suppresses automatic retries for that session until user action. Pause/Resume, foreground handoff, cancellation, automatic Stop intent and retained completed work remain tested. Process and stage counters describe actual reading work; recorded synthetic timings are not a hospital-workstation throughput guarantee.

The seven workspaces are **Today, Reports, Review, Exports, Folders, Trends and Settings**, with remembered Light/Dark appearance and continuously scrolling PDF pages. Normal in-app ZIP updates remain supported from version 5.3 onward; the calendar is bundled in the existing application script, so no one-time upgrade is needed from 5.4.

**Settings → Backup & support** offers **Export diagnostic ZIP** and **Open printable report**. Logs include retained supported actions, timings, reader/profile/reason codes, queue progress, grouped-decision/Undo counts, pending reasons, bounded reader/worker/cache timings, inferred filing bases, waiting-versus-review states, capability revisions and connection error numbers. The ZIP contains printable HTML, structured JSON and complete exported diagnostic/activity CSV/JSONL. Printed detail discloses its 500-row/event caps. PDFs, extracted text, filenames, hashes, private paths, usernames, passwords and raw logs are excluded; nothing uploads automatically.

The bundled **Standard** reader remains the Automatic default; **Python** is the offline alternate. No Python installation, pip, internet service or administrator launch is required on the work computer. Department Monthly evidence remains separate from received or automatically filed PDFs. Unsupported or conflicting files can still require occasional manual review.

A readable Report Library groups PDFs by scanner, year, month and Daily/Monthly/Other. Existing archives, original PDFs, legacy review history and configuration are retained. Background jobs keep browsing available. The self-contained local helper is bundled: no internet, administrator launch, runtime installation or public website is required. The larger download includes the runtime components. Workstation application policy must permit the helper executable and browser loopback access.

Use **Start CT QA Manager.cmd**. The original Windows interface remains available by running that launcher with the `classic` argument. Offline ZIP updates and scrubbed support logs remain available. Nothing is uploaded automatically.

Passwords, workplace network profiles and live report data are excluded from all release assets. Configure scanner access on the work computer. Updates use local files and do not contact GitHub. A previous-program copy is kept under Backups.

Windows validation: [recorded workflow]({run['html_url']}) at `{tested}`. The release code matches that validated source; documentation and release packaging metadata may be newer. These are synthetic checks, not hospital connectivity or endpoint-policy approval.
''',encoding='utf-8')
existing=subprocess.run(['gh','api',f'repos/{repo}/releases/tags/{tag}'],capture_output=True,text=True)
if existing.returncode==0:
    release=json.loads(existing.stdout)
    if not release['draft']:
        raise SystemExit('This version is already published. Use a new version rather than replacing an existing release.')
    subprocess.run(['gh','release','edit',tag,'--repo',repo,'--target',head,'--title',f'CT QA Manager Pro {tag}','--notes-file',str(notes)],check=True)
else:
    subprocess.run(['gh','release','create',tag,'--repo',repo,'--target',head,'--draft','--title',f'CT QA Manager Pro {tag}','--notes-file',str(notes)],check=True)
labels=['Full portable program - new installation','Update ZIP - use the app Updates tab','One-time upgrade - older versions','Visual preview - synthetic Windows screens','SHA-256 checksums']
subprocess.run(['gh','release','upload',tag,'--repo',repo,'--clobber',*[str(p)+'#'+label for p,label in zip(files,labels)]],check=True)
subprocess.run(['gh','release','edit',tag,'--repo',repo,'--draft=false','--latest'],check=True)
print(f'Published https://github.com/{repo}/releases/tag/{tag}')
