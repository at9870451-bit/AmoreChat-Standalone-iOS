# AmoreChat Standalone iOS

这是**从空工程编写**的原生 SwiftUI 聊天 App，不基于、也不包含 Amore / OpenMinis 的源码、页面、业务逻辑、数据库或 IPA。仓库 `at9870451-bit/AmoreChat-Standalone-iOS` 与先前误做的 `AmoreChat-iOS` 仓库是两个不同项目。

## 当前可用

- 按用户四张参考图重排原生白底/深色蓝点缀：居中欢迎语、左抽屉、双图标顶栏、胶囊输入与拍照/相册/文件展开态、分组设置页。抽屉、新建/搜索实际消息内容/切换/重命名/置顶/删除会话与确认操作。
- Application Support 目录中的本地 JSON 会话库（原子写入）、各会话草稿，以及沙盒中的图片/文件附件；使用系统相机、PhotosPicker、Files 导入和 Speech 框架语音转文字。
- 用户/助手区分、原生 Markdown 基本排版、常见语言代码着色、横向可滚动表格、有限 LaTeX→MathML 本地渲染（不能解析的公式原样展示），可展开的思考内容、消息复制/分享、仅本机的反馈记录。
- 消息长按的复制、分享和后缀删除是本机真实操作；系统 TTS 可朗读已存在回复。`ChatBackend` 协议支持文本/思考内容异步流、停止、失败、重试与重新生成、模式选项；**目前没有提供后端地址或 API 文档，默认适配器未配置，因此发送按钮明确禁用，不产生虚构回复，也不会实际进行联网搜索。** 请在拿到接口文档后单独实现 `ChatBackend`；仅打开 UI 模式开关不代表后台能力已经可用。

## 设置页功能边界

外观、语言（中英繁主要文案）、系统动态字号、本机昵称、系统朗读音色试听、会话 JSON 导出/确认清除、GitHub Release 检查与反馈链接均接真实本地或网络动作。**账号管理和退出登录需要后端账号协议，当前显示“本机访客/不可退出”，绝不模拟登录或云同步；服务协议页仅陈述本地版实际数据处理，不冒充任何第三方服务条款。** 公式仅支持明确列出的有限 LaTeX 子集，其他原样显示源码。

## 构建

需要 macOS 和 Xcode 26.x（目标 iOS 18+）。先用 `xcodegen generate --spec project.yml` 生成 `AmoreChatStandalone.xcodeproj`，再运行 `xcodebuild -project AmoreChatStandalone.xcodeproj -scheme AmoreChatStandalone -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`。也可查看 GitHub Actions `Standalone SwiftUI iOS` 的编译与测试结果。版本 `0.1.0`，Bundle ID `app.amorechat.standalone`，**不会覆盖旧 Amore App**。正式真机安装还需你自己的签名。签名、真机、模型请求、摄像头/麦克风权限与实际后端接入需分别验收；CI 编译成功不等于这些环节均已通过。

项目结构：`AmoreChat/App.swift` App 入口与导航；`Core/ChatModels.swift` 数据与后端协议；`Core/ChatController.swift` 状态与流式生命周期；`Core/ChatArchive.swift` 本地原子持久化；`Core/SpeechInput.swift` 原生语音服务；`UI/` 全部独立 SwiftUI 组件。原创应用图标由 `scripts/make_icon.py` 生成。
