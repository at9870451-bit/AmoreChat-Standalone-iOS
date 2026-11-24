import Foundation

/// User-managed drop folder exposed in Files under On My iPhone / AmoreChat.
/// ChatArchive and credential storage are deliberately outside Documents.
enum ImportFolder {
    static let name = "Imports"

    static func directory(in documents: URL? = nil) throws -> URL {
        let root = try documents ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                             appropriateFor: nil, create: true)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return folder
    }

    static func files(zipOnly: Bool, in documents: URL? = nil) throws -> [URL] {
        let folder = try directory(in: documents)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let candidates = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                     options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        return candidates.filter { url in
            guard !zipOnly || url.pathExtension.lowercased() == "zip",
                  let values = try? url.resourceValues(forKeys: keys) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
