import Foundation
import UniformTypeIdentifiers

actor ChatArchive {
    private let directory: URL
    private let archiveURL: URL
    private let mediaURL: URL

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AmoreChatStandalone", isDirectory: true)
        directory = base
        archiveURL = base.appendingPathComponent("sessions.json")
        mediaURL = base.appendingPathComponent("Attachments", isDirectory: true)
    }

    func load() throws -> [ChatSession] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: archiveURL.path) else { return [] }
        let data = try Data(contentsOf: archiveURL)
        return try JSONDecoder().decode([ChatSession].self, from: data)
    }

    func save(_ sessions: [ChatSession]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(sessions).write(to: archiveURL, options: .atomic)
    }

    func importFile(_ source: URL, preferredName: String? = nil,
                    maxBytes: Int = 8 * 1_024 * 1_024) throws -> ChatAttachment {
        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        let id = UUID()
        let sourceName = source.lastPathComponent
        let displayName = preferredName.flatMap { $0.isEmpty ? nil : $0 }
            ?? (sourceName.isEmpty ? "附件" : sourceName)
        let safeExtension = source.pathExtension.lowercased()
        let destination = mediaURL.appendingPathComponent(id.uuidString)
            .appendingPathExtension(safeExtension.isEmpty ? "bin" : safeExtension)
        let byteCount = try LocalDocumentImport.copy(source, to: destination, maxBytes: 8 * 1_024 * 1_024)
        let type = UTType(filenameExtension: safeExtension)?.preferredMIMEType ?? "application/octet-stream"
        return ChatAttachment(id: id, name: displayName, localURL: destination, type: type, byteCount: byteCount)
    }

    func importImage(_ data: Data) throws -> ChatAttachment {
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        let id = UUID()
        let bytes = [UInt8](data.prefix(16))
        let type: (ext: String, mime: String)
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { type = ("png", "image/png") }
        else if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { type = ("jpg", "image/jpeg") }
        else if bytes.starts(with: [0x47, 0x49, 0x46]) { type = ("gif", "image/gif") }
        else if bytes.count >= 12 && Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46]
                && Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { type = ("webp", "image/webp") }
        else if bytes.count >= 12 && Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] { type = ("heic", "image/heic") }
        else { throw CocoaError(.fileReadCorruptFile) }
        let destination = mediaURL.appendingPathComponent(id.uuidString).appendingPathExtension(type.ext)
        try data.write(to: destination, options: .atomic)
        return ChatAttachment(id: id, name: "图片.\(type.ext)", localURL: destination, type: type.mime, byteCount: data.count)
    }

    /// Remove only archive-owned files, never an arbitrary file URL from a message.
    func removeMedia(_ attachment: ChatAttachment) {
        let own = mediaURL.standardizedFileURL.path + "/"
        guard attachment.localURL.standardizedFileURL.path.hasPrefix(own) else { return }
        try? FileManager.default.removeItem(at: attachment.localURL)
    }
}
