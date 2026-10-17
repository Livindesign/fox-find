# Changelog

## 0.8.3 — 2026-10-17

### 新增

- 统一文件操作入口：右键菜单、列表/网格中的「…」和 `⌘K` 均可操作当前文件。
- 支持在 `⌘K` 操作菜单中搜索命令，并显示对应快捷键。
- 搜索条件支持单独移除；相似图片搜索显示参考图和退出入口。

### 优化

- 将查找方式收拢为「自动 / 仅文件名 / 文件内容」菜单，与排序独立设置，减少筛选区占用。
- 调整列表与网格操作按钮、文件信息、底部按键指引的对齐和间距。
- 完善内容目录、索引进度和相近内容的状态提示。
- 后台补充内容结果时保留已有结果、选中项和滚动位置，减少界面跳动。

### 修复

- 修复内容搜索刷新期间结果短暂清空、闪烁和搜索状态反复切换的问题。
- 修复操作菜单打开期间后台刷新可能改变操作目标的问题。
- 修复退出相似图片搜索后未恢复原分类和排序的问题。
- 修复手动切换分类或位置后，旧的解析条件仍影响搜索的问题。

---

### Added

- Unified file actions across right-click, list/grid overflow and `⌘K`.
- Searchable action menu with keyboard shortcuts.
- Removable search conditions and a reference-image context with an explicit exit action.

### Improved

- Compact matching-mode menu, separate from sorting.
- Alignment and spacing for file metadata, action buttons and footer shortcuts.
- Clearer content-folder, indexing-progress and related-result status.
- Existing results, selection and scroll position stay in place as additional content results arrive.

### Fixed

- Transient empty results, flicker and repeated searching/result-state transitions during content refreshes.
- Background updates changing the file targeted by an open action menu.
- Previous category and sorting not being restored after leaving image-similarity search.
- Stale parsed conditions remaining active after manually changing category or location.
