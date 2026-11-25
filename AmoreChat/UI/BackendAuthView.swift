import SwiftUI

struct BackendAuthView: View {
    @Bindable var auth: BackendAuthStore
    @State private var mode: Mode = .login
    @State private var username = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var showsPassword = false
    @FocusState private var focused: Field?

    enum Mode: Hashable { case login, register }
    private enum Field: Hashable { case username, password, invite }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 52)
                WhaleMark()
                    .frame(width: 54, height: 54)
                VStack(spacing: 7) {
                    Text(mode == .login ? "登录 AmoreChat" : "创建账户")
                        .font(.system(size: 25, weight: .semibold))
                    Text(mode == .login ? "你的会话、模型和 token 额度会跟随账户显示" : "注册必须使用有效邀请码")
                        .font(.footnote)
                        .foregroundStyle(ChatTheme.muted)
                        .multilineTextAlignment(.center)
                }

                Picker("方式", selection: $mode) {
                    Text("登录").tag(Mode.login)
                    Text("注册").tag(Mode.register)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("auth.mode")

                VStack(spacing: 13) {
                    authField(title: "账号", symbol: "person") {
                        TextField("3-32 位字母、数字或下划线", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .focused($focused, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { focused = .password }
                            .accessibilityIdentifier("auth.username")
                    }
                    authField(title: "密码", symbol: "lock") {
                        HStack(spacing: 8) {
                            if showsPassword {
                                TextField("至少 8 位", text: $password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .textContentType(.newPassword)
                            } else {
                                SecureField("至少 8 位", text: $password)
                                    .textContentType(.password)
                            }
                            Button {
                                showsPassword.toggle()
                            } label: {
                                Image(systemName: showsPassword ? "eye.slash" : "eye")
                                    .foregroundStyle(ChatTheme.muted)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(showsPassword ? "隐藏密码" : "显示密码")
                        }
                        .focused($focused, equals: .password)
                        .submitLabel(mode == .register ? .next : .go)
                        .onSubmit {
                            if mode == .register { focused = .invite } else { submit() }
                        }
                        .accessibilityIdentifier("auth.password")
                    }
                    if mode == .register {
                        authField(title: "邀请码", symbol: "ticket") {
                            TextField("必填，例如 AMX3K9Q2", text: $invite)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .focused($focused, equals: .invite)
                                .submitLabel(.go)
                                .onSubmit { submit() }
                                .accessibilityIdentifier("auth.invite")
                        }
                    }
                }
                .padding(16)
                .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 22))
                .overlay {
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(ChatTheme.line.opacity(0.6), lineWidth: 0.6)
                        .allowsHitTesting(false)
                }

                if let error = auth.errorText, !error.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        Text(error)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("auth.error")
                }

                if let bonus = auth.publicConfig?.signupTokenBonus, mode == .register {
                    HStack(spacing: 7) {
                        Image(systemName: "bolt.fill").foregroundStyle(ChatTheme.accent)
                        Text("注册赠送 \(BackendAuthStore.tokenText(bonus)) token；邀请人也会获得奖励。")
                            .font(.footnote).foregroundStyle(ChatTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: submit) {
                    HStack {
                        if auth.doingNetworkWork { ProgressView().tint(.white) }
                        Text(auth.doingNetworkWork ? "请稍候…" : (mode == .login ? "登录" : "使用邀请码注册"))
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(ChatTheme.accent, in: RoundedRectangle(cornerRadius: 16))
                .opacity(canSubmit && !auth.doingNetworkWork ? 1 : 0.45)
                .disabled(!canSubmit || auth.doingNetworkWork)
                .accessibilityIdentifier("auth.submit")

                if auth.phase == .signedOut && auth.errorText != nil {
                    Button("重试连接") { Task { await auth.retryConnection() } }
                        .font(.footnote)
                        .foregroundStyle(ChatTheme.accent)
                        .accessibilityIdentifier("auth.retry")
                }

                Text("密码只在传输时使用，服务器保存 BCrypt 哈希；登录令牌保存在本机 Keychain。")
                    .font(.caption2)
                    .foregroundStyle(ChatTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)

                Spacer(minLength: 30)
            }
            .padding(.horizontal, 22)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(ChatTheme.settingsBackground.ignoresSafeArea())
        .foregroundStyle(ChatTheme.text)
        .task { await auth.loadPublicConfig() }
        .onChange(of: mode) { _, _ in
            focused = nil
            password = ""
            invite = ""
        }
    }

    private var canSubmit: Bool {
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        if account.count < 3 || secret.count < 8 { return false }
        if mode == .register {
            return invite.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6
        }
        return true
    }

    private func submit() {
        guard canSubmit, !auth.doingNetworkWork else { return }
        focused = nil
        Task {
            if mode == .login {
                await auth.login(username: username, password: password)
            } else {
                await auth.register(username: username, password: password, inviteCode: invite)
            }
        }
    }

    private func authField<Content: View>(title: String, symbol: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(ChatTheme.muted)
            content()
                .font(.body)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(ChatTheme.raised, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct BackendStartupView: View {
    var body: some View {
        VStack(spacing: 18) {
            WhaleMark().frame(width: 58, height: 58)
            ProgressView()
            Text("正在连接账户服务…").font(.footnote).foregroundStyle(ChatTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChatTheme.settingsBackground.ignoresSafeArea())
        .foregroundStyle(ChatTheme.text)
    }
}