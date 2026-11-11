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

Version 5.3.0 adds a redesigned workspace with **Today, Reports, Review, Exports, Trends and Settings**, a remembered **Light/Dark switch**, consistent local icons and a large continuously scrolling PDF viewer. Review keeps **Approve**, **Disapprove** and **Undo** close to the report; no typed name or approval checkbox is required to sort files. Exports has its own scanner, month and multiple-year filters.

Background content reading processes **one PDF at a time**, yields for foreground actions, runs at lower process priority, and provides **Pause/Resume** and **Stop reading**. Each bulk action is capped at 20 actual PDF reads. Completed readings remain cached; searching, reviewing and exporting can continue between reads.

The bundled Standard and Python readers extract supported water CT and image-noise measurements with clearly printed HU bounds, context and source pages. **Trends** keeps scanner, mode, system and slice contexts separate, retains unusual readings and links points back to their source PDFs. Change is latest minus first in the selected period, not a calibrated drift diagnosis or clinical approval. Opening a chart starts no hidden PDF reading.

Automatic uses Standard first because it was faster in the recorded cold-read comparison on identical synthetic PDFs; Python is available as an alternate. This does not predict hospital network speed. Existing successful readings stay cached, and older measurements are collected only through explicit bounded reads. No separate Python installation, pip, internet service or administrator launch is required.

Use the **Upgrade ZIP** for the one-time move from version 5.2 or earlier: its older updater cannot admit the added Python file types. From version 5.3 onward, use the normal in-app Update ZIP in **Settings → Updates**. PDF layout alone does not establish your department's Daily/Monthly convention; scanner-specific filing rules default to Ask until configured. Existing approvals and clinical evidence remain preserved.

Version 5.3.1 adds **Export diagnostic ZIP** and **Open printable report** in Settings → Backup & support. The ZIP contains a printable HTML report, summary JSON, per-report diagnostic JSONL/CSV, and complete retained structured activity JSONL/CSV. It records reading times, reader/profile/reason codes, cache and measurement progress, anonymous scanner rules, queue controls and connection error numbers. PDFs, extracted text, filenames, hashes, private paths, usernames and passwords are excluded. Nothing is uploaded automatically. Print views disclose their 500-row/event display limits; machine-readable files retain the complete exported data.

**Read & organize automatically** processes unresolved files; **Read all saved PDFs** handles eligible historical measurement upgrades. Explicit queues continue beyond20 while retaining one-PDF checkpoints, foreground priority, Pause/Resume/Stop and cached read-error suppression. Older unknown-template results can be refreshed once for the current support revision. Compatible Siemens Definition Flash and SOMATOM Drive layouts now pass strict section/footer checks. Explicit manufacturer Quality Daily reports have a separate Daily profile, and supported individual/combined IEC test sets have their own scanner filing rule. Reference-suffixed and unknown test layouts remain for review. Saved per-scanner Daily/Monthly rules are still required when the report does not state its type; uncertain or conflicting documents remain for review. Existing approvals, PDFs and clinical evidence stay preserved.

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
