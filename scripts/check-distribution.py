#!/usr/bin/env python3
"""Check the selected source tree before publication; never inspect user data."""
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
files = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root).decode().split('\0')
errors = []
for name in filter(None, files):
    path = root / name
    if path.is_symlink():
        errors.append(f'Unexpected source symlink: {name}')
    if not path.is_file():
        continue
    if path.is_symlink() or any(x in path.parts for x in ('Vendor', '.build', 'Pro')) or path.suffix in {'.gguf', '.oilfind', '.sqlite', '.db', '.p12', '.key'}:
        errors.append(f'Unexpected distribution file: {name}')
    try:
        body = path.read_text()
    except UnicodeDecodeError:
        continue
    checks = [r'github_pat_[A-Za-z0-9_]{20,}', r'gh[pousr]_[A-Za-z0-9]{30,}',
              r'sk-[A-Za-z0-9_-]{30,}', r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
              r'/Users/[^/\s]+/(?:Documents/Codex|Desktop/CODE)/']
    if any(re.search(pattern, body) for pattern in checks):
        errors.append(f'Potential credential or personal development path: {name}')

for name in ('LICENSE', 'NOTICE.md', 'THIRD-PARTY-NOTICES.md', 'LICENSES/Oil-Find-MIT.txt',
             'LICENSES/DigUp-MIT.txt', 'LICENSES/llama.cpp-MIT.txt', 'PRIVACY.md'):
    if not (root / name).is_file():
        errors.append(f'Missing notice: {name}')
if 'Copyright (c) 2026 Lin Zhihuang' not in (root / 'LICENSE').read_text():
    errors.append('Original copyright missing')
for name in ('scripts/install.sh', 'scripts/uninstall.sh', 'scripts/create-signing-cert.sh'):
    if (root / name).exists():
        errors.append(f'Unreviewed lifecycle script: {name}')
if errors:
    raise SystemExit('\n'.join(errors))
print(f'PASS: {len([f for f in files if f])} distribution files; notices and sensitive-file patterns checked')
