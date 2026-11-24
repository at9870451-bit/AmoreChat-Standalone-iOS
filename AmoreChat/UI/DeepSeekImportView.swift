import SwiftUI

/// File selection and validation do not mutate the chat store. Only confirmation commits.
struct DeepSeekImportView: View {
    let onCommit: @MainActor (DeepSeekImportResult) async throws -> (added: Int, duplicates: Int)
    @Environment(\.dismiss) private var dismiss
    @State private var showingPicker = false
    @State private var showingImportFolder = false
    @State private var parsed: DeepSeekImportResult?
    @State private var isBusy = false
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("导入 DeepSeek 历史记录").font(.title3.bold())
            Text("仅支持官方导出的 ZIP v3。先校验完整压缩包，不覆盖本机聊天。当前只接收纯文本、思考内容和已完成消息；附件、网页工具、模板提示等会使整包报错，不会悄悄丢弃。请保留原始 ZIP 备份。")
                .font(.footnote).foregroundStyle(.secondary)
            if let parsed {
                Text("已检查：\(parsed.sourceSessionCount) 个原始会话，\(parsed.sessions.count) 个线性会话（含 \(parsed.branchCount) 个分支副本），\(parsed.messageCount) 条消息。")
                    .font(.subheadline)
                Button("确认导入") {
                    isBusy = true
                    Task { @MainActor in
                        defer { isBusy = false }
                        do {
                            let result = try await onCommit(parsed)
                            notice = "已导入 \(result.added) 个会话，跳过 \(result.duplicates) 个重复会话。"
                            self.parsed = nil
                        } catch { notice = "保存失败，未提交导入：\(error.localizedDescription)" }
                    }
                }
                .disabled(isBusy)
                .accessibilityIdentifier("history.import.confirm")
            }
            Button("选择 DeepSeek ZIP") { showingPicker = true }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                .accessibilityIdentifier("history.import.pick")
            Button("本机导入文件夹") { showingImportFolder = true }
                .disabled(isBusy)
                .accessibilityIdentifier("history.import.folder")
            if isBusy { ProgressView("正在处理…") }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("history.import.result")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ChatTheme.settingsBackground.ignoresSafeArea())
        .navigationTitle("导入聊天记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("返回") { dismiss() }.disabled(isBusy)
                    .accessibilityIdentifier("history.import.back")
            }
        }
        .sheet(isPresented: $showingImportFolder) {
            ImportFolderView(zipOnly: true) { url in prepare(PickedDocument(url)) }
        }
        .background {
            NativeDocumentPicker(isPresented: $showingPicker) { document in
                if let document { prepare(document) }
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private func prepare(_ document: PickedDocument) {
        parsed = nil; notice = nil; isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            do {
                parsed = try await Task.detached(priority: .userInitiated) {
                    try LocalDocumentImport.loadDeepSeek(document.url)
                }.value
            } catch { notice = error.localizedDescription }
        }
    }
}
