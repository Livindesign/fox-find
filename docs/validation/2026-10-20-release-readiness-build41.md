# 0.0.1 build 41 · 发布检查 / Release readiness

日期：2026-10-20。此记录区分源码公开、候选包测试和普通用户正式分发。
仓库目前保持私有，历史 Release 保持草稿；本轮不改变公开状态。

## 本轮修正

- 工程统一使用 `FoxFindApp`、`FoxFindCore`、`CFoxFind`、`FoxFindContent`、
  `FoxFind` 和 `foxfind-cli`；同步测试模块、导入、C 头文件和 SwiftPM 资源包路径。
- 保留 `app.localfind.desktop`、`localfind` 协议、既有偏好设置、`Local Find`
  数据目录与 `.oilfind` 格式。工程改名不要求清空或重新扫描用户索引。
- 上游版权、许可和来源记录继续保留。历史验收文档中的旧源码路径代表当时版本，
  当前模块映射见 [开发文档](../DEVELOPMENT.md)。
- 构建先生成独立临时应用，签名校验后再替换构建产物，避免混入旧资源包。
  使用具名签名身份时启用 Hardened Runtime 与 timestamp；本机候选仍为 ad-hoc。
- 构建工具明确配对 Swift 与 SDK，避免 Python 启动器注入另一套 SDK 导致系统模块重复编译。
  不改变系统 `xcode-select`。
- 中英文 README、使用说明、更新说明与变更记录同步；补充收集篮实际用途、
  导出边界和快捷键。原生演示图使用虚构文件、路径和对话。
- 旧性能数字移至历史记录，不作为当前版本的普遍速度保证。

## 已执行的检查

环境：Apple silicon，macOS 27.0.1，Swift 6.2.3，配套 Xcode macOS 26.2 SDK。
单任务、`--jobs 1`、低优先级串行执行；未扫描用户全盘或下载模型。

| 检查 | 结果与边界 |
| --- | --- |
| 全量 Debug 回归 | 458 项：413 通过、45 按条件跳过、0 失败；88.740 秒 |
| 定向界面与工作流复测 | 62 项：61 通过、1 跳过、0 失败；覆盖底栏、菜单、恢复流程、收集篮及双语布局 |
| 小规模原生交互检查 | 511 个合成条目、12 次列表/网格切换与滚动；最大主线程处理 83.49 ms，低于该用例 250 ms 上限；不是显示 FPS 或大库延迟 |
| 模块与安装身份隔离 | 源码命名、资源名和兼容数据目录断言通过 |
| 源码分发检查 | 344 个待提交文件通过敏感路径、凭据模式、许可证完整性检查；用户已有的独立文档改动未纳入本轮提交 |
| 演示图 | 原生 DEBUG 渲染，使用隔离资料与合成数据；背景采用截图专用底色，不捕获桌面 |
| 真实候选包安装/回退 | 使用 build 41 ZIP 和 Ed25519 签名清单，在临时应用目录完成安装、版本验证与回退：1 项通过、0 跳过 |
| 包内容与签名 | ZIP 完整性、ad-hoc 签名严格校验通过；70 个归档条目，无模型、索引、测试目录、网站或私钥；仅含新 `FoxFind_FoxFindApp.bundle` |
| 本机更新与启动 | 已安装至 `/Applications/Fox Find.app`，与构建产物的 59 个文件逐个哈希一致；旧版备份保留 |
| 原生启动交互 | 新进程主界面已显示；`128*3` 返回 `384`；⌘⇧B 打开收集篮，已有 2 项保留，⌘W 返回同一搜索；清除验证输入后留在主界面 |

首次回归发现五个过时用例：新增收集篮入口后仍按旧按钮数量/快捷键检查、
菜单仍要求无图标，以及错误恢复测试等待少于启动索引延迟。
修正后的检查继续验证布局不重叠、选择状态、图标有效、旧快捷键不启用、
以及真实数据库失败后的重试恢复；没有删除失败用例或降低产品的响应阈值。
最终全量结果为上表所列。

本地日志：`build/build41-final-regression.log`、`build/build41-targeted.log`、
`build/build41-screenshots.log`。日志未作为公开附件上传。
安装器日志：`build/build41-installer.log`；安装回执：
`build/integrated-build41-receipt.json`。

