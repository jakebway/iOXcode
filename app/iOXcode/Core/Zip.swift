import Foundation
import Compression

enum ZipError: Error { case bad(String) }

/// Minimal ZIP reader (stored + deflate) and writer (stored only). No Zip64.
enum Zip {
    private static func u16(_ d: Data, _ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> Int {
        Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24
    }

    /// File names inside a zip, read from the central directory only (fast, no unpacking).
    static func names(_ zip: URL) -> [String] {
        guard let data = try? Data(contentsOf: zip, options: .alwaysMapped), data.count > 22 else { return [] }
        var eocd = -1
        var i = data.count - 22
        while i >= max(0, data.count - 70_000) { if u32(data, i) == 0x06054b50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { return [] }
        let count = u16(data, eocd + 10)
        var p = u32(data, eocd + 16)
        var out: [String] = []
        for _ in 0..<count {
            guard p + 46 <= data.count, u32(data, p) == 0x02014b50 else { break }
            let nlen = u16(data, p + 28), xlen = u16(data, p + 30), clen = u16(data, p + 32)
            out.append(String(decoding: data[(p + 46)..<(p + 46 + nlen)], as: UTF8.self))
            p += 46 + nlen + xlen + clen
        }
        return out
    }

    static func extract(_ zip: URL, to dest: URL, progress: ((Int, Int) -> Void)? = nil) throws {
        let data = try Data(contentsOf: zip, options: .alwaysMapped)
        var eocd = -1
        var i = data.count - 22
        while i >= max(0, data.count - 70_000) {
            if u32(data, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.bad("not a zip file") }
        let count = u16(data, eocd + 10)
        var p = u32(data, eocd + 16)
        let fm = FileManager.default
        let base = dest.standardizedFileURL.path
        for n in 0..<count {
            guard u32(data, p) == 0x02014b50 else { throw ZipError.bad("bad central directory") }
            let method = u16(data, p + 10)
            let csize = u32(data, p + 20)
            let usize = u32(data, p + 24)
            let nlen = u16(data, p + 28), xlen = u16(data, p + 30), clen = u16(data, p + 32)
            let attr = u32(data, p + 38)
            let local = u32(data, p + 42)
            let name = String(decoding: data[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            p += 46 + nlen + xlen + clen
            progress?(n, count)
            if name.hasPrefix("__MACOSX/") || name.contains("../") { continue }
            let target = dest.appendingPathComponent(name)
            guard target.standardizedFileURL.path.hasPrefix(base) else { continue }
            if name.hasSuffix("/") { try fm.createDirectory(at: target, withIntermediateDirectories: true); continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard u32(data, local) == 0x04034b50 else { throw ZipError.bad("bad local header") }
            let start = local + 30 + u16(data, local + 26) + u16(data, local + 28)
            let raw = data[start..<(start + csize)]
            let mode = (attr >> 16) & 0xF000
            if mode == 0xA000 { // symlink
                let dst = String(decoding: raw, as: UTF8.self)
                try? fm.removeItem(at: target)
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: dst)
                continue
            }
            if method == 0 {
                try Data(raw).write(to: target)
            } else if method == 8 {
                try inflate(raw, size: usize).write(to: target)
            } else { throw ZipError.bad("unsupported compression \(method) for \(name)") }
        }
    }

    private static func inflate(_ src: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard n == size else { throw ZipError.bad("inflate failed") }
        return out
    }

    // MARK: writer (stored)

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    private static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    /// Zips the contents of `folder` (the folder's children become top-level entries).
    static func create(from folder: URL, to zip: URL, prefix: String = "") throws {
        let fm = FileManager.default
        try? fm.removeItem(at: zip)
        fm.createFile(atPath: zip.path, contents: nil)
        let out = try FileHandle(forWritingTo: zip)
        defer { try? out.close() }
        var central = Data()
        var offset: UInt32 = 0
        func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
        func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
        let rootPath = folder.standardizedFileURL.path
        var entries: [(String, URL, Bool)] = []
        if let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
            for case let u as URL in en {
                let rel = String(u.standardizedFileURL.path.dropFirst(rootPath.count + 1))
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                entries.append((rel, u, isDir))
            }
        }
        entries.sort { $0.0 < $1.0 }
        for (rel, url, isDir) in entries {
            let full = prefix.isEmpty ? rel : prefix + "/" + rel
            let name = (isDir ? full + "/" : full)
            let nameData = Data(name.utf8)
            let body = isDir ? Data() : try Data(contentsOf: url, options: .mappedIfSafe)
            let crc = crc32(body)
            let exec = (!isDir && fm.isExecutableFile(atPath: url.path))
            let unixMode: UInt32 = isDir ? 0o040755 : (exec ? 0o100755 : 0o100644)
            var local = Data()
            local += le32(0x04034b50); local += le16(20); local += le16(0x0800); local += le16(0)
            local += le16(0); local += le16(0x21); local += le32(crc)
            local += le32(UInt32(body.count)); local += le32(UInt32(body.count))
            local += le16(UInt16(nameData.count)); local += le16(0); local += nameData
            try out.write(contentsOf: local)
            try out.write(contentsOf: body)
            central += le32(0x02014b50); central += le16(0x031E); central += le16(20); central += le16(0x0800)
            central += le16(0); central += le16(0); central += le16(0x21); central += le32(crc)
            central += le32(UInt32(body.count)); central += le32(UInt32(body.count))
            central += le16(UInt16(nameData.count)); central += le16(0); central += le16(0)
            central += le16(0); central += le16(0); central += le32(unixMode << 16)
            central += le32(offset); central += nameData
            offset += UInt32(local.count + body.count)
        }
        try out.write(contentsOf: central)
        var end = Data()
        end += le32(0x06054b50); end += le16(0); end += le16(0)
        end += le16(UInt16(entries.count)); end += le16(UInt16(entries.count))
        end += le32(UInt32(central.count)); end += le32(offset); end += le16(0)
        try out.write(contentsOf: end)
    }
}
