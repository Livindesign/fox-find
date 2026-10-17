# Onboarding validation — 0.8.4 build 18

2026-10-17 · Apple silicon · macOS 27.0.1 · Swift 6.2.3

`FOXFIND_GUIDE_PERF=1 CI=true swift test`: 292 tests, 263 passed, 29 skipped, 0 failures. Skipped model/hardware/opt-in tests are not passes.

| Synthetic rendering, P95 | Guide off | Guide on |
| --- | ---: | ---: |
| List | 3.40 ms | 3.44 ms |
| Grid | 4.54 ms | 4.42 ms |

Same synthetic 100-file fixture, 100 measured scroll/layout/display samples per mode after warm-up, debug build, same machine and run. These values are UI-processing measurements, not a claim about display refresh rate or every user's library. Differences this small are run-to-run noise.

- 100 guide status changes in each view: zero added grid reloads; selection and scroll unchanged.
- Existing content/semantic refresh stability: 0 empty flashes in 40 samples for each of the four mode/view combinations.
- Verified first-index publication before the pass finishes, with at most one early results notification per pass.
- Verified upgrade/skip persistence, real-result progression, editor focus, IME/Escape, native button key handling, compact 680×500 layout and action/syntax coexistence.
- Reviewed native dark/light and Chinese/English snapshots, including folder selection, indexing, ready, paused and error states. Settings state previews use synthetic aggregate status.
- Release app/helper built and signature integrity, ZIP integrity, distribution and independence checks passed.

No new global keyboard event monitor, cloud request or analytics is introduced. System permission-dialog behavior on other Macs, full VoiceOver reading order, and older macOS hardware remain manual acceptance boundaries. GitHub publication is separate.

Installed locally as Fox Find 0.8.4 build 18. Native accessibility inspection confirmed the Settings version, replay entry, step-one card and search-field focus. The previous app bundle was retained for rollback. The nonactivating search panel was unavailable to a later desktop screenshot capture; visual checks use the isolated native snapshots described above.
