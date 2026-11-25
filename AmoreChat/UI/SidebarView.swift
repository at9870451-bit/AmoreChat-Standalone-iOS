import SwiftUI

/// Every row is backed by ChatController's persisted sessions, never a mock timeline.
@MainActor struct SidebarView: View {
    @Bindable var controller: ChatController
    let onClose: () -> Void
    let onSettings: () -> Void
    let onSearch: () -> Void
    @AppStorage("standalone.profile.nickname") private var nickname = "访客"
    @Environment(BackendAuthStore.self) private var backend
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var itemFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) private var headerFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var searchHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var profileSize: CGFloat = 32
    @State private var managing = false
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var deletionID: UUID?

    private let groupTitles = ["置顶", "今天", "昨天", "7 天内", "30 天内", "更早"]

    private var selectedBackground: Color {
        colorScheme == .dark
            ? Color(red: 39.0 / 255, green: 46.0 / 255, blue: 63.0 / 255)
            : ChatTheme.accentWash
    }

    private var canDelete: Bool { !controller.isImporting && !controller.isGenerating }

    private var orderedSessions: [ChatSession] {
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
            searchButton
            timeline
            profileFooter
        }
        .foregroundStyle(ChatTheme.text)
        .background(ChatTheme.canvas)
        .alert("重命名对话", isPresented: Binding(
            get: { renameID != nil }, set: { if !$0 { renameID = nil } }
        ), presenting: renameID) { id in
            TextField("对话名称", text: $renameText)
            Button("取消", role: .cancel) { renameID = nil }
            Button("保存") {
                controller.rename(id, renameText)
                renameID = nil
            }
            .disabled(controller.isImporting || renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { _ in Text("名称仅保存于本机。") }
        .confirmationDialog("删除这段对话？", isPresented: Binding(
            get: { deletionID != nil }, set: { if !$0 { deletionID = nil } }
        ), titleVisibility: .visible, presenting: deletionID) { id in
            Button("删除对话", role: .destructive) {
                controller.delete(id)
                deletionID = nil
            }
            .disabled(!canDelete)
            Button("取消", role: .cancel) { deletionID = nil }
        } message: { _ in Text("本机记录与对应附件将被移除，无法撤销。") }
    }

    private var searchButton: some View {
        Button(action: onSearch) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .accessibilityHidden(true)
                Text("搜索对话内容…")
                    .lineLimit(1)
            }
            .font(.system(size: itemFontSize))
            .foregroundStyle(ChatTheme.muted)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: max(48, searchHeight), alignment: .leading)
            .background(ChatTheme.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(ChatTheme.line.opacity(0.65), lineWidth: 0.55).allowsHitTesting(false) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.search")
        .padding(.leading, 16)
        .padding(.trailing, 26)
        .padding(.top, 12)
    }

    private var timeline: some View {
        let groups = Dictionary(grouping: orderedSessions, by: bucket)
        let firstGroup = groupTitles.indices.first { groups[$0] != nil }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if groups.isEmpty {
                    Text("暂无历史对话")
                        .font(.system(size: itemFontSize))
                        .foregroundStyle(ChatTheme.muted)
                        .padding(.leading, 6)
                        .padding(.top, 20)
                }
                ForEach(groupTitles.indices, id: \.self) { group in
                    if let sessions = groups[group] {
                        dateHeader(groupTitles[group], showsManage: group == firstGroup)
                            .padding(.top, group == firstGroup ? 0 : 16)
                        ForEach(sessions) { session in row(session) }
                    }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 20)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func dateHeader(_ title: String, showsManage: Bool) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: headerFontSize))
                .foregroundStyle(ChatTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
                .accessibilityAddTraits(.isHeader)
            if showsManage {
                Button { managing.toggle() } label: {
                    icon(managing ? "checkmark.circle" : "list.bullet.indent")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(managing ? "完成管理" : "管理对话")
                .accessibilityIdentifier("sidebar.manage")
            }
        }
        .frame(minHeight: showsManage ? 44 : 28)
    }

    private var profileFooter: some View {
        let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(spacing: 10) {
            Image(systemName: "person.fill")
                .font(.system(size: profileSize / 2))
                .foregroundStyle(ChatTheme.muted)
                .frame(width: profileSize, height: profileSize)
                .background(ChatTheme.raised, in: Circle())
                .accessibilityHidden(true)
            Text(name.isEmpty ? "访客" : name)
                .font(.system(size: itemFontSize))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onSettings) { icon("ellipsis") }
                .buttonStyle(.plain)
                .accessibilityLabel("打开设置")
                .accessibilityIdentifier("sidebar.settings")
        }
        .padding(.leading, 16)
        .padding(.trailing, 20)
        .frame(minHeight: max(68, profileSize + 24))
    }

    private func icon(_ name: String, minHeight: CGFloat = 44) -> some View {
        Image(systemName: name)
            .font(.system(size: 16))
            .foregroundStyle(ChatTheme.muted)
            .frame(width: 44)
            .frame(minHeight: minHeight)
            .contentShape(Rectangle())
    }

    private func row(_ session: ChatSession) -> some View {
        let selected = controller.currentID == session.id
        let title = session.title.isEmpty ? "新对话" : session.title
        let height = max(44, rowHeight)

        return HStack(spacing: 0) {
            Button {
                controller.open(session.id)
                if !controller.isImporting, !controller.isGenerating, controller.currentID == session.id {
                    onClose()
                }
            } label: {
                HStack(spacing: 8) {
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: headerFontSize))
                            .foregroundStyle(ChatTheme.accent)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .lineLimit(1)
                }
                .font(.system(size: itemFontSize))
                .foregroundStyle(selected ? ChatTheme.accent : ChatTheme.text)
                .padding(.leading, 6)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.session.\(session.id)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu { sessionActions(session) }

            if selected || managing {
                Menu {
                    sessionActions(session)
                } label: {
                    icon("ellipsis", minHeight: height)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("管理 \(title)")
                .accessibilityIdentifier("sidebar.session.menu.\(session.id)")
            }
        }
        .background(selected ? selectedBackground : Color.clear, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func sessionActions(_ session: ChatSession) -> some View {
        Button("重命名", systemImage: "pencil") {
            renameText = session.title
            renameID = session.id
        }
        .disabled(controller.isImporting)
        Button(session.isPinned ? "取消置顶" : "置顶", systemImage: session.isPinned ? "pin.slash" : "pin") {
            controller.pin(session.id)
        }
        .disabled(controller.isImporting)
        Button("删除", systemImage: "trash", role: .destructive) {
            deletionID = session.id
        }
        .disabled(!canDelete)
    }
}
