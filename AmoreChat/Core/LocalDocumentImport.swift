import Foundation
import Darwin

enum LocalDocumentImport {
    private enum Failure: LocalizedError {
        case notRegularFile, tooLarge(Int), cannotRead, cannotWrite

        var errorDescription: String? {
            switch self {
            case .notRegularFile:
                return "请选择普通文件，不支持文件夹或符号链接。"
            case .tooLarge(let bytes):
                let mib = 1_024 * 1_024
                let limit = bytes > 0 && bytes % mib == 0 ? "\(bytes / mib) MiB" : "\(bytes) 字节"
                return "文件超过大小上限（\(limit)）。"
            case .cannotRead:
                return "无法读取所选文件。请确认它已下载到设备，再从「文件」重新选择。"
            case .cannotWrite:
                return "无法将文件保存到本机。请检查可用存储空间后重试。"
            }
        }
    }

    private static let chunkSize = 64 * 1_024

    /// The destination's parent must already exist. Publish only a complete, size-checked copy.
    @discardableResult
    static func copy(_ source: URL, to destination: URL, maxBytes: Int) throws -> Int {
        guard source.isFileURL, maxBytes >= 0 else { throw Failure.cannotRead }
        guard destination.isFileURL else { throw Failure.cannotWrite }
        try Task.checkCancellation()

        // A picker-created local copy may not be security scoped; false is not a read failure.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        // Reject a visible symlink or folder before the coordinator can substitute a URL.
        // Metadata can be unavailable before File Provider materialization, so a failed
        // lookup here is not fatal. Recheck the actual opened file inside coordination.
        if source.withUnsafeFileSystemRepresentation({ path in
            guard let path else { return false }
            var info = stat()
            return lstat(path, &info) == 0 && (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFREG)
        }) {
            throw Failure.notRegularFile
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var result: Result<Int, Error>?
        coordinator.coordinate(readingItemAt: source, options: [], error: nil) { readableURL in
            result = Result { try copyReadableFile(readableURL, to: destination, maxBytes: maxBytes) }
        }
        // Foundation skips the accessor if coordination fails.
        guard let result else { throw Failure.cannotRead }
        return try result.get()
    }

    /// Synchronous staging and parsing; call off the main actor.
    static func loadDeepSeek(_ source: URL) throws -> DeepSeekImportResult {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("AmoreChat-DeepSeek-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.cannotWrite
        }
        defer { try? manager.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("history.zip")
        try copy(source, to: archive, maxBytes: DeepSeekImportZIP.maxArchive)
        try Task.checkCancellation()
        return try DeepSeekImport.parse(archive)
    }

    private static func copyReadableFile(_ source: URL, to destination: URL, maxBytes: Int) throws -> Int {
        try Task.checkCancellation()
        let input = try openSource(source)
        defer { try? input.close() }
        var info = stat()
        guard fstat(input.fileDescriptor, &info) == 0 else { throw Failure.cannotRead }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw Failure.notRegularFile }
        guard info.st_size <= maxBytes else { throw Failure.tooLarge(maxBytes) }

        // Stage beside the final URL, so a failed read or size check never touches it.
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".document-import-\(UUID().uuidString).partial")
        let descriptor = partial.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw Failure.cannotWrite }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: partial) }

        let count: Int
        do {
            count = try transfer(from: input, to: output, maxBytes: maxBytes)
        } catch {
            try? output.close()
            throw error
        }
        do {
            try output.close()
        } catch {
            throw Failure.cannotWrite
        }
        try Task.checkCancellation()
        do {
            // FileManager.moveItem does not replace an existing destination.
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            throw Failure.cannotWrite
        }
        return count
    }

    private static func openSource(_ url: URL) throws -> FileHandle {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw Failure.cannotRead }
            // Don't follow a symlink substituted before open, or block opening a FIFO.
            let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if descriptor < 0 {
                if errno == ELOOP { throw Failure.notRegularFile }
                throw Failure.cannotRead
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
    }

    private static func transfer(from input: FileHandle, to output: FileHandle, maxBytes: Int) throws -> Int {
        var count = 0
        while true {
            try Task.checkCancellation()
            let remaining = maxBytes - count
            let bytes: Data?
            do {
                // Read one byte beyond the remaining budget to distinguish exact fit from growth.
                bytes = try input.read(upToCount: min(chunkSize - 1, remaining) + 1)
            } catch {
                throw Failure.cannotRead
            }
            guard let bytes, !bytes.isEmpty else { return count }
            guard bytes.count <= remaining else { throw Failure.tooLarge(maxBytes) }
            do {
                try output.write(contentsOf: bytes)
            } catch {
                throw Failure.cannotWrite
            }
            count += bytes.count
        }
    }
}
