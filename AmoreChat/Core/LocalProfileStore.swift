import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

/// An immutable, metadata-free thumbnail prepared off the main actor.
struct LocalAvatarDraft: @unchecked Sendable {
    fileprivate let jpegData: Data
    let image: UIImage
}

/// Device-only profile data. Never participates in chat archives or network requests.
@MainActor
@Observable
final class LocalProfileStore {
    private(set) var accountID: Int64?
    private(set) var avatarImage: UIImage?
    private(set) var needsAvatarSetup = false
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorText: String?

    @ObservationIgnored private let files = LocalProfileFiles()
    @ObservationIgnored private var selection = UUID()
    @ObservationIgnored private var hasLoaded = false

    /// Call for every authenticated-user change, including nil on logout.
    /// Clear the old cache before the first suspension so accounts never share a photo.
    func selectAccount(_ id: Int64?) async {
        if accountID == id, hasLoaded || isLoading { return }
        let request = UUID()
        selection = request
        accountID = id
        avatarImage = nil
        needsAvatarSetup = false
        isSaving = false
        isLoading = id != nil
        hasLoaded = id == nil
        errorText = nil
        guard let id else { return }

        do {
            let snapshot = try await files.load(accountID: id)
            guard selection == request else { return }
            avatarImage = snapshot.image
            needsAvatarSetup = !snapshot.setupCompleted
            hasLoaded = true
        } catch {
            guard selection == request else { return }
            // A locked/corrupt file must not cause a recurring, unavoidable setup gate.
            errorText = "无法读取本机头像。你可以稍后重试，或选择新头像重新保存。"
        }
        guard selection == request else { return }
        isLoading = false
    }

    /// Passing no draft persists Skip. Changes and the completion flag are one atomic write.
    /// Edits remain in the view until this succeeds; cancelling an editor changes nothing.
    @discardableResult
    func completeSetup(avatar: LocalAvatarDraft? = nil, removeAvatar: Bool = false) async -> Bool {
        guard let id = accountID, !isLoading, !isSaving else { return false }
        let request = selection
        isSaving = true
        errorText = nil
        defer { if selection == request { isSaving = false } }
        do {
            try await files.save(accountID: id, jpegData: avatar?.jpegData, removeAvatar: removeAvatar)
            guard selection == request else { return false }
            if removeAvatar {
                avatarImage = nil
            } else if let avatar {
                avatarImage = avatar.image
            }
            needsAvatarSetup = false
            hasLoaded = true
            return true
        } catch {
            guard selection == request else { return false }
            errorText = "无法保存本机头像设置，请检查设备可用空间后重试。"
            return false
        }
    }

    /// PhotosPicker returns only the selected asset; full image decoding stays off the UI actor.
    nonisolated static func prepareAvatar(from data: Data) async throws -> LocalAvatarDraft {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let image = try LocalAvatarCodec.decodeThumbnail(data)
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
            ) else { throw LocalProfileError.invalidImage }
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: 0.86
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw LocalProfileError.invalidImage }
            try Task.checkCancellation()
            // Do not copy source properties: EXIF, GPS and camera metadata are discarded.
            return LocalAvatarDraft(jpegData: output as Data, image: UIImage(cgImage: image))
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private enum LocalProfileError: Error {
    case invalidImage
}

private enum LocalAvatarCodec {
    /// ImageIO applies source orientation while decoding at most 768 px on the longest edge.
    static func decodeThumbnail(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 768,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw LocalProfileError.invalidImage }
        return image
    }
}

private struct LocalProfileSnapshot: @unchecked Sendable {
    let image: UIImage?
    let setupCompleted: Bool
}

/// All disk access and cached-image decoding run on this worker actor, not MainActor.
private actor LocalProfileFiles {
    private struct Record: Codable {
        var setupCompleted = false
        var avatarJPEG: Data?
    }

    func load(accountID: Int64) throws -> LocalProfileSnapshot {
        let record = try read(accountID: accountID)
        let image: UIImage?
        if let data = record.avatarJPEG {
            image = UIImage(cgImage: try LocalAvatarCodec.decodeThumbnail(data))
        } else {
            image = nil
        }
        return LocalProfileSnapshot(image: image, setupCompleted: record.setupCompleted)
    }

    func save(accountID: Int64, jpegData: Data?, removeAvatar: Bool) throws {
        // Explicit replacement/deletion also allows recovery from a corrupt previous record.
        var record: Record
        if jpegData != nil || removeAvatar {
            record = Record()
        } else {
            record = try read(accountID: accountID)
        }
        if removeAvatar {
            record.avatarJPEG = nil
        } else if let jpegData {
            record.avatarJPEG = jpegData
        }
        record.setupCompleted = true
        let url = try recordURL(accountID: accountID)
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: attributes)
        var protectedRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedRoot.setResourceValues(values)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true, attributes: attributes)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(record).write(to: url, options: [
            .atomic, .completeFileProtectionUntilFirstUserAuthentication
        ])
    }

    private func read(accountID: Int64) throws -> Record {
        let url = try recordURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else { return Record() }
        return try PropertyListDecoder().decode(Record.self, from: Data(contentsOf: url))
    }

    private func recordURL(accountID: Int64) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support.appendingPathComponent("LocalProfiles", isDirectory: true)
            .appendingPathComponent(String(accountID), isDirectory: true)
            .appendingPathComponent("profile.plist", isDirectory: false)
    }
}
