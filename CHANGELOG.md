# Changelog

## 0.8.6 — 2026-10-17

### Build 26

- 引导窗口随主窗口等高显示，移动和调整尺寸时保持上下对齐。
- The side guide follows the main window height and stays aligned when moved or resized.

- 操作菜单支持整行悬停高亮，鼠标和键盘选择保持同步，跳过不可用操作。
- 底部“操作”的文字、按键提示与其他快捷键提示统一。
- 从应用打开磁盘权限设置后，增加限时、一次性的退出重启衔接；主动退出和系统关机时取消。
- Actions highlight under the pointer and stay in sync with keyboard navigation, skipping unavailable commands.
- Consistent text and keycap styling across footer shortcuts.
- A bounded, one-shot companion reopens the app after the privacy pane quits it; explicit Quit and shutdown cancel the companion.

### Build 25

- 宫格无缩略图时显示对应的彩色文档、文件夹及应用图标。
- 图片缩略图采用独立的后台缩放队列，不再等待文件信息或文档预览，滚动后保留已加载图片。
- 操作菜单移除搜索框，增加深浅色柔和阴影，保留上下选择、回车执行、Esc 返回及操作快捷键。
- Full-color file, folder and app icons when grid previews are unavailable.
- Independently queued, downsampled image previews no longer wait for metadata or document providers; cached previews survive scrolling.
- A search-field-free actions menu with adaptive shadows, arrow/Return/Escape navigation and action shortcuts.

### Build 24

- 自动更新设置的开关靠右，检查更新按钮放在说明下方。
- 菜单栏“开机启动”改用胶囊开关，保留图标与文字对齐。
- 恢复 AppKit 响应式滚动；滑动时延后图标加载，停下后补充可见项。
- 网格按可见区域计算布局，减少大结果集的布局与绘制开销，保留上下渐隐。
- Update settings now place the switch on the right and the check button below the description.
- A native Launch at Login switch replaces the menu checkmark.
- Restored AppKit responsive scrolling, deferred cold icons during gestures and bounded grid layout to the viewport.
- Reduced tile painting overhead while preserving edge fades and full result access.

- Redesigned the update window with the Fox Find icon, frosted glass and clearer controls.
- Kept guide pages stable while typing, clearing queries and opening actions.
- Moved cold icon lookup off the scrolling thread; discarded stale thumbnail work and deferred previews during scrolling.

### 新增 / Added

- GitHub 自动检查更新与应用内下载、校验、重启安装。
- 菜单栏单色狐狸图标，随系统菜单栏明暗自适应。
- GitHub update checks with verified downloads and restart installation; a monochrome fox menu-bar icon.

### 优化与修复 / Improved and Fixed

- 应用网格显示真实应用图标，并以“应用”替代无意义的零大小。
- 顶部狐狸菜单补齐图标与文字，保留快捷键与原有操作。
- 设置采用统一毛玻璃与轻分组；筛选项左对齐，保留 16 pt 内边距并收紧间距。
- 滚动条缩细、降低亮度并适配深浅色，修复跟随位置与结果/预览区重叠。
- Actual app icons, icon-and-label menu commands, frosted settings and more consistent filter spacing.
- Accurate, thinner scroll thumbs in both appearances; result and preview areas no longer overlap.

- 更多操作面板收窄，统一蓝灰毛玻璃、圆角选中效果和渐隐滚动条。
- 关闭引导后重启保持关闭；菜单手动查看不会重新开启自动引导。
- 引导插图按显示尺寸解码；操作菜单复用行视图，减少重复刷新与预览清理。
- Compact frosted actions, persistent guide dismissal, smaller decoded artwork and less repeated UI work.

## 0.8.5 — 2026-10-17

### 新增 / Added

- 深色毛玻璃原生搜索界面，内置文件预览与常用文件夹入口。
- 面型分类图标、收拢的类型菜单，以及更清晰的底部快捷键提示。
- 引导窗口增加左右圆形翻页按钮，支持独立浏览三页说明。
- Native frosted search window with inline previews, folder shortcuts and custom category icons.
- Circular previous/next controls for browsing guide tips independently of task progress.

- 原生界面使用引导：搜索、预览与内容索引按实际操作推进，支持跳过和重新查看。
- 菜单栏和设置增加「使用引导」入口；升级用户默认不自动弹出。
- Native, event-driven guidance for search, preview and content indexing, with skip and replay.
- Getting Started entries in the menu bar and Settings. Existing users are not interrupted on upgrade.

### 优化 / Improved

- 毛玻璃底色调整为中性蓝灰，引导插图移除深色背景与大面积阴影。
- 修复下拉箭头旋转时偏移；查找方式菜单去掉重复图标。
- Neutral blue-gray glass with transparent guide artwork; centered dropdown rotation and simpler search-method choices.
- 结果上下边缘按实际滚动位置柔和渐隐，滚动条仅在滚动时显示，停止后淡出。
- 引导快捷键加入按压与回弹演示，插图轻移入场；切页和操作面板增加轻量过渡，遵循系统减少动态效果设置。
- 移除主搜索栏品牌图标与多余分割线，调整文字、图标和按钮的对齐及留白。
- PDF 页码提示改为「相关内容在第 X 页」「查看这一页」。
- Soft result-edge fades and transient scrollbars; gentle guide keypress, illustration and panel transitions.
- Cleaner spacing, aligned controls and plain-language related-page actions.

- 引导适配深浅色、中英文与自定义强调色；保留搜索焦点、输入法和结果滚动位置。
- 首份可用文字完成索引后即可开始搜索，不必等待整轮识别结束。
- Guidance follows appearance and accent preferences while preserving editing and result positions.
- First usable indexed text becomes searchable before the rest of the indexing pass finishes.

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
