# Glamo 项目交接

本项目以本地视频文件的导入、预览、编辑和导出为主。使用原生 SwiftUI，最低 iOS 17，工程与共享 Scheme 均为 `Glamo`。本文件记录 2026-11-13 的交付和用户确认的约定。后续状态以本项目的代码、配置和新验证记录为准。

## 业务与测试约定

- 在线课程沿用 Clipo。课程页提供链接和短码输入，通过 `search-check` 进入可纵向切换的全屏播放器。游客登录、推荐、收藏、离线播放、额度、开屏与激励广告、订阅和恢复购买继续走原有路径。订阅与媒体导出保留服务端权益校验。
- 当前是测试配置。API 为 `https://devapi.io-jp.com`，`getV2.name` 为 `Glamo`，取自 `GlamoConfiguration.applicationName`，定义在 `Glamo/Core/APIClient.swift`。Bundle ID 为 `im.seex.lobo`，游客登录 `source` 和业务 `packageName` 同源。五包共用测试 BID，同一设备依次安装。
- 广告使用 Clipo 的 Google 官方演示 App ID 和开屏、激励广告位。官网、用户协议、隐私政策使用 HTTPS 占位链接。测试商品为月付 `coins_1.99` USD 9.99、年付 `conis_4.99` USD 99.99。会员页展示 StoreKit 返回的本地化价格和账期。
- 播放联调用 Clipo 的原测试短码，在「视频 → 课程 → 打开课程」手动输入。短码和广告配置见工具包的 [Clipo 基线](/Users/chengdupengyuyan/.codex/skills/toolkit/references/clipo-baseline.md) 第 1、5 节。Clipo 源工程位于 `/Users/chengdupengyuyan/Fun/Clipo`。
- 用户确认本项目测试通过后，再收集尚未提供的正式 BID、API 域名、广告 App ID 和广告位、官网、用户协议和隐私政策。切换时 Bundle ID、登录 `source` 与业务 `packageName` 一起使用正式 BID，`getV2.name` 继续用 `Glamo`。核对正式月年商品与后台订单映射。

## 本项目的原创界面

- App 图标和启动图使用原创玻璃视频片框。工作页面使用系统无衬线字体及动态字号，Plus 品牌标题保留 Instrument Serif。
- 「视频」首页优先展示文件导入、相册导入和最近文件。导入后打开原有编辑器，列表可预览本地视频和导出的音频。导入使用应用内副本，保存格式沿用已有文件索引。
- 视频、工具、文件和我的使用原创导航图标。常规窄屏竖屏使用悬浮玻璃底栏，宽屏、系统侧栏与无障碍大字号等场景使用原生 `TabView` 导航。背景延伸到容器边缘，前景按可用区域布局。
- **文件与课程**。「文件」按全部、导入和导出筛选本地文件。「课程」从首页打开，包含在线推荐、链接和短码、收藏、下载、妆容指南和试妆记录。
- **Plus 会员页**。优先展示 MP4 和 M4A 导出权益，继续提供本地化月年价格、六项权益、恢复购买和 Apple 订阅管理。实现见 `Glamo/Features/MembershipView.swift`。
- **试妆小结**。已验证的 Plus 会员可在试妆历史详情里，通过系统分享妆容名称、耗时、各部位镜前检查结果和备注。所有用户均可继续导出 CSV。
- 后续 UI 工作按全局 UI 技能约定使用 `ui-design-reference`、`ui-taste` 和适用的原创素材工作流。iOS 适配按 Duo 约定，保留当前 SwiftUI 和各主题的交互设计。

## 交付时的验证状态

- 已静态核对文件导航、导入与导出入口、课程返回路径、本地化及图标资源。
- 待运行验证的事项包括编译、本地导入和预览、模拟器和真机显示、Duo 布局、测试后台返回、短码播放、广告以及 Apple Sandbox 购买与恢复。按用户约定，默认只做静态核对，编译和测试在用户明确要求时执行。
