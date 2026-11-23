import SwiftUI

/// Edits a draft until Save is explicitly tapped. Existing secrets remain in Keychain;
/// an empty key field means "retain the previous key" ONLY if the destination is unchanged.
@MainActor
struct ModelEditorView: View {
    let controller: ChatController
    let catalog: ModelCatalog
    let existing: ModelProfile?

    @Environment(\.dismiss) private var dismiss
    @State private var provider: ModelProvider
    @State private var label: String
    @State private var baseURL: String
    @State private var appendV1: Bool
    @State private var modelID: String
    @State private var apiKey = ""
    @State private var revealsKey = false
    @State private var availableModels: [String] = []
    @State private var showsModelPicker = false
    @State private var isFetching = false
    @State private var fetchTask: Task<Void, Never>?
    @State private var requestID: UUID?
    @State private var errorMessage = ""
    @State private var showsError = false

    init(controller: ChatController, catalog: ModelCatalog, existing: ModelProfile?) {
        self.controller = controller
        self.catalog = catalog
        self.existing = existing
        let initialProvider: ModelProvider = existing?.provider ?? .deepSeek
        _provider = State(initialValue: initialProvider)
        _label = State(initialValue: existing?.label ?? "")
        _baseURL = State(initialValue: existing?.baseURL ?? initialProvider.defaultBaseURL)
        _appendV1 = State(initialValue: existing?.appendV1 ?? initialProvider.defaultAppendV1)
        _modelID = State(initialValue: existing?.modelID ?? "")
    }

