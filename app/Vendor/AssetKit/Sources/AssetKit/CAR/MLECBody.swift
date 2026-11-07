import Foundation

/// MLEC wrapper for bitmap pixels, framed in one or three KCBC chunks.
///
/// Layout verified against actool's reference Assets.car:
///
///   MLEC magic        4 bytes
///   compressionType   u32  (0 = raw, 3 = LZFSE)
///   bytesPerPixel     u32  (4 for BGRA8)
///   chunkCount        u32  (1 or 3)
///   then chunkCount * KCBC chunks
///
/// Each KCBC chunk:
///
///   KCBC magic        4 bytes
///   reserved          8 zero bytes
///   chunkHeight       u32  (rows covered by this chunk)
///   payloadSize       u32  (bytes of compressed payload following)
///   payload[]         LZFSE bvx2 stream
///
/// Chunking policy mirrors actool: when height divides evenly by 3, emit 3
/// chunks of equal row height (120 -> 3x40, 180 -> 3x60); otherwise emit a
/// single chunk covering the whole image. The 3-chunk split is mimicry
/// rather than a correctness requirement: CoreUI accepts both layouts.
enum MLECBody {
    static func encode(width: UInt32, height: UInt32, pixelsBGRA: [UInt8]) -> Data {
        // The TVL "bytes per row" slot declares a stride aligned up to 16 bytes, and CoreUI reads rows at that stride,
        // so every row has to be padded to it (118 px = 472 bytes -> 480). Unpadded rows come out sheared.
        let packedRow = Int(width) * 4
        let bytesPerRow = (packedRow + 15) & ~15
        var padded = pixelsBGRA
        if bytesPerRow != packedRow {
            padded = [UInt8](repeating: 0, count: bytesPerRow * Int(height))
            for row in 0..<Int(height) {
                let src = row * packedRow
                padded.replaceSubrange(row * bytesPerRow..<row * bytesPerRow + packedRow, with: pixelsBGRA[src..<src + packedRow])
            }
        }
        let canChunkInThree = height % 3 == 0
        let chunkCount: UInt32 = canChunkInThree ? 3 : 1
        let rowsPerChunk = height / chunkCount

        var chunks: [(rows: UInt32, payload: [UInt8])] = []
        for i in 0..<Int(chunkCount) {
            let start = i * Int(rowsPerChunk) * bytesPerRow
            let end = start + Int(rowsPerChunk) * bytesPerRow
            let slice = Array(padded[start..<end])
            chunks.append((rows: rowsPerChunk, payload: LZFSE.encode(slice)))
        }

        // First word is the pixel kind CoreUI uses to decide whether the bitmap has alpha: actool writes 0 for bitmaps
        // with transparency and 2/3 for fully opaque ones. Always writing 3 made every image load as opaque
        // (transparent pixels rendered black).
        var hasAlpha = false
        var i = 3
        while i < pixelsBGRA.count { if pixelsBGRA[i] != 255 { hasAlpha = true; break }; i += 4 }

        var w = ByteWriter()
        w.writeFourCC("MLEC")
        var kind: UInt32 = hasAlpha ? 0 : 3
        var comp: UInt32 = 4
        if hasAlpha, let v = ProcessInfo.processInfo.environment["ASSETKIT_KIND"] {
            let p = v.split(separator: ":").compactMap { UInt32($0) }
            if p.count == 2 { kind = p[0]; comp = p[1] }
        }
        w.writeLE(kind)                         // pixel kind: 0 = has alpha, 3 = opaque
        w.writeLE(comp)                         // compression: 4 = LZFSE
        w.writeLE(chunkCount)

        for chunk in chunks {
            w.writeFourCC("KCBC")
            w.writeZeros(8)                     // reserved
            w.writeLE(chunk.rows)               // chunkHeight (rows)
            w.writeLE(UInt32(chunk.payload.count))
            w.write(chunk.payload)
        }
        return w.data
    }
}
