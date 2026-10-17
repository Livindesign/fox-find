# Fox Find architecture

Fox Find is a native AppKit/SwiftUI macOS application, with a filename search core
derived from Oil Find's public MIT source and independently maintained content features.
See [NOTICE](../NOTICE.md) and [third-party notices](../THIRD-PARTY-NOTICES.md) for provenance.

## Modules

- `COilFind`: C matching, directory and low-level search primitives.
- `OilFindCore`: filename index, queries, persistence, filesystem changes and signed update installation.
- `OilFindApp`: native search panel, list/grid views, menus, settings, onboarding and update presentation.
- `LocalFindContent`: opt-in content extraction, OCR, PDF page references, SQLite storage and semantic search orchestration.
- `FoxFindSemanticCore`, `LlamaRuntime`, `SemanticWorker`: embedding contracts, local model runtime and isolated worker process.

The inherited module names are source compatibility names. The distributed application
is Fox Find, bundle identifier `app.localfind.desktop`. Data remains under the legacy
`~/Library/Application Support/Local Find/` directory to preserve existing indexes.

## Search and presentation

Filename matching returns indexed results first. Optional content and semantic search
can supplement them. Query generations and cancellation prevent stale asynchronous
results from replacing a newer query. Clearing input cancels pending work and empties
results. Matching mode and sort order are independent choices.

List and grid presentation preserve selection and scroll position while content arrives.
Visible cells and icons are reused; asynchronous thumbnails are bound to item identity.
Scroll gestures defer disruptive refreshes. In-panel PDF/Quick Look previews load on
selection, while action menus capture the selected file identity before execution.

The interface uses a shared neutral glass tint, original functional vector icons and
real file/application icons in results. Custom accent colors remain a user preference.
Motion respects Reduce Motion, glass respects Reduce Transparency, and keyboard handling
is scoped to the application. Onboarding dismissal persists across launches; replay is explicit.

## Content and privacy

Content indexing is opt-in per folder. Vision OCR, document extraction and optional
embeddings run locally. Model download, update checks and user-opened web links are the
network boundaries; see [privacy](../PRIVACY.md). The plaintext content cache is not a
backup of original files. Semantic results are experimental and depend on indexed content.

## Updates and delivery

From 0.8.6, a signed manifest and app ZIP are hosted in Fox Find's GitHub Releases.
Ed25519 verifies the manifest; SHA-256 and byte count bind the archive; code validation
and bundle/version checks verify extracted contents. Installation preserves a rollback
copy and confirms relaunch before cleanup. See [updates](UPDATES.md) for the exact workflow.

Packaging never installs the application or publishes a release. Private keys, indexes,
models, local build output, website files and internal marketing drafts are excluded
from source publication. Tests remain part of the open-source project.
