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

During interactive development on the user's Mac, run only the affected suite with
`nice -n 15 env CI=true swift test --jobs 1 --filter <SuiteName>`. Do not run the
full suite and performance workloads concurrently or repeatedly rerun a failed
benchmark until it passes. Stop task-owned workloads when the user reports lag;
preserve indexes and downloaded models. Use simulated time and small synthetic
fixtures for scheduling checks. Large result sets, real models and frame-time
benchmarks belong in a separate acceptance session after resource pressure has
settled; they are not routine checks after every edit.

The app is written to `build/release/Fox Find.app`. Packaging creates an arm64 ZIP
and checksum file under `dist/`; it does not install, replace, or delete any app.
`--debug` builds permit isolated `--snapshot` rendering; release builds do not.
`LOCALFIND_SIGN_IDENTITY` can select a local signing identity; default is ad-hoc.
Setting that variable alone does not perform notarization.

## UI design contract

Read [UI-DESIGN-SYSTEM.md](UI-DESIGN-SYSTEM.md) before changing or adding an
interface. It records the approved visual language, shared components, interaction
rules and acceptance checklist. Native dark neutral-gray glass applies to new
features as well as the search window. See [workflow validation](validation/2026-10-18-workflow-tools.md)
for the current local acceptance boundary.

## Modules

| Directory | Responsibility |
| --- | --- |
| `Sources/COilFind` | Upstream-derived C matching and directory primitives |
| `Sources/OilFindCore` | Filename index, queries, events and persistence |
| `Sources/OilFindApp` | Native AppKit UI; bilingual `L10n.swift` |
| `Sources/LocalFindContent` | Content extraction, SQLite indexes, semantic integration |
| `Sources/FoxFindSemanticCore`, `Sources/LlamaRuntime`, `Sources/SemanticWorker` | Shared model contracts and isolated embedding helper |

Some upstream update-library code remains for provenance/tests. From 0.8.6,
UpdateManager uses Fox Find's own signed GitHub release feed. The upstream update
client is not called by the product. `scripts/verify-isolation.py` checks this boundary,
the pinned release key and independent app/data identity. See [updates](UPDATES.md)
for release signing and hosting.

## Repository contents

The public repository includes application code, tests, licenses, build scripts and
user/developer documentation. The website and internal design/marketing drafts are
maintained privately outside this repository. App ZIPs contain neither tests nor website files.

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
