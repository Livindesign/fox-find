#!/usr/bin/env python3
"""Check the fork's installation/data identity and disabled upstream lifecycle hooks."""
import pathlib, plistlib
root = pathlib.Path(__file__).resolve().parents[1]
info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'app.localfind.desktop'
assert info['CFBundleExecutable'] == 'FoxFind'
assert info['CFBundleName'] == 'Fox Find'
assert info['CFBundleURLTypes'][0]['CFBundleURLSchemes'] == ['localfind']
for path in (root / 'Sources').rglob('*.swift'):
    text = path.read_text()
    assert 'Library/Application Support/Oil Find' not in text, path
    assert 'Library/Caches/Oil Find' not in text, path
    assert 'LegacyAuthorizationCleanup' not in text, path
    assert 'com.oiloil.find.trial' not in text, path
app = (root / 'Sources/OilFindApp/AppDelegate.swift').read_text()
assert 'UpdateManager.shared.start()' not in app
assert 'SystemUpdateFiles().cleanupAfterLaunch' not in app
manager = (root / 'Sources/OilFindApp/UpdateManager.swift').read_text()
assert 'UpdateClient(' not in manager and 'UpdateInstaller(' not in manager
print('PASS: independent identity, storage and lifecycle; upstream update/authorization hooks absent')
