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

Version 5.6.0 simplifies the workflow across **Today, Monthly, Reports, Review, Exports, Folders, Trends and Settings**.

- **Review has one decision area.** It explicitly targets the Current PDF or Selected reports. A checkbox also previews its report; opening an unselected report clears the batch with a notice. Approve names Daily, Monthly or Other. Up to 50 selected files and durable Undo batch remain supported. Original PDFs and clinical review history are preserved.
- **Monthly has its own workspace.** See filed Monthly reports, checklist items found in recognized cached contents, and existing reviewed evidence separately. Set the department checklist and due day directly, with effective-month history and retained unsaved drafts. Printed warnings, unmatched custom labels, future periods and activation dates remain explicit. No new clinical sign-off is created.
- **Today is shorter.** It focuses on today's Daily receipt and a compact Monthly link. The Daily receipt calendar lives under Reports, with a Today shortcut and matching date-filtered exports.
- **Folders is simpler.** Open the ordinary scanner/year/month/Daily-Monthly-Other tree directly; full-library export and full backup are secondary tools. Filtered Exports retains its separate selection.
- **Trends adds table position.** Eight metric families are supported. Continuous and stepwise movement stay separate for each of four printed positions, with millimetre values, printed limits and source pages. Only a fully validated current table emits readings; reference material remains excluded. Existing supported measurements are retained.
- **Graph refreshes settle.** Content-identical background snapshots no longer restart the same request. Real measurement changes invalidate the graph, and in-flight updates coalesce. Coverage distinguishes read PDFs from availability of a selected test/context. Opening Monthly or Trends reads cached metadata and starts no hidden PDF parsing.

The local app remains offline and portable. Standard is the Automatic default PDF reader; bundled Python is an alternate. No work-computer installation, pip, online AI service or administrator launch is required. Unsupported or conflicting PDFs can still need occasional review. Department checklist policy and clinical review remain separate from file organization and detected sections.

Use the **Update ZIP inside Settings → Program updates** from version 5.3 onward. Do not unpack it or manually overwrite files. Reports, settings, credentials and saved decisions are retained, with a previous-program backup. Use Portable for a new installation or the separate one-time Upgrade helper for 5.2 and earlier.

The visual preview embeds actual synthetic Windows browser captures in both themes. Settings → Backup & support offers a scrubbed diagnostic ZIP and printable report. PDFs, text, filenames, private paths, usernames, passwords, workplace profiles and live archive data are excluded from generic Releases; nothing uploads automatically.

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
