#!/usr/bin/env python3
"""Check the fork's installation/data identity and disabled upstream lifecycle hooks."""
import pathlib, plistlib, re
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
assert 'UpdateManager.shared.start()' in app
assert 'SystemUpdateFiles().cleanupAfterLaunch' in app
manager = (root / 'Sources/OilFindApp/UpdateManager.swift').read_text()
assert re.search(r'(?<!\w)UpdateClient\(', manager) is None
assert 'GitHubUpdateClient(publicKey:' in manager and 'signature: FoxUpdateSignature()' in manager
trust = (root / 'Sources/OilFindCore/Update/GitHubUpdateClient.swift').read_text()
assert 'https://github.com/Livindesign/fox-find/releases/latest/download/fox-find-update.json' in trust
assert 'isValidSignature' in trust and info.get('FoxUpdatePublicKey')
print('PASS: independent identity; Fox Find signed GitHub updates; upstream update/authorization hooks absent')
