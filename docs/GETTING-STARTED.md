# Get started

The next version includes a native getting-started guide, replayable from the menu bar or Settings. See [guide details](ONBOARDING.md).

## Find a filename or open an app

Open Fox Find, press **⌘⇧L**, and type a name. Use **Return** to open,
**⌘Return** to show in Finder, and **⌘Y** to preview. Switch to **Apps** to narrow
to applications. Your global shortcut can be changed in Settings.

The **Find** menu controls matching: Auto combines available sources;
Filenames searches names; File Contents searches indexed extracted content.
It does **not** sort. Use **Sort** for name, date, size or relevance.
Clearing the query clears its results.

## Search inside a document or image

1. Open Settings → Content Search and add one folder you recognize.
2. Allow that folder when macOS prompts. Wait for its indexed-file count to rise.
3. Search a distinctive word visible in a supported PDF, text document or image.
4. Right-click a result or press **⌘K** for available file operations.

Files outside the selected content folders will not produce content matches.
Folder access alone does not add a folder to the content index.

## Description and similar-image search (experimental)

1. Add a content folder containing suitable photos or documents.
2. Enable **Local semantic search · Experimental** in Settings.
3. Select **Download Local Models** (~865 MB); wait for model verification and
   some semantic segments to be indexed. An empty index cannot return matches.
4. In Auto or File Contents, describe something that is actually in that folder.
   A similar candidate is labeled as possibly related; verify it in preview.
5. For an image stored on this Mac, right-click → **Find Similar Images**. Or
   use the search toolbar's More menu to choose a reference image from disk.
6. Edit/clear the query or use the reference-image exit control to leave similarity search.

“Available locally” means a readable file on this Mac or a connected drive. It
does not mean pasting an image URL from the internet. Results depend on folder
coverage, indexing progress and model relevance; there is no guaranteed answer.

## PDF match pages

Only results that report a page number have a page to jump to. Select one and use
**⌘⇧Y** or its matching-page action. The page is the physical PDF page, which can
differ from a printed page label. The file fingerprint is checked before opening;
search again if the PDF has changed. Other results may offer extracted text instead.

## No results?

Check the selected type, location, date and matching mode. Remove a filter chip or
clear filters. For content, confirm that the folder was added, access is allowed,
indexing is not paused and the file is downloaded/readable. For capture-date photo
queries, check EXIF/capture metadata; modification time is a different condition.
For semantic search, confirm the model and segment count. Try a filename to
separate a filename-index problem from a content-index problem.

## Remove Fox Find

Quit Fox Find and move **Fox Find.app** from Applications to Trash. Search data is
kept unless you separately remove `~/Library/Application Support/Local Find/`.
That directory belongs to this fork, not Oil Find. Removing it deletes Fox Find
indexes and catalogs, not your original documents. No upstream uninstall script
is included in this repository.
