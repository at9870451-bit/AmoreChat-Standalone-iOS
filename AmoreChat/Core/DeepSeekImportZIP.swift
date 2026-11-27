import Foundation
import Compression

/// ZIP32 subset documented by deepseek-ai/chat-demo/src/services/chat/history/README.md.
/// No extraction to disk: every filename is validated before any payload is decompressed.
struct DeepSeekImportZIP {
    struct Entry {
        let path: String
        let method: UInt16
        let flags: UInt16
        let crc: UInt32
        let compressed: Int
        let expanded: Int
        let offset: Int
        let name: Data
    }

    static let maxEntries = 4_096
    private let bytes: Data
    let entries: [Entry]
    private let centralStart: Int

    init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value >= 0 else {
            throw DeepSeekImportError.unsafeArchive("无法读取压缩包大小")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        bytes = data
        guard data.count >= 22 else { throw DeepSeekImportError.invalidZIP }
        let tail = max(0, data.count - 22 - 65_535)
        guard let end = stride(from: data.count - 22, through: tail, by: -1).first(where: {
            data.u32($0) == 0x06054b50 && $0 + 22 + Int(data.u16($0 + 20)) == data.count
        }) else { throw DeepSeekImportError.invalidZIP }
        let count = Int(data.u16(end + 10))
        let centralSize = Int(data.u32(end + 12)), centralStart = Int(data.u32(end + 16))
        guard data.u16(end + 4) == 0, data.u16(end + 6) == 0,
              data.u16(end + 8) == data.u16(end + 10), count > 0,
              count <= Self.maxEntries, count != 0xffff,
              centralSize != Int(UInt32.max), centralStart != Int(UInt32.max),
              centralStart <= end, centralSize == end - centralStart
        else { throw DeepSeekImportError.unsafeArchive("ZIP64、分卷、超量条目或中心目录不合法") }
        var cursor = centralStart, found = [Entry](), paths = Set<String>()
        var total = 0
        for _ in 0..<count {
            guard cursor <= end - 46, data.u32(cursor) == 0x02014b50 else {
                throw DeepSeekImportError.invalidZIP
            }
            let flags = data.u16(cursor + 8), method = data.u16(cursor + 10)
            if flags & 1 != 0 || flags & 0x40 != 0 { throw DeepSeekImportError.encryptedZIP }
            guard flags & ~UInt16(0x080e) == 0, method == 0 || method == 8,
                  data.u16(cursor + 34) == 0 else {
                throw DeepSeekImportError.unsafeArchive("不支持的 ZIP 压缩方式或标志")
            }
            let compressed = Int(data.u32(cursor + 20)), expanded = Int(data.u32(cursor + 24))
            let offset = Int(data.u32(cursor + 42))
            guard compressed != Int(UInt32.max), expanded != Int(UInt32.max),
                  compressed <= data.count, method != 0 || compressed == expanded,
                  offset < centralStart else {
                throw DeepSeekImportError.unsafeArchive("条目过大或 ZIP64 不受支持")
            }
            let sum = total.addingReportingOverflow(expanded)
            guard !sum.overflow else { throw DeepSeekImportError.unsafeArchive("解压总量过大") }
            total = sum.partialValue
            guard expanded <= compressed * 250 + 1_024 else {
                throw DeepSeekImportError.unsafeArchive("疑似 ZIP 炸弹（压缩比过高）")
            }
            let nameSize = Int(data.u16(cursor + 28)), extraSize = Int(data.u16(cursor + 30))
            let commentSize = Int(data.u16(cursor + 32))
            let next = cursor + 46 + nameSize + extraSize + commentSize
            guard next <= end, nameSize > 0 else { throw DeepSeekImportError.invalidZIP }
            let rawName = data.subdata(in: cursor + 46..<cursor + 46 + nameSize)
            guard flags & 0x800 != 0 || rawName.allSatisfy({ $0 < 128 }),
                  let decoded = String(data: rawName, encoding: .utf8) else {
                throw DeepSeekImportError.unsafeArchive("文件名不是 UTF-8")
            }
            let path = decoded.precomposedStringWithCanonicalMapping
            let components = (path.hasSuffix("/") ? String(path.dropLast()) : path).split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
                  !path.prefix(2).contains(":"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  paths.insert(path.hasSuffix("/") ? String(path.dropLast()) : path).inserted else {
                throw DeepSeekImportError.unsafeArchive("路径穿越或重复 ZIP 条目")
            }
            try Self.checkExtra(data, cursor + 46 + nameSize, extraSize)
            let host = data.u16(cursor + 4) >> 8, mode = data.u32(cursor + 38) >> 16
            let fileType = mode & 0xf000
            guard fileType != 0xa000, host != 3 || fileType == 0 || fileType == 0x8000 ||
                (fileType == 0x4000 && path.hasSuffix("/")) else {
                throw DeepSeekImportError.unsafeArchive("ZIP 符号链接或特殊文件不受支持")
            }
            if path.hasSuffix("/") {
                guard expanded == 0 && (fileType == 0 || fileType == 0x4000) else {
                    throw DeepSeekImportError.unsafeArchive("目录条目无效")
                }
            } else if fileType == 0x4000 {
                throw DeepSeekImportError.unsafeArchive("目录伪装成文件")
            }
            found.append(Entry(path: path, method: method, flags: flags, crc: data.u32(cursor + 16),
                               compressed: compressed, expanded: expanded, offset: offset, name: rawName))
            cursor = next
        }
        guard cursor == end else { throw DeepSeekImportError.invalidZIP }
        found.sort { $0.offset < $1.offset }
        for (index, entry) in found.enumerated() {
            let boundary = index + 1 == found.count ? centralStart : found[index + 1].offset
            _ = try Self.payloadRange(data, entry, boundary)
        }
        self.centralStart = centralStart
        entries = found.filter { !$0.path.hasSuffix("/") }
    }

    func read(_ entry: Entry) throws -> Data {
        guard let index = entries.firstIndex(where: { $0.offset == entry.offset }) else {
            throw DeepSeekImportError.invalidZIP
        }
        let boundary = index + 1 == entries.count ? centralStart : entries[index + 1].offset
        let start = try Self.payloadRange(bytes, entry, boundary).lowerBound
        let compressed = bytes.subdata(in: start..<start + entry.compressed)
        let result: Data
        if entry.method == 0 { result = compressed }
        else {
            guard !compressed.isEmpty else { throw DeepSeekImportError.invalidZIP }
            // One extra byte detects an underestimated output size instead of
            // accepting a truncated prefix with a matching CRC.
            let capacity = entry.expanded + 1
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              source.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.expanded else { throw DeepSeekImportError.invalidZIP }
            output.count = written
            result = output
        }
        guard Self.checksum(result) == entry.crc else { throw DeepSeekImportError.invalidZIP }
        return result
    }

    private static func payloadRange(_ data: Data, _ entry: Entry, _ boundary: Int) throws -> Range<Int> {
        let startHeader = entry.offset
        guard startHeader <= boundary - 30, data.u32(startHeader) == 0x04034b50,
              data.u16(startHeader + 6) == entry.flags,
              data.u16(startHeader + 8) == entry.method,
              Int(data.u16(startHeader + 26)) == entry.name.count else { throw DeepSeekImportError.invalidZIP }
        let extra = Int(data.u16(startHeader + 28))
        let start = startHeader + 30 + entry.name.count + extra
        guard start <= boundary, entry.compressed <= boundary - start,
              data.subdata(in: startHeader + 30..<startHeader + 30 + entry.name.count) == entry.name else {
            throw DeepSeekImportError.invalidZIP
        }
        try checkExtra(data, startHeader + 30 + entry.name.count, extra)
        if entry.flags & 8 == 0 {
            guard data.u32(startHeader + 14) == entry.crc,
                  data.u32(startHeader + 18) == entry.compressed,
                  data.u32(startHeader + 22) == entry.expanded else { throw DeepSeekImportError.invalidZIP }
        } else {
            let finish = start + entry.compressed
            guard boundary - finish >= 12 else { throw DeepSeekImportError.invalidZIP }
            let marker = data.u32(finish) == 0x08074b50 ? 4 : 0
            guard boundary - finish >= marker + 12,
                  data.u32(finish + marker) == entry.crc,
                  data.u32(finish + marker + 4) == entry.compressed,
                  data.u32(finish + marker + 8) == entry.expanded else { throw DeepSeekImportError.invalidZIP }
        }
        return start..<start + entry.compressed
    }

    private static func checkExtra(_ data: Data, _ start: Int, _ count: Int) throws {
        guard start <= data.count, count <= data.count - start else { throw DeepSeekImportError.invalidZIP }
        var offset = start
        while offset < start + count {
            guard offset <= start + count - 4 else { throw DeepSeekImportError.invalidZIP }
            if data.u16(offset) == 1 { throw DeepSeekImportError.unsafeArchive("ZIP64 扩展不受支持") }
            offset += 4 + Int(data.u16(offset + 2))
            guard offset <= start + count else { throw DeepSeekImportError.invalidZIP }
        }
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        return ~crc
    }
}

private extension Data {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
}
