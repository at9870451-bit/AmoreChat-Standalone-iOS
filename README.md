# AmoreChat Standalone iOS

这是**从空工程编写**的原生 SwiftUI 聊天 App，不基于、也不包含 Amore / OpenMinis 的源码、页面、业务逻辑、数据库或 IPA。仓库 `at9870451-bit/AmoreChat-Standalone-iOS` 与先前误做的 `AmoreChat-iOS` 仓库是两个不同项目。

## 当前可用

- 按用户四张参考图重排原生白底/深色蓝点缀：居中欢迎语、左抽屉、双图标顶栏、胶囊输入与拍照/相册/文件展开态、分组设置页。抽屉、新建/搜索实际消息内容/切换/重命名/置顶/删除会话与确认操作。
- Application Support 目录中的本地 JSON 会话库（原子写入）、各会话草稿，以及沙盒中的图片/文件附件；使用系统相机、PhotosPicker、Files 导入和 Speech 框架语音转文字。模型请求支持 JPEG/PNG/WebP/GIF，HEIC 安全转 JPEG，可提取文字的 PDF 和 UTF-8 文本；本地附件不再受服务器上传限制；图片 HEIC 转 JPEG 后按所选模型能力发送。
- 用户/助手左右排版，AI 回复无会话头像；紧凑可折叠思考过程，灰色用户气泡和原生 Markdown/代码高亮/表格/有限离线 MathML。输入区在空白与编辑状态共用语音／发送圆键；生成中独立停止键和加号、语音键并排。点语音圆键切换到按住听写，实时显示系统回传的文字，松手后只填入草稿，不自动发送。聊天页轻点空白可收键盘。
- 消息复制、分享、后缀删除是本机真实操作，TTS 可朗读已有回复。模型请求内置概括性的中文助手人设：短输入先承接上下文，作品类别默认介绍或推荐真实作品，只有用户明确邀请或已约定互动时才开局；日常聊天简短自然，技术回答按需要展开。人设不包含聊天原文、标题、附件、账号或 ZIP 内容。可在「设置 → 添加模型 / 服务商」输入自己的 HTTPS 接口、模型 ID 和 API Key（保存在 iOS 钥匙串），选择 DeepSeek、OpenAI、OpenRouter 或 Chat Completions 兼容地址；`ChatBackend` 使用 SSE 真实流式传输文本/思考内容，支持停止、失败、重试和重新生成。**未配置模型时发送禁用，不伪造 AI 回复。** 联网搜索支持官方 OpenRouter，以及按服务商文档明确配置为兼容其网页插件的自定义接口；开启时需确认可能额外计费。自定义 Chat Completions 模型也可显式配置思考协议；真实可用性以配置端点为准。

## 设置页功能边界

外观支持系统跟随与强制浅／深色，个性化开关可在思考结束后自动折叠。朗读音色使用 iOS 系统音色，可滑动、试听并确认保存，不冒充 DeepSeek 的云端音色。数据管理支持本地 JSON 导出、清除和 DeepSeek ZIP v3 导入。导入参考 [DeepSeek 官网归档的公开读取规范](https://github.com/deepseek-ai/deepseek-harness/blob/4b399c39a6d1479cd84ca591b4d7c88e24d38a96/packages/experimental/deepseek-chat-import/README.zh.md)：已完成的纯文字／思考子集保留时间、思考耗时（若有）和分支；分支作为单独会话，重复导入去重，不覆盖本机记录。含附件、工具、模板或不支持状态的归档会整包拒绝。只有公开格式和合成样本，没有实测用户的 iOS 官方导出文件。应用现在接入 AmoreChat 账户服务：首次打开必须用账号密码登录或在邀请码下注册；设置中显示真实 token 余额、邀请码和额度流水；服务器不保存聊天记录、附件或照片，本地附件不受服务器大小限制；服务协议及权限页说明账号数据与仅本机保存策略。额度显示与后台账本已接通；服务器 API 的每次回复按上游返回的真实用量扣减账户 token，BYOK 模型不扣服务器 token。模型用量不能等同于供应商账单；后台调整、奖励和异常消费均记录流水。公式支持有限 LaTeX 子集。

## 从文件导入

- 聊天附件：点输入栏 `＋ → 文件`。选择完成后复制到本机草稿，不会自动发送；文件卡片显示真实文件名和大小。
- DeepSeek 历史：侧栏 → 设置 → 数据管理 → 导入 DeepSeek 官方聊天 ZIP。选择原 ZIP，不要先解压；预览后再确认合并。导入仅支持上文所述 v3 子集。
- 如果系统「文件」能显示却交不回所选文件：在「我的 iPhone → AmoreChat → Imports」复制一份，返回相应入口的「本机导入文件夹」，刷新并选择。只有用户放入 Documents 的文件会在「文件」中可见；会话库、已归档附件和钥匙串不在该目录。

## 构建

需要 macOS 和 Xcode 26.x（目标 iOS 18+）。先用 `xcodegen generate --spec project.yml` 生成 `AmoreChatStandalone.xcodeproj`，再运行 `xcodebuild -project AmoreChatStandalone.xcodeproj -scheme AmoreChatStandalone -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`。GitHub Actions 的 `Standalone iOS Device Build` 和 `Standalone iOS UI Screens` 分别核验真 iOS 设备目标与模拟器。版本 `0.5.3`，Bundle ID `app.amorechat.standalone`，**不会覆盖旧 Amore App**。正式真机安装仍需自己的签名；本项目不自带或读取服务商密钥，在线模型请求、付费搜索与系统权限需在用户配置后验收。

项目结构：`AmoreChat/App.swift` App 入口与导航；`Core/ChatModels.swift` 数据与后端协议；`Core/ChatController.swift` 状态与流式生命周期；`Core/ChatArchive.swift` 本地原子持久化；`Core/SpeechInput.swift` 原生语音服务；`UI/` 全部独立 SwiftUI 组件。原创应用图标由 `scripts/make_icon.py` 生成。

## 大小限制

0.5.3 起 App 不限制本地聊天记录、附件、图片或导入 ZIP 的业务大小；实际可用空间由设备决定。发送给模型时请求体大小受设备内存与所选服务商限制，服务商拒收会显示上游错误，AmoreChat 服务器不存储聊天或附件。
