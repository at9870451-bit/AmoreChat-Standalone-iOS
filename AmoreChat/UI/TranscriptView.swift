import SwiftUI
import UIKit

/// Transcript only: the composer and session drawer are separate native views.
@MainActor
struct TranscriptView: View {
    @Bindable var controller: ChatController
    let onReadAloud: (String) -> Void
    var onBackgroundTap: () -> Void = {}
    var forceBottomSignal: Int = 0
    var jump: HistoryJump? = nil
    @State private var nearBottom = true
    @State private var visibleLimit = 80
    @State private var scrollUpdate: Task<Void, Never>?
    private let bottomID = "transcript-bottom"
    private struct ScrollTarget: Equatable {
        let sessionID: UUID?
        let jump: HistoryJump?
    }
    private var visibleMessages: [ChatMessage] { Array(controller.messages.suffix(visibleLimit)) }

    private var revision: String {
        guard let last = controller.messages.last else { return "empty" }
        return "\(last.id)-\(last.content.utf8.count)-\(last.reasoning?.utf8.count ?? 0)-\(last.status.rawValue)"
    }

    var body: some View {
        GeometryReader { viewport in
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if controller.messages.isEmpty {
                        VStack(spacing: 22) {
                            WhaleMark(size: 34)
                            Text("你好，有什么我能帮你的吗？")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(ChatTheme.text)
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("home.welcome")
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: max(230, viewport.size.height - 45), alignment: .center)
                    }
                    if controller.messages.count > visibleLimit {
                        Button("加载更早的消息") { visibleLimit += 80 }
                            .font(.footnote).foregroundStyle(ChatTheme.accent)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    ForEach(visibleMessages) { message in
                        MessageRow(message: message,
                                   onReadAloud: onReadAloud,
                                   onDeleteFrom: { controller.deleteFromMessage(message.id) },
                                   onRegenerate: { controller.regenerate() },
                                   canRegenerate: controller.backendReady && !controller.isGenerating
                                       && controller.messages.last?.id == message.id && message.role == .assistant)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .frame(maxWidth: 780).frame(maxWidth: .infinity)
                .padding(.leading, 23).padding(.trailing, 20)
                .padding(.top, controller.messages.isEmpty ? 22 : 32).padding(.bottom, 22)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(onBackgroundTap))
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 90
            } action: { _, isAtBottom in nearBottom = isAtBottom }
            .overlay(alignment: .bottomTrailing) {
                if !nearBottom && !controller.messages.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { reader.scrollTo(bottomID, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down").font(.headline).padding(12)
                            .background(ChatTheme.surface, in: Circle())
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    }
                    .accessibilityLabel("跳转到最新消息")
                    .padding(18)
                }
            }
            .onChange(of: revision) { _, _ in
                // Do not force users back down while they read earlier turns. Stream updates
                // are coalesced and use no overlapping layout animations.
                guard nearBottom else { return }
                if controller.messages.last?.status != .streaming {
                    scrollUpdate?.cancel(); scrollUpdate = nil
                    reader.scrollTo(bottomID, anchor: .bottom)
                    return
                }
                guard scrollUpdate == nil else { return }
                scrollUpdate = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
                    guard !Task.isCancelled, nearBottom else { scrollUpdate = nil; return }
                    reader.scrollTo(bottomID, anchor: .bottom)
                    scrollUpdate = nil
                }
            }
            .onDisappear { scrollUpdate?.cancel(); scrollUpdate = nil }
            .onChange(of: controller.messages.last?.id) { _, _ in
                guard controller.isGenerating || controller.messages.last?.role == .user else { return }
                nearBottom = true
                scrollUpdate?.cancel(); scrollUpdate = nil
                reader.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: forceBottomSignal) { _, _ in
                reader.scrollTo(bottomID, anchor: .bottom)
                nearBottom = true
            }
            .task(id: ScrollTarget(sessionID: controller.currentID, jump: jump)) {
                if let jump, jump.sessionID == controller.currentID,
                   let index = controller.messages.firstIndex(where: { $0.id == jump.messageID }) {
                    visibleLimit = max(80, controller.messages.count - index)
                    nearBottom = false
                    // Give the lazy list one layout pass after extending its visible suffix.
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    reader.scrollTo(jump.messageID, anchor: .center)
                } else {
                    visibleLimit = 80
                    nearBottom = true
                    await Task.yield()
                    if !Task.isCancelled { reader.scrollTo(bottomID, anchor: .bottom) }
                }
            }
        }
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let onReadAloud: (String) -> Void
    let onDeleteFrom: () -> Void
    let onRegenerate: () -> Void
    let canRegenerate: Bool
    @State private var showDeleteConfirm = false
    @State private var reasoningOpen = false
    @ScaledMetric(relativeTo: .body) private var messageSize: CGFloat = 16.5
    @ScaledMetric(relativeTo: .subheadline) private var reasoningLabelSize: CGFloat = 15.5
    @AppStorage("standalone.reasoning.autoFold") private var autoFoldReasoning = true
    @AppStorage("standalone.chat.feedback.v1") private var feedbackBlob = "{}"
    private var isUser: Bool { message.role == .user }
    private var isThinking: Bool { message.status == .streaming && message.content.isEmpty }
    private var vote: Int { (decodeFeedback()[message.id.uuidString] ?? 0) }

