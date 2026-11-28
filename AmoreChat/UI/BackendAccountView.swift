import SwiftUI
import UIKit

@MainActor
struct BackendAccountView: View {
    @Bindable var controller: ChatController
    @Environment(BackendAuthStore.self) private var backend
    @State private var showsLogout = false
    @State private var showsAvatarEditor = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                profileCard
                quotaCard
                inviteCard
                localOnlyCard
                ledgerCard
                if backend.isTestMode {
                    Text("当前为界面预览模式，账户数据仅供展示。")
                        .font(.caption2).foregroundStyle(ChatTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else {
                    logoutButton
                }
            }
            .padding(16)
        }
        .background(ChatTheme.settingsBackground.ignoresSafeArea())
        .sheet(isPresented: $showsAvatarEditor) {
            AvatarSetupView()
        }
        .task {
            guard !backend.isTestMode else { return }
            await backend.refreshUser()
            await backend.loadLedger()
        }
        .confirmationDialog("退出账户？", isPresented: $showsLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { backend.logout() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后需要重新输入账号密码；本机会话仍保留。")
        }
    }

    private var profileCard: some View {
        accountCard {
            Button {
                showsAvatarEditor = true
            } label: {
                HStack(spacing: 13) {
                    LocalAvatarView(size: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(backend.user?.username ?? "AmoreChat 账户")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(ChatTheme.text)
                        Text("头像仅保存在本机")
                            .font(.caption).foregroundStyle(ChatTheme.muted)
                    }
                    Spacer(minLength: 0)
                    Label("更换头像", systemImage: "chevron.forward")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ChatTheme.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更换头像")
            .accessibilityIdentifier("account.editAvatar")
        }
    }

    private var quotaCard: some View {
        accountCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Token 额度").font(.footnote).foregroundStyle(ChatTheme.muted)
                        Text(backend.user.map { BackendAuthStore.tokenText($0.tokenBalance) } ?? "—")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text("可用于 AmoreChat 模型对话。")
                            .font(.caption2).foregroundStyle(ChatTheme.muted)
                    }
                    Spacer(minLength: 0)
                    Button {
                        Task {
                            await backend.refreshUser()
                            await backend.loadLedger()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 38, height: 38)
                            .background(ChatTheme.raised, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(backend.doingNetworkWork || backend.isTestMode)
                    .accessibilityLabel("刷新额度")
                    .accessibilityIdentifier("account.refreshTokens")
                }
                if let config = backend.publicConfig {
                    Divider().overlay(ChatTheme.line)
                    HStack(spacing: 18) {
                        Label("注册 \(BackendAuthStore.compactTokenText(config.signupTokenBonus))",
                              systemImage: "gift")
                        Label("邀请 \(BackendAuthStore.compactTokenText(config.inviteTokenBonus))",
                              systemImage: "person.badge.plus")
                    }
                    .font(.caption2).foregroundStyle(ChatTheme.muted)
                }
            }
        }
    }

    private var inviteCard: some View {
        accountCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("我的邀请").font(.footnote).foregroundStyle(ChatTheme.muted)
                HStack(spacing: 8) {
                    Text(backend.user?.inviteCode ?? "—")
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    Button {
                        UIPasteboard.general.string = backend.user?.inviteCode
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ChatTheme.accent)
                    .disabled(backend.user?.inviteCode == nil)
                    .accessibilityIdentifier("account.copyInvite")
                }
                Text("成功邀请 \(backend.user?.inviteCount ?? 0) 人；每成功邀请一人，即可获得相应的 Token 奖励。")
                    .font(.caption2).foregroundStyle(ChatTheme.muted)
            }
        }
    }

    private var localOnlyCard: some View {
        accountCard {
            VStack(alignment: .leading, spacing: 9) {
                Text("聊天记录与附件").font(.footnote).foregroundStyle(ChatTheme.muted)
                Label {
                    Text("会话、文件和照片只保存在本机")
                        .font(.caption.weight(.medium))
                } icon: {
                    Image(systemName: "lock.iphone").foregroundStyle(ChatTheme.accent)
                }
                Text("聊天资料由你在本机管理；账户页提供额度和邀请信息。")
                    .font(.caption2).foregroundStyle(ChatTheme.muted)
                Text("导入或清除请在「数据管理」操作，导出的文件由你自行保存。")
                    .font(.caption2).foregroundStyle(ChatTheme.muted)
            }
        }
    }

    private var ledgerCard: some View {
        accountCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("额度变动").font(.footnote).foregroundStyle(ChatTheme.muted)
                if let ledger = backend.ledger, !ledger.items.isEmpty {
                    ForEach(ledger.items.prefix(8)) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ledgerReason(entry.reason)).font(.caption)
                                Text(entry.createdAt.prefix(10)).font(.caption2)
                                    .foregroundStyle(ChatTheme.muted)
                            }
                            Spacer()
                            Text((entry.delta >= 0 ? "+" : "") + BackendAuthStore.tokenText(entry.delta))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(entry.delta >= 0 ? .green : ChatTheme.muted)
                        }
                    }
                } else {
                    Text(backend.ledgerError == nil ? "暂无额度变动记录。" : "暂时无法获取额度记录，请稍后刷新。")
                        .font(.caption2)
                        .foregroundStyle(backend.ledgerError == nil ? ChatTheme.muted : .red)
                }
            }
        }
    }

    private var logoutButton: some View {
        Button(role: .destructive) {
            showsLogout = true
        } label: {
            Text("退出登录")
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(.red)
                .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("account.logout")
    }

    private func accountCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .strokeBorder(ChatTheme.line.opacity(0.5), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
    }

    private func ledgerReason(_ reason: String) -> String {
        switch reason {
        case "SIGNUP_BONUS": return "注册赠送"
        case "INVITE_BONUS": return "邀请奖励"
        case "AI_USAGE": return "模型用量"
        case "ADMIN_ADJUST": return "额度调整"
        default: return "额度变动"
        }
    }
}
