#!/usr/bin/env python3
"""Build-time checks. Python is NOT an application runtime dependency."""
from __future__ import annotations
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
failures = []
checks = 0

def check(condition, message):
    global checks
    checks += 1
    if not condition:
        failures.append(message)

scripts = sorted([*root.rglob('*.ps1'), *root.rglob('*.psm1')])
check(len(scripts) >= 3, 'Application scripts are present')
for path in scripts:
    raw = path.read_bytes()
    text = raw.decode('utf-8-sig')
    check(raw.startswith(b'\xef\xbb\xbf'), f'{path.name} has UTF-8 BOM for Windows PowerShell 5.1')
    check(b'\r\r\n' not in raw, f'{path.name} has valid Windows line endings')
    # Conservative detector; does not establish Windows parser or runtime behavior.
    check(not re.search(r'\?\?|\?\.|(?m:^\s*)ForEach-Object\s+-Parallel', text), f'{path.name} avoids PowerShell 7-only constructs')

app_scripts = [p for p in scripts if 'App' in p.parts]
for path in app_scripts:
    text = path.read_text(encoding='utf-8-sig')
    check(not re.search(r'(?i)-ExecutionPolicy\s+(Bypass|Unrestricted)|Set-ExecutionPolicy', text), f'{path.name} never weakens execution policy')
    check(not re.search(r'(?i)Register-ScheduledTask|schtasks\.exe|New-ScheduledTask', text), f'{path.name} does not schedule background work')
    check(not re.search(r'(?i)WNetCancelConnection|Remove-SmbMapping|Remove-PSDrive|net(?:\.exe)?\s+use\s+.*?/delete', text), f'{path.name} never disconnects existing mappings')

for path in root.rglob('*.xaml'):
    try:
        doc = ET.parse(path)
        names = [elem.attrib.get('{http://schemas.microsoft.com/winfx/2006/xaml}Name') for elem in doc.iter()]
        names = [n for n in names if n]
        check(len(names) == len(set(names)), f'{path.name} has unique control names')
        check(doc.getroot().tag.startswith('{http://schemas.microsoft.com/winfx/2006/xaml/presentation}'), f'{path.name} uses WPF presentation namespace')
        for elem in doc.iter():
            check(not any(k.rsplit('}', 1)[-1] in ('Click', 'Loaded', 'Closing', 'SelectionChanged') for k in elem.attrib), f'{path.name} avoids compiled code-behind event declarations')
    except ET.ParseError as exc:
        check(False, f'{path.name}: {exc}')

for path in root.rglob('*.json'):
    if 'Test' not in path.name and '.ctqa' not in path.parts:
        try:
            json.loads(path.read_text(encoding='utf-8-sig'))
            check(True, f'{path.name} is valid JSON')
        except (ValueError, UnicodeError) as exc:
            check(False, f'{path.name}: {exc}')

launchers = list(root.glob('*.cmd')) + list(root.glob('*.bat'))
check((root / 'Start CT QA Manager.cmd').exists(), 'Root has one named application launcher')
check(all(p.name in ('Start CT QA Manager.cmd', 'Update CT QA Manager.cmd', 'Apply CT QA Network Update.cmd') for p in launchers), 'Only named application, update and private network setup launchers are present')
for path in launchers:
    text = path.read_text(encoding='utf-8-sig')
    check('-STA' in text.upper(), 'Launcher uses an STA for WPF')
    check(not re.search(r'(?i)-ExecutionPolicy|Set-ExecutionPolicy', text), 'Launcher preserves execution policy')
    check('pause' in text.lower(), 'Launcher keeps startup errors visible')

network = root / 'App' / 'Network.psm1'
if network.exists():
    text = network.read_text(encoding='utf-8-sig')
    check('SecureStringToGlobalAllocUnicode' in text and 'ZeroFreeGlobalAllocUnicode' in text,
          'Credential native buffer has paired secure allocation and clearing')
    check('WNetAddConnection2W' in text and 'WNetCancelConnection' not in text,
          'Network implementation adds connections without a disconnect API')

print(json.dumps({'checks': checks, 'failed': len(failures), 'failures': failures,
                  'scope': 'Static package checks only. Windows execution and WPF rendering require Windows.'}, indent=2))
sys.exit(1 if failures else 0)
