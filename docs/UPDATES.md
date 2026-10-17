# GitHub updates / GitHub 更新

## 用户体验

0.8.6 起，Fox Find 默认每天检查一次 GitHub Releases。首次检查至少延迟启动后 90 秒，
后台检查不会打开窗口。菜单栏有「检查更新」，设置里可以关闭自动检查。
发现新版本后，用户点击「下载并重启」才会下载安装；不会在使用中静默替换或退出。
无需注册账号，无需个人服务器，搜索词和文件信息不会随更新请求发送。

更新仅接受内置 Ed25519 公钥验证通过的清单，以及清单绑定的 SHA-256、大小、版本和 GitHub 下载地址。
下载直接写入临时文件，校验、解压和安装在后台执行。安装前保留旧应用；替换失败回退。
重启辅助进程等待新应用确认启动；未确认则恢复旧版。首次确认后的备份清理也在后台进行。
应用目录不可写时会显示错误并保留旧版，不申请管理员权限。

## 发布状态

2026-10-17：仓库已转为私有，`v0.8.6` 和 `v0.8.3-preview.1` 已撤回为草稿。
匿名访问仓库及自动更新清单返回 404；更新客户端将清单 404 视为暂无可用更新。
`0.0.1`（build 27）仅用于本地验收；完整回归及维护者体验验收通过后再发布。

版本号重新从 0.0.1 开始，build 继续递增。旧 0.8.x 不会自动降级到 0.0.1，
需手动安装一次；不修改版本比较规则来绕过防降级检查。重新公开仓库与发布是独立操作，
本地构建、测试和提交不会自动触发两者。

The repository is private and both prior releases are drafts. Version 0.0.1 is a local
acceptance candidate, not a published release. Existing 0.8.x installations require
one manual install because automatic downgrades remain blocked.

- 清单：https://github.com/Livindesign/fox-find/releases/latest/download/fox-find-update.json
- 包：https://github.com/Livindesign/fox-find/releases/download/vVERSION/Fox-Find-VERSION-macOS-arm64.zip
- GitHub 文档：[链接到最新发布资源](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)

## 维护者发布步骤

1. 修改 `Resources/Info.plist` 的版本和递增 build；同步 `Resources/UpdateNotes.json` 与 `CHANGELOG.md`。
2. 完成测试和原生界面验收，运行 `FOX_FIND_RELEASE_ID=0.0.1 bash scripts/package.sh`（替换版本）。
3. 检查 ZIP、签名和清单，运行真实包安装/回退测试。测试只使用临时目录。
4. 获得维护者发布指令后，在同一个 **正式 Release** 上传 ZIP、`SHA256SUMS.txt`、`fox-find-update.json`。
   标签必须与清单 URL 一致，例如 `v0.0.1`。构建脚本不推送、不发布、不安装。
5. 从 GitHub 下载最终清单与包，复核签名、哈希和版本，再验证旧版应用内更新到新版。

Release 正文只写新增、改进和修复。维护者操作、许可和安装说明留在项目文档。
`Tests/` 留在源码仓库，但不会复制进应用 ZIP；官网与内部推广材料独立保管，不进入本仓库。

## 签名密钥

发布私钥保存在维护者电脑的 `~/Library/Application Support/Fox Find Release/ed25519.key`，
目录权限 0700，文件权限 0600。私钥不在仓库、应用或安装包中；应单独加密备份，不能上传公开附件。
`swift scripts/sign-update.swift --initialize` 只在文件不存在时创建，输出的只有可公开的公钥。
该公钥固定在 `Resources/Info.plist` 的 `FoxUpdatePublicKey`。

本机有对应密钥时，`scripts/package.sh` 自动生成签名清单；没有私钥的贡献者仍能构建应用，
不会生成官方更新清单。派生项目应使用自己的仓库地址和密钥。不要删除或重新生成官方私钥，
否则已安装应用会拒绝新密钥签署的更新。Apple 代码签名和发布清单签名是两层不同校验。

## Test the actual package

```sh
FOX_TEST_UPDATE_ARCHIVE="$PWD/dist/Fox-Find-0.0.1-macOS-arm64.zip" \
FOX_TEST_UPDATE_MANIFEST="$PWD/dist/fox-find-update.json" \
FOX_TEST_UPDATE_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :FoxUpdatePublicKey' Resources/Info.plist)" \
swift test --filter FoxUpdateTests.testPackagedInstallAndRollbackInIsolatedDirectory
```

The test authenticates the release manifest, installs its actual signed app archive
into a temporary application directory, then verifies rollback to an older fixture.
It does not replace `/Applications/Fox Find.app`. This is local installer acceptance;
it does not claim GitHub publication or a completed remote upgrade.
