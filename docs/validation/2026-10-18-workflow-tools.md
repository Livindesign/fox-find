# 新功能分支本地验证 · 2026-10-18

## Current delivery update — 20:21 local time

The maintainer approved merging `codex/workflow-tools-v1` into local `main` at
`f87cd19`. The earlier handoff launched only the isolated build 38 preview and
omitted rebuilding and installing the complete app. This delivery corrects that:

- Built and installed the complete **0.0.1 build 39** at `/Applications/Fox Find.app`.
  It includes the previous search/content/AI conversation features and the new workflows.
- Release build completed in 78.85 seconds with `FOX_BUILD_JOBS=1` and nice 15;
  the pinned runtime was reused. No new stress suite was run.
- Preserved installed build 37 under ignored `build/install-backups/`; settings,
  indexes and models were not cleared. Bundle signatures and matching executable
  SHA-256 were verified. Signing is ad-hoc, not notarized.
- Launched the installed executable, opened Collection from the complete main
  window's More menu, inspected its neutral-gray surface and empty state, then
  returned to the main search window. This is not the synthetic demo process.
- Receipt: `build/integrated-build39-receipt.json`; build log:
  `build/integrated-build39.log`.
- Local merge and installation are complete. No push or public release was made.
  Whole-product and real-library acceptance gaps below remain open.

## Earlier development-branch record

分支：`codex/workflow-tools-v1`。上一轮基线：`18955d8`，功能提交：`21518b2`。
结论：功能验证和二期界面重排已完成本轮相关检查；最终深灰材质的最后一次原生复核被再次锁屏阻止。**未合并、未推送、未发布**，不代表全产品已经达到发布要求。

## 本轮范围

1. 跨搜索收集篮：去重、持久化、移除、清空、复制文件引用、导出独立副本。
2. 继续资料：只摘录选中的对话文字，保留来源与消息位置，组合文件路径和手写要求，预览、复制、保存 Markdown。
3. 原文件候选对照：当前结果或指定文件夹内有限比较；区分相同字节、可能相似、名称相关，展示尺寸与路径，可加入收集篮。
4. 二期 UI 重排与共用设计语言：收集清单/编辑/预览分区、主次操作、双图对照、统一对话阅读窗口；消除系统蓝色选中，玻璃统一深色中性灰。
5. [UI-DESIGN-SYSTEM.md](../UI-DESIGN-SYSTEM.md) 是后续界面实现约束。AGENTS.md 要求修改前读取，Theme 与 GlassChrome 为共享实现，不能按功能临时另立风格。

边界、入口和复验步骤见 [WORKFLOW-TOOLS.md](../WORKFLOW-TOOLS.md)。没有增加向量索引、全盘扫描、模型常驻或远程 API。

## 自动回归与构建

```sh
nice -n 15 env CI=true FOX_WORKFLOW_SNAPSHOTS=build/workflow-ui-final \
  swift test --jobs 1 --filter 'WorkflowToolsTests|FileActionCapabilitiesTests|AIConversationTests|SearchEditingTests'
nice -n 15 swift build --jobs 1 --product FoxFind
bash scripts/build-workflow-preview.sh --skip-build
```

- 相关回归 **39 项通过、0 失败，测试部分耗时 6.932 秒**；另有 33 项同步检查通过。
- 覆盖文件缺失/离线/符号链接、重名、复制中途取消回滚、选中片段与偏移、来源停用、收集上限、图片比较限制、纯色误匹配、目录不递归。
- 新回归包含目录别名下排除参考图自身与重复物理文件，以及非当前窗口不抢占编辑快捷键。
- 中英文都以深色原生视图渲染，检查过主操作、文字截断、资料分区。渲染日志：`build/workflow-ui-final.log`；布局截图：`build/workflow-ui-final/`。
- 回归后收紧按钮内边距，并将玻璃底色设为显式 sRGB 深灰；最终产品构建 **4.73 秒**、ad-hoc 签名验证通过。日志：`build/workflow-ui-package.log`。
- `git diff --check`、打包脚本语法检查通过。原有 QuickSearchTests 未使用返回值警告保留，未顺手改动。

## 原生鼠标/键盘验证

本轮解锁后已在独立预览包执行，并非仅截图或调用业务方法：

