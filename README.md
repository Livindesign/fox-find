<p align="center"><img src="docs/assets/icon.png" width="100" height="100" alt="Fox Find fox icon"></p>
<h1 align="center">Fox Find</h1>
<p align="center"><strong>Find the file. Keep your flow.</strong><br>Native Mac search for filenames, document text, and words inside images.</p>
<p align="center"><a href="https://github.com/Livindesign/fox-find/releases/tag/v0.8.3-preview.1">Download preview</a> · <a href="docs/GETTING-STARTED.md">Get started</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="SUPPORT.md">Support the project</a></p>
<p align="center">macOS 14+ · Apple silicon · MIT source · 0.8.3 Preview</p>

![Fox Find — a quieter way to find things on your Mac](docs/assets/hero.png)
<p align="center"><sub>Product illustration based on the new native interface, using fictional sample files. The latest public download may use the previous interface.</sub></p>

Press **⌘⇧L**, type, preview, open. Fox Find combines a filename index with optional
local OCR and document-content indexing. No account or paid activation is required.

**Built on [Oil Find's MIT-licensed public core](https://github.com/oil-oil/oil-find).**
This is an independent fork with a separate content-search implementation and interface.
Selected semantic runtime components are adapted from [DigUp](https://github.com/ARahim3/DigUp).
See [credits and provenance](NOTICE.md).

## One search, a few useful ways to find things

| You remember… | Try… |
| --- | --- |
| Part of a filename | Type it, use pinyin initials, or filter with `ext:pdf` and `size:>10mb`. |
| Words in a document or screenshot | Add its folder to **Content Search**, wait for indexing, then search its words. |
| A photo's folder or date | Use folder/type/date filters. Chinese phrases such as `下载目录最近7天拍摄图片` become visible, removable conditions. Capture-date filtering needs readable photo metadata. |
| What an image looks like | Enable **Local semantic search · Experimental**, download the model and index a folder; describe the image or use **Find Similar Images**. Relevance varies. |
| An app you want to open | Search its name, or select Apps. |
| A quick calculation | Enter `128*1.2` or a supported unit conversion. |

- **Stay at the keyboard.** Quick Look, Finder reveal, drag and drop, favorites, saved searches and a searchable **⌘K** action menu.
- **Choose your view.** List or thumbnail grid, dark/light appearance and custom accent colors. Sorting is separate from the filename/content matching mode.
- **Remember external drives.** Keep an offline catalog; reconnect the drive to open its files. Offline content depends on what was indexed while connected.
- **Keep content local.** OCR, extraction and optional embeddings run on your Mac. Content indexing is limited to folders you choose.

## Try the preview

1. Download `Fox-Find-0.8.3-preview.1-macOS-arm64.zip` from [Releases](https://github.com/Livindesign/fox-find/releases/tag/v0.8.3-preview.1).
2. Unzip and move **Fox Find.app** to Applications. Open it and press **⌘⇧L**.
3. Allow the folders you want searched. Filename search works separately from content search; add a content folder in Settings for OCR/text results.

**Preview distribution:** this build is ad-hoc signed, **not Apple-notarized**.
macOS may block the first launch. Read [Apple's guidance](https://support.apple.com/en-us/102445)
before deciding whether to open it, or build from source. SHA-256 checksums detect
download corruption; they are not a substitute for notarization.

Apple silicon only. The deployment target is macOS 14; release testing was done
on macOS 27.0.1, not yet across older macOS versions or other Macs.
See [release validation and known limits](docs/RELEASE-0.8.3.md).

## A few shortcuts

| Shortcut | Action |
| --- | --- |
| **⌘⇧L** | Show search (configurable) |
| **Return / ⌘Return** | Open / reveal in Finder |
| **⌘Y** | Quick Look |
| **⌘K** | Actions for the selected result |
| **⌘⇧Y** | Open a reported PDF match page, or view extracted text when available |
| **⌘/** | Keyboard and search-syntax help |

Right-click any result for the same file actions. See the [getting-started guide](docs/GETTING-STARTED.md).

## Privacy and honest limits

No analytics SDK or cloud inference is included. Optional model downloads connect
to Hugging Face and its CDN. Opening a bookmark or web result opens your browser.
From 0.8.6, the app checks GitHub Releases daily for signed updates; this can be
disabled in Settings. Downloading and restarting require your click. No license-check
service is enabled. See [updates](docs/UPDATES.md).

The local database contains **unencrypted extracted text**, protected by user-only
filesystem permissions, not a separate password. See [privacy](PRIVACY.md).

Semantic search is opt-in and experimental: it needs a separate ~865 MB model
download and indexed content folders. It cannot search unindexed content; similarity
is not an exact match. Extraction has size/page limits. Encrypted documents,
cloud-only placeholders and some formats are unsupported. Network volumes and
Intel Macs are outside the current supported scope.

[Version changes](CHANGELOG.md)

## Build from source

Requires Apple silicon, macOS 14+, Xcode / Command Line Tools with Swift 5.10+,
Git, CMake and Ninja. The first build fetches pinned llama.cpp source; model weights
are not downloaded by the build.

```sh
git clone https://github.com/Livindesign/fox-find.git
cd fox-find
bash scripts/build-llama.sh
CI=true swift test
bash scripts/build-app.sh
open 'build/release/Fox Find.app'
```

See [development](docs/DEVELOPMENT.md) for packaging, test scope and module layout.
The website is maintained separately and is not included in this source tree.

## Help it get better

Report a reproducible issue, test an older macOS version, improve a translation,
or contribute a focused pull request. [Contribution guide](CONTRIBUTING.md) ·
[Roadmap](docs/ROADMAP.md) · [Security](SECURITY.md).

If Fox Find is useful, a genuine star or a short demo helps others discover it.
Financial support is optional; **no payment destination is enabled yet**.
See [Support](SUPPORT.md) for the sponsorship policy and ways to help today.

## License and thanks

[MIT](LICENSE). Original Oil Find copyright © 2026 Lin Zhihuang is preserved;
Fox Find modifications © 2026 Livindesign and contributors. Thank you to
[Oil Find](https://github.com/oil-oil/oil-find), [DigUp](https://github.com/ARahim3/DigUp)
and [llama.cpp](https://github.com/ggml-org/llama.cpp). Their notices ship with the app.
Model weights have their own license. Fox Find is not affiliated with or endorsed
by these projects; sponsoring this fork does not buy an upstream license or support.
