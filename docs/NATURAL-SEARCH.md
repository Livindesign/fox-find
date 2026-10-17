# Natural-language search / 自然语言搜索

## Current behavior — 0.0.1 build 33 candidate

Fox Find first resolves supported Chinese expressions into exact filters, then
uses the remaining words for filename/content search and optional semantic search.
The conditions below the search field show what was understood.

先把支持的中文表达转换成明确条件，再用剩余描述查找文件名、文字和可选语义结果。
搜索框下方的条件标签显示实际理解的日期、类型和位置。

| Input / 输入 | Interpretation / 实际含义 |
| --- | --- |
| `7月拍摄的照片` / `七月拍的相片` | Images captured in July across all years; the chip says All years. 所有年份 7 月的图片，标签明确显示“所有年份”。 |
| `去年7月拍摄的照片` | July of the previous year. 去年 7 月。 |
| `2024年2月29日拍摄的照片` | That calendar day in the current time zone. 当前时区中的指定日期。 |
| `上个月拍摄的照片` / `上周拍摄的照片` | Previous calendar month / Monday–Sunday week. 上一个自然月／周一至周日。 |
| `最近7天拍摄的照片` | Rolling seven-day interval. 最近连续 7 天。 |
| `下载目录7月拍摄的红色照片` | Downloads + July across all years + images; “红色” is the description. 下载目录、所有年份 7 月、图片是硬条件，“红色”是描述。 |
| `蓝天和山丘的图片` | Images only; visual description can use semantic retrieval. 仅图片，剩余描述可用于语义检索。 |

Capture time comes from EXIF DateTimeOriginal. Missing/unreadable capture dates are
excluded and counted as unknown. Filename dates, file creation/modification times
and EXIF digitization times do not substitute for capture time. Calendar boundaries
are half-open: July includes July 1 but excludes August 1. A month without a year
means that month in every year. An explicit year still selects only that year.

拍摄时间读取 EXIF 原始拍摄日期；缺失或无法读取时记为未知，不用文件名、创建时间、
修改时间或数字化时间替代。7 月范围包含 7 月 1 日，不包含 8 月 1 日。
只写月份会查找所有年份的该月；写明年份或“去年”时，严格按指定年份查找。

Date/type-only queries bypass OCR and model inference, including in Content mode.
Explicit descriptions still honor the selected matching mode. Names mode does
not perform semantic retrieval. Quoted names, paths and explicit query syntax stay literal.

仅日期和类型的查询直接筛选文件，不依赖 OCR 或模型，选择“内容”模式也一样。
有描述词时仍遵循查找方式；“文件名”模式不运行语义查询。引号、路径和显式查询语法保留原义。

## Known gaps / 已知边界

- `7月至8月拍摄的照片`, `7月的照片`, `昨天下载的PDF`, invalid dates and unsupported
  exclusions/comparisons such as `不要红色的照片` or `不超过10MB的图片` are **not fully parsed**.
  They now show a limitation message and use literal search; approximate suggestions are suppressed.
  区间、未指明日期含义、下载时间及排除／上限条件尚未完整支持；现在会提示，并停止语义补充。
- “Shot in Beijing”, people, exact object counts, colors and relationships are not
  verified GPS/person/object predicates. Embedding similarity cannot prove them.
  “北京拍摄”“两个人”“没有红色”需要对应的数据与规则，不能把相似度当作事实校验。
- English natural-language date parsing, arbitrary word order and arbitrary Chinese
  expressions are not complete. The guard recognizes a bounded set, not every unsupported phrase.
  英文日期和任意中文句式未完整覆盖，提示保护也不是通用语言理解器。
- Metadata is cached per file but currently filtered by inspecting candidates;
  a large cold photo library can still take time. Missing permissions, cloud-only
  files and incomplete indexing limit coverage.
  大图库的冷元数据筛选仍可能耗时；权限、云端占位文件、索引未完成都会影响覆盖。

## Recommended next work / 下一步优先级

These are proposals, not completed functionality or measured performance gains.
以下是方案，不是已完成能力或已测出的提速。

1. **Typed metadata index first.** Persist source/path/type/capture time, its provenance,
   availability and fingerprint in indexed SQLite columns. Apply date/type/scope before
   scoring; update incrementally and explain unknown coverage. Keep model inference off
   the filter-only path. 元数据预索引优先，避免每次查询逐张读取照片头。
2. **One validated query plan.** Represent date field, range, scope, type, comparisons,
   exclusions and residual description explicitly. Extend a shared Chinese/English test
   corpus. An optional small language model may propose a plan for complex phrasing,
   but every operator/value must validate; never silently drop unsupported conditions.
   通用查询计划先于扩展正则，复杂表达也必须验证，不能静默丢条件。
3. **Rank relevant descriptions.** Preserve exact filename matches, add text relevance
   ranking, then fuse text and visual candidates within the same hard constraints.
   Current text search uses FTS5 trigram substring matching; it does not yet rank with BM25.
   SQLite provides [BM25 and column weighting](https://www.sqlite.org/fts5.html#the_bm25_function).
   [Elastic's hybrid-search documentation](https://www.elastic.co/docs/solutions/search/hybrid-search)
   describes RRF fusion. Adapt these ideas locally; no Elasticsearch server is required.
4. **Rerank a bounded shortlist only if evaluation justifies it.** A query/document
   reranker can improve ordering but costs inference time. Test the top 20–50 candidates,
   not the whole library; text reranking alone cannot verify image pixels.
   [Retrieve & Re-Rank](https://sbert.net/examples/sentence_transformer/applications/retrieve_rerank/README.html).
5. **Acceptance corpus before model changes.** Include dates/year rollover/time zones,
   wrong types, zero-answer queries, negatives, Chinese two-character terms, OCR noise,
   names and image descriptions. Measure hard-filter violations (target zero), precision
   at 10, recall, first-results P95, total P95, memory and cancellation. Compare the same
   files/queries before and after; do not import another project's benchmark numbers.

The current vector store scans vectors with exact dot products and fixed modality
thresholds. ANN may help a much larger vector corpus, but approximate indexes must
be benchmarked for recall and filtering; adding one does not repair incorrect intent parsing.
当前向量库逐条算相似度，阈值固定。大库可评估 ANN，但它不能修复意图解析错误。

Capture metadata is checked automatically in a bounded background queue. Cached
matching dates are indexed and inspected first, then uncached files are checked.
Cached candidates are revalidated; missing EXIF is never replaced with file mtime.
Editing or clearing the search cancels obsolete work. Repeatedly stalled file
reads preserve progress and expose a retry action instead of blocking the UI.

拍摄信息在后台自动检查，缓存中的匹配日期优先返回，其余文件随后补齐。
已有缓存会核对文件是否变化，不用修改日期替代缺失的 EXIF。修改或清空
搜索会取消旧任务；连续无法读取的文件保留进度并提供重试，不阻塞界面。
