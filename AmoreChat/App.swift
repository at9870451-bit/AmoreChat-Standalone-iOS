import SwiftUI

@main
struct AmoreChatStandaloneApp: App {
    @State private var auth = BackendAuthStore()
    @State private var controller = AppControllerFactory.make()
    @State private var speech = SpeechInput()
    @State private var reader = SpeechReader()
    @State private var localProfile = LocalProfileStore()

    var body: some Scene {
        WindowGroup {
            BackendGateView(auth: auth, controller: controller, speech: speech, reader: reader)
                .environment(localProfile)
        }
    }
}

@MainActor
struct BackendGateView: View {
    @Bindable var auth: BackendAuthStore
    @Bindable var controller: ChatController
    @Bindable var speech: SpeechInput
    @Bindable var reader: SpeechReader
    @Environment(LocalProfileStore.self) private var localProfile

    private var avatarSetupPresented: Binding<Bool> {
        Binding(get: {
            auth.isSignedIn && !auth.isTestMode && localProfile.needsAvatarSetup
        }, set: { _ in })
    }

    var body: some View {
        Group {
            switch auth.phase {
            case .checking:
                BackendStartupView()
            case .signedOut:
                BackendAuthView(auth: auth)
            case .signedIn:
                RootView(controller: controller, speech: speech, reader: reader)
            }
        }
        .environment(auth)
        .task { await auth.start() }
        .task(id: auth.user?.id) {
            await localProfile.selectAccount(auth.isSignedIn ? auth.user?.id : nil)
        }
        .fullScreenCover(isPresented: avatarSetupPresented) {
            AvatarSetupView(isInitialSetup: true)
                .environment(localProfile)
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
    @State private var forceBottomSignal = 0
    @State private var speechStartTask: Task<Void, Never>?
    @State private var speechPermissionTask: Task<Void, Never>?
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.system.rawValue
    @AppStorage("standalone.appLanguage") private var language = "system"
    @AppStorage("standalone.fontScale") private var fontScale = 1.0
    @AppStorage("standalone.reader.muted") private var readerMuted = true
    @AppStorage("standalone.speech.voiceID") private var readerVoiceID = ""
    @Environment(\.dynamicTypeSize) private var systemTextSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(BackendAuthStore.self) private var backend
    @ScaledMetric(relativeTo: .headline) private var headerTitleSize: CGFloat = 16

    private var appearanceMode: AppearanceMode { AppearanceMode(storedValue: appearance) }
    private var displayTextSize: DynamicTypeSize {
        if fontScale < 0.95 { return .small }
        if fontScale > 1.35 { return .xxxLarge }
        if fontScale > 1.18 { return .xxLarge }
        if fontScale > 1.04 { return .xLarge }
        return systemTextSize
    }

    var body: some View {
        GeometryReader { safeGeometry in
            GeometryReader { canvasGeometry in
                drawerCanvas(size: canvasGeometry.size,
                             topInset: safeGeometry.safeAreaInsets.top,
                             bottomInset: max(0, canvasGeometry.size.height - safeGeometry.size.height))
            }
            // Measure the actual container through its bottom edge. The keyboard still
            // participates in layout; only the home-indicator container inset is ignored.
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .background { WindowAppearance(mode: appearanceMode).frame(width: 0, height: 0) }
        .environment(\.locale, language == "system" ? .current : Locale(identifier: language))
        .dynamicTypeSize(displayTextSize)
        .task {
            // Make the user-managed destination available in Files on first launch.
            await Task.detached(priority: .utility) { _ = try? ImportFolder.directory() }.value
            controller.setServerAccessToken(backend.currentAccessToken)
            await backend.loadServerModels()
            if backend.isSignedIn, backend.serverModelsError == nil, !backend.isTestMode {
                controller.updateServerModels(backend.serverModels)
            }
        }
        .onChange(of: backend.serverModels) { _, models in
            guard backend.isSignedIn, backend.serverModelsError == nil, !backend.isTestMode else { return }
            controller.updateServerModels(models)
        }
        .onChange(of: backend.currentAccessToken) { _, token in
            controller.setServerAccessToken(token)
        }
        .onChange(of: controller.isGenerating) { wasGenerating, isGenerating in
            if wasGenerating && !isGenerating && !backend.isTestMode {
                Task { await backend.refreshUser() }
            }
        }
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
            if phase == .background {
                cancelSpeech(); reader.stop()
                Task { await controller.flushLocalState() }
            }
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

    /// Both panels and the final corner clip use this one measured canvas.
    /// Its bottom is the physical screen bottom (or keyboard top), never a guessed offset.
    private func drawerCanvas(size: CGSize, topInset: CGFloat, bottomInset: CGFloat) -> some View {
        let sidebarWidth = min(340, size.width * 0.783)
        let fullHeight = size.height
        let previewTop = sidebarOpen ? min(36, topInset * 0.60) : 0
        let previewBottomGap = sidebarOpen ? max(20, bottomInset * 0.68) : 0
        let previewContentInset: CGFloat = sidebarOpen ? previewTop + 18 : 0
        let previewWidth = sidebarOpen ? size.width - sidebarWidth : size.width
        let panelHeight = fullHeight - previewBottomGap + previewTop
        let panelShape = RoundedRectangle(cornerRadius: sidebarOpen ? 38 : 0, style: .continuous)
        return ZStack(alignment: .topLeading) {
            ChatTheme.canvas.ignoresSafeArea()
                .frame(width: size.width, height: fullHeight)
            if sidebarOpen {
                SidebarView(controller: controller,
                            bottomSafeAreaInset: bottomInset,
                            onClose: { setSidebar(false) },
                            onSettings: { setSidebar(false); settingsOpen = true },
                            onSearch: {
                                keyboardDismissSignal &+= 1
                                cancelSpeech()
                                reader.stop()
                                historySearchOpen = true
                            })
                    .frame(width: sidebarWidth, height: fullHeight, alignment: .topLeading)
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
                    }, onBackgroundTap: { keyboardDismissSignal &+= 1 },
                                   forceBottomSignal: forceBottomSignal, jump: historyJump)
                }
                ComposerView(controller: controller, onVoiceModeEntered: prepareSpeech,
                             onInputFocus: { forceBottomSignal &+= 1 },
                             onSpeechStart: beginSpeech, onSpeechStop: finishSpeech,
                             speechInputActive: speech.isStarting || speech.isRecording || speech.isFinishing,
                             speechPartial: speech.transcript, speechFinishing: speech.isFinishing,
                             speechPermissionPending: speech.requestingPermission,
                             dismissKeyboardSignal: keyboardDismissSignal,
                             bottomSafeAreaInset: sidebarOpen ? 32 : bottomInset)
            }
            // The conversation keeps its screen-wide layout; only its leading slice is
            // visible after translation, matching the reference rather than reflowing text.
            .frame(width: size.width, height: panelHeight - previewContentInset, alignment: .top)
            .padding(.top, previewContentInset)
            .background(sidebarOpen ? ChatTheme.drawerPreview : ChatTheme.canvas)
            .clipShape(panelShape)
            .overlay {
                panelShape
                    .strokeBorder(ChatTheme.line.opacity(sidebarOpen ? 0.42 : 0), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .allowsHitTesting(!sidebarOpen)
            .accessibilityHidden(sidebarOpen)
            .offset(x: sidebarOpen ? sidebarWidth : 0, y: -previewTop)
            .zIndex(1)
            if sidebarOpen {
                Button { setSidebar(false) } label: {
                    Color.clear
                        .frame(width: previewWidth, height: fullHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭侧边栏")
                .accessibilityIdentifier("root.sidebar.close")
                .offset(x: sidebarWidth)
                .zIndex(2)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .simultaneousGesture(DragGesture(minimumDistance: 28)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                if value.translation.width > 80 && value.startLocation.x < 32 {
                    setSidebar(true)
                } else if value.translation.width < -72 && sidebarOpen {
                    setSidebar(false)
                }
            })
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

    private func setSidebar(_ open: Bool) {
        guard open != sidebarOpen else { return }
        if open {
            keyboardDismissSignal &+= 1
            cancelSpeech()
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.27)) { sidebarOpen = open }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { setSidebar(!sidebarOpen) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().frame(width: 17, height: 1.65)
                    Capsule().frame(width: 9, height: 1.65)
                }
                .frame(width: 44, height: 44)
                .background(ChatTheme.surface, in: Circle())
                .overlay { Circle().strokeBorder(ChatTheme.line.opacity(0.68), lineWidth: 0.5) }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开历史对话")
            .accessibilityIdentifier("root.sidebar.open")
            if !controller.messages.isEmpty {
                Button { modelSettingsOpen = true } label: {
                    Text(controller.sessions.first(where: { $0.id == controller.currentID })?.title ?? "新对话")
                        .font(.system(size: headerTitleSize, weight: .regular)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
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
            .buttonStyle(.plain)
            .background(ChatTheme.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(ChatTheme.line.opacity(0.68), lineWidth: 0.5).allowsHitTesting(false) }
        }
        .foregroundStyle(ChatTheme.text)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}
