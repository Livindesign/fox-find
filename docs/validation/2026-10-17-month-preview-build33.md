# 0.0.1 build 33 — month search and preview interactions

Local candidate, installed and exercised on the development Mac. No repository
visibility, GitHub Release or update-feed changes were made in this iteration.

## Behavior

- A month without a year, such as `七月拍摄的照片` or `7月拍摄的图片`, searches
  that month across all years. An explicit year, `今年` or `去年` remains an exact
  year constraint. Capture dates come from media metadata; modification dates do
  not substitute for missing capture dates.
- The persistent metadata cache now indexes capture date and month instead of
  parsing every cached JSON record to find priority candidates. Prepared read and
  write statements are reused. Cached candidates still undergo file validation;
  uncached files remain eligible.
- Productive metadata scans continue across four-second work slices automatically.
  The four-reader concurrency limit and cancellation remain enforced. Three
  consecutive slices with no progress pause stalled I/O with an explicit resume
  action. Opening a menu or reactivating the window preserves checked progress.
- File lists use the full result width. Selection no longer starts an inline
  preview. Space or Command-Y opens a separate preview.
- Space, Escape and Command-Y close read-only previews. Editable find fields keep
  their normal Space input. Preview handling is scoped to the owning window.
- Clicking outside the action panel dismisses it without consuming the underlying
  click. Filter hover and selected backgrounds share the same corner radius.

## Verification

- Final affected regression: **73 cases, 71 passed, 2 opt-in cases skipped, zero
  failures**. Covers date parsing, real EXIF boundaries, cache migration and stale
  hints, continuous progress, cancellation, bounded readers, full-width layout,
  action-panel dismissal, preview keys, clear/edit behavior and stable results.
- The skipped cases are the optional metadata benchmark and multi-language visual
  snapshot export. The metadata benchmark was run separately; native UI checks
  below cover this iteration's concrete interactions.
- Earlier combined run: 71 cases, one skipped and one fixture-setup failure. The
  failing keyboard test cleared its search because it had no fixture source after
  an input-change callback. Its source setup was corrected and the affected suite
  passed in the final run; the earlier log is retained.
- Packaged install/rollback passed. ZIP integrity and strict code-signature checks
  passed. Build output, ZIP and installed app match across **59 files**.
- The process used for native verification was confirmed to execute the newly
  installed bundle, not the retained previous-version backup.

### Installed native app

All result fixtures were synthetic. Three JPEGs have real EXIF capture dates in
July 2024, July 2026 and August 2026; PDF and text fixtures exercise preview types.

| Scenario | Observed result |
| --- | --- |
| `七月拍摄的照片` in the synthetic folder | Two July images, checked 3/3; August excluded |
| `2026年七月拍摄的照片` | One image from July 2026, checked 3/3 |
| Switch all-July results from list to grid | Same two images and completed count |
| JPEG, PDF and text: Space, then Space again | Preview opens, then closes back to search |
| Open action panel, click main-window blank area | Panel dismisses; no action executes |
| List with selected result | Full-width list with no automatic preview column |
| Finish verification | Cleared query and restored All Locations/list view |

Conversation and content-preview windows use the same window-scoped keyboard
handler tested with read-only text. This iteration did not reopen personal
conversations for UI verification.

## Measured performance and limits

| Measurement | Result | Scope |
| --- | --- | --- |
| Date candidate lookup, 200,000 synthetic cached records / 200 matches | Median 40.35 ms before, 0.52 ms after | SQL query only; indexed query plan verified |
| One-time index construction for that fixture | 113.21 ms | Synthetic SQLite cache |
| 400 synthetic JPEGs, cold metadata cache, four concurrent runs | Before 55.78–62.92 ms; after 52.95–60.07 ms | No material full-scan speedup established |
| 40-cycle synthetic list/grid and search workload | Switch P95 130.56 ms, maximum 201.19 ms; search-ready P95 19.76 ms | Synthetic interaction workload, not a cross-version comparison |
| Warm memory growth in that workload | 0.08 MiB | Sampled process footprint |
| Quick Look window open in that workload | 624 ms | Window-open timing, not image first-frame latency |
| Combined/content modes in list/grid | 0 empty-result flashes across 40 samples per combination | Deterministic regression fixture |

The indexed SQL improvement is **not** a whole-disk latency claim. The first scan
still reads uncached media metadata and can take time on large libraries or slow
storage. This iteration did not complete a cold scan of the user's entire image
library, measure Quick Look first-image latency, or clear earlier APFS unmount and
multi-device acceptance gaps. Missing permissions or EXIF remain explicit unknowns.

## Local artifacts

Ignored evidence directory: `build/acceptance-ai/build33/`. Contains regression,
stress and package logs, synthetic cache benchmark, installation receipt and
synthetic native screenshots. No private result data is included in this report.

- App version: **0.0.1 (33)**.
- Archive: `dist/Fox-Find-0.0.1-macOS-arm64.zip`.
- Archive SHA256: `7c1ed9023fef1ab029e7639830710e97cacd29fbff551221505f6e3d4ed5f0a3`.
- Binary SHA256: `b085a3edab2255c3055e3cb1ddadb9cf8037c5063a7524212afb4b5da816416c`.
- Prior installed app retained in the ignored `build/install-backups/` directory.
