import SwiftUI

struct BackendAuthView: View {
    @Bindable var auth: BackendAuthStore
    @State private var mode: Mode = .login
    @State private var username = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var showsPassword = false
    @FocusState private var focused: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Mode: Hashable { case login, register }
    private enum Field: Hashable { case username, password, invite }
    private let ink = Color(red: 0.75, green: 0.78, blue: 0.85)
    private let muted = Color(red: 0.48, green: 0.51, blue: 0.59)

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        brand(width: min(geometry.size.width - 42, 430), height: geometry.size.height)
                        modePicker
                            .padding(.top, 28)
                            .padding(.horizontal, 10)
                        fields
                            .padding(.top, 20)
                        if let error = auth.errorText, !error.isEmpty {
                            errorBanner(error).padding(.top, 14)
                        }
                        submitButton
                            .padding(.top, 22)
                            .id("auth.action.position")
                        if mode == .register {
                            registrationNote.padding(.top, 14)
                        }
                        if auth.phase == .signedOut && auth.errorText != nil {
                            Button("重试连接") { Task { await auth.retryConnection() } }
                                .font(.footnote).foregroundStyle(ink)
                                .padding(.top, 14)
                                .accessibilityIdentifier("auth.retry")
                        }
                        securityNote.padding(.top, 25)
                    }
                    .padding(.horizontal, 21)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: focused) { _, field in
                    guard field != nil else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
                        scroll.scrollTo(field == .invite ? "auth.action.position" : "auth.form.position", anchor: .center)
                    }
                }
            }
        }
        .background { AuthBackdrop() }
        .foregroundStyle(.white)
        // The supplied auth artwork is intentionally dark; appearance of signed-in chat is unchanged.
        .preferredColorScheme(.dark)
        .task { await auth.loadPublicConfig() }
        .onChange(of: mode) { _, _ in
            focused = nil
            password = ""
            invite = ""
            showsPassword = false
            auth.clearSignInError()
        }
    }

    private func brand(width: CGFloat, height: CGFloat) -> some View {
        let heroWidth = min(width, 360)
        // Maintain recognizable artwork on short screens; forms remain scrollable above the keyboard.
        let top = height > 720 ? min(42, (height - 650) * 0.25) : CGFloat(12)
        return VStack(spacing: 0) {
            Image("AuthWhaleHero")
                .resizable().scaledToFit()
                .frame(width: heroWidth, height: heroWidth * 321 / 620)
                .accessibilityHidden(true)
            Text("AmoreChat")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.7)
                .minimumScaleFactor(0.7).lineLimit(1)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("auth.brand")
            Text("与更聪明的 AI 一起，探索无限可能")
                .font(.system(size: 14))
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(.top, top)
        .frame(maxWidth: .infinity)
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            modeButton("登录", value: .login, identifier: "auth.mode.login")
            modeButton("注册", value: .register, identifier: "auth.mode.register")
        }
        .padding(3)
        .background(Color(red: 0.12, green: 0.13, blue: 0.17).opacity(0.85), in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.035), lineWidth: 1) }
        .accessibilityIdentifier("auth.mode")
    }

    private func modeButton(_ label: String, value: Mode, identifier: String) -> some View {
        Button {
            guard !auth.doingNetworkWork else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { mode = value }
        } label: {
            Text(label)
                .font(.system(size: 16, weight: mode == value ? .semibold : .regular))
                .foregroundStyle(mode == value ? Color.white : ink)
                .frame(maxWidth: .infinity, minHeight: 37)
                .background {
                    if mode == value {
                        Capsule()
                            .fill(LinearGradient(colors: [Color(red: 0.54, green: 0.58, blue: 0.69),
                                                         Color(red: 0.35, green: 0.38, blue: 0.48)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay { Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1) }
                            .shadow(color: .white.opacity(0.09), radius: 4, y: -1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(auth.doingNetworkWork)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var fields: some View {
        VStack(spacing: 16) {
            field(title: "账号", symbol: "person") {
                TextField("", text: $username, prompt: Text("3-32 位字母、数字或下划线").foregroundStyle(muted))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .keyboardType(.asciiCapable)
                    .focused($focused, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
                    .accessibilityLabel("账号")
                    .accessibilityIdentifier("auth.username")
            }
            field(title: "密码", symbol: "lock") {
                HStack(spacing: 4) {
                    Group {
                        if showsPassword {
                            TextField("", text: $password, prompt: Text("至少 8 位").foregroundStyle(muted))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("", text: $password, prompt: Text("至少 8 位").foregroundStyle(muted))
                        }
                    }
                    .textContentType(mode == .register ? .newPassword : .password)
                    .focused($focused, equals: .password)
                    .submitLabel(mode == .register ? .next : .go)
                    .onSubmit { if mode == .register { focused = .invite } else { submit() } }
                    .accessibilityLabel("密码")
                    .accessibilityIdentifier("auth.password")
                    Button {
                        showsPassword.toggle()
                        if focused == .password { focused = .password }
                    } label: {
                        Image(systemName: showsPassword ? "eye" : "eye.slash")
                            .font(.system(size: 18))
                            .foregroundStyle(ink)
                            .frame(width: 39, height: 42)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsPassword ? "隐藏密码" : "显示密码")
                    .accessibilityIdentifier("auth.password.toggle")
                }
            }
            if mode == .register {
                field(title: "邀请码", symbol: "ticket") {
                    TextField("", text: $invite, prompt: Text("请输入有效邀请码").foregroundStyle(muted))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .focused($focused, equals: .invite)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                        .accessibilityLabel("邀请码")
                        .accessibilityIdentifier("auth.invite")
                }
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 17)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.15, green: 0.17, blue: 0.21).opacity(0.97),
                                             Color(red: 0.075, green: 0.085, blue: 0.11).opacity(0.94),
                                             Color(red: 0.12, green: 0.13, blue: 0.17)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.08), .white.opacity(0.13)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.22), radius: 20, y: 7)
        }
        .id("auth.form.position")
        .disabled(auth.doingNetworkWork)
    }

    private func field<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .light))
                .foregroundStyle(ink)
                .frame(width: 28)
                .padding(.top, 17)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12)).foregroundStyle(ink)
                content()
                    .font(.system(size: 14))
                    .tint(Color(red: 0.4, green: 0.63, blue: 1))
                    .padding(.leading, 12)
                    .padding(.trailing, title == "密码" ? 1 : 12)
                    .frame(minHeight: 42)
                    .background(Color(red: 0.18, green: 0.20, blue: 0.25).opacity(0.72),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var submitButton: some View {
        Button(action: submit) {
            HStack(spacing: 10) {
                if auth.doingNetworkWork { ProgressView().tint(.white).controlSize(.small) }
                Text(auth.doingNetworkWork ? "请稍候…" : (mode == .login ? "登录 AmoreChat" : "注册 AmoreChat"))
                    .font(.system(size: 17, weight: .semibold))
                if !auth.doingNetworkWork { Image(systemName: "arrow.right").font(.system(size: 20, weight: .medium)) }
            }
            .frame(maxWidth: .infinity, minHeight: 55)
            .contentShape(Capsule())
            .background(LinearGradient(colors: [Color(red: 0.37, green: 0.60, blue: 1),
                                                Color(red: 0.16, green: 0.40, blue: 0.98)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.8) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .opacity(auth.doingNetworkWork ? 0.8 : 1)
        .disabled(!canSubmit || auth.doingNetworkWork)
        .accessibilityHint(canSubmit ? "提交账户信息" : (mode == .register ? "请填写账号、密码和有效邀请码" : "请填写账号和密码"))
        .accessibilityIdentifier("auth.submit")
    }

    private var registrationNote: some View {
        VStack(spacing: 5) {
            Label("注册需有效邀请码", systemImage: "ticket")
                .font(.system(size: 12, weight: .medium))
            if let bonus = auth.publicConfig?.signupTokenBonus, bonus > 0 {
                Text("注册赠送 \(BackendAuthStore.compactTokenText(bonus)) token")
                    .font(.system(size: 11))
            }
        }
        .foregroundStyle(ink)
        .multilineTextAlignment(.center)
        .accessibilityIdentifier("auth.registration.note")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").padding(.top, 1)
            Text(message).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.63))
        .padding(12)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityIdentifier("auth.error")
    }

    private var securityNote: some View {
        VStack(spacing: 10) {
            HStack(spacing: 13) {
                Rectangle().fill(ink.opacity(0.18)).frame(height: 0.6).frame(maxWidth: .infinity)
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 14))
                    .accessibilityHidden(true)
                Text("安全加密 · BCrypt · Keychain")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: true, vertical: false)
                Rectangle().fill(ink.opacity(0.18)).frame(height: 0.6).frame(maxWidth: .infinity)
            }
            Text("密码仅在传输时使用，服务器保存 BCrypt 哈希，\n登录令牌保存在本机 Keychain。")
                .font(.system(size: 10.5))
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(ink)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("auth.security")
    }

    private var canSubmit: Bool {
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep a forgiving login; stricter registration checks also run on the server.
        guard account.count >= 3, account.count <= 32, password.count >= 8 else { return false }
        if mode == .register {
            guard account.unicodeScalars.allSatisfy({ scalar in
                (65...90).contains(scalar.value) || (97...122).contains(scalar.value) ||
                (48...57).contains(scalar.value) || scalar.value == 95
            }), password.utf8.count <= 72 else { return false }
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
}

struct BackendStartupView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image("AuthWhaleHero").resizable().scaledToFit().frame(width: 210, height: 110)
                .accessibilityHidden(true)
            ProgressView().tint(.white)
            Text("正在连接账户服务…").font(.footnote).foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AuthBackdrop() }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}
