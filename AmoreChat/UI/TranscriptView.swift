import SwiftUI
import UIKit

/// Transcript only: the composer and session drawer are separate native views.
@MainActor
struct TranscriptView: View {
    @Bindable var controller: ChatController
    @State private var nearBottom = true
    private let bottomID = "transcript-bottom"

    private var revision: String {
        guard let last = controller.messages.last else { return "empty" }
        return "\(last.id)-\(last.content.count)-\(last.reasoning?.count ?? 0)-\(last.status.rawValue)"
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if controller.messages.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 29, weight: .medium))
                                .foregroundStyle(ChatTheme.accent)
                                .frame(width: 64, height: 64)
                                .background(ChatTheme.accentWash,
                                            in: RoundedRectangle(cornerRadius: 18))
                                .accessibilityHidden(true)
                            Text("你好，我能帮你做些什么？")
                                .font(.title2.weight(.semibold))
                            if !controller.backendReady {
                                Text("尚未接入后端，可以先保存草稿和本地会话。")
                                    .font(.footnote)
                                    .foregroundStyle(ChatTheme.muted)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 10)], spacing: 10) {
                                prompt("整理要点", symbol: "list.bullet", value: "请帮我整理以下内容的要点：")
                                prompt("解释概念", symbol: "lightbulb", value: "请解释以下概念，并举例说明：")
                                prompt("编写文案", symbol: "square.and.pencil", value: "请帮我起草文案，主题是：")
                                prompt("制定计划", symbol: "calendar", value: "请帮我制定一个计划：")
                            }
                            .padding(.top, 10)
                        }
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 85)
                        .accessibilityIdentifier("home.welcome")
                    }
                    ForEach(controller.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    if let error = controller.errorText, !error.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ChatTheme.danger)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(error).font(.subheadline).textSelection(.enabled)
                                if controller.backendReady && !controller.isGenerating {
                                    Button("重试上次回复") { controller.retry() }.font(.subheadline.weight(.semibold))
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12).background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .combine)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .frame(maxWidth: 780).frame(maxWidth: .infinity)
                .padding(.horizontal, 16).padding(.vertical, 22)
            }
            .background(ChatTheme.canvas)
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
                if nearBottom { reader.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: controller.currentID) { _, _ in
                nearBottom = true
                DispatchQueue.main.async { reader.scrollTo(bottomID, anchor: .bottom) }
            }
            .task { reader.scrollTo(bottomID, anchor: .bottom) }
        }
    }
    private func prompt(_ title: String, symbol: String, value: String) -> some View {
        Button {
            guard controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if controller.currentID == nil { controller.newChat() }
            controller.draft = value
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(ChatTheme.accent)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .padding(.horizontal, 12)
                .background(ChatTheme.accentWash, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityHint("仅填写草稿，不自动发送")
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    @State private var reasoningOpen = false
    @AppStorage("standalone.chat.feedback.v1") private var feedbackBlob = "{}"
    private var isUser: Bool { message.role == .user }
    private var vote: Int { (decodeFeedback()[message.id.uuidString] ?? 0) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 32) }
            if !isUser {
                Image(systemName: "sparkle").font(.subheadline.weight(.semibold))
                    .foregroundStyle(ChatTheme.accent).frame(width: 29, height: 29)
                    .background(ChatTheme.accentWash, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 9) {
                Text(isUser ? "你" : "AmoreChat")
                    .font(.caption.weight(.semibold)).foregroundStyle(ChatTheme.muted)
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup(isExpanded: $reasoningOpen) {
                        RichTextView(source: reasoning).font(.subheadline)
                            .padding(.top, 8).foregroundStyle(ChatTheme.muted)
                    } label: { Label("思考过程", systemImage: "brain.head.profile") }
                    .font(.caption).tint(ChatTheme.accent)
                    .padding(10).background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                if !message.content.isEmpty {
                    RichTextView(source: message.content)
                        .padding(isUser ? 13 : 0)
                        .background(isUser ? ChatTheme.accentWash : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            Button("复制文本", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content }
                            ShareLink(item: message.content) { Label("分享文本", systemImage: "square.and.arrow.up") }
                        }
                } else if message.status == .streaming {
                    ProgressView().controlSize(.small).accessibilityLabel("正在生成回复")
                }
                ForEach(message.attachments) { item in
                    if item.type.hasPrefix("image/"), let image = UIImage(contentsOfFile: item.localURL.path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 230)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("图片附件：\(item.name)")
                    }
                    ShareLink(item: item.localURL) {
                        Label(item.name, systemImage: item.type.hasPrefix("image/") ? "photo" : "doc")
                            .font(.footnote).lineLimit(1).padding(8)
                            .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel("分享附件：\(item.name)")
                }
                HStack(spacing: 16) {
                    Text(message.createdAt, style: .time)
                    if !message.content.isEmpty {
                        Button { UIPasteboard.general.string = message.content } label: {
                            Image(systemName: "doc.on.doc")
                        }.accessibilityLabel("复制消息")
                        ShareLink(item: message.content) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("分享消息")
                    }
                    if !isUser && message.status == .complete && !message.content.isEmpty {
                        feedbackButton(1, "赞同", "hand.thumbsup")
                        feedbackButton(-1, "不赞同", "hand.thumbsdown")
                    }
                    if message.status == .failed {
                        Label("未完成", systemImage: "exclamationmark.circle").foregroundStyle(ChatTheme.danger)
                    }
                }
                .font(.caption).foregroundStyle(ChatTheme.muted)
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 590, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 12) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
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