    private var thinkingTitle: Text {
        if message.status == .failed && message.content.isEmpty { return Text("思考已中断") }
        if let duration = message.reasoningDuration, duration.isFinite, duration > 0 {
            return Text("已思考（用时 \(Int(min(86_400, max(1, duration.rounded())))) 秒）")
        }
        return Text("已思考")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 12) {
                if !isUser, let reasoning = message.reasoning, !reasoning.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Button { reasoningOpen.toggle() } label: {
                            HStack(spacing: 8) {
                                if message.thinkingRequested == true && !isThinking {
                                    DeepThinkingGlyph()
                                }
                                if isThinking {
                                    ThinkingDots()
                                } else {
                                    thinkingTitle
                                }
                                Image(systemName: reasoningOpen ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(ChatTheme.muted)
                            .font(.system(size: reasoningLabelSize, weight: .regular))
                            .frame(minHeight: 37, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("message.reasoning")
                        .accessibilityValue(reasoningOpen ? "已展开" : "已折叠")
                        if reasoningOpen {
                            HStack(alignment: .top, spacing: 11) {
                                RichTextView(source: reasoning, isReasoning: true)
                                    .equatable()
                                    .foregroundStyle(ChatTheme.muted)
                                    .padding(.leading, 14)
                                    .overlay(alignment: .leading) {
                                        ChatTheme.line.frame(width: 1)
                                    }
                            }
                            .accessibilityIdentifier("message.reasoning.content")
                            .padding(.bottom, 7)
                        }
                    }
                    .onAppear { reasoningOpen = isThinking || !autoFoldReasoning }
                    .onChange(of: isThinking) { wasThinking, active in
                        if active { reasoningOpen = true }
                        else if wasThinking && autoFoldReasoning { reasoningOpen = false }
                    }
                    .onChange(of: autoFoldReasoning) { _, fold in
                        if !isThinking { reasoningOpen = !fold }
                    }
                }
                if !message.content.isEmpty {
                    Group {
                        if isUser {
                            Text(message.content)
                                .font(.system(size: messageSize, weight: .regular))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 11)
                                .background(ChatTheme.raised, in: UnevenRoundedRectangle(
                                    topLeadingRadius: 23, bottomLeadingRadius: 23,
                                    bottomTrailingRadius: 5, topTrailingRadius: 23))
                                .frame(maxWidth: 300, alignment: .trailing)
                                .accessibilityIdentifier("message.user.bubble")
                        } else {
                            RichTextView(source: message.content)
                                .equatable()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .contextMenu {
                            Button("复制文本", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content }
                            ShareLink(item: message.content) { Label("分享文本", systemImage: "square.and.arrow.up") }
                            if canRegenerate { Button("重新生成", systemImage: "arrow.clockwise", action: onRegenerate) }
                            Button("从此处删除", systemImage: "trash", role: .destructive) {
                                showDeleteConfirm = true
                            }
                        }
                } else if message.status == .streaming && message.reasoning?.isEmpty != false {
                    ThinkingDots()
                        .frame(minHeight: 37, alignment: .leading)
                }
                ForEach(message.attachments) { item in
                    ShareLink(item: item.localURL) { AttachmentCard(attachment: item) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("分享附件：\(item.name)")
                        .accessibilityIdentifier("message.attachment")
                }
                if !isUser {
                    HStack(spacing: 19) {
                        if !message.content.isEmpty {
                            Button { UIPasteboard.general.string = message.content } label: {
                                Image(systemName: "doc.on.doc")
                            }.accessibilityLabel("复制消息")
                        }
                        if message.status == .complete && !message.content.isEmpty {
                            feedbackButton(1, "赞同", "hand.thumbsup")
                            feedbackButton(-1, "不赞同", "hand.thumbsdown")
                            Button { onReadAloud(message.content) } label: {
                                Image(systemName: "speaker.wave.2")
                            }.accessibilityLabel("朗读回复")
                            ShareLink(item: message.content) { Image(systemName: "arrowshape.turn.up.right") }
                                .accessibilityLabel("分享消息")
                        }
                        if message.status == .failed {
                            Label("未完成", systemImage: "exclamationmark.circle")
                                .foregroundStyle(ChatTheme.danger)
                        }
                        Spacer(minLength: 0)
                        if canRegenerate && message.status == .complete {
                            Button(action: onRegenerate) { Image(systemName: "arrow.clockwise") }
                                .accessibilityLabel("重新生成")
                        }
                    }
                    .font(.system(size: 17))
                    .foregroundStyle(ChatTheme.muted)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 590, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 12) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .confirmationDialog("删除这条及之后的消息？", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("删除后续消息", role: .destructive, action: onDeleteFrom)
            Button("取消", role: .cancel) {}
        } message: { Text("为了保持上下文一致，将从此处截断本机历史，无法撤销。") }
    }

    private func feedbackButton(_ value: Int, _ title: String, _ symbol: String) -> some View {
        Button { setFeedback(value) } label: {
            Image(systemName: vote == value ? "\(symbol).fill" : symbol)
                .foregroundStyle(vote == value ? ChatTheme.accent : ChatTheme.muted)
        }
        .accessibilityLabel(title)
        .accessibilityValue(vote == value ? "已选择" : "未选择")
        .accessibilityHint("仅保存在本机，不会发送给服务")
    }
    private func decodeFeedback() -> [String: Int] {
        guard let data = feedbackBlob.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }
    private func setFeedback(_ value: Int) {
        var data = decodeFeedback()
        let key = message.id.uuidString
        if data[key] == value { data.removeValue(forKey: key) } else { data[key] = value }
        if let encoded = try? JSONEncoder().encode(data), let text = String(data: encoded, encoding: .utf8) {
            feedbackBlob = text
        }
    }
}
