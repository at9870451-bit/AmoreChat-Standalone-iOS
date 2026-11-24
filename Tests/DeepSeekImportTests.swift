import XCTest
@testable import AmoreChatStandalone

/// SYNTHETIC fixture, shaped after deepseek-ai/chat-demo v3 format.ts/schema.ts.
/// This is NOT a real user's official export, and does not assert DeepSeek server compatibility.
final class DeepSeekImportTests: XCTestCase {
    private let stamp = "2026-01-05T09:00:00.000Z"

    private func example() -> (String, String, String) {
        let manifest = #"{"export_format_version":3}"#
        let index = #"[{"id":"synthetic-1","title":"测试会话","pinned":false,"message_count":4,"inserted_at":"2026-01-05T09:00:00.000Z","updated_at":"2026-01-05T09:00:00.000Z"}]"#
        let session = #"{"id":"synthetic-1","title":"测试会话","pinned":false,"current_message_id":4,"inserted_at":"2026-01-05T09:00:00.000Z","updated_at":"2026-01-05T09:00:00.000Z","messages":[{"id":1,"parent_id":null,"role":"USER","status":"FINISHED","thinking_enabled":false,"search_enabled":false,"accumulated_token_usage":0,"inserted_at":"2026-01-05T09:00:00.000Z","fragments":[{"type":"REQUEST","content":"你好"}]},{"id":2,"parent_id":1,"role":"ASSISTANT","status":"FINISHED","thinking_enabled":true,"search_enabled":false,"accumulated_token_usage":0,"inserted_at":"2026-01-05T09:00:00.000Z","fragments":[{"type":"THINK","content":"先思考","elapsed_secs":1.2},{"type":"RESPONSE","content":"你好！"}]},{"id":3,"parent_id":1,"role":"ASSISTANT","status":"FINISHED","thinking_enabled":false,"search_enabled":false,"accumulated_token_usage":0,"inserted_at":"2026-01-05T09:00:00.000Z","fragments":[{"type":"RESPONSE","content":"另一分支"}]},{"id":4,"parent_id":2,"role":"USER","status":"FINISHED","thinking_enabled":false,"search_enabled":false,"accumulated_token_usage":0,"inserted_at":"2026-01-05T09:00:00.000Z","fragments":[{"type":"REQUEST","content":"谢谢"}]}]}"#
        return (manifest, session, index)
    }

