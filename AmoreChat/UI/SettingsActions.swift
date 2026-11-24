import AVFoundation
import SwiftUI

struct DataManagementPage: View {
    @Bindable var controller: ChatController
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var confirmDeletion = false
    @State private var showDeepSeekImport = false

    var body: some View {
        List {
            Section("本机记录") {
                LabeledContent("会话", value: "\(controller.sessions.count)")
                LabeledContent("消息", value: "\(controller.sessions.reduce(0) { $0 + $1.messages.count })")
                Text("数据只保存在本机 Application Support。导出的 JSON 包括消息与附件路径，不包含附件文件本身。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("导出") {
                Button { prepareExport() } label: { Label("准备会话 JSON", systemImage: "square.and.arrow.up") }
                if let exportURL {
                    ShareLink(item: exportURL) { Label("分享会话 JSON", systemImage: "doc.text") }
                }
                if let exportError { Text(exportError).foregroundStyle(.red) }
            }
            Section("导入") {
                Button { showDeepSeekImport = true } label: {
                    Label("导入 DeepSeek 官方聊天 ZIP", systemImage: "square.and.arrow.down")
                }
                .disabled(controller.isGenerating || controller.isImporting)
                Text("仅接受已校验的官方 ZIP v3 纯文字与思考子集；不支持附件/工具的归档会全部拒绝，不会悄悄丢消息。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("清理") {
                Button(role: .destructive) { confirmDeletion = true } label: {
                    Label("清除本机所有会话和附件", systemImage: "trash")
                }
                .disabled(controller.isGenerating || controller.isImporting || controller.sessions.isEmpty)
            }
        }
        .sheet(isPresented: $showDeepSeekImport) {
            NavigationStack {
                DeepSeekImportView { result in
                    try await controller.importDeepSeek(result)
                }
                .navigationTitle("导入聊天记录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("关闭") { showDeepSeekImport = false }
                    }
                }
            }
        }
        .confirmationDialog("要清除全部本机记录吗？", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("永久清除", role: .destructive) { controller.deleteAllSessions() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除本机的会话、草稿和已归档附件。操作不可撤销；请先导出。")
        }
    }
    private func prepareExport() {
        do { exportURL = try controller.exportSessions(); exportError = nil }
        catch { exportError = "导出失败：\(error.localizedDescription)" }
    }
}

struct VoiceSettingsPage: View {
    @AppStorage("standalone.speech.voiceID") private var voiceID = ""
    @State private var reader = SpeechReader()
    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("zh") || $0.language.hasPrefix("en")
        }.sorted { $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language }
    }
    var body: some View {
        List {
            Picker("朗读音色", selection: $voiceID) {
                Text("系统默认").tag("")
                ForEach(voices, id: \.identifier) { voice in
                    Text("\(voice.name) · \(voice.language)").tag(voice.identifier)
                }
            }
            Button {
                reader.read("你好，这是 AmoreChat 的系统朗读示例。", voiceID: voiceID)
            } label: { Label("试听", systemImage: "speaker.wave.2") }
            Button { reader.stop() } label: { Label("停止试听", systemImage: "stop.circle") }
            Text("朗读只处理已有消息或试听文本，不会生成 AI 回答。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onDisappear { reader.stop() }
    }
}

struct UpdateCheckPage: View {
    let version: String
    @State private var status = "尚未检查"
    @State private var isChecking = false
    @State private var releaseURL: URL?
    var body: some View {
        List {
            LabeledContent("本机版本", value: version)
            Label(status, systemImage: isChecking ? "hourglass" : "info.circle")
                .fixedSize(horizontal: false, vertical: true)
            if let releaseURL { Link(destination: releaseURL) { Label("打开版本发布页", systemImage: "arrow.up.right.square") } }
            Button("重新检查") { Task { await check() } }.disabled(isChecking)
            Text("只查询本项目公开 GitHub Release，不会自动下载或替换应用。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task { await check() }
    }
    private func check() async {
        guard !isChecking else { return }
        isChecking = true; status = "正在连接 GitHub…"
        defer { isChecking = false }
        guard let url = URL(string: "https://api.github.com/repos/at9870451-bit/AmoreChat-Standalone-iOS/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AmoreChat-Standalone-iOS", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                status = code == 404 ? "尚无正式发布版本。" : "版本查询失败：HTTP \(code)"
                releaseURL = nil
                return
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let tag = json?["tag_name"] as? String, !tag.isEmpty,
                  let urlText = json?["html_url"] as? String,
                  let foundURL = URL(string: urlText), foundURL.host == "github.com" else {
                status = "发布数据无效，无法比较版本。"; return
            }
            releaseURL = foundURL
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            status = latest.compare(version, options: .numeric) == .orderedDescending
                ? "发现新版本 \(tag)" : "当前为最新正式发布版本（\(tag)）。"
        } catch {
            status = "无法联网检查更新：\(error.localizedDescription)"
            releaseURL = nil
        }
    }
}
