# Lightweight workflow tools

Developed on `codex/workflow-tools-v1` from `18955d8` (local build 37 fixes).
Merged into local `main` at `f87cd19`; the complete app was installed and launched as
0.0.1 build 39 on 2026-10-18. Build 38 is a separate synthetic preview, not the installed full app.

This increment implements three explicitly invoked workflows: a cross-search collection,
an editable Markdown context pack made from selected conversation excerpts and file
references, and bounded image-original candidate comparison. No model is loaded, no
background scan is started, and no original is moved or deleted by these workflows.

Acceptance: persistence and deduplication, exact excerpt attribution, bounded/cancellable
I/O, missing/offline/cloud-file handling, collision-safe copy export, honest similarity
labels, native neutral-glass windows, and English/Chinese text. Use synthetic fixtures
and serial targeted tests (`nice -n 15 env CI=true swift test --jobs 1 --filter WorkflowToolsTests`).

The complete local app now includes these workflows. The public release remains unchanged.
Passing these tests does not close the existing large-library scrolling and Quick Look
acceptance gaps; local integration and public-release acceptance are separate steps.

## What is implemented

* Search result action **加入收集篮 / Add to collection**, a count in the footer, and
  **收集篮与继续资料 / Collection and context pack** in the More menu. Collections
  survive searches and relaunches; duplicates are detected by normalized path.
* Conversation preview **收集选中文字 / Collect selection** records only the selected
  message text, provider, conversation ID, preview-message ordinal and UTF-16 offset.
  A selection spanning messages retains their separate attribution. Disabling a
  conversation provider removes its collected excerpts.
* Context pack: editable task title and next steps, inspectable Markdown preview,
  copy and save. Files remain explicit path references, not attachments or summaries.
  Source excerpts are fenced as literal material. No remote services are called.
* Copy file references to Finder, or export copies into a uniquely named new folder.
  Preflight rejects missing/offline/cloud files; copy export rejects directories,
  packages and symlinks. Duplicate names receive numbered suffixes. Cancellation or
  failure removes the incomplete new directory. Copy export preserves file bytes;
  it is not a filesystem backup of extended attributes or Finder tags.
* Image action **比较原文件候选 / Compare original candidates**. Compares at most 64
  images from a bounded prefix of the current results or a chosen folder's direct
  children. Uses small ImageIO thumbnails and perceptual fingerprints; exact-byte
  matches additionally require SHA-256. Larger/newer is never treated as proof of
  origin. Candidate paths, dimensions, file sizes and evidence remain visible.

## Resource limits and deliberate scope

All image/file work shares one utility queue and can be cancelled by closing its
window. No startup indexing, recursive scan, embedding job or model load is added.
Collection: 100 items, 128 KiB of excerpt text, bounded settings payload. Copy export:
100 MiB per regular local file, 500 MiB total, 1 MiB streaming chunks. Image comparison:
64 candidates, 512 directory entries visited, 256 px thumbnails, at most 64 MiB hashed;
images above 36 megapixels or 16,000 pixels on either axis are skipped.
Time budgets stop between files (5 seconds comparing, 2 seconds enumerating); an OS
filesystem or decoder call itself cannot be interrupted. Network filesystems and
every camera RAW codec have not been accepted. Crop/rotation/major edits can defeat
the simple fingerprint: this first increment is candidate comparison, not a global
original-file search or a learned visual search engine.

## Isolated native preview

Run `bash scripts/build-workflow-preview.sh`. Output:
`build/workflow-preview/Fox Find Workflow Preview.app`.

This debug-only app has its own bundle ID and preferences. Its index contains only
six synthetic entries. It does not initialize the real content extension, disk
scanner, watchers, OCR or models. It does not replace `/Applications/Fox Find.app`.
The menu provides demo search, collection and demo conversation excerpts. All
app-owned windows use the dark neutral-gray design contract. Use this preview to validate the UI and workflow before a real-library
acceptance run. Cmd-Q exits the preview.

Manual acceptance:

1. Search Studio, add one image, then search notes and add the text file. Open the
   collection count; both should remain, and repeat collection should not duplicate.
2. Open Demo conversation from the app menu, select only a short passage, collect it.
   Verify exact source text and attribution in the context pack. Edit the next steps,
   copy/save and inspect the output. Clear removes local references only.
3. Compare candidates for Studio-preview.png. Studio-copy.png should be byte-identical;
   Studio-original.png should only be described as visually similar, with larger
   dimensions. Add a candidate to the collection.
4. Export copies to an empty test folder. Check duplicate names, then remove a demo
   source and verify export reports failure rather than a complete delivery. Close an
   in-progress operation to cancel. Restore demo files by relaunching the preview.