本地候选包：`dist/Fox-Find-0.0.1-candidate.41-macOS-arm64.zip`，12,406,781 字节。
SHA-256：`aa31fc39f4d7c6f2f993bd2a85df3906c69ac6c70c4718dc328a81a883757eed`。
可执行文件 SHA-256：`477287e7b005d94a37af3104ca62aa0d53bc522328bb348bd883fb36b88ffcb0`。

## 尚未等同于通过的范围

45 项跳过包括真实模型、真实 APFS/FSEvents 和外置卷、压力/计时场景、真实 GitHub
下载、真实安装包测试及可选截图输出。小规模 UI、真实安装包与本轮截图已单独运行，
其余专项检查应
分别记录，不能把跳过数写成通过数。

| 发布事项 | 当前证据 / 完成条件 |
| --- | --- |
| 普通用户安装的签名、公证 | `security find-identity -v -p codesigning` 返回 **0 个有效身份**。需维护者配置 Developer ID 与公证账号，签名、公证并 staple，才能验证 Gatekeeper 的正常首次启动 |
| 干净安装与权限恢复 | 当前机器已有索引、偏好与权限。需在干净账户/另一台 Mac 验证首次启动、目录授权、完整磁盘权限退出重启、卸载后数据保留；不能用已有安装替代 |
| 实际大库并行负载 | 全量单元回归和 511 条 UI 检查未覆盖大库冷启动、EXIF 首轮读取、真实模型索引同时输入/滚动/预览的峰值；需单独记录首个结果、P95、内存峰值、取消与恢复结果 |
| 客户端跳转 | 路由和失败处理有测试；不能据此声称每个安装版本的 Codex/Claude/WorkBuddy 均完成客户端原生跳转验收。CLI-only 会话明确使用继续命令 |
| 最低系统范围 | macOS 14 是部署目标，目前证据来自 macOS 27.0.1；对外承诺较早版本前需兼容验收 |
| 线上自动更新 | 私有仓库下匿名正式 feed 不提供包。需在批准的受控预发布步骤中复核实际下载地址、签名、旧版到新版及失败回退，再推广正式更新 |

自然语言搜索仍是有边界的条件解析加可选语义搜索，并非任意自然语言理解。
接收/下载/创建时间、复杂嵌套条件与通用视觉否定不在当前完整支持范围内；
未识别部分须保持提示。参见 [条件覆盖](2026-10-18-natural-combinations-build35.md)。
这类能力可作为明确标注的实验项，而非承诺“所有表达都能准确命中”。

非阻断观察：离屏网格截图时 AppKit 输出一次约束数值上限警告；当前布局、截图
和相关测试通过，另行记录，不把本轮工程命名迁移扩大为布局重构。
本机旧版搜索/设置窗口中发送 ⌘Q 未退出；本次安装按确认的应用进程路径停止旧进程，
未将此操作算作“退出快捷键通过”。该快捷键与菜单栏退出的一致性仍需单独核验。

## 发布判断

**源码公开与稳定安装包发布是两个决定。** 工程名和署名不是发布阻碍；
源码可在维护者确认公开范围后公开，并明确候选/实验状态。Apple 签名和公证
不是公开源码的前提。

目前还不足以宣布面向普通用户的稳定 0.0.1 已全面验收。主要缺口是正式分发身份、
干净环境验证，以及实际大库/模型与客户端的端到端证据。不得将本轮自动化通过
表述为“所有功能、性能问题已经解决”。

## English

Build 41 unifies engineering names, preserves installed identity and data compatibility,
rebuilds the app in a clean staging bundle, pairs Swift with its matching SDK, and refreshes
bilingual documentation and synthetic native screenshots. Upstream notices remain intact.

The final Debug suite passed: **413 passed, 45 conditionally skipped, 0 failures** out of
458 tests. Targeted UI/workflow validation passed 61 tests with one skipped. A separate
511-entry interaction check recorded 83.49 ms maximum main-thread work over 12 interactions;
this is neither display FPS nor a large-library end-to-end result.
The real candidate archive also passed isolated install/rollback validation. Build 41
is installed locally with a build 40 backup; native launch, calculation, collection
opening/closing and preservation of the existing two collection entries were verified.

Publishing source as a clearly labeled candidate is distinct from a stable consumer release.
No valid Developer ID signing identity is available locally. Clean-machine permissions and
restart, large-library/model contention, installed source-client navigation, older macOS
compatibility and the final hosted update path still need their respective acceptance evidence.
Skipped checks are not passes. The repository remains private and releases remain drafts.
