import SwiftUI

/// Every row is backed by ChatController's persisted sessions, never a mock timeline.
@MainActor struct SidebarView: View {
    @Bindable var controller: ChatController
    let onClose: () -> Void
    let onNewChat: () -> Void
    let onSettings: () -> Void
    let onSearch: () -> Void
    @AppStorage("standalone.profile.nickname") private var nickname = "访客"
    @State private var managing = false
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var deletionID: UUID?

    private var matches: [ChatSession] {
        controller.sessions.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }
    private func bucket(_ session: ChatSession) -> Int {
        if session.isPinned { return 0 }
        if Calendar.current.isDateInToday(session.updatedAt) { return 1 }
        if Calendar.current.isDateInYesterday(session.updatedAt) { return 2 }
        let age = Date().timeIntervalSince(session.updatedAt)
        if age < 7*86400 { return 3 }
        if age < 30*86400 { return 4 }
        return 5
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: onSearch) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.system(size: 18))
                        Text("搜索对话内容…")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(ChatTheme.muted)
                    .padding(.horizontal, 12).frame(height: 48)
                    .background(ChatTheme.surface, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.search")
                Button(action: onClose) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .frame(width: 40, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Close sidebar")
            }
            .padding(.horizontal, 12).padding(.top, 12)
            HStack(spacing: 8) {
                Button {
                    onNewChat()
                    if !controller.isGenerating { onClose() }
                } label: {
                    Label("新建对话", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.new")
                Button { managing.toggle() } label: {
                    Image(systemName: managing ? "checkmark.circle" : "list.bullet.indent")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(managing ? "完成管理" : "管理对话")
                .accessibilityIdentifier("sidebar.manage")
            }
            .padding(.horizontal, 18).padding(.top, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if matches.isEmpty {
                        Text("暂无历史对话")
                            .font(.subheadline).foregroundStyle(ChatTheme.muted)
                            .padding(.top, 32)
                    }
                    ForEach(0..<6, id: \.self) { group in
                        let items = matches.filter { bucket($0) == group }
                        if !items.isEmpty {
                            Text(["置顶", "今天", "昨天", "7 天内", "30 天内", "更早"][group])
                                .font(.caption.weight(.medium))
                                .foregroundStyle(ChatTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, group == 0 ? 10 : 24)
                                .padding(.bottom, 8)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(items) { session in row(session) }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(nickname.isEmpty ? "访客" : nickname).lineLimit(1)
                    Text("仅保存在本机").font(.caption).foregroundStyle(ChatTheme.muted)
                }
                Spacer()
                Button(action: onSettings) { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .accessibilityLabel("打开设置")
                    .accessibilityIdentifier("sidebar.settings")
            }
            .padding(.horizontal, 18)
            .frame(height: 68)
        }
        .foregroundStyle(ChatTheme.text)
        .background(ChatTheme.canvas)
        .alert("重命名对话", isPresented: Binding(
            get: { renameID != nil }, set: { if !$0 { renameID = nil } }
        )) {
            TextField("对话名称", text: $renameText)
            Button("取消", role: .cancel) { renameID = nil }
            Button("保存") {
                if let renameID { controller.rename(renameID, renameText) }
                renameID = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("名称仅保存于本机。") }
        .confirmationDialog("删除这段对话？", isPresented: Binding(
            get: { deletionID != nil }, set: { if !$0 { deletionID = nil } }
        ), titleVisibility: .visible) {
            Button("删除对话", role: .destructive) {
                if let deletionID { controller.delete(deletionID) }
                deletionID = nil
            }
            Button("取消", role: .cancel) { deletionID = nil }
        } message: { Text("本机记录与对应附件将被移除，无法撤销。") }
    }

    private func row(_ session: ChatSession) -> some View {
        HStack(spacing: 0) {
            Button {
                controller.open(session.id)
                if controller.currentID == session.id { onClose() }
            } label: {
                HStack(spacing: 8) {
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption).foregroundStyle(ChatTheme.accent)
                    }
                    Text(session.title.isEmpty ? "新对话" : session.title)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.body)
                .foregroundStyle(ChatTheme.text)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.session.\(session.id)")
            .contextMenu {
                Button("重命名", systemImage: "pencil") { renameID = session.id; renameText = session.title }
                Button(session.isPinned ? "取消置顶" : "置顶", systemImage: "pin") { controller.pin(session.id) }
                Button("删除", systemImage: "trash", role: .destructive) { deletionID = session.id }
            }
            if managing {
                Menu {
                    Button("重命名", systemImage: "pencil") { renameID = session.id; renameText = session.title }
                    Button(session.isPinned ? "取消置顶" : "置顶", systemImage: "pin") { controller.pin(session.id) }
                    Button("删除", systemImage: "trash", role: .destructive) { deletionID = session.id }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("管理 \(session.title)")
            }
        }
        .padding(.leading, 3)
        .frame(minHeight: 44)
        .background(controller.currentID == session.id ? ChatTheme.surface : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
    }
}
