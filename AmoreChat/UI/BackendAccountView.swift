import SwiftUI
import UIKit

@MainActor
struct BackendAccountView: View {
    @Bindable var controller: ChatController
    @Environment(BackendAuthStore.self) private var backend
    @State private var showsLogout = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                profileCard
                quotaCard
                inviteCard
                localOnlyCard
                ledgerCard
                if backend.isTestMode {
                    Text("当前是界面测试模式，未连接真实云端账户。")
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
        .task {
            guard !backend.isTestMode else { return }
            await backend.refreshUser()
            await backend.loadLedger()
        }
        .confirmationDialog("退出云端账户？", isPresented: $showsLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { backend.logout() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后需要重新输入账号密码；本机会话仍保留。")
        }
    }

    private var profileCard: some View {
        accountCard {
            HStack(spacing: 13) {
                Image(systemName: "person.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(ChatTheme.muted)
                    .frame(width: 44, height: 44)
                    .background(ChatTheme.raised, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(backend.user?.username ?? "云端账户")
                        .font(.body.weight(.semibold))
                    Text(backend.user?.isAdmin == true ? "管理员账户" : "AmoreChat 云端账户")
                        .font(.caption).foregroundStyle(ChatTheme.muted)
                }
                Spacer(minLength: 0)
                Text(BackendConfig.baseURL.host ?? "")
                    .font(.caption2).foregroundStyle(ChatTheme.muted)
                    .lineLimit(1)
            }
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
                        Text("额度由账户后台记账；管理员可调整。")
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
                Text("成功邀请 \(backend.user?.inviteCount ?? 0) 人；每成功邀请一人，邀请人获得后台设定的 token 奖励。")
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
                Text("服务器不保存或留存聊天内容、附件、照片；这里只记录账户、额度和邀请。")
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
                    Text(backend.ledgerError ?? "暂无额度变动记录。")
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
            Text("退出云端账户")
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
        case "AI_USAGE": return "模型 token 用量"
        case "ADMIN_ADJUST": return "管理员调整"
        default: return reason
        }
    }
}
