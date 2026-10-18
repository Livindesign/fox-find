# 新功能分支本地验证 · 2026-10-18

分支：`codex/workflow-tools-v1`。保存上一轮改动后的基线：`18955d8`。
当前结论：可进行本地产品体验，尚未达到合并与公开发布验收。

## 本轮实现

1. 跨搜索收集篮：去重、持久化、移除、清空、复制文件引用、导出独立副本。
2. 继续资料：只摘录选中的对话文字，保留来源与消息位置，组合文件路径和手写要求，预览、复制、保存 Markdown。
3. 原文件候选对照：当前结果或指定文件夹内有限比较；区分相同字节、可能相似、名称相关，展示尺寸与路径，可加入收集篮。

边界、入口和复验步骤见 [WORKFLOW-TOOLS.md](../WORKFLOW-TOOLS.md)。这次没有增加向量索引、全盘扫描、模型常驻或远程 API。

## 已完成验证

命令：

```sh
nice -n 15 env CI=true FOX_WORKFLOW_SNAPSHOTS=build/workflow-validation \
  swift test --jobs 1 --filter 'WorkflowToolsTests|FileActionCapabilitiesTests|AIConversationTests'
bash scripts/build-workflow-preview.sh --skip-build
```

最终测试：**35 项通过、0 失败，测试耗时 5.600 秒**。

| 范围 | 结果 |
| --- | --- |
| 收集、摘录、导出、比较、窗口 | 14 项通过 |
| 文件类型菜单及新入口 | 5 项通过 |
| 对话来源与已有对话流程回归 | 16 项通过 |
| 深色中文、浅色英文原生视图渲染 | 已检查，无文字溢出；使用合成资料 |
| 独立验证包启动 | 已启动运行，无运行时错误；验证后关闭测试进程 |
| ad-hoc 签名完整性 | `codesign --verify --deep --strict` 通过 |
| 补丁空白检查、打包脚本语法 | 通过 |

覆盖关键失败路径：文件缺失/离线/符号链接、重名、复制中途取消回滚、对话片段跨消息、来源停用、收集数量和字节上限、图片比较去重和上限、纯色误匹配、目录不递归。

首轮发现一项目录 URL 尾斜杠断言差异，已按实际路径比较修正。独立验证包首次启动发现 preferences suite 与包标识相同导致初始化失败，已换为独立数据域并复验启动。原有 QuickSearchTests 未使用返回值编译警告仍在，未顺手改动。

## 本地产物

* `build/workflow-preview/Fox Find Workflow Preview.app`，约 20 MiB；版本 `0.0.1-dev`、build 38。
* 包标识 `app.localfind.workflow-preview`；数据域 `app.localfind.workflow-preview.data`。
* 演示仅有六个索引项，使用临时目录下的合成图片、文本和对话。不替换 `/Applications/Fox Find.app`。
* 核心可执行文件 SHA-256：`5dab6e2206a5e67410d68156c7f746caeb318d228499d56fa929d964a1e31325`。
* 最终日志 `build/workflow-validation-final.log`；截图 `build/workflow-validation/`。

## 未完成的验收

Mac 锁屏阻止了原生鼠标/键盘全流程验收，已请求解锁；尚未获得解锁回复。
视图渲染和自动化回归不能替代实际点击、剪贴板粘贴、导出面板和用户体验确认。

已有大资料库滚动、Quick Look 首帧等发布验收缺口不因这次新功能通过而视为关闭。
本轮没有重复全库压力测试，没有改动已安装的主应用，也没有推送、合并或发布 Releases。
在这些体验与性能门槛确认前，不把验证包标为正式 0.0.1。
