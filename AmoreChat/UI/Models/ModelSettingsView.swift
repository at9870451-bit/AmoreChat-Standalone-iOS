import SwiftUI

/// BYOK model configuration for the standalone app. All stored data and credentials
/// go through ModelCatalog; this view never persists an API key itself.
@MainActor
struct ModelSettingsView: View {
    let controller: ChatController
    @Environment(\.dismiss) private var dismiss

    @State private var catalog = ModelCatalog.shared
    @Environment(BackendAuthStore.self) private var backend
    @State private var editor: EditorRequest?
    @State private var removalID: UUID?
    @State private var showsRemovalConfirmation = false

    private struct EditorRequest: Identifiable {
        let id = UUID()
        let profile: ModelProfile?
    }

    var body: some View {
        Group {
            if catalog.profiles.isEmpty && backend.serverModels.isEmpty {
                ContentUnavailableView {
                    Label("尚未配置模型", systemImage: "cpu")
                } description: {
                    Text("添加自己的服务商、HTTPS 地址和 API 密钥后，即可使用兼容 Chat Completions 的模型。")
                } actions: {
                    Button {
                        editor = EditorRequest(profile: nil)
                    } label: {
                        Label("添加模型", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isGenerating)
                    .accessibilityIdentifier("model.add.empty")
                }
            } else {
                List {
                    if backend.isSignedIn {
                        Section {
                            if backend.isTestMode {
                                Text("界面测试模式不连接真实服务器模型。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else if let message = backend.serverModelsError {
                                Text(message).font(.footnote).foregroundStyle(.red)
                            } else if backend.serverModels.isEmpty {
                                Text("管理员尚未在服务器添加可用模型。你也可以继续使用下方自己的 API。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else {
                                ForEach(backend.serverModels) { model in
                                    serverRow(model)
                                }
                            }
                        } header: {
                            Text("服务器 API")
                        } footer: {
                            Text("使用账户 token 额度，无需填写 API Key。")
                        }
                    }
                    Section("当前使用") {
                        if let current = catalog.active {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(current.label).font(.body.weight(.semibold))
                                    Text(current.provider == .amoreServer ? "AmoreChat 模型" : current.modelID)
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(ChatTheme.accent)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("当前模型：\(current.label)，\(current.modelID)")
                        } else {
                            Text("尚未选择模型，请在下方选择一个已保存的配置。")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        if catalog.profiles.isEmpty {
                            Text("尚未添加自己的模型配置。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(catalog.profiles.filter { $0.provider != .amoreServer }) { profile in
                                profileRow(profile)
                            }
                        }
                    } header: {
                        Text("以自己的 API 连接")
                    } footer: {
                        Text("自己的 API 密钥由本机 Keychain 保存，请求直接发送到所填的 HTTPS 地址；这类请求不扣服务器 token。")
                    }

                    if controller.isGenerating {
                        Section {
                            Text("回复生成期间不可切换或删除模型。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .background(ChatTheme.canvas.ignoresSafeArea())
        .navigationTitle("模型与服务商")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { dismiss() }
                    .accessibilityIdentifier("model.close")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editor = EditorRequest(profile: nil)
                } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(controller.isGenerating)
                .accessibilityLabel("添加模型")
                .accessibilityHint("添加自己的服务商配置")
                .accessibilityIdentifier("model.add")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { adInset }
        .task {
            await backend.loadPublicConfig()
            await backend.loadServerModels()
            if backend.isSignedIn, backend.serverModelsError == nil, !backend.isTestMode {
                controller.updateServerModels(backend.serverModels)
            }
        }
        .sheet(item: $editor) { request in
            NavigationStack {
                ModelEditorView(controller: controller, catalog: catalog, existing: request.profile)
            }
        }
        .confirmationDialog("删除模型配置？", isPresented: $showsRemovalConfirmation,
                            titleVisibility: .visible) {
            Button("删除配置", role: .destructive) {
                guard !controller.isGenerating, let id = removalID else { return }
                catalog.remove(id)
                controller.refreshBackend()
                removalID = nil
            }
            Button("取消", role: .cancel) { removalID = nil }
        } message: {
            Text("删除后无法恢复此配置。需要继续聊天时，请选择一个可用模型。")
        }
    }

    private var activeAd: BackendPublicConfig? {
        guard let config = backend.publicConfig, config.adEnabled,
              !config.adTitle.isEmpty || !config.adImageUrl.isEmpty else { return nil }
        return config
    }

    private var adInset: some View {
        Group {
            if let ad = activeAd {
                BackendAdBanner(config: ad)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
            }
        }
    }

    private func serverRow(_ model: BackendServerModel) -> some View {
        let active = catalog.active?.provider == .amoreServer && catalog.active?.modelID == String(model.id)
        return Button {
            guard !controller.isGenerating else { return }
            controller.activateServerModel(model)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .foregroundStyle(ChatTheme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.label).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(model.model).font(.subheadline)
                        .foregroundStyle(.secondary).lineLimit(2)
                    Text(capabilityLine(model))
                        .font(.caption2).foregroundStyle(ChatTheme.muted)
                }
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ChatTheme.accent)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isGenerating)
        .accessibilityLabel("选择服务器模型 \(model.label)，使用服务器 token 额度")
        .accessibilityValue(active ? "当前使用" : "未选择")
        .accessibilityIdentifier("model.server.\(model.id)")
    }

    private func capabilityLine(_ model: BackendServerModel) -> String {
        var parts = ["服务器额度"]
        if model.supportsThinking { parts.append("思考") }
        if model.webSearchEnabled { parts.append("智能搜索") }
        return parts.joined(separator: " · ")
    }

    private func profileRow(_ profile: ModelProfile) -> some View {
        HStack(spacing: 12) {
            Button {
                guard !controller.isGenerating else { return }
                if catalog.activeID != profile.id {
                    controller.selectModel(profile.id)
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.label)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("\(profile.provider.displayName) · \(profile.modelID)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if catalog.activeID == profile.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(ChatTheme.accent)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.isGenerating)
            .accessibilityLabel("选择\(profile.label)，模型\(profile.modelID)")
            .accessibilityValue(catalog.activeID == profile.id ? "当前使用" : "未选择")
            .accessibilityIdentifier("model.select.\(profile.id.uuidString)")

            Menu {
                if profile.provider != .amoreServer {
                    Button {
                        editor = EditorRequest(profile: profile)
                    } label: {
                        Label("编辑配置", systemImage: "pencil")
                    }
                }
                Button(role: .destructive) {
                    removalID = profile.id
                    showsRemovalConfirmation = true
                } label: {
                    Label("删除配置", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(ChatTheme.muted)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(controller.isGenerating)
            .accessibilityLabel("管理\(profile.label)")
            .accessibilityIdentifier("model.manage.\(profile.id.uuidString)")
        }
    }
}
