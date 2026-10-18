# Build 40 window flows and collection feedback

## Scope

Fix collection/search/preview window ownership, covered-list hover, inconsistent native menu icons, verbose failure states, and duplicate collection footer text. Keep neutral-gray glass and bilingual labels. No search/index/model behavior changes or public release.

## Evidence

- Affected suites: `WindowFlowTests`, `WorkflowToolsTests`, `PreviewKeyTests`, `ApplicationMenuTests`, `SearchEditingTests`: 28 tests passed, 0 failures. Final keyboard-scope adjustment reran `WindowFlowTests`: 6 tests passed, 0 failures (the same six, not additional cases).
- Checks cover return to the originating search and preserved query, stale close-callback cancellation, collection shortcut and copy routing, covered-result hover state, recursive menu icon presence, status layout bounds, collection persistence/export and editing shortcuts.
- Bilingual synthetic snapshots: `build/ui-polish-build40/{collection,status,original}-{zh,en}.png`. Checked dark neutral-gray layout, clipped content, footer spacing, and button hierarchy.
- Native synthetic app: open collection with Command-Shift-B; reopen search; Command-Y image preview; Space closes to search, without resurrecting collection. Command-W on collection returns to search. Native copy action replaces default footer text in place.
- Native filter menu verified icon rendering. SF Symbol-backed menu images initially existed in the data but were omitted by this macOS menu renderer; rendering small template bitmaps fixed the visible icon column. Screenshot: `build/ui-polish-build40/native-filter-menu.png`.
- Native collection copy state screenshot: `build/ui-polish-build40/native-collection-copied.png`.
- Distribution check passed after the commit: 338 tracked distribution files, notices and sensitive-file patterns checked. Generated assets, samples, logs and application builds remain ignored.
- Installed the full build 40 at `/Applications/Fox Find.app`, retained a build 39 rollback copy, and verified signing. The full search window was visibly opened; its collection button opened the collection with both existing items intact and the single footer message. The user resumed interaction, so further UI automation stopped.

## Limits

Native interaction used six synthetic fixtures; no repeated full-library scan or model workload. This is not a claim that all historical search, source-client navigation, first-install permission restart or public update issues are resolved. Menu hover ownership has automated state coverage; arbitrary pointer trajectories and every third-party Quick Look provider have not been exhaustively exercised. Build 40 is a local candidate only.

Build/install hash and native full-app launch receipt: ignored local file `build/integrated-build40-receipt.json`.
