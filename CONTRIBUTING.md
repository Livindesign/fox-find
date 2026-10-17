# Contributing

Focused fixes are welcome: reproducible search bugs, accessibility, Chinese/English
copy, performance measurements and compatibility reports are especially useful.

1. Check existing issues. Describe the expected behavior and a small synthetic
   example, without uploading private files or index databases.
2. For a large change, open an issue first. For a focused fix, send a PR with the
   behavior change and relevant validation.
3. Follow [development instructions](docs/DEVELOPMENT.md). Keep UI copy bilingual
   in `L10n.swift`; keep per-file allocations out of search hot loops.
4. Run relevant tests and `python3 scripts/check-distribution.py`.

Preserve third-party notices. Identify copied/adapted source and its license.
Do not include proprietary upstream modules, vendor app binaries, model weights,
personal indexes, payment secrets or credentials. Contributions are accepted under
this repository's MIT license; contributors must have the right to submit them.

Use a respectful tone and keep reports about the behavior, not the person.
Please do not add unrelated features to a bug-fix PR.
