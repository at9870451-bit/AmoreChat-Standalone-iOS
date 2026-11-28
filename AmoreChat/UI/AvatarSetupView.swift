import PhotosUI
import SwiftUI

/// Present in a sheet/fullScreenCover. Both onboarding and later edits use this same view.
@MainActor
struct AvatarSetupView: View {
    var isInitialSetup = false
    @Environment(LocalProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var draft: LocalAvatarDraft?
    @State private var removesAvatar = false
    @State private var isImporting = false
    @State private var showsRemovalConfirmation = false
    @State private var errorText: String?
    @State private var operation = UUID()
    @State private var importTask: Task<Void, Never>?
    @State private var editorAccountID: Int64?

    private var accountMatches: Bool { editorAccountID != nil && editorAccountID == profile.accountID }
    private var isBusy: Bool { isImporting || profile.isLoading || profile.isSaving || !accountMatches }
    private var hasAvatar: Bool { draft != nil || (!removesAvatar && profile.avatarImage != nil) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Text(isInitialSetup ? "为自己选一个头像" : "本机头像")
                        .font(.title2.weight(.semibold))
                    LocalAvatarView(size: 112, previewImage: draft?.image,
                                    hidesStoredAvatar: removesAvatar || draft != nil)
                        .padding(.top, 4)
                    Text("头像只保存在本机，不会上传。你可以随时在账户页更换或删除。")
                        .font(.subheadline)
                        .foregroundStyle(ChatTheme.muted)
                        .multilineTextAlignment(.center)

                    PhotosPicker(selection: $pickedPhoto, matching: .images,
                                 preferredItemEncoding: .current) {
                        Label(hasAvatar ? "更换头像" : "从照片库选择头像", systemImage: "photo")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || profile.accountID == nil)
                    .accessibilityIdentifier("avatar.choose")

                    if isImporting {
                        HStack {
                            ProgressView()
                            Text("正在处理照片…").font(.subheadline)
                            Spacer()
                            Button("取消", action: cancelImport)
                        }
                    }

                    if hasAvatar {
                        Button("删除本机头像", role: .destructive) {
                            showsRemovalConfirmation = true
                        }
                        .disabled(isBusy)
                        .accessibilityIdentifier("avatar.remove")
                    }

                    if let message = errorText ?? profile.errorText {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("avatar.error")
                    }

                    Button(action: finish) {
                        HStack(spacing: 8) {
                            if profile.isSaving { ProgressView() }
                            Text("完成").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || profile.accountID == nil)
                    .accessibilityIdentifier("avatar.done")

                    if isInitialSetup {
                        Button("暂时跳过", action: skip)
                            .disabled(profile.isLoading || profile.isSaving || !accountMatches)
                            .accessibilityIdentifier("avatar.skip")
                    }
                    Text("仅保存最长边不超过 768 像素的头像缩略图，移除照片的位置等原始信息。不会影响聊天附件。")
                        .font(.caption)
                        .foregroundStyle(ChatTheme.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
            .background(ChatTheme.settingsBackground.ignoresSafeArea())
            .navigationTitle(isInitialSetup ? "设置头像" : "更换头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isInitialSetup {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            cancelImport()
                            dismiss()
                        }
                        .disabled(profile.isSaving)
                        .accessibilityIdentifier("avatar.cancel")
                    }
                }
            }
        }
        .tint(ChatTheme.accent)
        .foregroundStyle(ChatTheme.text)
        .interactiveDismissDisabled(isInitialSetup || profile.isSaving)
        .onAppear { editorAccountID = profile.accountID }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            importPhoto(item)
        }
        .onChange(of: profile.accountID) { _, _ in
            cancelImport()
            draft = nil
            removesAvatar = false
            dismiss()
        }
        .onDisappear(perform: cancelImport)
        .confirmationDialog("删除本机头像？", isPresented: $showsRemovalConfirmation,
                            titleVisibility: .visible) {
            Button("删除头像", role: .destructive) {
                draft = nil
                removesAvatar = true
                errorText = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("点击「完成」后恢复默认头像，不会删除照片库中的原图。")
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        guard accountMatches else { return }
        cancelImport()
        let request = UUID()
        operation = request
        let accountID = profile.accountID
        errorText = nil
        isImporting = true
        importTask = Task { @MainActor in
            defer {
                if operation == request {
                    isImporting = false
                    pickedPhoto = nil
                    importTask = nil
                }
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    if operation == request { errorText = "无法读取所选照片，请选择另一张。" }
                    return
                }
                try Task.checkCancellation()
                let prepared = try await LocalProfileStore.prepareAvatar(from: data)
                try Task.checkCancellation()
                guard operation == request, profile.accountID == accountID else { return }
                draft = prepared
                removesAvatar = false
            } catch is CancellationError {
                // Cancelling the picker/import keeps both the stored avatar and the draft intact.
            } catch {
                guard operation == request, profile.accountID == accountID else { return }
                errorText = "无法导入这张照片。请确认照片已下载到设备，或选择另一张图片。"
            }
        }
    }

    private func cancelImport() {
        operation = UUID()
        importTask?.cancel()
        importTask = nil
        isImporting = false
        pickedPhoto = nil
    }

    private func finish() {
        guard accountMatches else { return }
        let accountID = editorAccountID
        let avatar = draft
        let shouldRemoveAvatar = removesAvatar
        Task { @MainActor in
            guard profile.accountID == accountID else { return }
            if await profile.completeSetup(avatar: avatar, removeAvatar: shouldRemoveAvatar) { dismiss() }
        }
    }

    private func skip() {
        guard accountMatches else { return }
        let accountID = editorAccountID
        cancelImport()
        Task { @MainActor in
            guard profile.accountID == accountID else { return }
            if await profile.completeSetup() { dismiss() }
        }
    }
}
