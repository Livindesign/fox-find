# Fox Find 0.8.6 · build 26

[Release and downloads](https://github.com/Livindesign/fox-find/releases/tag/v0.8.6)

## Artifact / 发布产物

| Field / 项目 | Value / 内容 |
| --- | --- |
| Published / 发布时间 | 2026-10-17 10:36:49 UTC |
| Source tag / 源码标签 | `v0.8.6` |
| Source commit / 源码提交 | `98f831cd0a6d4faca7768012b4866ea3299de3df` |
| App version / 应用版本 | `0.8.6` · build `26` |
| Archive / 安装包 | `Fox-Find-0.8.6-macOS-arm64.zip` |
| Size / 大小 | 11,899,616 bytes |
| SHA-256 | `da4890c8d76109cfacf27176ac9c23921ff4cef381157c638a5681922d330074` |
| Validation machine / 验证环境 | Apple M1 Pro · 16 GB · macOS 27.0.1 · Swift 6.2.3 |

The release includes the app ZIP, `SHA256SUMS.txt` and signed `fox-find-update.json`.
The tag points to the source used for the validated package; later documentation-only
commits do not change that package.

发布包含安装包、校验文件与签名更新清单。标签固定在已验证安装包对应的源码提交；
后续文档更新不改变该安装包。

## Verified / 已验证

- Code signature and ZIP integrity passed; all 54 app files matched the built, packaged and locally installed app.
- The published ZIP and latest-update feed were downloaded from GitHub; archive version, size and SHA-256 matched the final local package.
- Both release-specific checks passed with no skips: the production GitHub download transport, and Ed25519 verification followed by installation and rollback in an isolated temporary directory.
- Native installed-app checks covered the search window, opening actions, skipping unavailable commands with the keyboard, and returning focus to search with Escape.
- Permission-relaunch subprocess tests and an isolated Launch Services fixture passed.

- 代码签名与 ZIP 完整性通过；构建、打包和本机安装的 54 个应用文件一致。
- 已从 GitHub 下载公开安装包与最新更新清单，版本、大小和 SHA-256 与最终本地产物一致。
- 两项发布检查均通过，无跳过：实际 GitHub 更新下载，以及 Ed25519 签名验证后的隔离安装与回退。
- 本机原生界面已验证搜索窗口、操作菜单、键盘跳过不可用操作，以及 Esc 返回搜索焦点。
- 权限退出重启逻辑的子进程测试与独立 Launch Services 示例通过。

Performance figures and their measurement scope are recorded in [PERFORMANCE.md](PERFORMANCE.md).
性能数据及计量范围见 [PERFORMANCE.md](PERFORMANCE.md)。

## Scope / 验证边界

Apple silicon; deployment target macOS 14. This build is ad-hoc signed and has not
been Apple-notarized. Older macOS versions and other Macs still need device testing.
The actual Full Disk Access toggle and system Quit & Reopen prompt were not replayed.
The published package was installed and rolled back in isolation; this does not claim
a completed automatic upgrade on a separate user's Mac.

面向 Apple 芯片，最低部署目标 macOS 14。目前采用 ad-hoc 签名，未经 Apple 公证。
较早 macOS 和其他 Mac 仍需设备验证；未重放实际磁盘权限开关与系统退出重启提示。
公开安装包已通过隔离安装与回退，此结果不代表已完成另一位用户电脑上的自动升级。

Users of `0.8.3-preview.1` must install the new version manually once; that older build
has no update entry point. See [UPDATES.md](UPDATES.md) for the GitHub update channel.

`0.8.3-preview.1` 没有更新入口，需要先手动安装一次新版。
GitHub 更新通道说明见 [UPDATES.md](UPDATES.md)。
