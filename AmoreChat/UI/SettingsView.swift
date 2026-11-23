import SwiftUI

struct SettingsView: View {
    @Bindable var controller: ChatController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("服务连接") {
                Label("尚未配置后端", systemImage: "wifi.slash")
                    .foregroundStyle(ChatTheme.muted)
                Text("这是从零编写的独立 iOS App，尚未收到服务地址和 API 文档。发送功能会保持禁用，不会生成假的 AI 回答。")
                    .font(.footnote)
                    .foregroundStyle(ChatTheme.muted)
            }
            Section("对话偏好") {
                Toggle("深度思考", isOn: $controller.thinkingEnabled)
                Toggle("联网搜索", isOn: $controller.webSearchEnabled)
                Text("偏好会在接入真实后端时通过 ChatBackend 的选项传递；当前不会触发网络请求。")
                    .font(.footnote)
                    .foregroundStyle(ChatTheme.muted)
            }
            Section("数据") {
                LabeledContent("保存方式", value: "仅存于本机")
                LabeledContent("会话数", value: "\(controller.sessions.count)")
                Text("每次修改以原子写入方式保存到 Application Support；附件由应用复制到独立目录。")
                    .font(.footnote)
                    .foregroundStyle(ChatTheme.muted)
            }
            Section("关于") {
                LabeledContent("版本", value: "0.1.0")
                Text("界面参考通用聊天应用交互，使用原创图形与 SwiftUI 代码，不包含 Amore/OpenMinis 或 DeepSeek 的源码及品牌资源。")
                    .font(.footnote)
                    .foregroundStyle(ChatTheme.muted)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }
}
