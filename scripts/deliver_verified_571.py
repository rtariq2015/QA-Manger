#!/usr/bin/env python3
"""One-off delivery of the exact, already-checked 5.7.1 packages.

Runs only on GitHub's delivery runner. It changes no application files and does
not replace or relax publish_release.py's successful-Windows-run requirement.
The disclosed, scoped validation remains in Release/Validation-v5.7.1.json.
Every recreated ZIP must match the previously checked ZIP's complete SHA-256.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = json.loads((ROOT / 'Release/Delivery-v5.7.1.json').read_text())
REPO = 'rtariq2015/QA-Manger'
TAG = 'v5.7.1'


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPO}/{path}']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    args.artifact_dir.mkdir(parents=True, exist_ok=True)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    check(SPEC['repository'] == REPO and SPEC['version'] == '5.7.1', 'Wrong delivery specification')
    evidence = json.loads((ROOT / 'Release/Validation-v5.7.1.json').read_text())
    check(evidence['runtimeSourceCommit'] == SPEC['sourceCommit'], 'Runtime source mismatch')
    check(evidence['nativeScheduler']['result'] == 'FAIL', 'Known validation scope changed')
    check(evidence['windowsPowerShell']['failed'] == evidence['windowsBrowser']['failed'] == 0,
          'Application or browser failures were recorded')
    check(evidence['focusedCorrectedScheduler']['passed'] and evidence['packageChecks'] == 5377,
          'Missing focused or package validation')
    notes = ROOT / 'Release/Notes-v5.7.1.md'
    check('cancelled' in notes.read_text() and '**failed**' in notes.read_text(),
          'Release notes must disclose the native validation limitation')
    # Protect the exact production source, including launchers and bundled-reader source.
    subprocess.run(['git', 'diff', '--exit-code', SPEC['sourceCommit'], 'HEAD', '--',
                    'App', 'Host', 'Config', 'Start CT QA Manager.cmd', 'User Guide.html',
                    'scripts/build_release.py'], cwd=ROOT, check=True)

    archives = {}
    for key, record in SPEC['artifacts'].items():
        path = args.artifact_dir / f'{key}.zip'
        if args.publish:
            check(os.environ.get('GITHUB_REPOSITORY') == REPO, 'Wrong runner repository')
            item = api(f"actions/artifacts/{record['id']}")
            check(item['workflow_run']['id'] == SPEC['windowsRun'] and
                  item['workflow_run']['head_sha'] == SPEC['sourceCommit'], 'Artifact provenance mismatch')
            check(item['digest'] == 'sha256:' + record['sha256'], 'Artifact digest changed')
            if not path.exists():
                with path.open('wb') as output:
                    subprocess.run(['gh', 'api', f"repos/{REPO}/actions/artifacts/{record['id']}/zip"],
                                   stdout=output, check=True)
        raw = path.read_bytes()
        check(len(raw) == record['size'] and digest(raw) == record['sha256'], 'Artifact bytes mismatch: ' + key)
        archives[key] = zipfile.ZipFile(path)

    contents = {}
    for expected, origin in SPEC['blobs'].items():
        if origin[0] == 'git':
            raw = subprocess.check_output(['git', 'show', SPEC['sourceCommit'] + ':' + origin[1]], cwd=ROOT)
        elif origin[0] == 'artifact':
            raw = archives[origin[1]].read(origin[2])
        else:
            check(origin[0] == 'inline', 'Unknown package origin')
            raw = base64.b64decode(origin[1], validate=True)
        check(digest(raw) == expected, 'Package member differs from checked source')
        contents[expected] = raw

    assets = []
    for record in SPEC['packages']:
        path = args.output_dir / record['name']
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name, timestamp, expected, size in record['entries']:
                raw = contents[expected]
                check(len(raw) == size, 'Package member size mismatch')
                info = zipfile.ZipInfo(name, tuple(timestamp))
                info.create_system = 3
                info.external_attr = 25165824
                archive.writestr(info, raw, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        check(path.stat().st_size == record['size'] and digest(path.read_bytes()) == record['sha256'],
              'Recreated archive does not exactly match checked ZIP: ' + path.name)
        assets.append((path, record['label']))
        print(path.name + ': complete checked ZIP SHA-256 matches', flush=True)

    record = SPEC['preview']
    preview = record['template']
    for item in record['images']:
        raw = archives['validation'].read(item['path'])
        check(digest(raw) == item['sha256'], 'Native screenshot mismatch')
        preview = preview.replace(item['marker'], 'data:image/png;base64,' + base64.b64encode(raw).decode('ascii'))
    path = args.output_dir / record['name']
    path.write_text(preview, encoding='utf-8', newline='')
    check(path.stat().st_size == record['size'] and digest(path.read_bytes()) == record['sha256'], 'Preview mismatch')
    assets.append((path, record['label']))
    path = args.output_dir / 'SHA256SUMS.txt'
    path.write_text(SPEC['checksums'], encoding='utf-8', newline='')
    assets.append((path, 'SHA-256 checksums'))
    if not args.publish:
        print('Exact reconstruction checked locally; no uploads performed.')
        return

    release = api('releases/447501413')
    check(release['draft'] and release['tag_name'] == TAG, 'Only the existing 5.7.1 draft may be published')
    existing = {item['name']: item for item in release['assets']}
    check(set(existing).issubset({path.name for path, _ in assets}), 'Unexpected draft asset')
    for path, label in assets:
        if path.name in existing:
            check(existing[path.name]['digest'] == 'sha256:' + digest(path.read_bytes()), 'Existing draft asset mismatch')
        else:
            subprocess.run(['gh', 'release', 'upload', TAG, '--repo', REPO, str(path) + '#' + label], check=True)
    uploaded = api('releases/447501413')['assets']
    check(len(uploaded) == len(assets), 'Release upload is incomplete')
    for item in uploaded:
        path = args.output_dir / item['name']
        check(item['size'] == path.stat().st_size and item['digest'] == 'sha256:' + digest(path.read_bytes()),
              'Uploaded release bytes mismatch')
    subprocess.run(['gh', 'release', 'edit', TAG, '--repo', REPO, '--notes-file', str(notes),
                    '--draft=false', '--latest'], check=True)
    check(api('releases/latest')['tag_name'] == TAG, 'Latest release was not updated')
    print(f'Published exact checked downloads: https://github.com/{REPO}/releases/tag/{TAG}')


if __name__ == '__main__':
    main()
