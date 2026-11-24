import SwiftUI

/// Draw the two mode symbols rather than relying on a variant of an SF Symbol
/// that may not exist in this version of iOS. Circle, hit area and baseline stay fixed.
struct ComposerGlyph: View {
    enum Kind { case voice, keyboard }
    let kind: Kind
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let scale = size.width / 25
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale)
            }
            let stroke = StrokeStyle(lineWidth: 1.65 * scale, lineCap: .round, lineJoin: .round)
            ctx.stroke(Path(ellipseIn: rect(1.12, 1.12, 22.76, 22.76)), with: .color(color), style: stroke)
            switch kind {
            case .voice:
                ctx.fill(Path(ellipseIn: rect(6.6, 11.35, 2.2, 2.2)), with: .color(color))
                let arcs: [(CGFloat, CGFloat, CGFloat)] = [(10.4, 9.6, 13.15), (13.25, 7.3, 18.2)]
                for arc in arcs {
                    var path = Path()
                    path.move(to: point(arc.0, arc.1))
                    path.addQuadCurve(to: point(arc.0, 25 - arc.1), control: point(arc.2, 12.5))
                    ctx.stroke(path, with: .color(color), style: stroke)
                }
            case .keyboard:
                for row in 0..<2 {
                    for col in 0..<3 {
                        let dot = rect(7.15 + CGFloat(col) * 4.15, 7.5 + CGFloat(row) * 3.55, 2.4, 2.15)
                        ctx.fill(Path(roundedRect: dot, cornerRadius: 0.35 * scale), with: .color(color))
                    }
                }
                ctx.fill(Path(roundedRect: rect(7.15, 15.3, 10.7, 1.7), cornerRadius: 0.4 * scale), with: .color(color))
            }
        }
        .frame(width: 25, height: 25)
        .accessibilityHidden(true)
    }
}
