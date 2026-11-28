import SwiftUI
import PhotosUI
import UIKit

/// Rounded floating composer. Its card ends above the home-indicator region,
/// while the parent chat canvas remains full height and keyboard-aware.
@MainActor
struct ComposerView: View {
    @Bindable var controller: ChatController
    let onVoiceModeEntered: () -> Void
    var onInputFocus: () -> Void = {}
    let onSpeechStart: () -> Void
    let onSpeechStop: () -> Void
    var speechInputActive = false
    var speechPartial = ""
    var speechFinishing = false
    var speechPermissionPending = false
    var dismissKeyboardSignal: Int = 0
    var bottomSafeAreaInset: CGFloat = 0

    @FocusState private var messageFocused: Bool
    @State private var attachmentsOpen = false
    @State private var voiceMode = false
    @GestureState private var voiceTouchDown = false
    @State private var holdingToSpeak = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var showingFileImporter = false
    @State private var showingImportFolder = false
    @State private var confirmPaidSearch = false
    @State private var inputError: String?
    @State private var modeNotice: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var inputSize: CGFloat = 16.5
    @ScaledMetric(relativeTo: .subheadline) private var chipSize: CGFloat = 13.5

    private var hasText: Bool { !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasContent: Bool { hasText || !controller.attachments.isEmpty }
    private var modesLocked: Bool { controller.isLoading || controller.isImporting || controller.isGenerating }
    private var showSend: Bool { hasContent && !voiceMode && !speechInputActive && !controller.isGenerating }
    private var showVoice: Bool { !showSend || !controller.attachments.isEmpty }

    private var canSend: Bool {
        controller.backendReady && !controller.isLoading && !controller.isImporting && !controller.isAttachingFile
            && !voiceMode && !speechInputActive && !controller.isGenerating && hasContent
    }

    private var visibleControllerError: String? {
        guard let error = controller.errorText, !error.isEmpty,
              !error.hasPrefix("请求失败：") else { return nil }
        return error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = visibleControllerError {
                errorRow(error)
            }
            if let inputError {
                errorRow(inputError)
            }
            if let modeNotice {
                Label(modeNotice, systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(ChatTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9).padding(.bottom, 8)
                    .accessibilityIdentifier("composer.mode.notice")
            }

            VStack(alignment: .leading, spacing: 4) {
                if !controller.attachments.isEmpty {
                    attachmentPreviews
                    if !voiceMode && !speechInputActive && !hasText && !controller.isGenerating {
                        attachmentPrompts
                    }
                }

                HStack(alignment: .top, spacing: 4) {
                    if voiceMode || speechInputActive {
                        voicePad
                    } else {
                        TextField("发消息或按住说话", text: $controller.draft, axis: .vertical)
                            .lineLimit(1...5)
                            .textInputAutocapitalization(.sentences)
                            .submitLabel(.send)
                            .focused($messageFocused)
                            .onChange(of: messageFocused) { _, focused in
                                if focused { onInputFocus() }
                            }
                            .onSubmit {
                                if canSend { controller.send(); messageFocused = false }
                            }
                            .font(.system(size: inputSize, weight: .regular))
                            .tint(ComposerColors.blue)
                            .foregroundStyle(ComposerColors.text)
                            .frame(minHeight: 44, alignment: .topLeading)
                            .accessibilityLabel("消息")
                            .accessibilityIdentifier("composer.message")
                            .accessibilityHint(controller.backendReady
                                ? "输入消息，或添加附件后发送"
                                : "草稿会保存；接入后端前无法发送")
                    }

                }

                if voiceMode || speechInputActive {
                    ChatTheme.line.opacity(0.8)
                        .frame(height: 0.5)
                        .padding(.horizontal, -12)
                        .accessibilityHidden(true)
                }

                HStack(spacing: 0) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                            modeChip("深度思考", id: "thinking", symbol: "atom", isOn: controller.thinkingEnabled) {
                                modeNotice = nil
                                if !controller.setThinking(!controller.thinkingEnabled) {
                                    modeNotice = controller.backendReady
                                        ? "当前模型没有可用的思考协议，请在模型设置中检查。"
                                        : "请先在设置中添加可用的 AI 模型。"
                                }
                            }
                            modeChip("智能搜索", id: "search", symbol: "globe", isOn: controller.webSearchEnabled) {
                                modeNotice = nil
                                if controller.webSearchEnabled { controller.setWebSearch(false) }
                                else if !controller.backendReady {
                                    modeNotice = "请先在设置中添加可用的 AI 模型。"
                                } else if controller.supportsWebSearch {
                                    confirmPaidSearch = true
                                } else {
                                    modeNotice = "此模型不支持网页搜索。请选择 OpenRouter 或已声明网页搜索协议的兼容接口。"
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("composer.modes")

                    Button {
                        messageFocused = false
                        withAnimation(.easeInOut(duration: 0.22)) {
                            attachmentsOpen.toggle()
                        }
                    } label: {
                        Image(systemName: attachmentsOpen ? "xmark.circle" : "plus.circle")
                            .font(.system(size: 27, weight: .regular))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ComposerColors.text)
                    .disabled(controller.isGenerating || controller.isImporting || speechInputActive || controller.isAttachingFile)
                    .accessibilityLabel(attachmentsOpen ? "收起附件选项" : "添加附件")
                    .accessibilityIdentifier("composer.attach.toggle")

                    if showVoice { voiceAction }
                    if controller.isGenerating { stopAction }
                    else if showSend { sendAction }
                }
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 8)

            if attachmentsOpen {
                VStack(alignment: .trailing, spacing: 4) {
                    attachmentTiles
                    Button {
                        showingImportFolder = true
                    } label: {
                        Label("本机导入文件夹", systemImage: "folder")
                            .font(.footnote).foregroundStyle(ChatTheme.muted)
                            .padding(.horizontal, 6).frame(minHeight: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("composer.attach.folder")
                }
                .padding(.horizontal, 4)
                .padding(.top, 15)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // A floating, four-corner composer: keep a clear gutter above the home indicator.
        .background {
            RoundedRectangle(cornerRadius: 29, style: .continuous)
                .fill(ComposerColors.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 29, style: .continuous)
                        .strokeBorder(ComposerColors.cardBorder, lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, max(10, bottomSafeAreaInset))
        .alert("联网搜索可能产生额外费用", isPresented: $confirmPaidSearch) {
            Button("开启联网搜索") {
                guard controller.setWebSearch(true) else { return }
                modeNotice = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会把网页搜索选项和聊天请求发送到当前配置的模型接口。搜索可能额外计费，后续发送也会使用，直到关闭或更改模型。兼容接口是否实际支持搜索，以服务商为准。")
        }
        .onChange(of: controller.selectedModelName) { _, _ in modeNotice = nil }
        .onChange(of: controller.backendReady) { _, _ in modeNotice = nil }
        .onChange(of: speechInputActive) { old, active in
            if old && !active && hasContent { voiceMode = false }
        }
        .onChange(of: controller.currentID) { _, _ in
            holdingToSpeak = false
            voiceMode = false
        }
        .onChange(of: dismissKeyboardSignal) { _, _ in
            messageFocused = false
        }
        .onChange(of: messageFocused) { _, focused in
            if focused && attachmentsOpen {
                withAnimation(.easeInOut(duration: 0.22)) { attachmentsOpen = false }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { data in
                showingCamera = false
                if let data {
                    inputError = nil
                    Task { await controller.attachImage(data) }
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task { @MainActor in
                defer { pickedPhoto = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        inputError = "无法读取所选照片。"
                        return
                    }
                    inputError = nil
                    await controller.attachImage(data)
                } catch {
                    inputError = "无法读取照片：\(error.localizedDescription)"
                }
            }
        }
        .background {
            NativeDocumentPicker(isPresented: $showingFileImporter) { document in
                if let document { importDocument(document) }
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .sheet(isPresented: $showingImportFolder) {
            ImportFolderView(zipOnly: false) { url in importDocument(PickedDocument(url)) }
        }
    }

    private func importDocument(_ document: PickedDocument) {
        attachmentsOpen = false
        voiceMode = false
        inputError = nil
        Task {
            await controller.attach(document.url)
            withExtendedLifetime(document) {}
        }
    }

    private var voicePad: some View {
        Text(speechPermissionPending ? "正在等待系统授权…" : (speechFinishing ? "正在整理最终文字…" :
             (speechPartial.isEmpty ? (holdingToSpeak || speechInputActive ? "正在聆听…" : "按住说话") : speechPartial)))
            .font(.body.weight(.semibold))
            .foregroundStyle(speechInputActive ? ComposerColors.blue : ComposerColors.text)
            .lineLimit(1...5)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).updating($voiceTouchDown) { _, down, _ in down = true })
            .onChange(of: voiceTouchDown) { _, down in
                if down {
                    guard !controller.isGenerating, !controller.isImporting,
                          !speechInputActive, !speechPermissionPending else { return }
                    holdingToSpeak = true
                    onSpeechStart()
                } else if holdingToSpeak {
                    holdingToSpeak = false
                    onSpeechStop()
                }
            }
            .accessibilityIdentifier("composer.speech.hold")
            .accessibilityHint("按住实时听写，松开后填入草稿")
            .accessibilityAction(named: Text(speechInputActive ? "结束听写" : "开始听写")) {
                if speechInputActive { onSpeechStop() }
                else if !controller.isGenerating && !controller.isImporting { onSpeechStart() }
            }
    }

    private var stopAction: some View {
        Button { controller.stop() } label: {
            roundAction("stop.fill")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("停止生成")
        .accessibilityIdentifier("composer.stop")
    }

    private var sendAction: some View {
        Button {
            controller.send()
            messageFocused = false
        } label: {
            roundAction("arrow.up", active: canSend)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel("发送消息")
        .accessibilityIdentifier("composer.send")
        .accessibilityHint(!controller.backendReady ? "尚未配置模型，暂不能发送" : "发送消息和附件")
    }

    private var voiceAction: some View {
        let showsKeyboard = voiceMode && !speechInputActive
        return Button {
            if speechInputActive { onSpeechStop(); return }
            voiceMode.toggle()
            attachmentsOpen = false
            messageFocused = !voiceMode
            if voiceMode { onVoiceModeEntered() }
        } label: {
            ComposerGlyph(kind: showsKeyboard ? .keyboard : .voice,
                          color: speechInputActive ? ChatTheme.accent : ComposerColors.text)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(speechFinishing || controller.isLoading || controller.isGenerating || controller.isImporting)
        .accessibilityLabel(speechFinishing ? "正在整理语音" : (speechInputActive ? "结束语音输入" : (showsKeyboard ? "切换键盘" : "语音输入")))
        .accessibilityIdentifier(showsKeyboard ? "composer.keyboard" : "composer.speech")
    }

    private func roundAction(_ symbol: String, active: Bool = true) -> some View {
        Image(systemName: symbol)
            .font(.system(size: symbol == "stop.fill" ? 14 : 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(active ? ComposerColors.actionBlue : ComposerColors.secondary, in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private var attachmentPreviews: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(controller.attachments) { attachment in
                    AttachmentCard(attachment: attachment, compact: true) {
                        controller.removeAttachment(attachment.id)
                    }
                    .disabled(controller.isGenerating)
                    .accessibilityIdentifier("composer.attachment.card")
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("待发送附件")
    }

    private var attachmentPrompts: some View {
        let isImage = controller.attachments.first?.type.hasPrefix("image/") == true
        let prompts = isImage ? ["这是什么", "分析一下", "怎么办", "解释一下"]
                              : ["分析一下", "答案是什么", "总结", "解释一下"]
        return ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(prompts, id: \.self) { prompt in
                    Button { if !hasText { controller.draft = prompt } } label: {
                        HStack(spacing: 6) {
                            Text(prompt)
                            Image(systemName: "arrow.right").accessibilityHidden(true)
                        }
                        .font(.system(size: chipSize, weight: .regular)).foregroundStyle(ComposerColors.text)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(ComposerColors.card, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ChatTheme.line, lineWidth: 0.5).allowsHitTesting(false) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("填入输入框，不会自动发送")
                    .accessibilityIdentifier("composer.attachment.prompt")
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 5)
    }

    private var attachmentTiles: some View {
        HStack(spacing: 8) {
            Button {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showingCamera = true
                } else {
                    inputError = "当前设备没有可用相机。"
                }
            } label: {
                tileLabel("拍照", symbol: "camera")
            }
            .buttonStyle(.plain)
            .disabled(controller.isGenerating)
            .accessibilityLabel("拍照添加附件")
            .accessibilityIdentifier("composer.attach.camera")
            .frame(maxWidth: .infinity)
            .frame(height: 86)

            PhotosPicker(selection: $pickedPhoto, matching: .images) {
                tileLabel("相册", symbol: "photo")
            }
            .buttonStyle(.plain)
            .disabled(controller.isGenerating)
            .accessibilityLabel("从相册选取照片")
            .accessibilityIdentifier("composer.attach.photos")
            .frame(maxWidth: .infinity)
            .frame(height: 86)

            Button { showingFileImporter = true } label: {
                tileLabel("文件", symbol: "paperclip")
            }
            .buttonStyle(.plain)
            .disabled(controller.isGenerating)
            .accessibilityLabel("从文件选取附件")
            .accessibilityIdentifier("composer.attach.file")
            .frame(maxWidth: .infinity)
            .frame(height: 86)
        }
    }

    private func tileLabel(_ title: String, symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
            Text(title)
                .font(.system(size: 16, weight: .medium))
        }
        .foregroundStyle(ComposerColors.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ComposerColors.tile, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 19))
    }

    private func modeChip(_ title: String, id: String, symbol: String, isOn: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if id != "thinking" || isOn {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: isOn ? .medium : .regular))
                        .symbolEffect(.bounce, value: isOn && !reduceMotion)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: chipSize, weight: .regular))
                    .fixedSize()
            }
            .foregroundStyle(isOn ? ComposerColors.blue : ComposerColors.text)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(isOn ? ComposerColors.selectedChip : Color.clear, in: Capsule())
            .overlay { Capsule().strokeBorder(isOn ? ComposerColors.chipBorder : ComposerColors.cardBorder, lineWidth: 0.8).allowsHitTesting(false) }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isOn)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(ModePressStyle())
        .disabled(modesLocked)
        .accessibilityLabel(title)
        .accessibilityIdentifier("composer.mode.\(id)")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityHint("双击\(isOn ? "关闭" : "开启")\(title)")
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            Button("关闭") {
                if inputError == message { inputError = nil }
                else { controller.errorText = nil }
            }.fontWeight(.medium)
        }
        .font(.footnote)
        .foregroundStyle(ChatTheme.danger)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

private struct ModePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.70 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Dynamic colors keep the dark reference while remaining readable in light mode.
private enum ComposerColors {
    static let actionBlue = Color(red: 0.23, green: 0.39, blue: 0.84)
    static let text = Color(uiColor: .label)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.155, green: 0.155, blue: 0.16, alpha: 1)
            : UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)
    })
    static let cardBorder = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.30, alpha: 1)
            : UIColor(white: 0.80, alpha: 1)
    })
    static let tile = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.20, alpha: 1)
            : UIColor(white: 0.92, alpha: 1)
    })
    static let blue = ChatTheme.thinkingBlue
    static let chip = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.16, green: 0.19, blue: 0.26, alpha: 1)
            : UIColor(red: 0.89, green: 0.93, blue: 1, alpha: 1)
    })
    static let selectedChip = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.19, green: 0.25, blue: 0.37, alpha: 1)
            : UIColor(red: 0.82, green: 0.89, blue: 1, alpha: 1)
    })
    static let chipBorder = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.20, green: 0.32, blue: 0.54, alpha: 1)
            : UIColor(red: 0.55, green: 0.67, blue: 0.93, alpha: 1)
    })
}
