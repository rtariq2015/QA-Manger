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
- **[Update ZIP — use inside the app]({base}CT_QA_Manager_Pro_v{version}_Update.zip)**: In version 5.3.0 or later, open **Updates**, choose/drop this ZIP, then install and restart. Your reports and settings stay in place.
- **[One-time upgrade — version 5.2 and earlier]({base}CT_QA_Manager_Pro_v{version}_Upgrade.zip)**: Use this package to move from 5.2 or earlier to the new bundled Python reader. Extract separately, close the existing program, run **Install update.cmd**, and select the existing program folder. It also includes **Export diagnostics.cmd**, which can export scrubbed logs while the existing app is open.
- **[Visual preview]({base}{preview.name})**: Actual offline browser screens using synthetic demonstration data.
- **[SHA-256 checksums]({base}SHA256SUMS.txt)**.

Version 5.4.0 makes routine reading and document filing mostly automatic. With **Read and organize automatically** enabled, opening a configured workspace or completing an import starts the eligible backlog. Completed readings stay cached; appropriate legacy Daily/Slice measurement capabilities and older unsupported templates are refreshed once. **Pause/Resume/Stop** remain available, one PDF is processed at a time at lower process priority, and foreground work has priority between PDFs. Stop suppresses automatic reading for the current app session.

Complete supported Basic reports use an **inferred Daily** file label and Extended reports use **inferred Monthly**. Individual/combined IEC reports retain an available existing Daily/Monthly grouping. These are visible filing conventions, separate from human approval and clinical QA evidence. Explicit document titles, saved decisions, Undo, conflicts and scanner overrides retain priority. Report-format selectors distinguish **Automatic**, **Ask me**, **Daily**, **Monthly** and **Other**; legacy blank rules use Automatic. Unread files are shown as waiting; the Review queue contains processed exceptions. No name or approval checkbox is needed for optional file sorting.

Strict historical **Reference** reports file as Other and cannot supply current Daily/Monthly receipt or graph values. Suspected reference material remains an exception and is excluded too. Supported standalone IEC component reports now have their own complete-profile detection. All recognition still requires stable verified PDF bytes, supported body evidence and matching report footers. Existing clinical archive fields, PDFs, manual decisions and credentials remain preserved.

**Trends** adds supported Daily inline water/noise measurements and **Slice thickness in mm**. Scanner, mode, system and slice contexts remain separate; explicit printed limits and source pages remain linked. Existing HU caches remain graphable. Ambiguous dual-source/shared-column tables are excluded. Reference values never replace current measurements. MTF and universal table recognition are not included.

Trusted queue plans, compact per-file responses, periodic overview/folder checkpoints and per-validation-pass reuse of checked directory ancestry reduce repeated full-library processing. Selected PDFs still receive fresh archive-membership, direct-path, length, timestamp and exact-buffer SHA-256 checks. This release includes actual recorded tests rather than a hospital-workstation speed guarantee.

Approve, Disapprove and Undo now reuse the validated dashboard and committed organization data, update only the selected readable copy and return consistent counters. The decision is saved durably before any folder-refresh warning; Undo and protected originals remain preserved.

The six workspaces remain **Today, Reports, Review, Exports, Trends and Settings**, with remembered Light/Dark appearance and continuously scrolling PDF pages. Export filters, multiple-year ZIP packages, durable Undo, the offline Python alternate and original Windows interface remain included.

**Settings → Backup & support** offers **Export diagnostic ZIP** and **Open printable report**. Logs include retained supported actions, timings, reader/profile/reason codes, queue progress, inferred filing bases, waiting-versus-review states, capability revisions and connection error numbers. The ZIP contains printable HTML, structured JSON and complete exported diagnostic/activity CSV/JSONL. Printed detail discloses its 500-row/event caps. PDFs, extracted text, filenames, hashes, private paths, usernames, passwords and raw logs are excluded; nothing uploads automatically.

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
