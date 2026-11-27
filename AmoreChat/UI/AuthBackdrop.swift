import SwiftUI

/// Decorations are not a screenshot: they resize with the device and stay behind real form controls.
struct AuthBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack {
                Color(red: 0.025, green: 0.035, blue: 0.047)
                Ellipse()
                    .fill(Color(red: 0.04, green: 0.09, blue: 0.16).opacity(0.4))
                    .frame(width: width * 0.9, height: proxy.size.height * 0.58)
                    .blur(radius: 65)
                    .position(x: width * 0.52, y: proxy.size.height * 0.47)
                orb(size: width * 0.74)
                    .position(x: -width * 0.12, y: -width * 0.02)
                orb(size: width * 0.48)
                    .position(x: width * 1.08, y: proxy.size.height * 0.31)
                orb(size: width * 0.62)
                    .position(x: -width * 0.12, y: proxy.size.height + width * 0.02)
                orb(size: width * 0.96)
                    .position(x: width * 1.14, y: proxy.size.height + width * 0.10)
            }
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func orb(size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 0.08, green: 0.15, blue: 0.29),
                                          Color(red: 0.035, green: 0.07, blue: 0.15),
                                          Color(red: 0.02, green: 0.03, blue: 0.05)],
                                 center: .topLeading, startRadius: 0, endRadius: size * 0.95))
            .overlay {
                Circle().strokeBorder(LinearGradient(colors: [.blue.opacity(0.65), .white.opacity(0.14), .clear],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
            .shadow(color: .blue.opacity(0.14), radius: 13, x: -3, y: -3)
            .frame(width: size, height: size)
    }
}
