import Foundation

/// MainActor-owned pending deltas, never an observable copy of the whole transcript.
@MainActor
final class ReplyStreamBuffer {
    struct Delta {
        let content: String
        let reasoning: String?
        let reasoningDuration: TimeInterval?
    }

    let sessionID: UUID
    let replyID: UUID
    private(set) var answer = ""
    private(set) var lastPublication: TimeInterval?
    private var content = ""
    private var reasoning: String?
    private var reasoningDuration: TimeInterval?
    private var thinkingStart: TimeInterval?
    private var answering = false

    init(sessionID: UUID, replyID: UUID) {
        self.sessionID = sessionID
        self.replyID = replyID
    }

    var hasPending: Bool {
        !content.isEmpty || reasoning != nil || reasoningDuration != nil
    }

    func append(_ chunk: BackendChunk, now: TimeInterval) {
        switch chunk {
        case .text(let text):
            if !answering, let thinkingStart {
                reasoningDuration = max(0, now - thinkingStart)
            }
            answering = true
            content += text
            answer += text
        case .reasoning(let text):
            if thinkingStart == nil && !answering { thinkingStart = now }
            if reasoning == nil { reasoning = "" }
            reasoning?.append(text)
        }
    }

    func finishTiming(now: TimeInterval) {
        if !answering, let thinkingStart {
            reasoningDuration = max(0, now - thinkingStart)
        }
    }

    func takePending(now: TimeInterval) -> Delta {
        let delta = Delta(content: content, reasoning: reasoning,
                          reasoningDuration: reasoningDuration)
        content = ""
        reasoning = nil
        reasoningDuration = nil
        lastPublication = now
        return delta
    }
}
