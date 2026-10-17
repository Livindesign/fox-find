# Privacy / 隐私

Fox Find processes filenames and selected file contents on your Mac. This build
has no analytics SDK, account login or cloud inference.

## What stays locally

- Filename/path, size, date and type indexes.
- Text extracted by Vision OCR and document readers from chosen content folders.
- Optional semantic vectors, snippets, page references and file fingerprints.
- Favorites, saved searches, preferences and external-drive catalogs.

App data uses `~/Library/Application Support/Local Find/` (a legacy directory name
retained for compatibility). The content database contains **plaintext extracted
content**. Its folder/file permissions are restricted to the current user;
the database is not separately encrypted. Other software with access to your
user account may be able to read it. Removing the application does not delete it.

Content indexing is opt-in per folder. Name indexing may cover more locations,
subject to your settings and macOS permissions. macOS can ask for Downloads,
Documents or Desktop access. Full Disk Access is not required for basic use.
Cloud placeholders are not downloaded automatically for content extraction.

## Network activity

- From 0.8.6, automatic update checks (enabled by default, configurable in Settings)
  fetch a signed release manifest from GitHub approximately once per day. Manual
  checks use the same endpoint. Choosing Download and Restart downloads the app
  from GitHub release assets. GitHub/CDN receives normal connection data such as
  your IP address; no filenames, queries, index contents or account credentials are
  included in these requests. See [update hosting and verification](docs/UPDATES.md).

- Selecting **Download Local Models** connects to Hugging Face and its CDN to
  download pinned model files (~865 MB). Requests reveal normal connection data
  such as your IP address to those services. Files and search queries are not
  sent to a remote inference service. Model files are size/SHA-256 checked.
- Opening a web search result or bookmark launches your browser and the target
  site's normal privacy policy applies.
- Building from source fetches dependencies from GitHub; tool installation may
  use package registries. This is separate from app search activity.

## Your controls

Pause content indexing or remove content folders in Settings. Semantic indexing
can be disabled independently. Review the clearing/rebuilding dialogs before
deleting caches; they explain what is removed. Search data is not a backup of
your original files. Never include private file paths, OCR text or database files
in a public issue. See the getting-started guide for uninstall instructions.

中文摘要：文件与查询在本机处理；检查 GitHub 更新及手动下载模型时联网，自动检查可在设置关闭。内容缓存保存未加密文字，
受当前用户的文件权限保护。退出/删除 App 不会自动删除缓存，目录权限可在系统设置撤销。