    var body: some View {
        Form {
            Section {
                Picker("服务商", selection: $provider) {
                    ForEach(ModelProvider.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .accessibilityIdentifier("model.editor.provider")
                TextField("配置名称", text: $label)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("model.editor.label")
            } header: {
                Text("服务商")
            } footer: {
                Text("服务商选项仅填写参考地址，不表示账号或模型已通过验证。自定义服务需兼容 OpenAI Chat Completions。")
            }

            Section {
                TextField("https://…", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .accessibilityLabel("HTTPS 基础地址")
                    .accessibilityIdentifier("model.editor.baseURL")
                Toggle("地址后追加 /v1", isOn: $appendV1)
                    .accessibilityIdentifier("model.editor.appendV1")
            } header: {
                Text("连接地址")
            } footer: {
                Text("按服务商文档填写基础地址。已包含 /v1 的地址请关闭追加选项；不需要 /v1 的服务也请关闭。")
            }

            Section {
                HStack(spacing: 10) {
                    Group {
                        if revealsKey {
                            TextField("输入 API 密钥", text: $apiKey)
                        } else {
                            SecureField("输入 API 密钥", text: $apiKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .accessibilityIdentifier("model.editor.apiKey")
                    Button {
                        revealsKey.toggle()
                    } label: {
                        Image(systemName: revealsKey ? "eye.slash" : "eye")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealsKey ? "隐藏密钥" : "显示密钥")
                    .accessibilityIdentifier("model.editor.revealKey")
                }
            } header: {
                Text("API 密钥")
            } footer: {
                if existing != nil && !destinationChanged {
                    Text("留空则继续使用此配置在本机 Keychain 中保存的密钥；输入新密钥可替换。")
                } else if existing != nil {
                    Text("服务商或地址已更改。为避免把旧密钥发送到新地址，请重新输入 API 密钥。")
                } else {
                    Text("密钥仅交给本机 Keychain 保存，不存储在用户偏好设置中。")
                }
            }

            Section {
                TextField("输入模型 ID", text: $modelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("model.editor.modelID")

                Button {
                    fetchAvailableModels()
                } label: {
                    HStack {
                        Label("从服务商获取模型列表", systemImage: "arrow.down.circle")
                        Spacer()
                        if isFetching { ProgressView().accessibilityLabel("正在获取模型") }
                    }
                    .frame(minHeight: 36)
                }
                .disabled(isFetching)
                .accessibilityIdentifier("model.editor.fetchModels")

                if !availableModels.isEmpty {
                    Button {
                        showsModelPicker = true
                    } label: {
                        HStack {
                            Label("选择已获取的模型", systemImage: "list.bullet")
                            Spacer()
                            Text("\(availableModels.count)").foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 36)
                    }
                    .accessibilityIdentifier("model.editor.pickModel")
                }
            } header: {
                Text("模型 ID")
            } footer: {
                Text("可手动输入模型 ID；获取列表会使用上方地址和密钥向该服务商发送 /models 请求。能获取列表不保证模型可用于聊天。")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(existing == nil ? "添加模型" : "编辑模型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
                    .accessibilityIdentifier("model.editor.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .fontWeight(.semibold)
                    .disabled(isFetching || controller.isGenerating)
                    .accessibilityIdentifier("model.editor.save")
            }
        }
        .sheet(isPresented: $showsModelPicker) {
            NavigationStack {
                AvailableModelsView(models: availableModels) { selected in
                    modelID = selected
                    showsModelPicker = false
                }
            }
        }
        .alert("无法完成操作", isPresented: $showsError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onChange(of: provider) { previous, next in
            if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                baseURL == previous.defaultBaseURL {
                baseURL = next.defaultBaseURL
            }
            appendV1 = next.defaultAppendV1
            if label == previous.displayName { label = next.displayName }
            availableModels = []
            cancelFetch()
        }
        .onChange(of: baseURL) { _, _ in
            availableModels = []
            cancelFetch()
        }
        .onChange(of: apiKey) { _, _ in
            availableModels = []
            cancelFetch()
        }
        .onChange(of: appendV1) { _, _ in
            availableModels = []
            cancelFetch()
        }
        .onDisappear { cancelFetch() }
    }

    private var destinationChanged: Bool {
        guard let existing else { return false }
        return provider != existing.provider ||
            normalizedBaseURL != existing.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) ||
            appendV1 != existing.appendV1
    }

    private var normalizedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasV1Suffix(_ value: String) -> Bool {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased().hasSuffix("/v1")
    }

    private func validatedProfile(requireModelID: Bool = true) throws -> ModelProfile {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if requireModelID {
            guard !cleanLabel.isEmpty else { throw EditorValidationError.message("请填写配置名称。") }
            guard !cleanModel.isEmpty else { throw EditorValidationError.message("请填写模型 ID 或从列表中选择。") }
        }
        guard let components = URLComponents(string: normalizedBaseURL),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.url != nil else {
            throw EditorValidationError.message("请输入有效的 HTTPS 基础地址（不能包含用户名、查询参数或片段）。")
        }
        guard !(appendV1 && Self.hasV1Suffix(normalizedBaseURL)) else {
            throw EditorValidationError.message("地址已经包含 /v1，请关闭“地址后追加 /v1”。")
        }
        return ModelProfile(id: existing?.id ?? UUID(), label: cleanLabel,
                            provider: provider, baseURL: normalizedBaseURL,
                            modelID: cleanModel, appendV1: appendV1,
                            format: .chatCompletions)
    }

    private func resolvedKey() throws -> String {
        let entered = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty { return entered }
        if let existing, !destinationChanged,
           catalog.apiKey(for: existing.id) != nil {
            // Catalog resolves the key by profile ID for both save and /models.
            return ""
        }
        throw EditorValidationError.message("请输入此服务商的 API 密钥。")
    }

    private func fetchAvailableModels() {
        do {
            let draft = try validatedProfile(requireModelID: false)
            let key = try resolvedKey()
            cancelFetch()
            isFetching = true
            let id = UUID()
            requestID = id
            fetchTask = Task {
                do {
                    let models = try await catalog.fetchModels(for: draft, apiKey: key)
                    try Task.checkCancellation()
                    guard requestID == id else { return }
                    var seen = Set<String>()
                    availableModels = models.filter { !$0.isEmpty && seen.insert($0).inserted }
                    if availableModels.isEmpty {
                        presentError("服务商未返回可选择的模型。仍可手动输入模型 ID。")
                    }
                } catch is CancellationError {
                    // A changed destination or dismissal invalidated this request.
                } catch {
                    guard requestID == id else { return }
                    presentError("获取模型列表失败：\(safeDescription(error, hiding: key))")
                }
                if requestID == id {
                    isFetching = false
                    requestID = nil
                    fetchTask = nil
                }
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }


    private func save() {
        guard !controller.isGenerating else { return }
        do {
            let profile = try validatedProfile()
            let key = try resolvedKey()
            try catalog.save(profile, apiKey: key)
            controller.refreshBackend()
            dismiss()
        } catch {
            presentError(safeDescription(error, hiding: apiKey))
        }
    }

    private func cancelFetch() {
        fetchTask?.cancel()
        fetchTask = nil
        requestID = nil
        isFetching = false
    }

    private func safeDescription(_ error: Error, hiding secret: String) -> String {
        let description = error.localizedDescription
        guard !secret.isEmpty else { return description }
        return description.replacingOccurrences(of: secret, with: "••••")
    }

    private func presentError(_ text: String) {
        errorMessage = text
        showsError = true
    }
}

private enum EditorValidationError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

@MainActor
private struct AvailableModelsView: View {
    let models: [String]
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [String] {
        guard !query.isEmpty else { return models }
        return models.filter { $0.localizedStandardContains(query) }
    }

    var body: some View {
        List(filtered, id: \.self) { model in
            Button {
                select(model)
            } label: {
                Text(model)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("选择模型 \(model)")
        }
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "搜索模型 ID")
        .navigationTitle("选择模型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
    }
}
