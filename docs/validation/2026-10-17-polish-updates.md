# Fox Find 0.8.6 build 23 — verification

## Changes

- Actions palette: 350 pt Chinese / 390 pt English instead of 520 pt; shared glass surface,
  rounded selection, 42 pt rows, transient scrollbars, reusable cells and cached search terms.
- Menu bar: template silhouette of the original leaping fox; white on a dark menu bar.
- Onboarding: dismissal persists across launches. Explicit replay does not re-enable automatic appearance.
- Images: decode thumbnails at the required display resolution instead of decoding full-size artwork.
- Updates: Fox Find's own GitHub Releases feed, Ed25519 manifest signature, SHA-256/size binding,
  strict app validation, background installation, launch confirmation and rollback. No personal server.

## Tests

On Apple silicon, macOS 27.0.1 / Swift 6.2.3, Swift 5 language mode:

- Full suite: **316 tests; 287 passed, 29 conditional skips, zero failures**.
  Conditional skips cover optional real-model/device/fixture-export and timing-dependent tests.
- The final shared settings-scrollbar change passed **25 targeted UI tests**, including a newly added
  full-content scrolling check. This follow-up is reported separately from the full-suite run.
- The existing menu test was updated to expect one visible Check for Updates entry; the hidden
  available-update entry is separate. Earlier failed assertions are not counted as successful runs.
- Real GitHub download: fetched the existing public 0.8.3 archive using the new streaming downloader,
  followed GitHub redirects and verified the repository-reported SHA-256 and size. It was not installed.
- Two additional integration checks passed on the final build 23 archive: live GitHub transport and isolated installation/rollback.
- Actual 0.8.6 package: authenticated its signed manifest, verified/extracted its real app archive,
  installed in a temporary directory and restored an older fixture. `/Applications` was not used by this test.
- Update error cases: tampered manifest, wrong signing key, foreign repository, wrong architecture,
  insecure redirects, archive corruption, version mismatch, failed replacement and rollback receipts.
- UI regressions include action filtering/execution, bilingual widths, remembered guide dismissal,
  preview cancellation, result stability and unchanged-results refresh suppression.
- Native dark/light action palette snapshots and onboarding artwork inspected.
- Installed app: white fox menu-bar icon captured; closing onboarding, restarting the actual app
  and reopening search leaves the guide hidden. Native Check for Updates opens and handles the currently absent stable feed.
- App/helper signatures, archive integrity, license resources and installed/source/archive binary hashes match.
- Application ZIP contains no Tests, site, Git metadata, indexes, database or release private key.

## Input and scrolling fixes (build 22)

- Guide reading pages stay pinned to the user's navigation. Result availability, query clearing,
  opening actions and completed searches no longer replace the text, remove buttons or turn the page.
  The actual content setup flow remains event-driven after an explicit setup action.
- Native child-guide windows no longer resize, reorder or repaint on every unchanged parent layout.
- File-type icon resolution (Launch Services) runs off the main thread. File icons and thumbnails use
  two bounded workers, small cached images and relevance checks before I/O and before delivery.
- During scrolling, expensive grid previews pause, and semantic background indexing yields.
  Visible previews resume after scrolling stops; selection and viewport preservation are unchanged.
- Repeated selection layouts do not reset the inline preview; hidden search windows skip status UI polling.
- The update window uses the existing app icon and native glass. No-update state has “我知道了”.
  Available-update state offers “跳过此版本”, an automatic-check toggle and “现在更新”.
  The toggle explicitly says checks are daily and installation still requires confirmation.

## Application icons, settings and scrollbars (build 23)

- App grids resolve the actual application icon using the background icon provider, with 256 px
  cached representations. App bundles bypass document thumbnails and display “App” instead of zero bytes.
  A synthetic app with a distinct custom icon is verified through the real grid renderer.
- Menu-bar commands use consistent 16 pt template glyphs with labels, shortcuts and state preserved.
- Settings uses the same neutral native glass as search, softer grouped panels, aligned controls and
  less redundant polling. Chinese/dark and English/light, the bottom section, language selection,
  shortcut recording and excluded-extension editing remain usable. Settings also adopts the same
  thin, idle-hidden scrollbar instead of the system legacy bar.
- Filter anchors retain 16 pt content padding and 4 pt inter-control gaps. Category icons are cached views.
- Scroll thumbs are 4 pt wide, inset from the edge and drawn at 24–27% opacity for light/dark backgrounds.
  Native hit targets stay wider. Regression checks cover top/middle/bottom tracking and idle hiding.
- Result and preview frames previously overlapped by 2 pt; they now have a 12 pt separation.

## Fixed-scenario performance

Same synthetic fixtures: build 21 baseline versus the final build 23 source. Timings are AppKit update/draw work,
not display FPS, GPU frame pacing or whole-disk search latency. macOS 27.0.1 on this Mac.

| Scenario | Before P95 ms | After P95 ms |
| --- | ---: | ---: |
| 100 results, list, guide off | 1.674 | 1.179 |
| 100 results, list, guide on | 1.432 | 1.108 |
| 100 results, grid, guide off | 1.476 | 1.587 |
| 100 results, grid, guide on | 1.491 | 1.404 |
| 1,000 results, list scrolling | 1.164 | 1.152 |
| 1,000 results, grid scrolling | 0.993 | 1.149 |
| 1,000 results, list with refresh | 1.148 | 1.063 |
| 1,000 results, grid with refresh | 1.030 | 1.108 |

Small mixed deltas include measurement noise; no universal scrolling speedup is claimed.
Every measured scenario stays below the 16.7 ms test budget. The substantive latency fix is
removing synchronous cold icon lookup from scrolling, not reducing already-small warm timings.

A deterministic slow-icon test submits 40 cold types in **0.153 ms** on the main thread;
39 stale requests are discarded before resolution and only the live request reaches the injected
50 ms resolver. This tests scheduling/cancellation, not actual Launch Services speed.

Guide input regression: 100 result-clear/result-return/action cycles preserve the selected tip and
its copy. Four content search stability cases show **0/40 spurious empty states and zero grid reloads**.
Decoded guide artwork footprint remains **25,164,432 → 3,295,744 bytes (−86.9%)**; this measures
illustration bitmaps, not application RSS. Older devices and display-level frame pacing need separate validation.

## Delivery boundary

The local installed app is 0.8.6 build 23. The signed ZIP and update manifest are generated under `dist/`.
Automatic checking and in-app installation are implemented, but a new public GitHub Release must carry
both assets before users can receive this version through the feed. The current public 0.8.3 preview
needs one manual upgrade because its updater was disabled. Full remote old-to-new relaunch acceptance
is pending publication; local installer/rollback and real GitHub transport are independently verified.

Website and internal design/marketing drafts are kept outside the public source tree. Tests, notices,
user/developer docs and this concise verification record remain public. Historical public commits are not rewritten.
