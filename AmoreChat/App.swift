import SwiftUI

@main
struct AmoreChatStandaloneApp: App {
    @State private var controller = ChatController()
    @State private var speech = SpeechInput()
    @State private var reader = SpeechReader()

    var body: some Scene {
        WindowGroup {
            RootView(controller: controller, speech: speech, reader: reader)
        }
    }
}

struct RootView: View {
    @Bindable var controller: ChatController
    @Bindable var speech: SpeechInput
    @Bindable var reader: SpeechReader
    @State private var sidebarOpen = false
    @State private var settingsOpen = false
    @State private var modelSettingsOpen = false
    @State private var keyboardDismissSignal = 0
    @AppStorage("standalone.appearance") private var appearance = "system"
    @AppStorage("standalone.appLanguage") private var language = "system"
    @AppStorage("standalone.fontScale") private var fontScale = 1.0
    @AppStorage("standalone.reader.muted") private var readerMuted = true
    @AppStorage("standalone.speech.voiceID") private var readerVoiceID = ""
    @Environment(\.dynamicTypeSize) private var systemTextSize

    private var displayScheme: ColorScheme? {
        appearance == "light" ? .light : appearance == "dark" ? .dark : nil
    }
    private var displayTextSize: DynamicTypeSize {
        if fontScale < 0.95 { return .small }
        if fontScale > 1.35 { return .xxxLarge }
        if fontScale > 1.18 { return .xxLarge }
        if fontScale > 1.04 { return .xLarge }
        return systemTextSize
    }

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(338, geometry.size.width * 0.85)
            ZStack(alignment: .leading) {
                ChatTheme.canvas.ignoresSafeArea()
                if sidebarOpen {
                    SidebarView(controller: controller,
                                onClose: { withAnimation(.easeInOut(duration: 0.27)) { sidebarOpen = false } },
                                onNewChat: { controller.newChat() },
                                onSettings: { sidebarOpen = false; settingsOpen = true })
                        .frame(width: sidebarWidth)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .leading))
                        .zIndex(0)
                }
                VStack(spacing: 0) {
                    header
                    if controller.isLoading {
                        ProgressView("正在读取会话…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TranscriptView(controller: controller, reader: reader,
                                       onReadAloud: { text in
                            if !readerMuted { reader.read(text, voiceID: readerVoiceID) }
                        }, onBackgroundTap: { keyboardDismissSignal &+= 1 })
                    }
                    ComposerView(controller: controller, onSpeech: {
                        Task {
                            if speech.isRecording {
                                speech.stop()
                                if !speech.transcript.isEmpty {
                                    if !controller.draft.isEmpty { controller.draft += " " }
                                    controller.draft += speech.transcript
                                }
                                speech.transcript = ""
                            } else { await speech.toggle() }
                        }
                    }, dismissKeyboardSignal: keyboardDismissSignal)
                    if speech.isRecording || !speech.transcript.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform")
                            Text(speech.transcript.isEmpty ? "正在聆听，点麦克风完成" : speech.transcript)
                                .lineLimit(2)
                            Spacer()
                            Button(speech.isRecording ? "结束录音" : "加入草稿") {
                                speech.stop()
                                if !speech.transcript.isEmpty {
                                    if !controller.draft.isEmpty { controller.draft += " " }
                                    controller.draft += speech.transcript
                                    speech.transcript = ""
                                }
                            }
                        }
                        .font(.footnote)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(ChatTheme.canvas)
                .clipShape(RoundedRectangle(cornerRadius: sidebarOpen ? 28 : 0))
                .offset(x: sidebarOpen ? sidebarWidth : 0)
                .zIndex(1)
                if sidebarOpen {
                    Color.black.opacity(0.10)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.27)) { sidebarOpen = false } }
                        .offset(x: sidebarWidth)
                        .zIndex(2)
                        .accessibilityLabel("关闭侧边栏")
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 28)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                    if value.translation.width > 80 && value.startLocation.x < 36 {
                        withAnimation(.easeOut(duration: 0.25)) { sidebarOpen = true }
                    } else if value.translation.width < -80 && sidebarOpen {
                        withAnimation(.easeOut(duration: 0.25)) { sidebarOpen = false }
                    }
                })
        }
        .preferredColorScheme(displayScheme)
        .environment(\.locale, language == "system" ? .current : Locale(identifier: language))
        .dynamicTypeSize(displayTextSize)
        .onChange(of: readerMuted) { _, muted in if muted { reader.stop() } }
        .onChange(of: controller.currentID) { _, _ in speech.stop(); reader.stop() }
        .sheet(isPresented: $settingsOpen) {
            NavigationStack { SettingsView(controller: controller) }
        }
        .sheet(isPresented: $modelSettingsOpen) {
            NavigationStack { ModelSettingsView(controller: controller) }
        }
        .alert("语音输入", isPresented: Binding(
            get: { speech.errorText != nil },
            set: { if !$0 { speech.errorText = nil } }
        )) {
            Button("好") { speech.errorText = nil }
        } message: {
            Text(speech.errorText ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                keyboardDismissSignal &+= 1
                withAnimation(.easeInOut(duration: 0.27)) { sidebarOpen.toggle() }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(ChatTheme.surface, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("打开历史对话")
            .accessibilityIdentifier("root.sidebar.open")
            Spacer(minLength: 0)
            if !controller.messages.isEmpty || controller.selectedModelName != nil {
                Button { modelSettingsOpen = true } label: {
                    VStack(spacing: 2) {
                        if !controller.messages.isEmpty {
                            Text(controller.sessions.first(where: { $0.id == controller.currentID })?.title ?? "AmoreChat")
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                        }
                        if let name = controller.selectedModelName {
                            Text(name).font(.caption).foregroundStyle(ChatTheme.muted).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择模型")
                .accessibilityIdentifier("root.model.select")
            }
            Spacer(minLength: 0)
            HStack(spacing: 1) {
                Button {
                    readerMuted.toggle()
                    if readerMuted { reader.stop() }
                } label: {
                    Image(systemName: readerMuted ? "speaker.slash" : "speaker.wave.2")
                        .font(.system(size: 19))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(readerMuted ? "开启朗读" : "静音朗读")
                .accessibilityIdentifier("root.reader.mute")
                Button { controller.newChat() } label: {
                    Image(systemName: "plus.message")
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("新建对话")
                .accessibilityIdentifier("root.chat.new")
            }
            .background(ChatTheme.surface, in: Capsule())
        }
        .foregroundStyle(ChatTheme.text)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 7)
    }
}
