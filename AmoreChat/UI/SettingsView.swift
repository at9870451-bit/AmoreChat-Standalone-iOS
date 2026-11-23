import AVFoundation
import SwiftUI
import UIKit

private enum SettingsPage: String, Identifiable {
    case account, models, data, language, appearance, font, personalization, voice, updates, agreement, help
    var id: String { rawValue }
}

struct SettingsView: View {
    @Bindable var controller: ChatController
    @Environment(\.dismiss) private var dismiss
    @State private var page: SettingsPage?
    @State private var showSignOutNotice = false
    @AppStorage("standalone.appearance") private var appearance = "system"
    @AppStorage("standalone.appLanguage") private var language = "system"
    @AppStorage("standalone.fontScale") private var fontScale = 1.0
    @AppStorage("standalone.profile.nickname") private var nickname = "访客"
    private let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.96, alpha: 1) })

    var body: some View {
        ScrollView {
            VStack(spacing: 23) {
                header
                card {
                    row("账户管理", symbol: "person.crop.circle", page: .account)
                    separator
                    row("数据管理", symbol: "externaldrive", page: .data)
                }
                section("AI 模型") {
                    row("添加模型 / 服务商", symbol: "plus.circle",
                        value: controller.selectedModelName ?? "未配置", page: .models)
                }
                section("应用") {
                    row("语言", symbol: "globe", value: languageName, page: .language)
                    separator
                    row("外观", symbol: "moon.stars", value: appearanceName, page: .appearance)
                    separator
                    row("字体大小", symbol: "textformat", page: .font)
                    separator
                    row("个性化", symbol: "wand.and.stars", page: .personalization)
                }
                section("语音") {
                    row("朗读音色", symbol: "speaker.wave.2", page: .voice)
                }
                section("关于") {
                    row("检查更新", symbol: "info.circle", value: version, page: .updates)
                    separator
                    row("服务协议", symbol: "doc.text", page: .agreement)
                }
                card { row("帮助与反馈", symbol: "questionmark.circle", page: .help) }
                card {
                    Button { showSignOutNotice = true } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.body)
                            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $page) { page in
            NavigationStack {
                destination(page)
                    .navigationTitle(title(for: page))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { self.page = nil }
                        }
                    }
            }
        }
        .alert("尚未登录", isPresented: $showSignOutNotice) {
            Button("好", role: .cancel) {}
        } message: {
            Text("当前只有本机访客身份，尚未接入账号后端，因此没有可退出的服务器登录。")
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Text("设置").font(.headline.weight(.semibold))
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 42, height: 42)
                    .foregroundStyle(ChatTheme.text)
                    .background(ChatTheme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(ChatTheme.line, lineWidth: 0.7))
            }
            .accessibilityLabel("关闭设置")
            .accessibilityIdentifier("settings.close")
        }
        .overlay(alignment: .leading) { Color.clear.frame(width: 42, height: 42) }
        .padding(.top, 10)
    }

    private var separator: some View { ChatTheme.line.frame(height: 0.5).padding(.leading, 54).padding(.trailing, 16) }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 24))
    }

    private func section<Content: View>(_ heading: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading).font(.footnote).foregroundStyle(ChatTheme.muted).padding(.leading, 16)
            card(content)
        }
    }

    private func row(_ title: LocalizedStringKey, symbol: String, value: String? = nil,
                     page target: SettingsPage) -> some View {
        Button { page = target } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 20)).frame(width: 22)
                Text(title).font(.body)
                Spacer(minLength: 4)
                if let value { Text(value).foregroundStyle(ChatTheme.muted).lineLimit(1) }
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                    .foregroundStyle(ChatTheme.muted)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.row.\(target.rawValue)")
    }

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0" }
    private var languageName: String {
        switch language { case "zh-Hans": return "简体中文"; case "zh-Hant": return "繁體中文"
        case "en": return "English"; default: return "系统" }
    }
    private var appearanceName: String {
        switch appearance { case "light": return "浅色"; case "dark": return "深色"; default: return "系统" }
    }
    private func title(for page: SettingsPage) -> String {
        switch page { case .account: "账户管理"; case .models: "模型与服务商"; case .data: "数据管理"; case .language: "语言"
        case .appearance: "外观"; case .font: "字体大小"; case .personalization: "个性化"
        case .voice: "朗读音色"; case .updates: "检查更新"; case .agreement: "服务协议"
        case .help: "帮助与反馈" }
    }

    @ViewBuilder private func destination(_ page: SettingsPage) -> some View {
        switch page {
        case .account: accountPage
        case .models: ModelSettingsView(controller: controller)
        case .data: DataManagementPage(controller: controller)
        case .language:
            List {
                Picker("语言", selection: $language) {
                    Text("跟随系统").tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                    Text("English").tag("en")
                }.pickerStyle(.inline)
                Text("切换后立即应用；翻译尚在完善中。").font(.footnote).foregroundStyle(.secondary)
            }
        case .appearance:
            List { Picker("外观", selection: $appearance) {
                Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
            }.pickerStyle(.inline) }
        case .font:
            Form {
                Slider(value: $fontScale, in: 0.85...1.5, step: 0.05)
                Text("字号偏好：\(Int(fontScale * 100))%（按系统动态字体档位显示）")
                Button("恢复系统大小") { fontScale = 1.0 }
            }
        case .personalization:
            Form { TextField("本机昵称", text: $nickname).textInputAutocapitalization(.words)
                Text("仅保存到本机。尚未接入账号或云同步。")
                    .font(.footnote).foregroundStyle(.secondary) }
        case .voice: VoiceSettingsPage()
        case .updates: UpdateCheckPage(version: version)
        case .agreement:
            ScrollView { Text("本应用可选用你自行添加的 AI 服务商：发送消息时，请求会直连所配置的 HTTPS API，模型服务商可能收费；仅 OpenRouter 官方地址的联网搜索选项会要求单独确认额外费用。会话和附件保存在本机，API Key 保存在 iOS 钥匙串，不提供云账号或同步。使用外部模型时还须遵守相应服务商的协议和隐私政策。本页不是第三方官方服务条款。")
                .padding().frame(maxWidth: .infinity, alignment: .leading) }
        case .help:
            List {
                ShareLink(item: "AmoreChat Standalone \(version) · iOS \(UIDevice.current.systemVersion) · 模型配置数 \(ModelCatalog.shared.profiles.count)") {
                    Label("分享诊断概要", systemImage: "square.and.arrow.up") }
                Link(destination: URL(string: "https://github.com/at9870451-bit/AmoreChat-Standalone-iOS/issues/new")!) {
                    Label("前往 GitHub 提交反馈", systemImage: "questionmark.bubble") }
                Text("不要在反馈中提交密钥、密码或私人聊天内容。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var accountPage: some View {
        Form {
            LabeledContent("本机身份", value: nickname.isEmpty ? "访客" : nickname)
            LabeledContent("云账号", value: "未连接")
            Text("尚未提供后端账号接口。不能在此页面假装登录或同步。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
