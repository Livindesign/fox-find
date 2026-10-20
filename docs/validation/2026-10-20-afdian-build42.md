# 爱发电接入 · build 42

日期：2026-10-20。范围为赞助入口、设置中的关于分组及相关文档。
仓库保持私有；本轮不是公开版本发布，也不替代 build 41 的完整发布验收记录。

## 接入结果

- GitHub Sponsor 使用 `.github/FUNDING.yml` 的自定义链接：
  <https://afdian.com/a/livindesign>。
- 中英文 README、SUPPORT 和应用按钮使用同一地址，标价为 9.9 元/月。
  说明支持一次可选择一个月，依据爱发电官方 FAQ 说明无自动续费。
- 已通过公开浏览器页面核对地址可访问，并显示 9.90 元/月；未进行支付。
  页面当时仍显示“未认证创作者”，品牌头像与动态可在维护者完成认证后完善。
- 应用设置底部新增“关于 Fox Find”：现有 Logo、版本与 MIT 标识、咖啡和项目主页按钮。
  复用 `SettingsGroup`、`SettingsButtonStyle`、`Theme` 圆角及原有玻璃窗口，
  按钮均为图标加文字；关于分组随设置语言重新呈现。

## 验证

| 项目 | 结果与边界 |
| --- | --- |
| 相关回归 | 三项通过、零失败：本地化键、既有设置窗口语言切换、原文件图片对照；最终界面微调后两项语言检查再次通过 |
| 中英文界面 | 两种语言的原生隔离设置截图均通过人工检查；按钮、说明无截断，保持中性灰 |
| 原生按钮跳转 | 本机应用内点击咖啡按钮，默认浏览器打开维护者的爱发电主页；项目主页按钮打开 Fox Find 仓库 |
| 原生语言切换 | 静态双语截图和设置语言用例已通过；手动切换检查遇到桌面状态变化后停止，未将其算作手动切换通过 |
| 安装 | `/Applications/Fox Find.app` 更新为 0.0.1 build 42；与构建产物的 60 个文件哈希一致，旧 build 41 保留备份 |
| 签名 | ad-hoc 严格校验通过；没有新增公证或正式分发身份 |
| 源码分发 | 敏感路径、凭据模式与许可完整性检查通过；维护者已有的独立文档改动未纳入提交 |

本机当前工具链为 Swift 6.4 / macOS 27 SDK。初次构建遇到既有图片指纹中的
加权灰度表达式类型检查超时，已拆为三个等价整数子表达式；相关图片对照用例通过。
本轮未进行全量性能或实际模型验收。

日志与本地证据：`build/sponsorship42-tests.log`、
`build/sponsorship42-final-tests.log`、`build/sponsorship42-release.log`、
`build/sponsorship42/about-zh.png`、`build/sponsorship42/about-en.png`、
`build/integrated-build42-receipt.json`。这些本机产物不作为公开附件上传。

## English

Build 42 connects the same maintainer-supplied Afdian URL to the GitHub Sponsor
configuration, bilingual documentation and an About section in Settings. The plan
is CNY 9.9/month; one month can be selected for one payment. The live creator page
and price were checked, without making a payment.

Three affected regression tests passed. Two language checks passed again after
final UI adjustments. Both synthetic native-language renders were inspected, and
both external buttons were exercised in the installed app. The attempted manual
language switch was stopped after desktop state changed and is not counted as a
manual language-switch pass. Build 41 is backed up; build 42 is installed locally
and ad-hoc signed. Repository visibility and public release status are unchanged.
