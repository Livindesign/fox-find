# Build 26: permission relaunch and interaction polish

Fox Find 0.8.6, build 26; Apple M1 Pro, 16 GB, macOS 27.0.1.

- A one-shot external companion is armed before the app opens Full Disk Access settings. It waits up to ten minutes for the original process to exit, gives macOS a short grace period to reopen it, then invokes Launch Services without requesting a new instance. Private temporary tickets cancel on explicit app Quit, system shutdown notification, starting a replacement permission flow or successful updater handoff. No login item, launch agent or TCC change is installed.
- Relaunch arguments bring the search window back for returning users; first-time users retain the welcome flow.
- File actions highlight the row under the pointer without reloading the table. Keyboard navigation continues from that row and skips unavailable actions. Pointer movement alone never executes an action.
- Footer Actions uses the same native label styling and keycap colors as the other hints. Semantic color alpha is preserved.
- The detached guide matches its parent window's height and vertical bounds, including move/resize notifications. Small screens retain the existing compact presentation.
- README screenshots use six fictional entries in a virtual directory. English and Chinese documentation includes the same feature views and measured performance, with reproducible generation and benchmark commands.

## Verification

- The initial affected suite ran 59 tests: 58 passed, one optional guide benchmark skipped, no failures. The opt-in synthetic filename benchmark passed separately.
- Final action/footer/relaunch regression: 37 tests, 35 passed, two optional performance checks skipped, no failures. The footer width check covers both languages.
- Relaunch subprocess tests cover parent still running, exit followed by exactly one open, explicit cancellation, expiry, grace-period cancellation and paths containing shell metacharacters.
- A separate native Launch Services exercise reopened an isolated synthetic `.app` after its watched parent exited. No user app was terminated and no permission settings were changed in that exercise.
- The actual macOS Full Disk Access toggle/quit dialog was **not** replayed: the user's existing privacy settings were preserved. That exact OS interaction and other macOS versions remain manual acceptance boundaries.
- Hover events and keyboard transitions were delivered only to fixture views. Detached guide top/bottom alignment was checked at three parent heights. Native screenshots were reviewed in dark/light appearance and both languages.
- Package signature, ZIP integrity, isolated update install/rollback and final installed-file hashes are verified separately during delivery. No public Release is published by these checks.

Performance data and scope: [PERFORMANCE.md](../PERFORMANCE.md).
