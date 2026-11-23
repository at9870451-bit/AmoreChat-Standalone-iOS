import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// The root view owns the safe area. This view only lays out the composer and its real pickers.
@MainActor
struct ComposerView: View {
    @Bindable var controller: ChatController
    let onSpeech: () -> Void

    @FocusState private var messageFocused: Bool
    @State private var attachmentsOpen = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var showingFileImporter = false
    @State private var inputError: String?

    private var hasContent: Bool {
        !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !controller.attachments.isEmpty
    }

    private var canSend: Bool {
        controller.backendReady && !controller.isLoading && !controller.isGenerating && hasContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !controller.backendReady && (controller.thinkingEnabled || controller.webSearchEnabled) {
                Text("模式已选择；深度思考与智能搜索待接入后端后生效。")
                    .font(.system(size: 11))
                    .foregroundStyle(ComposerColors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("composer.backend.note")
            }

            if let error = controller.errorText, !error.isEmpty {
                errorRow(error, retry: controller.backendReady && !controller.isGenerating)
            }
            if let inputError {
                errorRow(inputError, retry: false)
            }

            VStack(alignment: .leading, spacing: 4) {
                if !controller.attachments.isEmpty {
                    attachmentPreviews
                        .padding(.bottom, 4)
                }

                HStack(alignment: .top, spacing: 4) {
                    TextField("发消息或按住说话", text: $controller.draft, axis: .vertical)
                        .lineLimit(1...5)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.send)
                        .focused($messageFocused)
                        .onSubmit {
                            if canSend {
                                controller.send()
                                messageFocused = false
                            }
                        }
                        .font(.system(size: 18))
                        .tint(ComposerColors.blue)
                        .foregroundStyle(ComposerColors.text)
                        .frame(minHeight: 44, alignment: .topLeading)
                        .accessibilityLabel("消息")
                        .accessibilityIdentifier("composer.message")
                        .accessibilityHint(controller.backendReady
                            ? "输入消息，或添加附件后发送"
                            : "草稿会保存；接入后端前无法发送")

                    primaryAction
                        .opacity(hasContent || controller.isGenerating ? 1 : 0.01)
                }

                HStack(spacing: 4) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            modeChip("深度思考", symbol: "atom", isOn: controller.thinkingEnabled) {
                                controller.thinkingEnabled.toggle()
                            }
                            modeChip("智能搜索", symbol: "globe", isOn: controller.webSearchEnabled) {
                                controller.webSearchEnabled.toggle()
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
                    .disabled(controller.isGenerating)
                    .accessibilityLabel(attachmentsOpen ? "收起附件选项" : "添加附件")
                    .accessibilityIdentifier("composer.attach.toggle")

                    Button(action: onSpeech) {
                        Image(systemName: "waveform.circle")
                            .font(.system(size: 27))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ComposerColors.text)
                    .accessibilityLabel("语音输入")
                    .accessibilityHint("开始或结束语音输入")
                    .accessibilityIdentifier("composer.speech")
                }
                .frame(height: 44)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(ComposerColors.card, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 27, style: .continuous)
                    .strokeBorder(ComposerColors.cardBorder, lineWidth: 0.7)
            }

            if attachmentsOpen {
                attachmentTiles
                    .padding(.horizontal, 4)
                    .padding(.top, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, attachmentsOpen ? 16 : 0)
        .background(ChatTheme.canvas)
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
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                Task { @MainActor in
                    inputError = nil
                    // ChatArchive also obtains access while copying into its own storage.
                    await controller.attach(url)
                }
            case .failure(let error):
                inputError = "无法导入文件：\(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if controller.isGenerating {
            Button { controller.stop() } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 27))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(ChatTheme.danger)
            .accessibilityLabel("停止生成")
            .accessibilityIdentifier("composer.stop")
        } else {
            Button {
                controller.send()
                messageFocused = false
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 29))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? ComposerColors.blue : ComposerColors.secondary)
            .disabled(!canSend)
            .accessibilityLabel("发送消息")
            .accessibilityIdentifier("composer.send")
            .accessibilityHint(!controller.backendReady
                ? "尚未接入后端，暂不能发送"
                : (hasContent ? "发送消息和附件" : "输入消息或添加附件后发送"))
        }
    }

    private var attachmentPreviews: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(controller.attachments) { attachment in
                    HStack(spacing: 5) {
                        if attachment.type.hasPrefix("image/"),
                           let image = UIImage(contentsOfFile: attachment.localURL.path) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "doc")
                                .frame(width: 32, height: 32)
                                .accessibilityHidden(true)
                        }
                        Text(attachment.name)
                            .lineLimit(1)
                            .frame(maxWidth: 120, alignment: .leading)
                        Button {
                            controller.removeAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(controller.isGenerating)
                        .accessibilityLabel("移除附件 \(attachment.name)")
                    }
                    .font(.caption)
                    .foregroundStyle(ComposerColors.text)
                    .padding(.leading, 6)
                    .padding(.trailing, 2)
                    .background(ComposerColors.tile, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .contain)
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("待发送附件")
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

    private func modeChip(_ title: String, symbol: String, isOn: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .fixedSize()
            }
            .foregroundStyle(ComposerColors.blue)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(isOn ? ComposerColors.selectedChip : ComposerColors.chip,
                        in: Capsule())
            .overlay { Capsule().strokeBorder(ComposerColors.chipBorder, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityHint(controller.backendReady
            ? "双击\(isOn ? "关闭" : "开启")\(title)"
            : "模式待接入后端；双击\(isOn ? "关闭" : "开启")\(title)")
    }

    private func errorRow(_ message: String, retry: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            if retry {
                Button("重试") { controller.retry() }
                    .fontWeight(.semibold)
            } else if inputError == message {
                Button("关闭") { inputError = nil }
                    .fontWeight(.semibold)
            }
        }
        .font(.footnote)
        .foregroundStyle(ChatTheme.danger)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

/// Dynamic colors keep the dark reference while remaining readable in light mode.
private enum ComposerColors {
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
    static let blue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.35, green: 0.54, blue: 0.98, alpha: 1)
            : UIColor(red: 0.19, green: 0.36, blue: 0.79, alpha: 1)
    })
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
