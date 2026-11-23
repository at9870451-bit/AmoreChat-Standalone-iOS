import SwiftUI

@main
struct AmoreChatStandaloneApp: App {
    @State private var controller = ChatController()
    @State private var speech = SpeechInput()

    var body: some Scene {
        WindowGroup {
            RootView(controller: controller, speech: speech)
        }
    }
}

struct RootView: View {
    @Bindable var controller: ChatController
    @Bindable var speech: SpeechInput
    @State private var sidebarOpen = false
    @State private var settingsOpen = false

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(338, geometry.size.width * 0.85)
            ZStack(alignment: .leading) {
                ChatTheme.canvas.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    Divider()
                    if controller.isLoading {
                        ProgressView("正在读取会话…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TranscriptView(controller: controller)
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
                    })
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if sidebarOpen {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.easeOut(duration: 0.25)) { sidebarOpen = false } }
                        .accessibilityLabel("关闭侧边栏")
                        .transition(.opacity)
                    SidebarView(controller: controller,
                                onClose: { withAnimation(.easeOut(duration: 0.25)) { sidebarOpen = false } },
                                onNewChat: { controller.newChat() },
                                onSettings: { sidebarOpen = false; settingsOpen = true })
                        .frame(width: sidebarWidth)
                        .frame(maxHeight: .infinity)
                        .background(ChatTheme.canvas,
                                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .gesture(DragGesture(minimumDistance: 28)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                    if value.translation.width > 80 && value.startLocation.x < 36 {
                        withAnimation(.easeOut(duration: 0.25)) { sidebarOpen = true }
                    } else if value.translation.width < -80 && sidebarOpen {
                        withAnimation(.easeOut(duration: 0.25)) { sidebarOpen = false }
                    }
                })
        }
        .sheet(isPresented: $settingsOpen) {
            NavigationStack { SettingsView(controller: controller) }
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
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.25)) { sidebarOpen.toggle() }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("打开历史对话")
            .accessibilityIdentifier("root.sidebar.open")
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text(controller.sessions.first(where: { $0.id == controller.currentID })?.title ?? "AmoreChat")
                    .font(.headline)
                    .lineLimit(1)
                Text(controller.backendReady ? "已连接" : "未连接后端")
                    .font(.caption)
                    .foregroundStyle(ChatTheme.muted)
            }
            .frame(maxWidth: .infinity)
            Button {
                controller.newChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("新建对话")
            .accessibilityIdentifier("root.chat.new")
            Menu {
                Button("设置", systemImage: "gearshape") { settingsOpen = true }
                Button("搜索历史", systemImage: "magnifyingglass") {
                    withAnimation { sidebarOpen = true }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多操作")
        }
        .foregroundStyle(ChatTheme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
