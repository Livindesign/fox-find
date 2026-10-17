# Build 24: scrolling and settings

Validated on Apple silicon, macOS 27.0.1. Version 0.8.6, build 24.

## Changes

- Update settings: full-width title/switch row, description underneath, then the check button and version.
- Menu bar: the Chinese launch label is now “开机启动”; a native, accessible NSSwitch replaces the checkmark. The underlying service remains macOS Launch at Login.
- ResultScrollView explicitly opts into AppKit responsive scrolling. Before the fix, `isCompatibleWithResponsiveScrolling` returned false because the subclass overrides `scrollWheel`.
- Edge fading now belongs to the stationary viewport, with an opaque scrollbar gutter. The mask no longer moves with document bounds.
- Cold icon requests pause during a gesture. Cached icons remain usable; only visible rows are resolved after scrolling settles.
- Grid layout computes attributes for the requested viewport rather than using the full-dataset flow layout. Tile backgrounds use layer properties and unchanged selection does not trigger repainting.

## Repeatable scroll workload

`ScrollWorkloadTests` builds 300,000 synthetic index entries, including 1,500 application entries. No user directory is scanned. It opens native glass windows and performs 180 scrolling steps per case, flushing layer transactions and running the main loop between steps. Event objects are delivered directly to the fixture view, never posted to the system input queue.

| Scenario | Build 23 work P95 | Build 24 work P95 | Build 23 maximum | Build 24 maximum |
| --- | ---: | ---: | ---: | ---: |
| All results, list | 3.85 ms | 4.55 ms | 6.65 ms | 11.98 ms |
| All results, grid | 15.92 ms | 10.69 ms | 68.86 ms | 19.04 ms |
| Applications, list | 4.36 ms | 4.61 ms | 6.83 ms | 9.58 ms |
| Applications, grid | 12.65 ms | 11.17 ms | 18.13 ms | 17.27 ms |

The final run recorded zero main-loop intervals over 25 ms in all four cases; the baseline large grid recorded three. Large-grid work P95 fell about 33%. List CPU work did not improve in this workload; its main fix is restoring the native responsive scrolling path. These are main-thread update/draw/commit timings, not measured display FPS or a guarantee for every filesystem, machine or background workload. The fixture's app paths are synthetic; actual bundle icon loading has a separate regression test.

Sampling placed much of the scrolling work in backing-layer painting and commits. The reproducible workload, not the earlier short warm-cache loop, guided the rendering changes.

## Verification

```sh
CI=true FOX_SCROLL_WORKLOAD=1 FOXFIND_PERF=1 swift test
python3 scripts/verify-isolation.py
python3 scripts/check-distribution.py
FOX_FIND_RELEASE_ID=0.8.6 bash scripts/package.sh
```

- 321 tests: 291 passed, 30 optional tests skipped, zero failures.
- A follow-up last-item navigation check exposed a reveal problem outside the prepared grid region. Revealing its exact layout rect fixes it; the final polish/workspace/interaction suite passed all 32 tests. The DEBUG snapshot helper was also updated for the new layout class.
- Includes actual application-icon regression, grid selection/favorites, responsive scrolling, deferred cold icons, last-item grid layout, fade/scrollbar behavior, native menu switch actions and bilingual menu/settings behavior.
- Native dark Chinese and light English menu/settings snapshots checked.
- The signed ZIP's isolated install/rollback test passed; it never changes `/Applications`.
- Packaging and installation validation are recorded locally with the archive/binary hashes. No public GitHub Release was created for this build.
