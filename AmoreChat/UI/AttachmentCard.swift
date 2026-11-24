import SwiftUI
import ImageIO

/// Displays only files already copied into the chat archive, never a photo-library scan.
struct AttachmentCard: View {
    let attachment: ChatAttachment
    var compact = false
    var onRemove: (() -> Void)? = nil
    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 14

    init(attachment: ChatAttachment, compact: Bool = false, onRemove: (() -> Void)? = nil) {
        self.attachment = attachment
        self.compact = compact
        self.onRemove = onRemove
    }

    private var isImage: Bool { attachment.type.hasPrefix("image/") }
    private var subtitle: String {
        let suffix = URL(fileURLWithPath: attachment.name).pathExtension.uppercased()
        let kind = suffix.isEmpty ? "文件" : suffix
        guard let size = attachment.byteCount, size >= 0 else { return kind }
        if size < 1024 { return "\(kind) \(size) B" }
        let mb = size >= 1024 * 1024
        let units = Double(size) / (mb ? 1_048_576 : 1_024)
        return "\(kind) \(units.formatted(.number.precision(.fractionLength(0...2)))) \(mb ? "MB" : "KB")"
    }

    var body: some View {
        Group {
            if isImage {
                AttachmentThumbnail(url: attachment.localURL, compact: compact)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 25, weight: .regular))
                        .foregroundStyle(ChatTheme.accent)
                        .frame(width: 54, height: 54)
                        .background(ChatTheme.raised, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(attachment.name)
                            .font(.system(size: titleSize, weight: .regular))
                            .foregroundStyle(ChatTheme.text)
                            .lineLimit(1).truncationMode(.middle)
                        Text(subtitle)
                            .font(.caption).foregroundStyle(ChatTheme.muted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 11)
                .padding(.trailing, onRemove == nil ? 12 : 27)
                .padding(.vertical, 10)
                .frame(width: 219, alignment: .leading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(ChatTheme.line, lineWidth: 0.8).allowsHitTesting(false) }
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(ChatTheme.text)
                        .frame(width: 22, height: 22)
                        .background(ChatTheme.raised, in: Circle())
                        .frame(width: 44, height: 44, alignment: .topTrailing)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除附件 \(attachment.name)")
                .accessibilityIdentifier("composer.attachment.remove")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AttachmentThumbnail: View {
    let url: URL
    let compact: Bool
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: compact ? .fill : .fit)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(ChatTheme.muted)
                    .frame(width: compact ? 80 : 112, height: compact ? 80 : 130)
                    .background(ChatTheme.raised)
            }
        }
        .frame(maxWidth: compact ? 80 : 220, maxHeight: compact ? 80 : 238)
        .clipped()
        .task(id: url) {
            let copy = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return Optional<CGImage>.none }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: 720]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
            if !Task.isCancelled { image = copy }
        }
    }
}
