# 0.8.3-preview.1 — validation and limits

Prepared on 2026-10-17. Public preview approved by the maintainer on the same date.
Version changes are listed in [CHANGELOG.md](../CHANGELOG.md); this document records validation and limits.

App version: **0.8.3**, distribution build **17**. This packaging revision adds
complete dependency notices and standalone release materials to the build-16
application sources. It does not add new search features. No installed app was
replaced during publication preparation.

## Behavior in this version

- A shared file-action menu for right-click, row/grid overflow and **⌘K**.
- Matching mode and sorting are separate; fewer permanently visible controls.
- Removable parsed-query conditions and an explicit similar-image search context.
- Content/semantic updates retain existing results while work is pending.
- Selection and scroll position remain stable in the covered update scenarios.
- Content-folder coverage, semantic readiness and PDF physical-page actions have
  explicit status and file checks.

## Current local checks

Environment: Apple silicon, macOS 27.0.1, Swift 6.2.3, Swift 5 language mode.

| Check | Result | Boundary |
| --- | --- | --- |
| `CI=true swift test` in isolated publication checkout | 277 discovered/executed; **248 passed, 29 skipped, 0 failed** | Skips include opt-in visual, performance, real-index or real-model cases; not all model paths ran |
| Four stability scenarios: combined/content × list/grid | 40 samples each; 0 empty flashes; 0 unnecessary grid reloads | Synthetic test fixtures, not a complete real-directory interaction audit |
| Release app/helper build | Passed | Pinned native runtime reused from local build cache |
| `codesign --verify --deep --strict` | Passed | Ad-hoc integrity check; **not Developer ID / Apple notarization** |
| ZIP integrity and embedded notices | Passed | No model weights or user databases included |
| Distribution source check | Passed | Pattern-based credential/private-path check, not a formal security audit |
| Website, English/Chinese at 1440px and 390px | No horizontal overflow, broken images or script errors; FAQ controls work | Independent headless browser; website not deployed |

No hosted GitHub Actions run is claimed. Actions remains disabled following launch preparation; `docs/ci-macos.yml` is an inactive template.

Earlier build-16 synthetic 1,000-result view-update measurements were list P95
2.400 ms and grid P95 4.437 ms. These are historical AppKit update measurements,
**not FPS, end-to-end search latency or a performance promise for this package**.
They are not used as homepage marketing claims.

## Known limits before broad distribution

- Apple silicon only. macOS 14 is the deployment target, not a verified cross-version matrix.
- Other Macs, older systems, long real-directory sessions and scroll performance
  during real indexing still need broader acceptance.
- The app is not notarized. macOS may block launch and ad-hoc rebuilds can require
  folder permissions again. See [Apple guidance](https://support.apple.com/en-us/102445).
- Content search only covers explicitly chosen readable folders, with extraction
  limits. Cloud placeholders, encrypted documents and some formats are skipped.
- Semantic retrieval is experimental and opt-in; models (~865 MB) are downloaded
  separately. No whole-library accuracy or relevance guarantee is made.
- External offline results cannot be opened until the drive reconnects.
- No in-app updater is enabled. Upgrade manually from this project's Releases.
- Funding is not enabled. This preview has no paid activation requirement.

## 中文摘要

预览包 build 17 已完成本地测试、构建、签名完整性、压缩包与许可检查；
277 项测试中 248 通过、29 跳过、0 失败。网站在桌面/手机宽度通过基础检查。
这不等于 Apple 公证、多设备验收、真实大目录性能或全部语义场景验收。
仓库已获维护者批准公开；官网部署和爱发电收款尚未开启。
