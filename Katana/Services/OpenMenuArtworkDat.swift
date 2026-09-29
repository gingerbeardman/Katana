import Foundation

/// Inserts loose covers into an openMenu `BOX.DAT` or `ICON.DAT`.
///
/// The console looks covers up by the `product=` id in `OPENMENU.INI`. A loose
/// `0GDTEX.PVR` next to the game is invisible there until it is a chunk in
/// these files. Chunk 0 is the header and index; pictures start at chunk 1.
enum OpenMenuArtworkDat: Sendable {
    private static let headerSize = 16
    private static let entrySize = 16
    private static let idSize = 12

    /// 128×128 square-twiddled texture for `ICON.DAT` (grid view).
    nonisolated static func iconTexture(from boxPVR: Data) -> Data? {
        guard let decoded = try? PvrDecoder.decodeRGBA(from: boxPVR) else { return nil }
        return PvrEncoder.encodeCover(
            rgba: [UInt8](decoded.0),
            width: decoded.1,
            height: decoded.2,
            side: 128
        )
    }

    /// Adds or replaces `covers`, keyed by product id. A missing `existing`
    /// starts a new file. An unreadable existing file is returned unchanged.
    nonisolated static func merge(covers: [String: Data], into existing: Data?) -> Data? {
        let covers = covers.filter { id, pvr in
            !id.isEmpty && id.utf8.count <= idSize && !pvr.isEmpty
        }
        guard !covers.isEmpty else { return existing }
        if let existing, !existing.isEmpty {
            return merging(covers, into: existing) ?? existing
        }
        return create(covers)
    }

    // MARK: -

    private struct Parsed {
        var chunkSize: Int
        var padding0: Int
        var entries: [(id: String, offset: Int)]
        var chunks: [Int: Data]
    }

    private nonisolated static func create(_ covers: [String: Data]) -> Data? {
        guard let chunkSize = covers.values.map(\.count).max(), chunkSize > 0 else { return nil }
        let ids = covers.keys.sorted()
        var fitted: [(String, Data)] = []
        for id in ids {
            guard let pvr = covers[id], let chunk = fit(pvr, chunkSize: chunkSize) else { continue }
            fitted.append((id, chunk))
        }
        guard !fitted.isEmpty else { return nil }
        let padding0 = indexPadding(entryCount: fitted.count, chunkSize: chunkSize)
        let first = padding0 + 1
        let entries = fitted.enumerated().map { index, item in
            (item.0, first + index, item.1)
        }
        return write(chunkSize: chunkSize, padding0: padding0, entries: entries)
    }

    private nonisolated static func merging(_ covers: [String: Data], into existing: Data) -> Data? {
        guard var parsed = parse(existing) else { return nil }
        var changed = false
        for (id, pvr) in covers {
            guard let chunk = fit(pvr, chunkSize: parsed.chunkSize) else { continue }
            if let index = parsed.entries.firstIndex(where: { $0.id == id }) {
                parsed.chunks[parsed.entries[index].offset] = chunk
            } else {
                let next = (parsed.entries.map(\.offset).max() ?? parsed.padding0) + 1
                parsed.entries.append((id, next))
                parsed.chunks[next] = chunk
            }
            changed = true
        }
        guard changed else { return existing }
        let padding0 = indexPadding(entryCount: parsed.entries.count, chunkSize: parsed.chunkSize)
        let shift = padding0 - parsed.padding0
        let entries: [(String, Int, Data)] = parsed.entries.map { entry in
            let offset = entry.offset + shift
            let chunk = parsed.chunks[entry.offset] ?? Data(count: parsed.chunkSize)
            return (entry.id, offset, chunk)
        }
        return write(chunkSize: parsed.chunkSize, padding0: padding0, entries: entries)
    }

    private nonisolated static func parse(_ data: Data) -> Parsed? {
        guard data.count >= headerSize else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == UInt8(ascii: "D"),
              bytes[1] == UInt8(ascii: "A"),
              bytes[2] == UInt8(ascii: "T"),
              bytes[3] == 1
        else { return nil }
        let chunkSize = Int(le32(bytes, 4))
        let count = Int(le32(bytes, 8))
        let padding0 = Int(le32(bytes, 12))
        guard chunkSize > 0, chunkSize <= 2 * 1024 * 1024,
              count >= 0, count <= 50_000, padding0 >= 0, padding0 <= 64
        else { return nil }
        let tableEnd = headerSize + count * entrySize
        guard tableEnd <= data.count else { return nil }

        var entries: [(id: String, offset: Int)] = []
        var chunks: [Int: Data] = [:]
        entries.reserveCapacity(count)
        for index in 0..<count {
            let base = headerSize + index * entrySize
            let id = String(bytes: bytes[base..<(base + idSize)].prefix { $0 != 0 }, encoding: .ascii) ?? ""
            let offset = Int(le32(bytes, base + idSize))
            guard !id.isEmpty, offset > padding0 else { continue }
            let at = offset * chunkSize
            let end = at + chunkSize
            guard end <= data.count else { continue }
            entries.append((id, offset))
            if chunks[offset] == nil {
                chunks[offset] = data.subdata(in: at..<end)
            }
        }
        return Parsed(chunkSize: chunkSize, padding0: padding0, entries: entries, chunks: chunks)
    }

    private nonisolated static func write(
        chunkSize: Int,
        padding0: Int,
        entries: [(String, Int, Data)]
    ) -> Data {
        let indexBytes = (padding0 + 1) * chunkSize
        let maxOffset = entries.map(\.1).max() ?? padding0
        let total = max(indexBytes, (maxOffset + 1) * chunkSize)
        var data = Data(count: total)
        data[0] = UInt8(ascii: "D")
        data[1] = UInt8(ascii: "A")
        data[2] = UInt8(ascii: "T")
        data[3] = 1
        writeLE32(UInt32(chunkSize), into: &data, at: 4)
        writeLE32(UInt32(entries.count), into: &data, at: 8)
        writeLE32(UInt32(padding0), into: &data, at: 12)
        for (index, entry) in entries.enumerated() {
            let base = headerSize + index * entrySize
            for (offset, byte) in entry.0.utf8.prefix(idSize).enumerated() {
                data[base + offset] = byte
            }
            writeLE32(UInt32(entry.1), into: &data, at: base + idSize)
            let at = entry.1 * chunkSize
            let chunk = entry.2.count == chunkSize ? entry.2 : fit(entry.2, chunkSize: chunkSize) ?? Data(count: chunkSize)
            data.replaceSubrange(at..<(at + chunkSize), with: chunk.prefix(chunkSize))
        }
        return data
    }

    /// Chunks of header + index that must precede the first picture.
    private nonisolated static func indexPadding(entryCount: Int, chunkSize: Int) -> Int {
        let need = headerSize + entryCount * entrySize
        var padding0 = 0
        while (padding0 + 1) * chunkSize < need, padding0 < 64 {
            padding0 += 1
        }
        return padding0
    }

    private nonisolated static func fit(_ pvr: Data, chunkSize: Int) -> Data? {
        guard pvr.count <= chunkSize else { return nil }
        if pvr.count == chunkSize { return pvr }
        var chunk = Data(count: chunkSize)
        chunk.replaceSubrange(0..<pvr.count, with: pvr)
        return chunk
    }

    private nonisolated static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private nonisolated static func writeLE32(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
