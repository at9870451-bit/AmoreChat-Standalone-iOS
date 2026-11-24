import SwiftUI

struct HistoryJump: Equatable {
    let requestID = UUID()
    let sessionID: UUID
    let messageID: UUID
}

@MainActor struct HistorySearchView: View {
    let sessions: [ChatSession]
    let onClose: () -> Void
    let onSelect: (UUID, UUID?) -> Void
    @State private var query = ""
    @State private var matches: [Hit] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    private struct Hit: Identifiable, Sendable {
        let id: UUID
        let title: String
        let date: Date
        let messageID: UUID?
        let excerpt: String?
    }

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    focused = false
                    onClose()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")
                .accessibilityIdentifier("history.search.back")
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ChatTheme.muted)
                    TextField("搜索对话内容…", text: $query)
                        .focused($focused)
                        .submitLabel(.search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { focused = false }
                        .accessibilityIdentifier("history.search.query")
                    if !query.isEmpty {
                        Button {
                            query = ""
                            focused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(ChatTheme.muted)
                                .frame(width: 36, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(ChatTheme.surface, in: Capsule())
                .overlay { Capsule().strokeBorder(ChatTheme.line, lineWidth: 0.5).allowsHitTesting(false) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !term.isEmpty && matches.isEmpty && !searching {
                        Text("没有匹配的对话")
                            .foregroundStyle(ChatTheme.muted)
                            .padding(.top, 36)
                            .frame(maxWidth: .infinity)
                    }
                    if !term.isEmpty {
                        ForEach(matches) { hit in
                            Button {
                                focused = false
                                onSelect(hit.id, hit.messageID)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(hit.title).font(.body.weight(.medium)).lineLimit(1)
                                    if let excerpt = hit.excerpt {
                                        Text(excerpt).font(.subheadline).foregroundStyle(ChatTheme.muted).lineLimit(2)
                                    }
                                    Text(hit.date, style: .date).font(.caption).foregroundStyle(ChatTheme.muted)
                                }
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("history.search.result")
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .foregroundStyle(ChatTheme.text)
        .background(ChatTheme.canvas.ignoresSafeArea())
        .task { focused = true }
        .task(id: term) { await search(term) }
        .accessibilityAction(.escape) { onClose() }
    }

    private func search(_ value: String) async {
        matches = []
        guard !value.isEmpty else { searching = false; return }
        searching = true
        do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
        let snapshot = sessions
        let worker = Task.detached(priority: .userInitiated) {
            Self.lookup(value, sessions: snapshot)
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, term == value else { return }
        matches = result
        searching = false
    }

    nonisolated private static func lookup(_ term: String, sessions: [ChatSession]) -> [Hit] {
        var hits: [Hit] = []
        for session in sessions.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if Task.isCancelled { return [] }
            let message = session.messages.reversed().first(where: { $0.content.localizedStandardContains(term) })
            guard message != nil || session.title.localizedStandardContains(term) else { continue }
            var excerpt: String?
            if let message, let range = message.content.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                let before = String(message.content[..<range.lowerBound].suffix(24))
                let after = String(message.content[range.lowerBound...].prefix(110))
                excerpt = (before + after).replacingOccurrences(of: "\n", with: " ")
            }
            hits.append(Hit(id: session.id, title: session.title, date: session.updatedAt,
                            messageID: message?.id, excerpt: excerpt))
            if hits.count == 200 { break }
        }
        return hits
    }
}
