# 0.0.1 builds 31–32 — Claude navigation and bounded metadata search

Local candidate only. This work does not authorize publishing a release.

## Changes and evidence

- Claude Gateway stores native Code session descriptors in `Claude-3p/claude-code-sessions`. The prior importer read only `Claude/claude-code-sessions`, losing the link between desktop and CLI IDs. Both roots are now discovered and watched. Duplicate descriptors use the latest activity timestamp. Existing `local_…` sessions use their original native route; no resume-import/fork is performed.
- Removed the preview toggle. File list mode automatically displays the right preview at widths of at least 850 points; grid and narrow windows retain their full result area. A legacy disabled preview preference no longer overrides this behavior.
- A live sample of the old broad capture-date query showed serial ImageIO metadata reads, with additional cache-write and date-parse cost. The UI displayed no matches while hundreds of thousands of candidates were still unchecked.
- Metadata checks now use a shared pool of at most four readers and a four-second interaction budget. Progress snapshots distinguish running, paused and complete. Resuming retains the same source snapshot and checked prefix. New input cancels delivery; late readers cannot mutate delivered results. Filesystem events do not automatically restart a paused scan.
- Previously cached capture-date candidates are checked first, then every other candidate remains eligible. Cache hints never bypass current-file validation; displayed results retain their requested sort order. Cache query prioritization is capped at 10,000 hints, not at 10,000 results.
- Unreadable or absent capture dates remain unknown. Modification times and another year's dates are never silently substituted. Unqualified months remain the displayed current-year filter.

## Validation

Synthetic tests cover Gateway transcript-to-desktop mapping, Return dispatch, descriptor removal, existing provider lifecycle cases, list/grid layout, real EXIF boundaries, bounded reads/cancellation/resume, late callbacks, stale cache candidates, sort preservation and incomplete-result UI.

A 400-file synthetic JPEG comparison uses the same files, separate empty metadata caches, and alternating serial/concurrent execution order. Initial four runs: serial 109/203/154/128 ms; concurrent 68/80/75/73 ms. Median approximately 141 vs 74 ms. This is not a benchmark for a cold full disk or large HEIC/RAW libraries.

Final automated, package, installation and native-client results are recorded below after completion.

## Remaining boundaries

A cold full-library EXIF inventory still requires reading files and is not an instant indexed query. Partial coverage is explicit and resumable. Native metadata calls already running cannot be forcibly interrupted; the reader pool remains bounded and old callbacks are discarded. Missing permissions/metadata are not repaired by this change. Pure terminal-only sessions without a native descriptor retain preview/copy-resume behavior. This candidate does not clear the previously documented APFS unmount, Quick Look first-frame, or all-device performance acceptance gaps.

## Final local code validation

- Targeted regression: 73 tests, 69 passed, 4 opt-in cases skipped, zero failures. Includes native Quick Look fallback open/close teardown and EXIF fixtures.
- Metadata benchmark was separately opted in and passed. An early deadline test was adjusted from a scheduler-fragile 70 ms window to 250 ms; deadline, cancellation, bounded concurrency and resume assertions remain enforced.
- Enabling default inline preview exposed a Quick Look teardown assertion in the first stress run (`QLPreviewView deactivate` during deinit), together with >250 ms view switches. Fixed single-owner close lifecycle; image inline previews now use a bounded background ImageIO downsample and a 24 MiB cache instead of loading Quick Look on each selection.
- Repaired 40-cycle interaction workload passed: switch P95 69.81 ms, max 134.49 ms; search-ready P95 44.77 ms; warm memory growth 0.39 MiB. Quick Look window-open measurement 201.54 ms is **not** an image-first-frame measurement. A native NSLayoutConstraint warning from the separate Quick Look panel remains recorded; no recurrence of the teardown abort.
- Isolation and distribution checks passed. No personal fixture data, transcripts, models, keys or indexes are included in tracked outputs.

## Installed build 31 verification and follow-up

- Package, installed app and build output matched across 59 files. Archive SHA256: `61fb11eb33adddb88f0fe5ea2ced9fc344373535e7a7eee01bea3dbfdc0b6555`. Strict code-signature verification and isolated packaged install/rollback passed.
- Native UI: with Claude already showing a different conversation, Return on a Fox Find Claude result navigated to the intended existing session. Both the destination header and native `local_…` route were verified. Personal titles and IDs are omitted here.
- Native capture-date search returned 213 matches for an explicit prior-year July query, with a visible partial-coverage status. This is an observed partial result count, not a full-disk completeness claim.
- Reopening the accessory app could still restart a paused scan when pending refresh flags or index versions had changed. Build 32 preserves the paused snapshot on activation, and rechecks the paused state inside queued refresh callbacks. Explicit Continue still validates the source snapshot before resuming. A synthetic regression covers index-version changes, view switches, reopens, new queries and clear.
