import SwiftUI

struct BackendAdBanner: View {
    let config: BackendPublicConfig
    @Environment(\.openURL) private var openURL

    private var imageURL: URL? { BackendConfig.absoluteURL(config.adImageUrl) }
    private var destination: URL? {
        guard let url = URL(string: config.adLink), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    var body: some View {
        Button {
            if let destination { openURL(destination) }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "megaphone").foregroundStyle(ChatTheme.muted)
                    case .empty:
                        ProgressView()
                    @unknown default:
                        Image(systemName: "megaphone").foregroundStyle(ChatTheme.muted)
                    }
                }
                .frame(width: 58, height: 58)
                .background(ChatTheme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .clipped()

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("广告").font(.caption2).foregroundStyle(ChatTheme.muted)
                        if destination == nil { Text("· 未设置链接").font(.caption2).foregroundStyle(ChatTheme.muted) }
                    }
                    Text(config.adTitle.isEmpty ? "广告位" : config.adTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ChatTheme.text)
                        .lineLimit(2)
                    if destination != nil {
                        Text("了解详情").font(.caption).foregroundStyle(ChatTheme.accent)
                    }
                }
                Spacer(minLength: 0)
                if destination != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ChatTheme.muted)
                }
            }
            .padding(11)
            .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(ChatTheme.line.opacity(0.55), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(destination == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("广告：\(config.adTitle)")
        .accessibilityIdentifier("model.ad")
    }
}