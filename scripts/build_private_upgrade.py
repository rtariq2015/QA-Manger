"""Build a private, configured one-time upgrade from already checked release ZIPs.

The resulting file is for the local user only; never upload it to generic Releases.
"""
import argparse,hashlib,json,zipfile
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--portable',required=True,help='Locally built Work_Portable ZIP')
p.add_argument('--upgrade',required=True,help='Matching generic Upgrade ZIP')
p.add_argument('--output',required=True)
a=p.parse_args()
prefix='CT_QA_Manager_Pro/'
with zipfile.ZipFile(a.portable) as archive:
    data={n:archive.read(n) for n in archive.namelist() if not n.endswith('/')}
assert data and all(n.startswith(prefix) and '..' not in n.split('/') for n in data)
profile=json.loads(data[prefix+'Config/NetworkProfile.local.json'].decode('utf-8-sig'))
assert profile['Version']==1 and len(profile['Connections'])>0
assert all(not any(word in key.lower() for word in ['password','secret','credential']) for item in [profile]+profile['Connections'] for key in item)
for line in data[prefix+'Package-SHA256SUMS.txt'].decode().splitlines():
    digest,name=line.split('  ',1)
    assert hashlib.sha256(data[prefix+name]).hexdigest()==digest
with zipfile.ZipFile(a.upgrade) as archive:
    bootstrap={n:archive.read(n) for n in archive.namelist() if not n.startswith(prefix) and not n.endswith('/')}
assert 'Install update.cmd' in bootstrap
bootstrap['Install update.cmd']=bootstrap['Install update.cmd'].replace(b'App\\InstallUpdate.ps1',b'App\\ApplyNetworkUpdate.ps1')
assert b'ApplyNetworkUpdate.ps1' in bootstrap['Install update.cmd']
bootstrap['READ FIRST.txt']=('CT QA Manager - private configured upgrade\r\n\r\n'
    'Extract this ZIP into a NEW, SEPARATE folder.\r\n'
    'Close CT QA Manager. Run Install update.cmd and choose your EXISTING program folder.\r\n'
    'The program is updated and the supplied scanner paths/usernames are applied.\r\n'
    'Existing reports, archive location, review history and data are preserved.\r\n'
    'Passwords are NOT bundled. Enter scanner passwords securely in Settings if needed.\r\n'
    'If you deliberately use different scanner paths or accounts, use the generic upgrade instead.\r\n'
    'This private package must not be published in the generic GitHub release.\r\n').encode('ascii')
output=Path(a.output)
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
    for name,value in sorted({**bootstrap,**data}.items()):archive.writestr(name,value)
output.chmod(0o600)
print('Private configured upgrade built; no passwords included. Keep this package local.')
