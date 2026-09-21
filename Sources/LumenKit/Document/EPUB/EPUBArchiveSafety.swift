import Foundation

/// Preflight ZIP metadata before invoking ditto. EPUB needs ordinary files only.
/// ZIP64, encrypted, multipart, symlink and oversized archives are rejected explicitly.
enum EPUBArchiveSafety {
    static func validate(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= 22 else { throw invalid("ZIP 文件不完整") }
        let tailSize = min(size, 65_557)
        try file.seek(toOffset: size - tailSize)
        let tail = Array(try file.read(upToCount: Int(tailSize)) ?? Data())
        guard tail.count >= 22 else { throw invalid("ZIP 文件不完整") }
        var end: Int?
        for i in stride(from: tail.count - 22, through: 0, by: -1) {
            if u32(tail, i) == 0x06054b50 && i + 22 + Int(u16(tail, i + 20)) == tail.count {
                end = i; break
            }
        }
        guard let e = end else { throw invalid("缺少 ZIP 目录") }
        let count = Int(u16(tail, e + 10))
        let length = UInt64(u32(tail, e + 12))
        let offset = UInt64(u32(tail, e + 16))
        guard u16(tail, e + 4) == 0, u16(tail, e + 6) == 0,
              Int(u16(tail, e + 8)) == count, count < 20_000,
              length < 16 * 1024 * 1024,
              offset + length <= size - tailSize + UInt64(e) else {
            throw invalid("不支持分卷、ZIP64 或过大的 EPUB 目录")
        }
        try file.seek(toOffset: offset)
        let directory = Array(try file.read(upToCount: Int(length)) ?? Data())
        guard directory.count == Int(length) else { throw invalid("ZIP 目录截断") }
        try validateDirectory(directory, entryCount: count)
    }

    static func validateDirectory(_ data: [UInt8], entryCount: Int) throws {
        var cursor = 0
        var expanded: UInt64 = 0
        var paths = Set<String>()
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count, u32(data, cursor) == 0x02014b50 else {
                throw invalid("ZIP 条目损坏")
            }
            let nameLength = Int(u16(data, cursor + 28))
            let next = cursor + 46 + nameLength + Int(u16(data, cursor + 30)) + Int(u16(data, cursor + 32))
            guard next <= data.count, nameLength > 0 else { throw invalid("ZIP 路径损坏") }
            let nameBytes = data[(cursor + 46)..<(cursor + 46 + nameLength)]
            guard let name = String(bytes: nameBytes, encoding: .utf8),
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0"),
                  !name.split(separator: "/").contains(".."),
                  paths.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw invalid("ZIP 含越界、重复或不支持的资源路径")
            }
            let mode = u32(data, cursor + 38) >> 16
            let type = mode & 0xf000
            guard type == 0 || type == 0x8000 || type == 0x4000,
                  u16(data, cursor + 8) & 1 == 0,
                  u16(data, cursor + 34) == 0 else {
                throw invalid("EPUB 含符号链接、特殊文件、加密或分卷条目")
            }
            expanded += UInt64(u32(data, cursor + 24))
            guard expanded <= 512 * 1024 * 1024 else { throw invalid("EPUB 解压后超过 512 MB 限制") }
            cursor = next
        }
        guard cursor == data.count else { throw invalid("ZIP 目录大小不匹配") }
    }

    private static func invalid(_ message: String) -> EPUBError { .extractionFailed(message) }
    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(u16(b, i)) | UInt32(u16(b, i + 2)) << 16
    }
}
