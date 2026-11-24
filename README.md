# AmoreChat Standalone iOS

这是**从空工程编写**的原生 SwiftUI 聊天 App，不基于、也不包含 Amore / OpenMinis 的源码、页面、业务逻辑、数据库或 IPA。仓库 `at9870451-bit/AmoreChat-Standalone-iOS` 与先前误做的 `AmoreChat-iOS` 仓库是两个不同项目。

## 当前可用

- 按用户四张参考图重排原生白底/深色蓝点缀：居中欢迎语、左抽屉、双图标顶栏、胶囊输入与拍照/相册/文件展开态、分组设置页。抽屉、新建/搜索实际消息内容/切换/重命名/置顶/删除会话与确认操作。
- Application Support 目录中的本地 JSON 会话库（原子写入）、各会话草稿，以及沙盒中的图片/文件附件；使用系统相机、PhotosPicker、Files 导入和 Speech 框架语音转文字。模型请求支持 JPEG/PNG/WebP/GIF，HEIC 安全转 JPEG，可提取文字的 PDF 和 UTF-8 文本；超过 8MB 或无法解析的附件会在发送前明确报错，不会假称已上传。
- 用户/助手左右排版，AI 回复无会话头像；紧凑可折叠思考过程，灰色用户气泡和原生 Markdown/代码高亮/表格/有限离线 MathML。输入区同一主按钮在空白、文字输入和生成中分别承担实时语音、发送和停止；加号与主按钮并排。聊天页轻点空白可收键盘。
- 消息复制、分享、后缀删除是本机真实操作，TTS 可朗读已有回复。可在「设置 → 添加模型 / 服务商」输入自己的 HTTPS 接口、模型 ID 和 API Key（保存在 iOS 钥匙串），选择 DeepSeek、OpenAI、OpenRouter 或 Chat Completions 兼容地址；`ChatBackend` 使用 SSE 真实流式传输文本/思考内容，支持停止、失败、重试和重新生成。**未配置模型时发送禁用，不伪造 AI 回复。** 联网搜索仅对官方 OpenRouter 主机且用户明确确认可能额外计费后启用；其他服务商不伪装支持搜索。自定义 API 需兼容 Chat Completions，真实可用性取决于服务商。

## 设置页功能边界

外观支持系统跟随与可强制浅/深色，语言（中英繁主要文案）、系统动态字号、本机昵称、系统朗读音色试听、会话 JSON 导出/确认清除、GitHub Release 检查与反馈链接接真实本地或网络动作。数据管理支持导入 `deepseek-ai/chat-demo` 文档定义的 DeepSeek ZIP v3：严格校验并只导入纯文字/思考/已完成会话；含图片、工具、模板、异常状态或不兼容结构时整包失败，绝不假装完整导入。当前未取得用户真实官方导出 ZIP，模拟器只以合成的 v3 结构验证，无法保证你实际归档完全兼容。**账号管理和退出登录需要后端账号协议，当前显示“本机访客/不可退出”，绝不模拟登录或云同步；服务协议页仅陈述本地版实际数据处理，不冒充第三方条款。** 公式只支持有限 LaTeX 子集，其他原样显示源码。

## 构建

需要 macOS 和 Xcode 26.x（目标 iOS 18+）。先用 `xcodegen generate --spec project.yml` 生成 `AmoreChatStandalone.xcodeproj`，再运行 `xcodebuild -project AmoreChatStandalone.xcodeproj -scheme AmoreChatStandalone -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`。GitHub Actions 的 `Standalone iOS Device Build` 和 `Standalone iOS UI Screens` 分别核验真 iOS 设备目标与模拟器。版本 `0.3.0`，Bundle ID `app.amorechat.standalone`，**不会覆盖旧 Amore App**。正式真机安装仍需自己的签名；本项目不自带或读取服务商密钥，在线模型请求、付费搜索与系统权限需在用户配置后验收。

项目结构：`AmoreChat/App.swift` App 入口与导航；`Core/ChatModels.swift` 数据与后端协议；`Core/ChatController.swift` 状态与流式生命周期；`Core/ChatArchive.swift` 本地原子持久化；`Core/SpeechInput.swift` 原生语音服务；`UI/` 全部独立 SwiftUI 组件。原创应用图标由 `scripts/make_icon.py` 生成。
