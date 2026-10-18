# Fox Find

Read README.md, NOTICE.md and docs/DEVELOPMENT.md. This is an independent MIT
derivative of Oil Find; preserve upstream and dependency notices. App code uses
Swift 5 language mode, AppKit/SwiftUI and an optional local llama.cpp helper.

- Keep Chinese/English UI copy in sync. Avoid per-entry heap work in search loops.
- Do not commit models, indexes, credentials, build output or personal file fixtures.
- Use synthetic data and DEBUG snapshots for UI checks, not the user's disk.
- Build the pinned runtime before Swift; run affected tests and distribution checks.
- Do not change private/public visibility, enable Pages, activate funding or publish
  a public release without the maintainer's explicit instruction.
- Avoid unrelated edits. No installation or permissions changes during packaging.

- GitHub Release descriptions are version changelogs only: additions, improvements
  and fixes. Keep licensing, attribution, installation and validation details in
  the project documentation, not in the Release body.

## UI contract

Before any UI change, read `docs/UI-DESIGN-SYSTEM.md`. The approved native main
window is the visual baseline. Use Theme tokens, PanelSurface, GlassSection,
GlassButton, GlassListRow and existing ChromeButton/scroll components; do not
invent a feature-specific palette or plain system-form layout. App-owned surfaces
are dark neutral-gray glass, with matching title bars and clear action hierarchy.
Update the design contract and shared component together when introducing a new
pattern. Record bilingual synthetic native screenshots and actual interaction
checks for affected flows; compilation or screenshots alone are not UI acceptance.
