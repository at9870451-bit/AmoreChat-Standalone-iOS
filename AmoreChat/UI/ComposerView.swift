import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@MainActor
struct ComposerView: View {
    @Bindable var controller: ChatController
    let onSpeech: () -> Void

    @FocusState private var messageFocused: Bool
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var inputError: String?

    private var hasContent: Bool {
        !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !controller.attachments.isEmpty
    }

    private var canSend: Bool {
        controller.backendReady && !controller.isGenerating && hasContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.backendReady {
                Label("Not connected. Connect a backend in Settings to send messages.",
                      systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(ChatTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isStaticText)
            }

            if let error = controller.errorText, !error.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .accessibilityHidden(true)
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if controller.backendReady && !controller.isGenerating {
                        Button("Retry") { controller.retry() }
                            .fontWeight(.semibold)
                            .accessibilityHint("Retry the last failed request")
                    }
                }
                .font(.footnote)
                .foregroundStyle(ChatTheme.danger)
            }

            if let inputError {
                HStack(alignment: .top, spacing: 8) {
                    Text(inputError)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Dismiss") { self.inputError = nil }
                        .fontWeight(.semibold)
                }
                .font(.footnote)
                .foregroundStyle(ChatTheme.danger)
            }

            if !controller.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(controller.attachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: attachment.type.hasPrefix("image/")
                                      ? "photo" : "doc")
                                Text(attachment.name)
                                    .lineLimit(1)
                                    .accessibilityLabel("Attachment ready: \(attachment.name)")
                                Button {
                                    controller.removeAttachment(attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(controller.isGenerating)
                                .accessibilityLabel("Remove \(attachment.name)")
                            }
                            .font(.caption)
                            .foregroundStyle(ChatTheme.text)
                            .padding(.leading, 10)
                            .padding(.trailing, 2)
                            .background(ChatTheme.raised,
                                        in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
                .accessibilityLabel("Ready attachments")
            }

            TextField("Message", text: $controller.draft, axis: .vertical)
                .lineLimit(1...6)
                .textInputAutocapitalization(.sentences)
                .focused($messageFocused)
                .submitLabel(.send)
                .onSubmit { if canSend { controller.send() } }
                .font(.body)
                .foregroundStyle(ChatTheme.text)
                .frame(minHeight: 34, alignment: .topLeading)
                .accessibilityLabel("Message")
                .accessibilityHint(controller.backendReady
                    ? "Type a message to send" : "Message is saved but sending requires a connection")

            HStack(spacing: 4) {
                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    Image(systemName: "photo")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(controller.isGenerating)
                .accessibilityLabel("Attach photo")

                Button { showingFileImporter = true } label: {
                    Image(systemName: "paperclip")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(controller.isGenerating)
                .accessibilityLabel("Attach file")

                Button(action: onSpeech) {
                    Image(systemName: "mic")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(controller.isGenerating)
                .accessibilityLabel("Voice input")
                .accessibilityHint("Start speech input")
            }
            .foregroundStyle(ChatTheme.muted)

            HStack(spacing: 4) {
                modeButton("Think", symbol: "brain.head.profile",
                           isOn: controller.thinkingEnabled) {
                    controller.thinkingEnabled.toggle()
                }
                modeButton("Search", symbol: "globe",
                           isOn: controller.webSearchEnabled) {
                    controller.webSearchEnabled.toggle()
                }
                Spacer(minLength: 0)

                if controller.isGenerating {
                    Button { controller.stop() } label: {
                        Image(systemName: "stop.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(ChatTheme.danger, in: Circle())
                    }
                    .accessibilityLabel("Stop generating")
                } else {
                    Button {
                        controller.send()
                        messageFocused = false
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(canSend ? ChatTheme.accent : ChatTheme.muted,
                                        in: Circle())
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send message")
                    .accessibilityHint(!controller.backendReady
                        ? "Unavailable until a backend is connected"
                        : (hasContent ? "Send the message and attachments" : "Enter a message or attach a file"))
                }
            }
            .foregroundStyle(ChatTheme.muted)
        }
        .padding(12)
        .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: ChatTheme.radius))
        .overlay {
            RoundedRectangle(cornerRadius: ChatTheme.radius)
                .strokeBorder(ChatTheme.line.opacity(0.5), lineWidth: 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task { @MainActor in
                defer { pickedPhoto = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        inputError = "Could not read the selected photo."
                        return
                    }
                    inputError = nil
                    await controller.attachImage(data)
                } catch {
                    inputError = "Could not read the selected photo: \(error.localizedDescription)"
                }
            }
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                Task { @MainActor in
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                    inputError = nil
                    await controller.attach(url)
                }
            case .failure(let error):
                inputError = "Could not import file: \(error.localizedDescription)"
            }
        }
    }

    private func modeButton(_ title: String, symbol: String,
                            isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline)
                .frame(minWidth: 44, minHeight: 44)
                .background(isOn ? ChatTheme.accentWash : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(isOn ? ChatTheme.accent : ChatTheme.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) mode")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint("Double tap to \(isOn ? "disable" : "enable") \(title.lowercased()) mode")
    }
}
