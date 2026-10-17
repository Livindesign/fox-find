# Build 25: grid icons, previews and actions

Apple silicon, macOS 27.0.1; Fox Find 0.8.6, build 25.

## User-visible changes

- Grid fallback icons use the same file-type resolver as lists, including colorful Office/PDF icons, folders and application bundles. Missing paths retain their known type icon.
- Loaded thumbnails take priority over delayed icon callbacks and survive scrolling/favorite refreshes. Folder captions say Folder rather than zero bytes.
- ImageIO downsamples visible photos off the main thread on a bounded two-worker queue. Metadata and Quick Look use separate bounded queues, so video details or document providers cannot hold up photos. Unsupported images still fall back to Quick Look.
- Preview eligibility uses local file flags without synchronous FileProvider resource queries. Cloud-only files keep their icon without requesting a download.
- The actions menu removes its search field, adds an adaptive soft shadow and subtle edge, and retains arrow/Return/Escape navigation and action shortcuts. Its table uses plain styling to keep row corners and shortcuts inside the viewport.

## Thumbnail latency

The opt-in `GridIconTests.testVisibleImageThumbnailLatency` creates 12 new 4032 × 3024 JPEG fixtures outside the user's folders, displays one grid viewport and measures from scroll settlement to the actual thumbnail replacing the icon. It uses fresh paths each run and also checks cached image identity after another scroll cycle.

| Measure | Before preview pipeline change | Final build 25 |
| --- | ---: | ---: |
| First thumbnail | 54.58 ms | 22.54 ms |
| Sixth thumbnail | 122.27 ms | 33.41 ms |
| All 12 thumbnails | 190.30 ms | 43.92 ms |
| Cached visible refresh | 0.58 ms | 0.55 ms |

All 12 previews completed about 77% sooner in this local synthetic-photo workload. This is not a guarantee for network volumes, large RAW files, third-party document providers or every device. Existing previews are reused immediately; cold work remains deferred during a scrolling gesture.

## Scrolling and verification

The unchanged 300,000-entry workload from build 24 was repeated after the preview changes. Main-thread work P95: all-list 4.52 ms, all-grid 10.86 ms, app-list 5.56 ms, app-grid 11.06 ms. It recorded one main-loop interval over 25 ms in all-grid and zero in the other cases. These timings are not display FPS; the larger baseline comparison remains in `2026-10-17-scroll-build24.md`.

- 51 affected tests: 49 passed, 2 optional skipped, zero failures.
- After the final missing-path fallback and plain-menu layout fixes: 33 tests, 31 passed, 2 optional skipped, zero failures, including the thumbnail workload again.
- Coverage includes unavailable/offline previews, app icons, actual image decoding, thumbnail persistence, arrow/Return/Escape behavior, disabled actions, unchanged main query, favorites, grid layout, fade/scrollbar behavior and large-result scrolling.
- Native dark Chinese and light English grid/action snapshots were inspected.
- Signed archive installation and rollback pass in an isolated directory.
- Isolation, distribution and whitespace checks pass. Package/install evidence is recorded locally with hashes after packaging. No public Release was created.

Commands:

```sh
CI=true FOX_THUMBNAIL_WORKLOAD=1 FOX_SCROLL_WORKLOAD=1 swift test --filter 'GridIconTests|FoxPolishTests|SearchExperienceTests|AssetWorkspaceTests|FrostedInterfaceTests|ScrollWorkloadTests'
CI=true FOX_THUMBNAIL_WORKLOAD=1 swift test --filter 'GridIconTests|FoxPolishTests|SearchExperienceTests'
FOX_FIND_RELEASE_ID=0.8.6 bash scripts/package.sh
```
