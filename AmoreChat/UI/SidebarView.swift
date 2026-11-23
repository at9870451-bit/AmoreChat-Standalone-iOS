import SwiftUI

@MainActor
struct SidebarView: View {
    @Bindable var controller: ChatController
    let onClose: () -> Void
    let onNewChat: () -> Void
    let onSettings: () -> Void

    @State private var searchText = ""
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var showingRename = false
    @State private var deleteID: UUID?
    @State private var showingDelete = false

    private var matchingSessions: [ChatSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty
            ? controller.sessions
            : controller.sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return matches.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private var today: [ChatSession] {
        matchingSessions.filter { Calendar.current.isDateInToday($0.updatedAt) }
    }

    private var recent: [ChatSession] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        return matchingSessions.filter {
            !Calendar.current.isDateInToday($0.updatedAt) && $0.updatedAt >= cutoff
        }
    }

    private var earlier: [ChatSession] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        return matchingSessions.filter {
            !Calendar.current.isDateInToday($0.updatedAt) && $0.updatedAt < cutoff
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.title2.bold())
                    .foregroundStyle(ChatTheme.text)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Close sidebar")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Button {
                onNewChat()
                onClose()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(ChatTheme.accentWash, in: RoundedRectangle(cornerRadius: ChatTheme.radius))
            }
            .foregroundStyle(ChatTheme.accent)
            .accessibilityHint("Starts a new conversation")
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ChatTheme.muted)
                TextField("Search chats", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Search chats")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if matchingSessions.isEmpty {
                        Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "No chats yet. Start a new conversation."
                             : "No chats match your search.")
                            .font(.subheadline)
                            .foregroundStyle(ChatTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 32)
                    } else {
                        sessionGroup("Today", sessions: today)
                        sessionGroup("Past 7 days", sessions: recent)
                        sessionGroup("Earlier", sessions: earlier)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }

            Divider()
            Button(action: onSettings) {
                Label("Settings", systemImage: "gearshape")
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            .foregroundStyle(ChatTheme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(ChatTheme.canvas)
        .alert("Rename chat", isPresented: $showingRename) {
            TextField("Chat name", text: $renameText)
            Button("Cancel", role: .cancel) { renameID = nil }
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = renameID, !name.isEmpty { controller.rename(id, name) }
                renameID = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a name for this conversation.")
        }
        .confirmationDialog("Delete chat?", isPresented: $showingDelete, titleVisibility: .visible) {
            Button("Delete chat", role: .destructive) {
                if let id = deleteID { controller.delete(id) }
                deleteID = nil
            }
            Button("Cancel", role: .cancel) { deleteID = nil }
        } message: {
            Text("This conversation will be removed.")
        }
    }

    @ViewBuilder
    private func sessionGroup(_ title: String, sessions: [ChatSession]) -> some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ChatTheme.muted)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(sessions) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        let selected = controller.currentID == session.id
        return Button {
            controller.open(session.id)
            onClose()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left")
                    .foregroundStyle(selected ? ChatTheme.accent : ChatTheme.muted)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title.isEmpty ? "Untitled chat" : session.title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(ChatTheme.text)
                        .lineLimit(1)
                    Text(session.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(ChatTheme.muted)
                }
                Spacer(minLength: 4)
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(ChatTheme.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? ChatTheme.accentWash : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.title.isEmpty ? "Untitled chat" : session.title)\(session.isPinned ? ", pinned" : "")")
        .accessibilityValue(selected ? "Current chat" : "")
        .accessibilityHint("Open chat; additional actions are available")
        .accessibilityAction(named: Text("Rename chat")) { beginRename(session) }
        .accessibilityAction(named: Text(session.isPinned ? "Unpin chat" : "Pin chat")) {
            controller.pin(session.id)
        }
        .accessibilityAction(named: Text("Delete chat")) { beginDelete(session) }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { beginRename(session) }
            Button(session.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
                controller.pin(session.id)
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                beginDelete(session)
            }
        }
    }

    private func beginRename(_ session: ChatSession) {
        renameID = session.id
        renameText = session.title
        showingRename = true
    }

    private func beginDelete(_ session: ChatSession) {
        deleteID = session.id
        showingDelete = true
    }
}
