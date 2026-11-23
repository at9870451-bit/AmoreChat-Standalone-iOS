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

    func importFile(_ source: URL, preferredName: String? = nil) throws -> ChatAttachment {
        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        let id = UUID()
        let displayName = (preferredName ?? source.lastPathComponent).isEmpty ? "附件" : (preferredName ?? source.lastPathComponent)
        let safeExtension = source.pathExtension.lowercased()
        let destination = mediaURL.appendingPathComponent(id.uuidString)
            .appendingPathExtension(safeExtension.isEmpty ? "bin" : safeExtension)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: destination)
        let type = UTType(filenameExtension: safeExtension)?.preferredMIMEType ?? "application/octet-stream"
        return ChatAttachment(id: id, name: displayName, localURL: destination, type: type)
    }

    func importImage(_ data: Data) throws -> ChatAttachment {
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        let id = UUID()
        let destination = mediaURL.appendingPathComponent(id.uuidString).appendingPathExtension("png")
        try data.write(to: destination, options: .atomic)
        return ChatAttachment(id: id, name: "图片.png", localURL: destination, type: "image/png")
    }

    /// Remove only archive-owned files, never an arbitrary file URL from a message.
    func removeMedia(_ attachment: ChatAttachment) {
        let own = mediaURL.standardizedFileURL.path + "/"
        guard attachment.localURL.standardizedFileURL.path.hasPrefix(own) else { return }
        try? FileManager.default.removeItem(at: attachment.localURL)
    }
}