| 流程 | 已观察结果 |
| --- | --- |
| 多次搜索后收集 / 重开 | 文件跨搜索保留；重复加入不增加条数；重启后仍有文件、摘录和手写说明 |
| 选择对话片段 | 只收集“交付可编辑源文件与预览图片。”，保留消息 1、UTF-16 +8；未带入整条未选择正文 |
| 编辑与复制继续资料 | Cmd-A / 粘贴 / 撤销 / 重做正常；新版主按钮复制后粘贴，内容和出处正确；再撤销恢复演示说明 |
| 保存 Markdown | 原生 NSSavePanel 保存成功，输出检查包含摘录、偏移和说明 |
| 导出独立副本 | 原生 NSOpenPanel 选目录后导出成功；两份文件的 SHA-256 与原文件一致 |
| Finder 文件引用粘贴 | 复制文件后，在 Finder Cmd-V 得到实际副本，字节一致 |
| 候选对照 | 相同文件显示 SHA-256 一致；放大图只显示可能相似；尺寸和选择更新正常 |
| 目录别名去重 | 文件选择器返回 `/private/var/…`，参考图为 `/var/…`；仍只比较另外 3 张，不包含自己 |
| 关闭 / 返回 | Cmd-W、对话 Esc 关闭对应窗口，返回搜索保留原查询 |
| 二期界面原生检查 | 收集区、可读预览、双图与证据区、对话阅读区、主次操作、禁用和中性灰选中可见；无旧系统蓝色选中块 |

原生复制与输出证据（均为合成资料，留在忽略的 build 下）：

- `build/workflow-validation/interactive-integrity.json`
- `build/workflow-validation/interactive-export/Fox Find Context.md`
- `build/workflow-validation/interactive-export/Fox Find Collection-BC035C40`
- `build/workflow-validation/finder-paste`

## 界面验收状态

| 设计门槛 | 状态 |
| --- | --- |
| 共享组件与设计规范 | 通过；操作按钮、底板和辅助列表已提升为全应用共享组件 |
| 中英文布局 / 常规数据 / 长路径 | 已渲染检查；原生中文版主流程已操作 |
| 空、错误、处理中、取消 | 相关自动回归覆盖；新布局的全部状态尚未逐项原生视觉验收 |
| hover / focus / selected / disabled | 共享状态已实现；实际选中/禁用和点击已检查，完整 hover/focus 组合仍待最终视觉复核 |
| 深灰最终材质 | sRGB 底色构建已完成；最后一次启动后 Mac 再次锁屏，未取得最终截图，已请求解锁 |
| 设置/引导材质共用 | 代码已接入统一 token；此轮未逐页打开设置、更新和引导验收 |
| 发布性能 | 本轮没有重跑真实全库压力测试；原有大资料库滚动、Quick Look 首帧门槛仍须独立验收 |

系统文件面板的 Go To 字段通过 AX 设置路径及原生确认完成。CUA 注入的 Cmd-A/C/V 在该远程字段没有生效；同一现象也在 TextEdit 的系统面板复现，因此不能把此项写成 Fox Find 已验收，也不继续为自动化限制叠加猜测补丁。应用内编辑快捷键已经实际验证。

## 本地产物与环境

- `build/workflow-preview/Fox Find Workflow Preview.app`，约 20 MiB；`0.0.1-dev`、build 38。
- 包标识 `app.localfind.workflow-preview`，数据域 `app.localfind.workflow-preview.data`。
- 主可执行文件 SHA-256：`954953d40c9c94fd6a6ac38c36a08478077fb2f48d58e60d57c365f45fcb16ce`。
- 原生 Mach-O 直接作为 bundle executable；已去除 shell 启动 wrapper，避免 Launch Services 与辅助功能身份不一致。
- 只有六个索引项和临时合成图片/文本/对话，不初始化主应用的数据库、扫描器、OCR 或模型。
- 一次仅一个低优先级编译/相关测试任务；结束后已关闭任务专属预览进程，编译和测试已退出。不替换 `/Applications/Fox Find.app`，不清理用户索引或模型。

这些结果只证明上述限定场景。完整产品体验、真实资料库性能、用户设计确认仍是合并和公开发布前的门槛。
