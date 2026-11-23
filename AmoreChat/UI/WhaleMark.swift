import SwiftUI

/// An original vector mark, rendered locally; no copied third-party artwork.
struct WhaleMark: View {
    var size: CGFloat = 36
    var body: some View {
        Canvas { context, canvas in
            let x = canvas.width / 100, y = canvas.height / 80
            func p(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: a*x, y: b*y) }
            var body = Path()
            body.move(to: p(14, 38))
            body.addCurve(to: p(68, 26), control1: p(26, 7), control2: p(59, 16))
            body.addCurve(to: p(87, 15), control1: p(75, 22), control2: p(80, 12))
            body.addQuadCurve(to: p(89, 34), control: p(82, 27))
            body.addCurve(to: p(72, 62), control1: p(97, 50), control2: p(92, 62))
            body.addCurve(to: p(16, 63), control1: p(48, 75), control2: p(23, 68))
            body.addQuadCurve(to: p(14, 38), control: p(5, 55))
            body.closeSubpath()
            context.fill(body, with: .color(ChatTheme.accent))
            var tail = Path()
            tail.move(to: p(84, 28))
            tail.addQuadCurve(to: p(94, 5), control: p(83, 10))
            tail.addQuadCurve(to: p(98, 19), control: p(100, 12))
            tail.addQuadCurve(to: p(86, 39), control: p(98, 37))
            tail.closeSubpath()
            context.fill(tail, with: .color(ChatTheme.accent))
            var mouth = Path()
            mouth.move(to: p(16, 43))
            mouth.addQuadCurve(to: p(48, 64), control: p(21, 63))
            mouth.addQuadCurve(to: p(24, 34), control: p(22, 59))
            mouth.closeSubpath()
            context.fill(mouth, with: .color(ChatTheme.canvas))
            let eye = CGRect(x: 53*x, y: 38*y, width: 5*x, height: 5*y)
            context.fill(Path(ellipseIn: eye), with: .color(ChatTheme.canvas))
            var spout = Path()
            spout.move(to: p(59, 22))
            spout.addQuadCurve(to: p(62, 5), control: p(50, 11))
            spout.addQuadCurve(to: p(66, 18), control: p(70, 9))
            spout.closeSubpath()
            context.fill(spout, with: .color(ChatTheme.accent))
        }
        .frame(width: size * 1.3, height: size)
        .accessibilityHidden(true)
    }
}
