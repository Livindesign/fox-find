# 0.0.1 build 29：本地对话与检索排序

2026-10-17，Apple M1 Pro / 16 GB / macOS 27.0.1，Swift 6.2.3、SDK 26.2。
本轮是阶段性交付，**不是整个研究路线图已完成，也不是公开发布验收通过**。
仓库保持私有，历史 Release 仍为草稿。

## 已实现

- 原生「AI 对话」分类：Codex、Claude Code、WorkBuddy 的本地标题与可见用户/助手消息；中文和多关键词查询、最近记录、500 条显示上限、虚拟列表。
- 默认关闭；设置中显式开启，每个来源独立控制。来源只读，副本位于应用自己的索引目录。工具输出、隐藏思考、账号凭据不进入此索引。
- 来源事件监听、增量同步、流式写入期间同步新记录、重命名/删除/归档、账号切换隔离；后台按分片和 CPU 预算执行，查询可取消。
- 原应用跳转；不支持的桌面入口回退为本地内容查看，CLI 会话提供可复制的继续会话命令，不自动执行命令。
- 查看原文、复制带来源的对话内容。读取限制大小与消息数，截断显式标注。关闭来源立即撤销排队结果和原文操作；清除副本不改动原始记录。
- 自动选择首行不夺走输入空格；主动选中结果后才使用空格预览。输入清空与切换分类取消旧查询，照片等文件硬条件不被对话结果绕过。
- 内容查询对所有关键词均可被 trigram 索引的场景使用 BM25；任一词短于三个 Unicode scalar 时保留完整字面匹配。精确文件名仍在前，语义候选在后，显式名称/时间排序不变。
- 长文摘要先找文本位置，再只整理附近的小段，避免为每条结果处理整篇内容。

用法：设置 → 本地 AI 对话搜索 → 开启来源 → 主窗口「AI 对话」→ 输入关键词。
选中结果后 Return 尝试打开原会话，⌘Y 查看内容，⌘K/右键选择复制。输入 `*` 看最近对话，清空输入清空结果。
普通 ChatGPT/Claude 网页聊天历史不在此批来源内；此入口是关键词检索，不是对所有聊天内容提问的生成式问答。

## 回归与正确性

全量：382 项，**369 通过、13 跳过、0 失败**，136.72 秒。
随后针对最后的空格处理、来源撤销和界面接入再跑 54 项，**54 通过、0 失败**。
最后审查补上 Codex rollout 的内部 channel/工具接收者过滤，确保不把内部消息当可见正文；针对三种来源再跑 36 项，**36 通过、0 失败**。
这些数字是各次运行，不能相加成互不重复的测试数量。

覆盖：压缩索引与字面匹配 oracle、长消息及跨分片查询、重写/删除/归档、来源开关、WorkBuddy 账号变化、持续写入、缓存失效、提取次序与角色、截断、无效 URL 标识、命令路径转义、清空及迟到响应、分类隔离、虚拟列表和 BM25 排序。
测试使用合成资料；并未修改真实聊天记录、系统键盘设置或隐私权限。

真实模型补测：使用已有且校验过的本地权重，3 项通过。覆盖中文语义排序与取消、图片/HEIC/文档和离线缓存、13 页 PDF 断点续建及物理页码。未下载新模型，未使用个人素材。

4,000 段合成对话、500 条返回结果：首查 28.53 ms；禁用结果与解压缓存后 20 次查询 P95 46.65 ms；重复查询缓存命中 P95 0.11 ms。500 条虚拟列表的选择/布局 P95 3.65 ms，仅建立 7 个行视图。数据库页可能已被操作系统缓存，所以“禁用缓存”指应用缓存，并非冷磁盘；布局也不是屏幕帧率。

首次模型评估脚本把 24 条文本一次发送，超过现有 helper 每批 8 条的协议限制，出现 1 项失败。已修正评估脚本分批调用，没有放宽 helper 的资源限制；该失败与后续复测均保留记录。

