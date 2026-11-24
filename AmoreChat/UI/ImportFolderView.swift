import SwiftUI

/// A fallback for a provider that lists a file but does not return its URL to the picker.
struct ImportFolderView: View {
    let zipOnly: Bool
    let onSelection: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var files: [URL] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("在系统「文件」中，将文件复制到「我的 iPhone → AmoreChat → Imports」。返回此页后，点右上角刷新并选择文件。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section(zipOnly ? "ZIP 文件" : "可导入文件") {
                    if files.isEmpty && error == nil {
                        Text("导入文件夹为空").foregroundStyle(.secondary)
                    }
                    ForEach(files, id: \.self) { url in
                        Button {
                            dismiss()
                            onSelection(url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: zipOnly ? "archivebox" : "doc")
                        }
                        .accessibilityIdentifier("import.folder.file.\(url.lastPathComponent)")
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("本机导入文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("刷新", action: reload).accessibilityIdentifier("import.folder.refresh")
                }
            }
            .task { reload() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { reload() }
            }
        }
    }

    private func reload() {
        do {
            files = try ImportFolder.files(zipOnly: zipOnly)
            error = nil
        } catch {
            files = []
            self.error = "暂时无法读取本机导入文件夹，请重试。"
        }
    }
}
