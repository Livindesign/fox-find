# 私有发布准备与调研

调研日期：2026-10-17。**当前仓库保持私有；没有公开网站，也不接收打赏。**

## 能否商业化

可以以独立衍生项目提供源码、分发自建程序，并尝试自愿赞助。[MIT 许可](https://choosealicense.com/licenses/mit/)
允许商业使用、修改与分发，要求保留版权和许可。赞助不是收益保证；当前更适合验证使用价值，
不宜宣传为已经完成大规模兼容验证的成熟付费产品。

仅保留一句鸣谢不够：源码和二进制都应附完整许可。本次已将 Oil Find、DigUp、llama.cpp
及已识别的静态链接依赖许可放入 LICENSES，并随应用打包。另有来源 commit、改动范围、
独立维护与无背书说明。模型不随包分发，其 Apache-2.0 许可与应用 MIT 许可分开说明。

这不是“零隐患”结论：品牌名称/图标未做商标检索，跨境支付、平台规则与税务需按实际主体处理。
源码许可也不替代 Apple 签名、公证和兼容性验收。收费支持或商用发行条件改变时，应重新审查。

## 高 Star 项目的可借鉴部分

以下 Star 数为当日 GitHub API 快照，只是观察样本，不构成其增长原因的因果证明。

| 项目 | 当日 Stars | 借鉴内容 | Fox Find 的落地 |
| --- | ---: | --- | --- |
| [LocalSend](https://github.com/localsend/localsend) | 94,616 | 一句话用途、下载入口、多语言入口清楚 | 首屏讲用途，English/中文互链，直接到版本下载 |
| [Rectangle](https://github.com/rxhanson/Rectangle) | 30,083 | macOS 工具定位清晰，安装/使用/支持路径明确 | 单独的安装边界、快捷键、FAQ、支持说明 |
| [Maccy](https://github.com/p0deje/Maccy) | 21,953 | 简短卖点后马上能安装；针对真实问题的 FAQ | 不堆功能清单，先展示场景，再说明索引无结果与权限问题 |

页面采用真实 App 渲染和虚构文件素材，不使用上游截图伪装为 Fox Find，不借用上游性能数字。
图标沿用已确认的深色狐狸，官网用石墨黑、暖白与沙金。首屏只设一个主要下载按钮，
接着说明四种任务、隐私、安装边界、鸣谢和支持。没有虚构用户数、排名、用户评价或增长指标。

## 打赏怎么接

[GitHub 官方 FUNDING 文档](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/displaying-a-sponsor-button-in-your-repository)
允许通过 `.github/FUNDING.yml` 关联支持平台或自定义链接。当前账号未开通 GitHub Sponsors；
用户决定稍后设置爱发电。**因此暂不创建有效的 FUNDING 文件，不编造收款链接。**

收到确认后的爱发电公开地址，再核对页面主体、用途、付款/退款规则，将地址同步到 FUNDING、
SUPPORT 和网站。措辞为“支持 Fox Find 的维护”，不承诺开发排期、不声称原项目官方收费，
不使用“破解 Pro”“捐款免税”等表述。提醒用户也可以直接支持上游。

## 公开前清单

- [x] 新建独立私有仓库，来源与许可完整保留。
- [x] 双语 README、官网源码、上手说明、隐私、贡献指南、Issue 模板。
- [x] 私有预览 Release、源码包、应用包和 SHA-256。
- [ ] 维护者明确批准公开。私有状态不参与公开 Trending 或自然获客。
- [ ] 其他 Mac 和较早 macOS 的关键场景验收；Developer ID 与 Apple 公证。
- [ ] 爱发电账号与真实收款 URL。赞助始终自愿。
- [ ] 发布前再次核查版本资产与许可证，确认品牌名称与图标使用风险。

## 获得真实关注的第一轮

公开批准后，用 20–30 秒录屏演示一个完整任务：输入文件名 → 搜到截图文字 → 预览/打开。
中文重点解释内容索引怎么开启；英文重点讲 native macOS、local OCR、keyboard workflow。
先邀请少量真实用户测试，记录安装成功率、首次有效结果时间和一周后是否还在使用。
修好最常见的问题，再在相关社区按其规则分享一次；不要批量私信或到其他项目 Issue 拉 Star。

准备的 [发布文案](LAUNCH-COPY.md) 只供维护者审阅，尚未发布到任何社区。
Trending 没有本项目可保证的进入条件；真实持续使用比短期 Star 数更有价值。

## 主要参考

- [GitHub MIT 许可说明](https://choosealicense.com/licenses/mit/)
- [GitHub Sponsors](https://docs.github.com/en/sponsors/getting-started-with-github-sponsors/about-github-sponsors)
- [GitHub 赞助按钮配置](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/displaying-a-sponsor-button-in-your-repository)
- [Apple：安全地打开 Mac App](https://support.apple.com/zh-cn/102445)
- [Google EmbeddingGemma 2 模型卡](https://huggingface.co/google/embeddinggemma-2)
