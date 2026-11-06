import Foundation

/// Writes a BOM B+ tree.
///
/// Layout (big-endian unless noted):
/// - Tree header block: `'tree' u32`, `version u32`, `childBlockID u32`,
///   `blockSize u32`, `pathCount u32`, `isPathInternal u8`.
/// - Each node block: header of `isLeaf u16`, `count u16`, `forwardLink u32`,
///   `backwardLink u32`, followed by `count` entries of `{ valueBlockID u32, keyBlockID u32 }`.
///
/// For v1 catalogs we expect to write small trees that fit in a single leaf,
/// so this writer emits exactly one leaf node.
struct BOMTree {
    struct Entry {
        var key: Data
        var value: Data
    }

    /// Entry whose key is stored INLINE in the leaf (as a u32) instead of
    /// pointing to a separate key block. Used by trees with
    /// `isPathInternal = true` -- notably `BITMAPKEYS`.
    struct InlineKeyEntry {
        var key: UInt32
        var value: Data
    }

    static let treeMagic: UInt32 = 0x74726565 // 'tree'

    /// Inserts the tree into the BOM writer and returns the block ID of the tree header.
    @discardableResult
    static func insert(
        into bom: inout BOMWriter,
        entries: [Entry]
    ) -> UInt32 {
        // Sort by lexicographic byte order; BOM trees use byte-wise comparison
        // and CoreUI does binary search on rendition keys.
        let sorted = entries.sorted { lhs, rhs in
            byteCompare(lhs.key, rhs.key) < 0
        }

        var keyBlockIDs: [UInt32] = []
        var valueBlockIDs: [UInt32] = []
        for entry in sorted {
            // actool / CoreUI convention: value block is allocated BEFORE
            // its corresponding key block, so the value block has the lower
            // ID. UIImage(named:) lookup quietly returns nil when this
            // ordering is reversed (the catalog still parses with assetutil
            // but iOS's runtime walks the leaf assuming value-first IDs).
            valueBlockIDs.append(bom.addBlock(entry.value))
            keyBlockIDs.append(bom.addBlock(entry.key))
        }

        let blockSize: UInt32 = 4096
        let pairs = (0..<sorted.count).map { (valueBlockIDs[$0], keyBlockIDs[$0]) }
        let leafID = writeNodes(into: &bom, pairs: pairs, blockSize: blockSize, maxPerLeaf: 256)

        // Tree header block. actool's tree headers are 29 bytes -- 21 bytes
        // of fixed fields plus 8 trailing zeros (probably reserved/align).
        // Match the layout so all trees in our output are the same size as
        // the reference.
        var header = ByteWriter()
        header.writeBE(treeMagic)
        header.writeBE(UInt32(1))                   // version
        header.writeBE(leafID)                      // childBlockID
        header.writeBE(blockSize)
        header.writeBE(UInt32(sorted.count))        // pathCount
        header.write(byte: 0)                       // isPathInternal
        header.writeZeros(8)                        // trailing reserved
        return bom.addBlock(header.data)
    }

    /// Inserts a tree whose leaf entries carry an inline u32 key (the
    /// `isPathInternal = true` form). The leaf still stores `(valueBlockID,
    /// keyValue)` per entry, but `keyValue` is an inline u32 (typically a
    /// NameIdentifier) rather than a pointer to a key block.
    @discardableResult
    static func insertInlineKey(
        into bom: inout BOMWriter,
        entries: [InlineKeyEntry],
        blockSize: UInt32
    ) -> UInt32 {
        // Sort by key value; CoreUI binary-searches on the inline u32.
        let sorted = entries.sorted { $0.key < $1.key }

        var valueBlockIDs: [UInt32] = []
        for entry in sorted {
            valueBlockIDs.append(bom.addBlock(entry.value))
        }

        let pairs = (0..<sorted.count).map { (valueBlockIDs[$0], sorted[$0].key) }
        let perLeaf = max(8, Int(blockSize - 12) / 8 * 2 / 3)
        let leafID = writeNodes(into: &bom, pairs: pairs, blockSize: blockSize, maxPerLeaf: perLeaf)

        // Tree header block (29 bytes including 8 trailing reserved).
        var header = ByteWriter()
        header.writeBE(treeMagic)
        header.writeBE(UInt32(1))                   // version
        header.writeBE(leafID)                      // childBlockID
        header.writeBE(blockSize)
        header.writeBE(UInt32(sorted.count))        // pathCount
        header.write(byte: 1)                       // isPathInternal = true
        header.writeZeros(8)                        // trailing reserved
        return bom.addBlock(header.data)
    }

    /// Writes the nodes of a tree and returns the root block ID. A page of a BOM tree holds a limited number of
    /// entries (CoreUI rejects larger pages: "numKeys > maxKeys"), so bigger trees are split into linked leaf pages
    /// under one branch page, laid out the way actool does it: the branch lists every leaf but the last, each with
    /// the last key of that leaf, and the leaves are chained with forward/backward links.
    private static func writeNodes(
        into bom: inout BOMWriter,
        pairs: [(UInt32, UInt32)],
        blockSize: UInt32,
        maxPerLeaf: Int
    ) -> UInt32 {
        func page(isLeaf: Bool, entries: ArraySlice<(UInt32, UInt32)>, forward: UInt32, backward: UInt32) -> Data {
            var w = ByteWriter()
            w.writeBE(UInt16(isLeaf ? 1 : 0))
            w.writeBE(UInt16(entries.count))
            w.writeBE(forward)
            w.writeBE(backward)
            for e in entries { w.writeBE(e.0); w.writeBE(e.1) }
            // macOS 26.4+'s assetutil reads a page as a `blockSize`-sized stream and faults with
            // `BOMStreamGetDataPointer buffer overflow` if the underlying block is shorter.
            if w.offset < Int(blockSize) { w.writeZeros(Int(blockSize) - w.offset) }
            return w.data
        }

        if pairs.count <= maxPerLeaf {
            return bom.addBlock(page(isLeaf: true, entries: pairs[...], forward: 0, backward: 0))
        }

        var chunks: [ArraySlice<(UInt32, UInt32)>] = []
        var i = 0
        while i < pairs.count {
            chunks.append(pairs[i..<min(i + maxPerLeaf, pairs.count)])
            i += maxPerLeaf
        }
        let first = bom.nextBlockID
        var branch: [(UInt32, UInt32)] = []
        for (n, chunk) in chunks.enumerated() {
            let id = first + UInt32(n)
            let forward = n + 1 < chunks.count ? id + 1 : 0
            let backward = n > 0 ? id - 1 : 0
            let added = bom.addBlock(page(isLeaf: true, entries: chunk, forward: forward, backward: backward))
            precondition(added == id)
            if n + 1 < chunks.count { branch.append((id, chunk.last!.1)) }
        }
        precondition(branch.count <= Int(blockSize - 12) / 8, "tree too large for one branch page")
        return bom.addBlock(page(isLeaf: false, entries: branch[...], forward: 0, backward: 0))
    }

    static func byteCompare(_ a: Data, _ b: Data) -> Int {
        let count = min(a.count, b.count)
        for i in 0..<count {
            let av = a[a.index(a.startIndex, offsetBy: i)]
            let bv = b[b.index(b.startIndex, offsetBy: i)]
            if av != bv { return av < bv ? -1 : 1 }
        }
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        return 0
    }
}