    /// ZIP32 STORE/DEFLATE fixtures built in test process; central+local headers and CRC are real.
    private func archive(_ files: [(String, String)], flag: UInt16 = 0,
                         externalMode: UInt32 = 0, localName: String? = nil) throws -> URL {
        var data = Data(), directory = Data()
        for (name, content) in files {
            let body = Data(content.utf8), path = Data(name.utf8)
            let local = Data((localName ?? name).utf8)
            let crc = body.reduce(UInt32(0xffffffff)) { previous, byte in
                var current = previous ^ UInt32(byte)
                for _ in 0..<8 { current = (current >> 1) ^ (current & 1 == 1 ? 0xedb88320 : 0) }
                return current
            } ^ UInt32(0xffffffff)
            let offset = UInt32(data.count)
            data.u32(0x04034b50); data.u16(20); data.u16(flag); data.u16(0)
            data.u16(0); data.u16(0); data.u32(crc); data.u32(UInt32(body.count)); data.u32(UInt32(body.count))
            data.u16(UInt16(local.count)); data.u16(0); data.append(local); data.append(body)
            directory.u32(0x02014b50); directory.u16(0x0314); directory.u16(20); directory.u16(flag)
            directory.u16(0); directory.u16(0); directory.u16(0); directory.u32(crc)
            directory.u32(UInt32(body.count)); directory.u32(UInt32(body.count))
            directory.u16(UInt16(path.count)); directory.u16(0); directory.u16(0)
            directory.u16(0); directory.u16(0); directory.u32(externalMode)
            directory.u32(offset); directory.append(path)
        }
        let start = UInt32(data.count)
        data.append(directory)
        data.u32(0x06054b50); data.u16(0); data.u16(0)
        data.u16(UInt16(files.count)); data.u16(UInt16(files.count)); data.u32(UInt32(directory.count))
        data.u32(start); data.u16(0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try data.write(to: url)
        return url
    }

    private func parse(_ files: [(String, String)]) throws -> DeepSeekImportResult {
        let url = try archive(files)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DeepSeekImport.parse(url)
    }

    func testSyntheticExportMapsThinkingDatesBranchesAndDeduplicates() throws {
        let (manifest, session, index) = example()
        let files = [("manifest.json", manifest), ("chat_sessions/synthetic-1.json", session),
                     ("chat_session_index.json", index)]
        let result = try parse(files)
        XCTAssertEqual(result.sourceSessionCount, 1)
        XCTAssertEqual(result.sessions.count, 2) // current endpoint 4 + alternate leaf 3
        XCTAssertEqual(result.sessions.first?.messages.map(\.content), ["你好", "你好！", "谢谢"])
        XCTAssertEqual(result.sessions.first?.messages[1].reasoning, "先思考")
        let importedMessage = try XCTUnwrap(result.sessions.first?.messages.dropFirst().first)
        XCTAssertEqual(importedMessage.createdAt.timeIntervalSince1970, 1_767_603_600, accuracy: 1)
        XCTAssertEqual(result.sessions.last?.messages.last?.content, "另一分支")
        let replay = try parse(files)
        XCTAssertEqual(result.sessions.map(\.id), replay.sessions.map(\.id))
        XCTAssertEqual(result.merging(into: result.sessions).duplicates, 2)
        XCTAssertEqual(result.merging(into: result.sessions).added, 0)
    }

    func testHostedV3LayoutUsesNamedEntriesAndOptionalCurrentBranch() throws {
        let (manifest, session, _) = example()
        let minimalIndex = #"[{"id":"synthetic-1","pinned":true,"inserted_at":"2026-01-05T09:00:00.000Z","updated_at":"2026-01-05T09:00:00.000Z"}]"#
        let hostedSession = session.replacingOccurrences(of: "\"current_message_id\":4,", with: "")
            .replacingOccurrences(of: "\"updated_at\":\"\(stamp)\",", with: "")
        let result = try parse([("user.json", "{}"), ("chat_session_index.json", minimalIndex),
                                ("chat_sessions/synthetic-1.json", hostedSession), ("manifest.json", manifest)])
        let first = try XCTUnwrap(result.sessions.first)
        XCTAssertTrue(first.isPinned)
        XCTAssertEqual(first.messages.last?.content, "谢谢")
        XCTAssertEqual(first.messages.dropFirst().first?.reasoningDuration, 1.2)
    }

    func testRealDeflatePayloadAndUnorderedV3Entries() throws {
        // Python zipfile/ZIP_DEFLATED, no private data. Manifest deliberately last.
        let encoded = "UEsDBBQAAAAIAMBkeF3qDWnsPgAAAGIAAAAXAAAAY2hhdF9zZXNzaW9uX2luZGV4Lmpzb26LrlbKTFGyUipOzC3ISVXSUcrMK04tKklNiU8sAQobGRiZ6Roa6hoahRgYWIGRnoGBQRRQYWlBSiJhdbWxAFBLAwQUAAAACADAZHhd4bli+7QAAAAHAQAAGQAAAGNoYXRfc2Vzc2lvbnMvc2FtcGxlLmpzb26Vjd0KwjAMhV9l5HqTbogXvRNWcSCibt5MRIrLpND90GagiO9uOp9AEgg5J/nOG0wDErzuRosQAxniKWFjnjS5oJjeoyNsbppYz0S2StI0SbNKCDn3QghR82GH3usHepCX90wVMYzaYU+3sPWTtTG4YcafS3XiF0+aJh/iin1RblX+T17r9KNj+i+QXmMAn9TxrMqK7fvQE7usbdHaIWrd0EV1cVgtk9YhRrna7NaVgs+V6wtQSwMEFAAAAAgAwGR4XR/IYiMdAAAAGwAAAA0AAABtYW5pZmVzdC5qc29uq1ZKrSjILyqJT8svyk0siS9LLSrOzM9TsjKuBQBQSwECFAMUAAAACADAZHhd6g1p7D4AAABiAAAAFwAAAAAAAAAAAAAAgAEAAAAAY2hhdF9zZXNzaW9uX2luZGV4Lmpzb25QSwECFAMUAAAACADAZHhd4bli+7QAAAAHAQAAGQAAAAAAAAAAAAAAgAFzAAAAY2hhdF9zZXNzaW9ucy9zYW1wbGUuanNvblBLAQIUAxQAAAAIAMBkeF0fyGIjHQAAABsAAAANAAAAAAAAAAAAAACAAV4BAABtYW5pZmVzdC5qc29uUEsFBgAAAAADAAMAxwAAAKYBAAAAAA=="
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let result = try DeepSeekImport.parse(url)
        XCTAssertEqual(result.sessions.first?.messages.first?.content, "Hello from ZIP64-free DEFLATE")
    }

    @MainActor func testCommitMergesWithoutOverwritingLocalDraftAndDeduplicates() async throws {
        let (manifest, session, index) = example()
        let result = try parse([("manifest.json", manifest), ("chat_sessions/synthetic-1.json", session),
                                ("chat_session_index.json", index)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = ChatArchive(root: root)
        let controller = ChatController(archive: archive, backend: UnconfiguredBackend())
        await controller.load()
        controller.newChat()
        let localID = try XCTUnwrap(controller.currentID)
        controller.draft = "本地未发送草稿"
        let first = try await controller.importDeepSeek(result)
        XCTAssertEqual(first.added, 2)
        XCTAssertEqual(first.duplicates, 0)
        let second = try await controller.importDeepSeek(result)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.duplicates, 2)
        let saved = try await archive.load()
        XCTAssertEqual(saved.count, 3)
        XCTAssertEqual(saved.first(where: { $0.id == localID })?.draft, "本地未发送草稿")
        XCTAssertEqual(controller.currentID, localID)
    }

    func testUnexpectedOrTruncatedMessagesFailWithoutPartialResult() throws {
        let (manifest, session, index) = example()
        XCTAssertThrowsError(try parse([("manifest.json", manifest),
             ("chat_sessions/synthetic-1.json", session.replacingOccurrences(of: "\"RESPONSE\"", with: "\"FILE\"")),
             ("chat_session_index.json", index)]))
        XCTAssertThrowsError(try parse([("manifest.json", manifest),
             ("chat_sessions/synthetic-1.json", session)]))
        XCTAssertThrowsError(try parse([("manifest.json", manifest),
             ("chat_sessions/synthetic-1.json", session.replacingOccurrences(of: "\"FINISHED\"", with: "\"FAILED\"")),
             ("chat_session_index.json", index)]))
    }

    func testZipTraversalDuplicateSymlinkEncryptedAndVersionRejected() throws {
        let (manifest, session, index) = example()
        for entries in [[("manifest.json", manifest), ("../escaped", "secret")],
                        [("manifest.json", manifest), ("manifest.json", manifest)],
                        [("manifest.json", manifest), ("chat_sessions/synthetic-1.json", session),
                         ("chat_session_index.json", index), ("unknown.json", "{}")]] {
            let url = try archive(entries)
            XCTAssertThrowsError(try DeepSeekImport.parse(url))
            try? FileManager.default.removeItem(at: url)
        }
        let encrypted = try archive([("manifest.json", manifest)], flag: 1)
        XCTAssertThrowsError(try DeepSeekImport.parse(encrypted)) { error in
            guard case DeepSeekImportError.encryptedZIP = error else { return XCTFail("Wrong error: \(error)") }
        }
        try? FileManager.default.removeItem(at: encrypted)
        let symlink = try archive([("manifest.json", manifest)], externalMode: 0xa1ff0000)
        XCTAssertThrowsError(try DeepSeekImport.parse(symlink))
        try? FileManager.default.removeItem(at: symlink)
        let mismatchedHeader = try archive([("manifest.json", manifest)], localName: "other-namex")
        XCTAssertThrowsError(try DeepSeekImport.parse(mismatchedHeader))
        try? FileManager.default.removeItem(at: mismatchedHeader)
        XCTAssertThrowsError(try parse([("manifest.json", #"{"export_format_version":99}"#),
                                        ("chat_sessions/synthetic-1.json", session), ("chat_session_index.json", index)]))
    }
}

private extension Data {
    mutating func u16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func u32(_ value: UInt32) {
        u16(UInt16(truncatingIfNeeded: value)); u16(UInt16(truncatingIfNeeded: value >> 16))
    }
}
