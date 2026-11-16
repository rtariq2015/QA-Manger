#!/usr/bin/env python3
"""Build-time only: clean portable, offline update, and one-time upgrade ZIPs."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

parser=argparse.ArgumentParser()
parser.add_argument('--version',default='5.7.5')
parser.add_argument('--output-dir',required=True)
parser.add_argument('--private-profile')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
output=Path(args.output_dir);output.mkdir(parents=True,exist_ok=True)
assert (root/'App/Host/CTQa.Host.exe').is_file(), 'Build the self-contained Windows host before packaging.'
entries={p.relative_to(root).as_posix():p.read_bytes() for p in sorted((root/'App').rglob('*')) if p.is_file() and '__pycache__' not in p.parts and p.suffix not in ('.pyc','.pyo')}
reader_root=root/'App/Python'
assert (reader_root/'runtime/python.exe').is_file() and (reader_root/'Integrity.json').is_file(), 'Build or download the tested portable Python reader before packaging.'
reader_manifest=json.loads((reader_root/'Integrity.json').read_text())
for item in reader_manifest['Files']:
    assert hashlib.sha256((reader_root/item['Name']).read_bytes()).hexdigest().upper()==item['SHA256'].upper(), 'The Python reader differs from its tested manifest.'
for name in ['Start CT QA Manager.cmd','User Guide.html','Config/Settings.json']:
    entries[name]=(root/name).read_bytes()
entries['Package.json']=(json.dumps({'SchemaVersion':1,'Name':'CT QA Manager Pro','Version':args.version},indent=2)+'\n').encode()
manifest='Package-SHA256SUMS.txt'
def finish(data):
    data=dict(data)
    data[manifest]=''.join(hashlib.sha256(b).hexdigest()+'  '+name+'\n' for name,b in sorted(data.items()) if name!=manifest).encode()
    for line in data[manifest].decode().splitlines():
        digest,name=line.split('  ',1)
        assert hashlib.sha256(data[name]).hexdigest()==digest
    assert not any(n.startswith(('.github/','Tests/','docs/','.git/')) for n in data)
    assert not any(n in data for n in ['README.md','AGENTS.md','CONTRIBUTING.md'])
    return data
def write(name,data,prefix='CT_QA_Manager_Pro/'):
    path=output/name
    with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for file,content in sorted(data.items()):z.writestr(prefix+file,content)
    print(path.name,path.stat().st_size,'bytes',hashlib.sha256(path.read_bytes()).hexdigest())
    return path
clean=finish(entries)
write(f'CT_QA_Manager_Pro_v{args.version}_Portable.zip',clean)
write(f'CT_QA_Manager_Pro_v{args.version}_Update.zip',clean)
bootstrap={'CT_QA_Manager_Pro/'+n:b for n,b in clean.items()}
bootstrap['Install update.cmd']=('@echo off\nsetlocal DisableDelayedExpansion\nset "CTQA_PS=%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"\nif defined PROCESSOR_ARCHITEW6432 set "CTQA_PS=%SystemRoot%\\Sysnative\\WindowsPowerShell\\v1.0\\powershell.exe"\n"%CTQA_PS%" -NoLogo -NoProfile -STA -File "%~dp0CT_QA_Manager_Pro\\App\\InstallUpdate.ps1" %*\nset "CTQA_EXIT=%ERRORLEVEL%"\npause\nexit /b %CTQA_EXIT%\n').replace('\n','\r\n').encode('ascii')
bootstrap['Export diagnostics.cmd']=('@echo off\nsetlocal DisableDelayedExpansion\n"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoLogo -NoProfile -STA -File "%~dp0CT_QA_Manager_Pro\\App\\ExportDiagnostics.ps1" %*\nset "CTQA_EXIT=%ERRORLEVEL%"\npause\nexit /b %CTQA_EXIT%\n').replace('\n','\r\n').encode('ascii')
bootstrap['READ FIRST.txt']=('CT QA Manager Pro '+args.version+' - one-time upgrade from a version through 5.2\r\n\r\nExtract this ZIP into a NEW, SEPARATE folder.\r\n\r\nTo send a support report while your old program is open:\r\n  Run Export diagnostics.cmd and select your CURRENT program folder.\r\n  Save and share only the resulting CTQA-Support ZIP.\r\n  No PDFs, filenames, paths, usernames, passwords or raw logs are included.\r\n\r\nTo upgrade:\r\n  1. Close every CT QA Manager window.\r\n  2. Run Install update.cmd.\r\n  3. Select your EXISTING program folder containing Start CT QA Manager.cmd.\r\n  Your archive, settings, saved sign-ins and reviewer evidence are preserved.\r\n  A previous-program copy is kept in Backups.\r\n\r\nFuture updates:\r\n  In version 5.3.0 or later, open Settings and choose Updates and choose or drop an approved _Update.zip.\r\n  Check its version, then Install checked update & restart.\r\n\r\nFor a clean new installation, use the separate _Portable.zip.\r\nDo not move or delete your current data folder while upgrading.\r\n').encode()
write(f'CT_QA_Manager_Pro_v{args.version}_Upgrade.zip',bootstrap,prefix='')
if args.private_profile:
    raw=Path(args.private_profile).read_bytes();profile=json.loads(raw.decode('utf-8-sig'))
    assert profile['Version']==1 and isinstance(profile['Connections'],list)
    assert all(not any(word in key.lower() for word in ('password','secret','credential')) for obj in [profile]+profile['Connections'] for key in obj)
    configured=dict(entries);configured['Config/NetworkProfile.local.json']=raw
    path=write(f'CT_QA_Manager_Pro_v{args.version}_Work_Portable.zip',finish(configured));path.chmod(0o600)
