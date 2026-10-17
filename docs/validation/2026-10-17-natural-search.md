# Natural-search correction — 2026-10-17

Local 0.0.1 build 28 candidate. Repository remains private; prior releases remain
drafts. This is scoped validation, not approval for public release.

## Reproduced causes

- `NaturalSearch` handled recent N days/today/yesterday, but no calendar month.
- Type extraction was behind a prior-condition guard, so `7月拍摄的照片` and
  standalone image descriptions could reach the semantic engine with no image predicate.
- Content mode could restrict filter-only queries to content-indexed files.
- Positive comparison matching could consume `超过10MB` inside `不超过10MB`.

## Corrections

- Calendar date parser: current/explicit/relative year, Arabic/Chinese month,
  validated day, calendar periods and rolling weeks/months. Gregorian calendar,
  current time zone; week starts Monday. Conditions display the year.
- Standalone type intent, residual descriptions and literal filename protection.
- Filter-only queries bypass content/semantic providers in all three matching modes.
- Guard unsupported dates/comparisons/exclusions before positive extraction;
  show a bilingual limitation message instead of approximate suggestions.
- Real EXIF only; unknown dates remain excluded with an explanation.
- Bounded compiled-regex cache, no query-time model needed for these filters.

## Verification

M1 Pro / 16 GB / macOS 27.0.1 / Swift 6.2.3 / Debug tests. Synthetic files only.

- Related suite: 79 tests, **75 passed, 4 optional skips, 0 failures**, 61.34 s.
  Includes real local-model Chinese retrieval, HEIC/image/document filters,
  PDF pages, cancellation, offline cache, OCR and search-state stability.
  Skips: fixture export, UI screenshot export, opt-in entry benchmark, existing-user-index benchmark.
- Final parser/condition-removal/negative-comparison pass: 19 tests,
  **18 passed, 1 screenshot-export skip, 0 failures**, 3.57 s.
  This also enables and passes the entry benchmark skipped above. Counts overlap.
- 500 warmed parser calls across five phrases: **P95 0.401 ms**, max 0.748 ms.
  This measures parsing only, not EXIF scan, result display or semantic inference.
- 5,000 shortcuts + 500 apps + parser/calculator, 200 inputs: **P95 8.351 ms**.
- Real JPEG EXIF fixture: current July photo, August photo misleadingly named July,
  previous-July photo, unknown-date photo, matching-text JSON. Combined/content/name
  modes each return only the current-July photo; unknown count is one;
  **zero semantic/content provider calls** for the filter-only query.
- Mixed `7月拍摄的红色照片` sends `红色 kind:image` to the semantic provider,
  preserving the exact EXIF predicate in the controller's metadata filter.
- Leap day, invalid dates, DST day (23 h), month/year boundaries, negative and
  unsupported comparison guards, filename literals and clear-query behavior covered.
- Existing four-mode background-refresh test: zero empty flashes in 40 samples
  for each mode and no redundant grid reloads.

Raw local logs: `/tmp/fox-natural-regression.log`, `/tmp/fox-natural-final.log`;
copies under ignored `build/acceptance-natural/`. No personal file inventory is included.

## Remaining boundaries

The screenshot's exact personal library was not replayed. There is no claim that
every July photo has metadata, or that semantic relevance is complete. Unsupported
phrases are documented in [NATURAL-SEARCH.md](../NATURAL-SEARCH.md). Typed metadata
indexes, general range/exclusion parsing, hybrid ranking and reranking are proposals.
This fix does not close the separate long-duration / cross-device release gates in
the [0.0.1 acceptance report](2026-10-17-0.0.1-acceptance.md).

## Packaged and installed candidate

- Built and signed the arm64 release app from source commit `3d3af178f93b8e8a9226001988a18ad49a7bae22`.
- Archive CRC, all 54 bundled-file hashes and strict code signature checks passed.
- Signed-package installation and rollback test passed in an isolated directory.
- Installed `/Applications/Fox Find.app`, version 0.0.1 build 28; launched and confirmed the installed executable remains running. This is a startup check, not a personal-library end-to-end result claim.
- ZIP SHA-256: `ccb78bf843995d837cb1b6892355b6eb87aa2b372917e462863c01a778f6862e`.
- Previous installed app retained under ignored `build/install-backups/`; detailed installation receipt under `build/acceptance-natural/installation.json`.
- GitHub repository rechecked PRIVATE; v0.8.6 and v0.8.3-preview.1 remain drafts. No new release was published.
