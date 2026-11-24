import AVFoundation
import Speech
import SwiftUI
import UIKit

/// A settings destination. The presenting settings flow supplies the NavigationStack.
struct ServiceDisclosuresView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Disclosure.allCases) { item in
                    if item != .agreement { DisclosureSeparator() }
                    NavigationLink {
                        DisclosureDetails(item: item)
                    } label: {
                        HStack(spacing: 12) {
                            Text(item.title)
                                .foregroundStyle(ChatTheme.text)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(ChatTheme.muted)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(minHeight: 53)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.disclosure.\(item.rawValue)")
                }
            }
            .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(ChatTheme.settingsBackground.ignoresSafeArea())
        .navigationTitle("服务协议")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum Disclosure: String, CaseIterable, Identifiable {
    case agreement, privacy, sharing, data, permissions

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .agreement: "用户协议"
        case .privacy: "隐私政策"
        case .sharing: "第三方信息共享清单"
        case .data: "个人信息收集清单"
        case .permissions: "应用权限"
        }
    }
}

private struct DisclosureDetails: View {
    let item: Disclosure

    var body: some View {
        ScrollView {
            Group {
                switch item {
                case .agreement:
                    card {
                        entry("使用范围", "AmoreChat 是独立的聊天客户端。你可以在本机管理会话，也可使用自己配置的模型服务。应用不提供云账号或跨设备会话同步。本页是应用使用说明，并非任何模型服务商的官方条款。")
                        DisclosureSeparator()
                        entry("使用外部模型", "请遵守所选服务商的条款和使用限制。费用由服务商决定。请确认自己有权发送相关文字或附件，并核实模型生成的内容后再使用。")
                    }
                case .privacy:
                    card {
                        entry("本机保存", "会话、草稿及已导入应用的附件保存在本机。昵称、显示和朗读偏好、模型配置也保存在本机；API 密钥存入 iOS 钥匙串。")
                        DisclosureSeparator()
                        entry("何时使用外部服务", "发送消息时，请求直连你配置的模型服务。语音输入使用 iOS 语音识别，检查更新会查询公开发布信息。选择朗读音色或试听不会把文本发给模型服务。")
                        DisclosureSeparator()
                        entry("管理与删除", "可在「数据管理」导出会话或清除本机记录和已归档附件，在模型设置管理服务配置。本机清除不会删除已导出的副本或第三方已收到的数据。")
                    }
                case .sharing:
                    card {
                        entry("你配置的模型 API", "发送消息时，所选服务商会收到请求所需的消息与会话上下文、模型选项和用于认证的密钥（如配置）；支持图片的模型也可能收到所附图片。开启可用的联网搜索时，服务商可进一步处理搜索相关内容。数据保留、再共享和计费依服务商规则。")
                        DisclosureSeparator()
                        entry("Apple 的 iOS 语音功能", "朗读和试听使用 iOS 系统音色，不使用麦克风或模型服务。主动开启语音输入时，麦克风音频由 iOS 语音识别处理；系统可能通过 Apple 的服务器完成识别，转写可作为消息草稿。")
                        DisclosureSeparator()
                        entry("GitHub 公开版本查询", "打开「检查更新」时，应用查询公开发布信息。GitHub 会收到常规网络请求信息（如 IP 地址），不会收到聊天内容、附件或模型密钥。查询不会自动安装更新。")
                    }
                case .data:
                    card {
                        entry("会话、草稿和附件", "包括你输入或导入的内容以及收到的模型回复，用于显示、续写或导出会话。发送消息时，请求所需内容可能交给所选模型服务。")
                        DisclosureSeparator()
                        entry("本机昵称、偏好和模型配置", "用于显示本机身份、调整界面或朗读、选择模型与服务地址。不用于注册云账号。认证密钥单独存入 iOS 钥匙串，用于你配置的服务。")
                        DisclosureSeparator()
                        entry("语音输入与照片", "主动录入时使用麦克风并生成转写；应用不另存录音文件。拍照或从系统选择器选取的照片可作为附件存入会话；应用不读取整个相册。")
                    }
                case .permissions:
                    DisclosurePermissions()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(ChatTheme.settingsBackground.ignoresSafeArea())
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DisclosureSeparator: View {
    var body: some View {
        ChatTheme.line.frame(height: 0.5).padding(.horizontal, 16)
            .accessibilityHidden(true)
    }
}

private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0, content: content)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 24))
}

private func entry(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: 7) {
        Text(title).font(.headline).foregroundStyle(ChatTheme.text)
            .accessibilityAddTraits(.isHeader)
        Text(detail).font(.subheadline).foregroundStyle(ChatTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
}

private struct DisclosurePermissions: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var microphone: Status = .unknown
    @State private var speech: Status = .unknown
    @State private var camera: Status = .unknown
    @State private var settingsUnavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                entry("麦克风", "在你主动使用语音输入时采集音频。朗读不需要麦克风。")
                status(microphone.title)
                DisclosureSeparator()
                entry("语音识别", "在你主动使用语音输入时转写音频。朗读不需要语音识别权限。")
                status(speech.title)
                DisclosureSeparator()
                entry("相机", "在你选择拍照添加附件时使用。权限状态不表示设备一定有可用相机。")
                status(camera.title)
                DisclosureSeparator()
                entry("照片选择器", "只接收你在 iOS 照片选择器中选定的项目，不需要整个相册的访问授权。")
                status("无需整个相册权限")
                DisclosureSeparator()
                entry("文件选择器", "只访问你通过系统文件选择器主动选取的文件，无需常驻文件访问权限。")
            }

            card {
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    Task { @MainActor in
                        settingsUnavailable = !(await UIApplication.shared.open(url))
                    }
                } label: {
                    Label("打开系统设置", systemImage: "arrow.up.right.square")
                        .font(.body.weight(.medium))
                        .foregroundStyle(ChatTheme.accent)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.disclosure.openSettings")
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        .alert("无法打开系统设置", isPresented: $settingsUnavailable) {
            Button("好", role: .cancel) {}
        } message: {
            Text("你可以在 iOS 系统设置中搜索 AmoreChat，以查看可用权限。")
        }
    }

    private func status(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(ChatTheme.muted)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
    }

    private func refresh() {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: microphone = .notRequested
        case .denied: microphone = .denied
        case .granted: microphone = .allowed
        @unknown default: microphone = .unknown
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: speech = .notRequested
        case .restricted: speech = .restricted
        case .denied: speech = .denied
        case .authorized: speech = .allowed
        @unknown default: speech = .unknown
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: camera = .notRequested
        case .restricted: camera = .restricted
        case .denied: camera = .denied
        case .authorized: camera = .allowed
        @unknown default: camera = .unknown
        }
    }

    private enum Status {
        case notRequested, restricted, denied, allowed, unknown

        var title: LocalizedStringKey {
            switch self {
            case .notRequested: "未请求"
            case .restricted: "受系统限制"
            case .denied: "未允许"
            case .allowed: "已允许"
            case .unknown: "状态未知"
            }
        }
    }
}
