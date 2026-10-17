#!/usr/bin/env python3
"""Render native README screenshots from six fictional index entries, without scanning a disk."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
subprocess.run(['swift', 'build', '--product', 'FoxFind'], cwd=root, check=True)
binary = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip())
output = root / 'docs/assets/screenshots'
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='foxfind-demo-') as temporary:
    work = Path(temporary)
    fixture = work / 'fixture.swift'
    fixture.write_text('''import Foundation
import OilFindCore
let names = ["", "2026 Product plan.pdf", "2026 Brand guidelines.docx", "2026 Budget.xlsx", "2026 Launch deck.pptx", "2026 Moodboard.png", "2026 Resources"]
var b = ScanBuffer()
b.ids = (0..<names.count).map(UInt32.init); b.parents = Array(repeating: 0, count: names.count)
b.sizes = [0,2400000,810000,47000,18200000,3200000,0]; b.mtimes = Array(repeating: 1_790_000_000, count: names.count)
b.flags = [1,128,128,128,128,128,1]; b.depths = [0,1,1,1,1,1,1]; b.kinds = [1,3,3,3,3,4,1]
b.nameLens = names.map { UInt32($0.utf8.count) }; b.nameBytes = Array(names.joined().utf8)
let store = IndexStore(scan: ScanOutput(buffers: [b], count: names.count, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: "/Projects"))
try store.save(to: CommandLine.arguments[1])
''')
    objects = sorted((binary / 'OilFindCore.build').glob('*.o')) + sorted((binary / 'COilFind.build').rglob('*.o'))
    subprocess.run(['swiftc', '-I', str(binary / 'Modules'), '-I', str(binary / 'COilFind.build'), str(fixture), *map(str, objects), '-o', str(work / 'fixture')], check=True, cwd=root)
    database = work / 'demo.oilfind'
    subprocess.run([str(work / 'fixture'), str(database)], check=True)
    profile = work / 'profile'; profile.mkdir()
    environment = dict(os.environ, LOCALFIND_TEST_PROFILE=str(profile))
    for language in ['en', 'zh']:
        for name, appearance, state, extra in [
            ('search-dark', 'dark', 'results', []),
            ('grid-light', 'light', 'results', ['--grid', 'true']),
            ('actions-dark', 'dark', 'actions', []),
        ]:
            subprocess.run([str(binary / 'FoxFind'), '--snapshot', str(output / f'{name}-{language}.png'),
                            '--db', str(database), '--query', '2026', '--state', state,
                            '--appearance', appearance, '--language', language, '--inline-preview', 'false', *extra],
                           env=environment, cwd=root, check=True)
