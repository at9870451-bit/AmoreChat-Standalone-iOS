import XCTest
@testable import AmoreChatStandalone

final class LocalDocumentImportTests: XCTestCase {
    func testRegularTextCopiesAcrossChunksAtExactLimitWithoutMovingSource() throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("原始 文档.txt")
        let destination = root.appendingPathComponent("copied.txt")
        let bytes = Data(String(repeating: "合成文本\n", count: 10_000).utf8)
        try bytes.write(to: source)

        XCTAssertEqual(try LocalDocumentImport.copy(source, to: destination, maxBytes: bytes.count), bytes.count)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try names(in: root), ["原始 文档.txt", "copied.txt"])
    }

    func testOversizeFolderAndSymlinkAreRejectedWithoutAnyDestinationWrites() throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("large.txt")
        let folder = root.appendingPathComponent("folder.txt", isDirectory: true)
        let link = root.appendingPathComponent("link.txt")
        let destination = root.appendingPathComponent("copied.txt")
        let bytes = Data("synthetic".utf8)
        try bytes.write(to: source)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let originalNames = try names(in: root)

        XCTAssertThrowsError(try LocalDocumentImport.copy(source, to: destination, maxBytes: bytes.count - 1)) {
            XCTAssertTrue($0.localizedDescription.contains("大小上限"))
        }
        XCTAssertEqual(try names(in: root), originalNames)
        XCTAssertThrowsError(try LocalDocumentImport.copy(folder, to: destination, maxBytes: 1_024))
        XCTAssertEqual(try names(in: root), originalNames)
        XCTAssertThrowsError(try LocalDocumentImport.copy(link, to: destination, maxBytes: 1_024))
        XCTAssertEqual(try names(in: root), originalNames)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testPublishFailureKeepsExistingDestinationAndRemovesPartial() throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("previous.txt")
        let sourceBytes = Data("new".utf8), oldBytes = Data("existing".utf8)
        try sourceBytes.write(to: source)
        try oldBytes.write(to: destination)

        XCTAssertThrowsError(try LocalDocumentImport.copy(source, to: destination, maxBytes: 1_024))
        XCTAssertEqual(try Data(contentsOf: destination), oldBytes)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try names(in: root), ["source.txt", "previous.txt"])
    }

    func testArchiveKeepsRealNameMIMEAndByteCountAndRemovesOnlyItsCopy() async throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("我的 笔记.TXT")
        let bytes = Data("合成测试文字".utf8)
        try bytes.write(to: source)
        let archive = ChatArchive(root: root.appendingPathComponent("archive", isDirectory: true))

        let attachment = try await archive.importFile(source)
        XCTAssertEqual(attachment.name, source.lastPathComponent)
        XCTAssertEqual(attachment.type, "text/plain")
        XCTAssertEqual(attachment.byteCount, bytes.count)
        XCTAssertNotEqual(attachment.localURL, source)
        XCTAssertEqual(try Data(contentsOf: attachment.localURL), bytes)
        XCTAssertEqual(try names(in: attachment.localURL.deletingLastPathComponent()), [attachment.localURL.lastPathComponent])

        await archive.removeMedia(attachment)
        XCTAssertTrue(try names(in: attachment.localURL.deletingLastPathComponent()).isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testArchiveOversizeDoesNotLeaveAnAttachment() async throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("oversize.txt")
        let archiveRoot = root.appendingPathComponent("archive", isDirectory: true)
        let archive = ChatArchive(root: archiveRoot)
        let limit = 8 * 1_024 * 1_024
        try Data(repeating: 0x61, count: limit + 1).write(to: source)
        do {
            _ = try await archive.importFile(source)
            XCTFail("Expected an 8 MiB attachment limit")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("8 MiB"))
        }
        XCTAssertTrue(try names(in: archiveRoot.appendingPathComponent("Attachments")).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testImageArchiveStillKeepsOriginalBytesAndAddsByteCount() async throws {
        let root = try sandbox()
        let archive = ChatArchive(root: root)
        // Generated one-pixel PNG, not from a photo library or screen capture.
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a4Z0AAAAASUVORK5CYII="))
        let attachment = try await archive.importImage(png)
        XCTAssertEqual(attachment.name, "图片.png")
        XCTAssertEqual(attachment.type, "image/png")
        XCTAssertEqual(attachment.byteCount, png.count)
        XCTAssertEqual(try Data(contentsOf: attachment.localURL), png)
    }

    func testDeepSeekStagingIsRemovedAfterSuccessAndParseFailure() throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("synthetic-export.zip")
        let temp = FileManager.default.temporaryDirectory
        let stagingNames = { try self.names(in: temp).filter { $0.hasPrefix("AmoreChat-DeepSeek-") } }
        let before = try Set(stagingNames())
        // ZIP32 STORE with synthetic manifest.json (v3) and an empty chat_session_index.json.
        let fixture = "UEsDBBQAAAAAAAAAIQAfyGIjGwAAABsAAAANAAAAbWFuaWZlc3QuanNvbnsiZXhwb3J0X2Zvcm1hdF92ZXJzaW9uIjozfVBLAwQUAAAAAAAAACEAKbtMDQIAAAACAAAAFwAAAGNoYXRfc2Vzc2lvbl9pbmRleC5qc29uW11QSwECFAMUAAAAAAAAACEAH8hiIxsAAAAbAAAADQAAAAAAAAAAAAAAgAEAAAAAbWFuaWZlc3QuanNvblBLAQIUAxQAAAAAAAAAIQApu0wNAgAAAAIAAAAXAAAAAAAAAAAAAACAAUYAAABjaGF0X3Nlc3Npb25faW5kZXguanNvblBLBQYAAAAAAgACAIAAAAB9AAAAAAA="
        let zip = try XCTUnwrap(Data(base64Encoded: fixture))
        try zip.write(to: source)
        let result = try LocalDocumentImport.loadDeepSeek(source)
        XCTAssertEqual(result.sourceSessionCount, 0)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), zip)
        XCTAssertEqual(try Set(stagingNames()), before)

        let invalid = Data("not a zip".utf8)
        try invalid.write(to: source)
        XCTAssertThrowsError(try LocalDocumentImport.loadDeepSeek(source)) { error in
            guard case DeepSeekImportError.invalidZIP = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: source), invalid)
        XCTAssertEqual(try Set(stagingNames()), before)
    }

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDocumentImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func names(in directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }
}
