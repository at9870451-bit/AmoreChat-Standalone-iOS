import SwiftUI
import UIKit

@MainActor
struct LocalAvatarView: View {
    @Environment(LocalProfileStore.self) private var profile
    let size: CGFloat
    var previewImage: UIImage? = nil
    var hidesStoredAvatar = false

    private var image: UIImage? {
        if let previewImage { return previewImage }
        return hidesStoredAvatar ? nil : profile.avatarImage
    }

    var body: some View {
        ZStack {
            Circle().fill(ChatTheme.raised)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(ChatTheme.muted)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(image == nil ? "默认头像" : "本机头像")
    }
}