## 向量维度小样

固定 24 篇合成文档与 24 条中文改写查询，每条有一个预先指定目标；包含摄影、设计、合同、代码、生活资料及英文文档的中文查询。使用当前固定 Q8_0 模型，48 条文本共 3.11 秒（含 helper 启动与推理，不含权重散列检查）。只评估文本。

| 维度 | 第一名正确 | Recall@3 | MRR | 每条 Float32 向量 |
| --- | ---: | ---: | ---: | ---: |
| 128 | 22/24 | 24/24 | 0.9583 | 512 bytes |
| 256 | 24/24 | 24/24 | 1.0000 | 1,024 bytes |
| 512 | 24/24 | 24/24 | 1.0000 | 2,048 bytes |
| 768 | 24/24 | 24/24 | 1.0000 | 3,072 bytes |

128 维把「过期搜索结果回填」排在来源撤销之后，把「账号恢复代码存放」排在普通备份之后。256 维是后续扩大语料和图片评估的候选，**本轮不改变生产默认维度**。24 条合成样本不足以代表真实检索质量；纯向量存储的缩减不等于整个索引、进程内存或推理时间的同比缩减。缩短后重新归一化及查询/文档维度一致要求来自 [Google 模型说明](https://ai.google.dev/gemma/docs/embeddinggemma/model_card_2?hl=en)。

评估脚本修复后单独复跑 1 项通过、0 失败，逐条排序结果保留在本机 `build/acceptance-ai/dimension-evaluation.json`。

## 性能实测与边界

| 固定场景 | 结果 | 解释 |
| --- | ---: | --- |
| 241 篇合成文档，20 次查询 P95，改动前 → 后 | 6.21 → 3.21 ms | 独立分项运行，BM25 将预期重点文档排在前面；不是整机搜索耗时 |
| 1.08 MB 文本生成摘要，改动前 → 后 | 89.41 → 40.78 ms | 单次分项采样；不能当作稳定 P95 或普遍百分比收益 |
| 全量回归中同一文档查询 / 摘要 | 4.99 ms P95 / 61.61 ms | 同轮其他任务影响绝对耗时，完整保留 |
| 12 张 4032×3024 JPEG 缩略图 | 首张 36.45 ms，全部 58.08 ms | 缓存复用主线程 0.60 ms |
| 40 轮搜索/视图/预览切换 | 切换 P95 127.39 ms，最大 163.93 ms | 搜索就绪 P95 45.96 ms；不能称为全部流畅 |
| Quick Look 窗口出现 | 917.95 ms | 不等于图片已完整解码；此项仍需继续测首帧 |
| 30 万结果列表 / 宫格主线程处理 | P95 5.47 / 18.06 ms | 宫格出现 5 个超过 25 ms 的滚动间隔，列表 0 个 |
| 1,500 应用列表 / 宫格主线程处理 | P95 4.66 / 12.78 ms | 宫格出现 1 个超过 25 ms 的间隔 |
| 交互循环预热后内存 | 170.35 → 170.38 MiB | 短时合成运行，不代表长期真实库上界 |

滚动耗时不是显示 FPS。后续采样时宿主另有其他工程编译，带采样器的运行明显更慢，不能与不带采样器的历史结果直接作前后对比。采样集中在 AppKit 宫格视图创建/布局、图标栅格化与绘制提交；目前没有足够证据把长帧归因于某一个新函数。

## 技术评估与未完成项

- 新增固定中文文本语料的 128/256/512/768 维对照工具，复用已有模型，截取后重新 L2 归一化。默认生产索引仍为 768 维；小样成绩不能证明图片/音视频质量。
- 本机 SDK 中有 FoundationModels、CoreSpotlight、Vision 和 AppIntents，没有 CoreAI；当前 SDK 的模块接口未发现 SpotlightSearchTool。不能把系统已升级等同于新 SDK/API 已可编译。本轮未强行切换系统模型或推理后端。
- Foundation Models 命令行可用性探针编译成功，但运行返回 `unavailable(deviceNotEligible)`。本轮没有修改地区或系统 AI 设置，也不据此推断具体受限原因；系统模型还不能计为本机完成验收的替代后端。
- 仍待开发/评估：完整结构化照片元数据索引、约 200 条人工复核查询金标、中文短词分词和融合排名、按模态下载与加载、主体相似图片、带证据的文档问答、显式会话与文件关联、音视频片段、只读 MCP/App Intents。
- 仍待验收：各来源客户端真实会话导航、权限首次授权、多设备/较早系统、持续真实大库压力、预览首帧与宫格长帧。公开仓库/Release 的恢复仍需维护者确认。
- 全量运行中真实模型、签名包安装等可选项因环境参数未提供而跳过；补测结果在下方单列。公开 GitHub 下载未测试，私有状态下的 404 不作为下载成功。

## 复现

```sh
bash scripts/build-llama.sh
FOX_INTERACTION_STRESS=1 FOX_THUMBNAIL_WORKLOAD=1 \
  FOX_CONTENT_PERF=1 FOX_CONTENT_COUNT=100000 FOX_SCROLL_WORKLOAD=1 swift test

swift test --filter 'AIConversationTests|AITopic|WorkBuddy|SupplementarySearchTests|SearchEditingTests|SearchP0Tests'

FOX_SEMANTIC_DIMENSION_EVAL=1 \
  FOX_SEMANTIC_EVAL_OUTPUT="$PWD/build/acceptance-ai/dimension-evaluation.json" \
  FOX_FIND_TEST_MODELS="$HOME/Library/Application Support/Local Find/SemanticModels" \
  FOX_FIND_TEST_HELPER="$PWD/.build/debug/foxfind-semantic-worker" \
  swift test --filter 'SemanticDimensionEvaluationTests|SemanticTests/testReal|AIConversationTests/testLarge'
```

原始日志、采样和安装回执保留于被 Git 忽略的 `build/acceptance-ai/`；仓库只保留合成演示截图和汇总结果。

## 候选包与本机安装

- 应用源码提交：`adf4e808f31504cbf96bddad4dcc03ae76f39547`。
- 本地包：`dist/Fox-Find-0.0.1-macOS-arm64.zip`，12,248,161 bytes；未上传、未发布。
- ZIP SHA-256：`431100c59bebb75435dba04fc18e3a2846333dbaefac31b7fb0f9df38a03d104`。
- 可执行文件 SHA-256：`691248470fd97a9d9452eb2314a4a29cf562e044aed1646b722cf421c1ea1846`。
- Release 构建、严格代码签名验证、ZIP 完整性通过；签名更新清单通过实际安装/回滚测试（隔离临时目录，1 项通过）。
- `/Applications/Fox Find.app` 已替换为 **0.0.1 build 29**。构建、ZIP 与安装目录的 **59 个文件逐一散列一致**；三种对话来源图标及版权说明均在安装包中。
- 正常启动并完成 6 秒存活检查；该检查只确认启动，不是所有交互、首次权限或长时间稳定性的验收。
- 旧版保留于本机 `build/install-backups/Fox Find-before-0.0.1-20261017-204626.app`。偏好、收藏、内容索引未通过安装脚本删除或重置。
- 20:44 核对 GitHub：仓库 `private`，`v0.8.6` 和 `v0.8.3-preview.1` 均为草稿；本轮代码与演示文档仅本地提交。

## English status

Build 29 adds opt-in local AI conversation search, native previews/copy actions,
incremental source synchronization, and initial BM25 content ranking. It remains
a private 0.0.1 candidate. The full suite ran 382 tests (369 passed, 13 skipped),
followed by 54 focused passing tests after final UI changes. These runs overlap.
Synthetic workloads still recorded long grid intervals and slow preview startup;
this is not a claim that all performance issues are solved. Real source-app
navigation, first-run permissions, broader hardware/OS coverage and the remaining
research roadmap are not completed by this delivery.
