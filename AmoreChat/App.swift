import SwiftUI

@main
struct AmoreChatStandaloneApp: App {
    @State private var controller = AppControllerFactory.make()
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
    @State private var historySearchOpen = false
    @State private var historyJump: HistoryJump?
    @State private var keyboardDismissSignal = 0
    @State private var speechStartTask: Task<Void, Never>?
    @State private var speechPermissionTask: Task<Void, Never>?
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.system.rawValue
    @AppStorage("standalone.appLanguage") private var language = "system"
    @AppStorage("standalone.fontScale") private var fontScale = 1.0
    @AppStorage("standalone.reader.muted") private var readerMuted = true
    @AppStorage("standalone.speech.voiceID") private var readerVoiceID = ""
    @Environment(\.dynamicTypeSize) private var systemTextSize
    @Environment(\.scenePhase) private var scenePhase

    private var appearanceMode: AppearanceMode { AppearanceMode(storedValue: appearance) }
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
                                onSettings: { sidebarOpen = false; settingsOpen = true },
                                onSearch: {
                                    keyboardDismissSignal &+= 1
                                    cancelSpeech()
                                    reader.stop()
                                    historySearchOpen = true
                                })
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
                        TranscriptView(controller: controller,
                                       onReadAloud: { text in
                            guard !speech.isStarting && !speech.isRecording && !speech.isFinishing else { return }
                            if reader.isSpeaking { reader.stop() }
                            else { reader.read(text, voiceID: readerVoiceID) }
                        }, onBackgroundTap: { keyboardDismissSignal &+= 1 }, jump: historyJump)
                    }
                    ComposerView(controller: controller, onVoiceModeEntered: prepareSpeech,
                                 onSpeechStart: beginSpeech, onSpeechStop: finishSpeech,
                                 speechInputActive: speech.isStarting || speech.isRecording || speech.isFinishing,
                                 speechPartial: speech.transcript, speechFinishing: speech.isFinishing,
                                 speechPermissionPending: speech.requestingPermission,
                                 dismissKeyboardSignal: keyboardDismissSignal)
                    if !controller.messages.isEmpty {
                        Text("回答由 AI 生成，仅供参考")
                            .font(.caption2).foregroundStyle(ChatTheme.muted)
                            .padding(.top, 3)
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
        .background { WindowAppearance(mode: appearanceMode).frame(width: 0, height: 0) }
        .environment(\.locale, language == "system" ? .current : Locale(identifier: language))
        .dynamicTypeSize(displayTextSize)
        .onAppear {
            speech.onCompletion = { [weak controller, weak speech] text in
                guard let controller, !text.isEmpty else { return }
                if !controller.draft.isEmpty { controller.draft += " " }
                controller.draft += text
                speech?.transcript = ""
            }
        }
        .onDisappear {
            cancelSpeech()
            speech.onCompletion = nil
            reader.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { cancelSpeech(); reader.stop() }
        }
        .onChange(of: readerMuted) { _, muted in if muted { reader.stop() } }
        .onChange(of: controller.completedReplyText) { _, reply in
            if let reply, !readerMuted, !settingsOpen, !modelSettingsOpen,
               !speech.isStarting, !speech.isRecording, !speech.isFinishing {
                reader.read(reply, voiceID: readerVoiceID)
            }
        }
        .onChange(of: settingsOpen) { _, open in
            if open { keyboardDismissSignal &+= 1; cancelSpeech(); reader.stop() }
        }
        .onChange(of: modelSettingsOpen) { _, open in
            if open { keyboardDismissSignal &+= 1; cancelSpeech(); reader.stop() }
        }
        .onChange(of: controller.currentID) { _, id in
            if historyJump?.sessionID != id { historyJump = nil }
            cancelSpeech()
            reader.stop()
        }
        .sheet(isPresented: $settingsOpen) {
            NavigationStack { SettingsView(controller: controller) }
        }
        .sheet(isPresented: $modelSettingsOpen) {
            NavigationStack { ModelSettingsView(controller: controller) }
        }
        .fullScreenCover(isPresented: $historySearchOpen) {
            HistorySearchView(sessions: controller.sessions, onClose: { historySearchOpen = false }) { sessionID, messageID in
                guard !controller.isGenerating && !controller.isImporting else { return }
                controller.open(sessionID)
                sidebarOpen = false
                historySearchOpen = false
                if let messageID { historyJump = HistoryJump(sessionID: sessionID, messageID: messageID) }
                else { historyJump = nil }
            }
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

    private func prepareSpeech() {
        guard !speech.hasPermissions, !speech.requestingPermission else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--isolated-ui-test") { return }
        #endif
        speechPermissionTask?.cancel()
        speechPermissionTask = Task { guard !Task.isCancelled else { return }; await speech.preparePermissions() }
    }

    private func beginSpeech() {
        guard !controller.isGenerating && !controller.isImporting else { return }
        guard speech.hasPermissions else { prepareSpeech(); return }
        reader.stop()
        keyboardDismissSignal &+= 1
        speechStartTask?.cancel()
        let locale = language == "system" ? Locale.current : Locale(identifier: language)
        speechStartTask = Task {
            guard !Task.isCancelled else { return }
            await speech.start(locale: locale)
        }
    }

    private func finishSpeech() {
        speechStartTask?.cancel()
        speechStartTask = nil
        speech.stop()
    }

    private func cancelSpeech() {
        speechStartTask?.cancel()
        speechStartTask = nil
        speechPermissionTask?.cancel()
        speechPermissionTask = nil
        speech.cancel()
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
            if !controller.messages.isEmpty {
                Button { modelSettingsOpen = true } label: {
                    Text(controller.sessions.first(where: { $0.id == controller.currentID })?.title ?? "AmoreChat")
                        .font(.headline).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("点按选择模型")
                .accessibilityIdentifier("root.model.select")
            } else if let name = controller.selectedModelName {
                Button { modelSettingsOpen = true } label: {
                    Text(name).font(.subheadline).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityHint("点按选择模型")
                .accessibilityIdentifier("root.model.select")
            } else {
                Spacer(minLength: 0)
            }
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
