# Getting started guide / 使用引导

Fox Find 的产品定位是「小而美」。引导帮助用户完成一次真实搜索，不展示功能清单。

新用户从欢迎页进入搜索后自动开始；升级用户不自动弹出。在 macOS 菜单栏的 Fox Find 菜单选择「使用引导…」，或在设置的通用区域重新打开。

1. 输入应用名或文件名；有真实结果后进入下一步。
2. 预览、打开或查看选中结果的操作。没有结果时不会假装完成。
3. 按需设置内容搜索：选择一个文件夹，按系统提示授权。出现首份可搜索内容后，回到「文件内容」模式输入文件中实际出现的词。

引导可以随时关闭；Esc 先关闭引导，下一次 Esc 按原有方式处理。中文组词时 Esc 交给输入法，Tab 在引导期间用于原生焦点导航。菜单和预览使用现有快捷键。重看引导不会清除用户的索引或偏好。引导不下载模型、不启用语义搜索、不增加全局键盘监听，也不添加遥测。

A native guide starts after the welcome screen for new users. Existing users can replay it from the menu bar or Settings. Reading pages change only with the arrow controls; typing and search results never turn the page. Explicit setup actions enter the live content setup flow. Content search is optional, uses selected folders and reports real indexing status. Skip or dismiss anytime; it does not download models, enable semantic search or send analytics.

## Implementation

- `GuideProgress`: persisted, event-driven progression. Old users and dismissed/completed guides remain quiet.
- `GuideModel`: aggregate content readiness and bilingual copy. Observes content updates only while active.
- `GuideOverlay`: a native child panel beside search when there is room, or a compact window-local card on smaller screens. It preserves search focus on appearance and never changes result row layout. Clicking a guide button may focus the guide; Esc closes it.
- Circular arrows around the step count browse tips only. Actual search/action/indexing events still control persisted progress; browsing never marks work complete.
- Keycaps demonstrate a single press/rebound per page. Artwork enters with a small translation and settles; transitions use no permanent animation loop. Reduced Motion removes translation and keypress movement.
- Search uses a single clip-layer gradient mask per viewport. Overlay scrollbars fade after 750 ms of inactivity; a single timer runs only during a gesture.
- `GuideSettingsHeader`: the same visual language beside real content settings; native folder picker and system permissions.
- Content updates are coalesced. The first usable text is published once per indexing pass from the worker queue; later records retain the existing batching behavior.

UI snapshots use DEBUG-only `--guide search|result|contentOffer|contentSetup|contentSearch|success`, with optional `--guide-content empty|indexing|ready|paused|error`. Always supply a synthetic `--db` and isolated `LOCALFIND_TEST_PROFILE`; `contentSetup` uses `--state settings`. These controls are unavailable in release builds.

Tests cover upgrade/skip persistence, real-event progression, content readiness, IME/Escape, focus preservation, compact layouts, action-menu coexistence, index notifications and list/grid stability. Screenshots cover both appearances and languages. System permission prompts and older macOS hardware still require manual acceptance on those systems.
