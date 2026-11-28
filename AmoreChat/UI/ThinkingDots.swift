import SwiftUI

/// Native, local animation: no timers that mutate the transcript or pretend to be model output.
struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let interval: TimeInterval = 0.19

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: reduceMotion || scenePhase != .active)) { tick in
            let phase = Int(tick.date.timeIntervalSinceReferenceDate / interval) % 6
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(ChatTheme.muted)
                        .frame(width: 5, height: 5)
                        .opacity(reduceMotion || scenePhase != .active || phase == index || phase == index + 1 ? 1 : 0.35)
                }
            }
            .frame(minWidth: 27, minHeight: 20, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在思考")
        .accessibilityIdentifier("message.thinking.dots")
    }
}

/// Shares the same SF Symbol as the composer’s “深度思考” chip.
struct DeepThinkingGlyph: View {
    var body: some View {
        Image(systemName: "atom")
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(ChatTheme.thinkingBlue)
            .accessibilityHidden(true)
    }
}
