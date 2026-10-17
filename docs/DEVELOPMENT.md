# Development and distribution

## Requirements

Apple silicon Mac; deployment target macOS 14; Swift 5.10+ in Swift 5 language
mode. Install Xcode or Command Line Tools, Git, CMake and Ninja. The local release
was built with Swift 6.2.3 on macOS 27.0.1. Older target versions still need hardware testing.

`bash scripts/build-llama.sh` downloads llama.cpp tag `b11461`, verifies commit
`4d756bc72bf00a4aacf410ae15a2d315f3db400d`, applies the included patch and compiles
static libraries under ignored `Vendor/`. If CMake is missing, the script's fallback
uses `uv` to install pinned CMake/Ninja into an ignored local environment.

```sh
bash scripts/build-llama.sh
CI=true swift test
python3 scripts/verify-isolation.py
python3 scripts/check-distribution.py
bash scripts/build-app.sh
bash scripts/package.sh
```

`CI=true` skips time-sensitive/real-machine tests. Real-model acceptance additionally
requires `FOX_FIND_TEST_MODELS` and `FOX_FIND_TEST_HELPER`; ordinary CI does not
download model weights. Never interpret skipped tests as passes.

The app is written to `build/release/Fox Find.app`. Packaging creates an arm64 ZIP
and checksum file under `dist/`; it does not install, replace, or delete any app.
`--debug` builds permit isolated `--snapshot` rendering; release builds do not.
`LOCALFIND_SIGN_IDENTITY` can select a local signing identity; default is ad-hoc.
Setting that variable alone does not perform notarization.

## Modules

| Directory | Responsibility |
| --- | --- |
| `Sources/COilFind` | Upstream-derived C matching and directory primitives |
| `Sources/OilFindCore` | Filename index, queries, events and persistence |
| `Sources/OilFindApp` | Native AppKit UI; bilingual `L10n.swift` |
| `Sources/LocalFindContent` | Content extraction, SQLite indexes, semantic integration |
| `Sources/FoxFindSemanticCore`, `Sources/LlamaRuntime`, `Sources/SemanticWorker` | Shared model contracts and isolated embedding helper |
| `site` | Static bilingual project page; no third-party JS or analytics |

Some upstream update-library code remains for provenance/tests, but the app's
UpdateManager hooks are disabled. `scripts/verify-isolation.py` verifies the
independent app/data identity and absence of active upstream update/license hooks.

## Website preview

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory site
```

Open `http://127.0.0.1:8765`. The source repository is public. GitHub Pages and external
website hosting are not enabled; website deployment is a separate maintainer decision.

## Release procedure

Build/test from the tagged source. Verify `codesign --verify --deep --strict`, ZIP
integrity, `LICENSES/` in the app bundle and hashes. Check the archive contains no
user database, downloaded model or secret. GitHub Release descriptions contain only
version-specific additions, improvements and fixes, matching CHANGELOG.md. Keep
installation, licensing, attribution and validation details in the project documentation.
Review all assets again before changing repository visibility.

## Hosted CI

A ready-to-enable macOS workflow is stored in `docs/ci-macos.yml`. Hosted Actions
remain disabled. After deciding to enable CI, move
it to `.github/workflows/ci.yml` with an appropriately scoped credential and enable
Actions. Local test results are not presented as a hosted CI run.
