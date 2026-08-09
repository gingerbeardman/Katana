import Foundation

/// Lightweight Dreamcast IP.BIN reader for GDI/CDI (and raw track files).
enum IpBinReader: Sendable {
    private nonisolated static let katanaMarker = Array("SEGA SEGAKATANA".utf8)

    /// Read IP.BIN fields for a game folder.
    nonisolated static func read(from game: GameEntry) -> IpBinInfo? {
        read(folderURL: game.folderURL, imageFileName: game.imageFileName, format: game.format)
    }

    nonisolated static func read(folderURL: URL, imageFileName: String, format: DiscFormat) -> IpBinInfo? {
        let folder = folderURL
        switch format {
        case .gdi:
            return readFromGDI(folderURL: folder, gdiFileName: imageFileName)
        case .cdi, .ccd:
            let path = folder.appendingPathComponent(imageFileName)
            return readFromBinaryImage(path)
        case .unknown:
            // Try common names.
            for name in ["disc.gdi", "disc.cdi", "disc.ccd"] {
                let url = folder.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if name.hasSuffix(".gdi") {
                    if let info = readFromGDI(folderURL: folder, gdiFileName: name) { return info }
                } else if let info = readFromBinaryImage(url) {
                    return info
                }
            }
            return nil
        }
    }

    // MARK: - GDI

    nonisolated private static func readFromGDI(folderURL: URL, gdiFileName: String) -> IpBinInfo? {
        let gdiURL = folderURL.appendingPathComponent(gdiFileName)
        let text = (try? String(contentsOf: gdiURL, encoding: .utf8))
            ?? (try? String(contentsOf: gdiURL, encoding: .isoLatin1))
        guard let text else { return nil }

        // Quote-aware parse (Redump: `… 2352 "Game (Track 1).bin" 0`). Space-splitting
        // alone breaks on those names and never opens the track → no serial / IP title.
        let candidates = GdiCue.dataTracksForIPBIN(in: text)
        for track in candidates {
            let trackURL = folderURL.appendingPathComponent(track.fileName)
            // 2352-byte sectors often put the IP.BIN header a few bytes in; 256 KB is plenty.
            if let info = readHeader(from: trackURL, maxSearch: 256 * 1024) {
                return info
            }
        }
        return nil
    }

    // MARK: - CDI / raw binary search

    /// Brute-scan cap when the CDI track table is unreadable. Whole-image scans of
    /// CDDA-heavy discs streamed hundreds of MB per game off the card and froze the app.
    private nonisolated static let fallbackScanLimit = 64 * 1024 * 1024

    /// Bounded scan from the start of a file (GDI data tracks).
    nonisolated private static func readHeader(from url: URL, maxSearch: Int) -> IpBinInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return scanForHeader(handle, from: 0, maxBytes: maxSearch)
    }

    nonisolated private static func readFromBinaryImage(_ url: URL) -> IpBinInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 256 else { return nil }

        // Fast path: header at (or near) offset 0.
        if let info = scanForHeader(handle, from: 0, maxBytes: 512) { return info }

        // DiscJuggler CDI keeps its track table in a footer at EOF. Homebrew discs
        // (NG:DEV, Sturmwind, Ghost Blade…) put IP.BIN in the data session *after*
        // large CDDA sessions — jump straight to each data track instead of
        // streaming the whole image.
        for offset in cdiDataTrackOffsets(handle: handle, fileSize: fileSize) where offset < fileSize {
            if let info = scanForHeader(handle, from: offset, maxBytes: 1024 * 1024) {
                return info
            }
        }

        // No parseable track table — bounded brute scan from the start.
        return scanForHeader(handle, from: 0, maxBytes: fallbackScanLimit)
    }

    /// Chunked marker scan starting at `start`, reading at most `maxBytes`.
    nonisolated private static func scanForHeader(
        _ handle: FileHandle,
        from start: UInt64,
        maxBytes: Int
    ) -> IpBinInfo? {
        let marker = Data(katanaMarker)
        let chunkSize = 4 * 1024 * 1024
        var scanned = 0
        var carry = Data() // tail of previous chunk so a marker spanning chunks still matches
        try? handle.seek(toOffset: start)
        while scanned < maxBytes {
            var found: IpBinInfo?
            var exhausted = false
            // FileHandle chunks are autoreleased NSData — drain per iteration or a
            // long scan holds every chunk (sampled at 1.9 GB footprint).
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: min(chunkSize, maxBytes - scanned)),
                      !chunk.isEmpty
                else {
                    exhausted = true
                    return
                }
                let windowStart = start + UInt64(scanned) - UInt64(carry.count)
                var window = carry
                window.append(chunk)
                var searchRange = window.startIndex..<window.endIndex
                while let hit = window.range(of: marker, in: searchRange) {
                    let absolute = windowStart
                        + UInt64(window.distance(from: window.startIndex, to: hit.lowerBound))
                    try? handle.seek(toOffset: absolute)
                    if let slice = try? handle.read(upToCount: 512),
                       let info = parse(ipData: slice) {
                        found = info
                        return
                    }
                    searchRange = window.index(after: hit.lowerBound)..<window.endIndex
                }
                scanned += chunk.count
                try? handle.seek(toOffset: start + UInt64(scanned))
                carry = Data(window.suffix(marker.count - 1))
            }
            if let found { return found }
            if exhausted { break }
        }
        return nil
    }

    // MARK: - DiscJuggler CDI track table

    /// Byte offsets where data-track content starts (past each track's pregap).
    /// Layout follows cdirip's CDI reader; bails to `[]` on anything unexpected —
    /// callers then fall back to a bounded scan.
    nonisolated private static func cdiDataTrackOffsets(
        handle: FileHandle,
        fileSize: UInt64
    ) -> [UInt64] {
        let v2: UInt32 = 0x8000_0004, v3: UInt32 = 0x8000_0005, v35: UInt32 = 0x8000_0006
        guard fileSize > 16,
              let tail = readAt(handle, offset: fileSize - 8, count: 8), tail.count == 8
        else { return [] }
        let version = tail.leU32(0)
        let headerOffset = tail.leU32(4)
        guard version == v2 || version == v3 || version == v35, headerOffset != 0 else { return [] }
        let headerPosition = version == v35 ? fileSize - UInt64(headerOffset) : UInt64(headerOffset)
        guard headerPosition < fileSize else { return [] }
        let tocSize = Int(min(fileSize - headerPosition, 4 * 1024 * 1024))
        guard let toc = readAt(handle, offset: headerPosition, count: tocSize) else { return [] }

        var r = ByteReader(toc)
        let startMark: [UInt8] = [0, 0, 1, 0, 0, 0, 255, 255, 255, 255]
        guard let sessions = r.u16(), sessions > 0, sessions < 100 else { return [] }
        var trackPosition: UInt64 = 0
        var offsets: [UInt64] = []
        for _ in 0..<sessions {
            guard let ntracks = r.u16(), ntracks < 100 else { return offsets }
            for _ in 0..<ntracks {
                guard let extra = r.u32() else { return offsets }
                if extra != 0 { r.skip(8) }
                guard r.match(startMark), r.match(startMark) else { return offsets }
                r.skip(4)
                guard let filenameLength = r.u8() else { return offsets }
                r.skip(Int(filenameLength))
                r.skip(11 + 4 + 4)
                guard let dj4Marker = r.u32() else { return offsets }
                if dj4Marker == 0x8000_0000 { r.skip(8) }
                r.skip(2)
                guard let pregap = r.u32(), let length = r.u32() else { return offsets }
                r.skip(6)
                guard let mode = r.u32() else { return offsets }
                r.skip(12)
                guard r.u32() != nil, let totalLength = r.u32() else { return offsets } // start LBA, total
                r.skip(16)
                guard let sectorSizeID = r.u32() else { return offsets }
                let sectorSize: UInt64
                switch sectorSizeID {
                case 0: sectorSize = 2048
                case 1: sectorSize = 2352
                case 2: sectorSize = 2336
                default: return offsets
                }
                if mode != 0 { // 0 = audio; 1 / 2 = data
                    offsets.append(trackPosition + UInt64(pregap) * sectorSize)
                }
                let sectors = max(UInt64(totalLength), UInt64(pregap) + UInt64(length))
                trackPosition += sectors * sectorSize
                r.skip(29)
                if version != v2 {
                    r.skip(5)
                    if let dj4 = r.u32(), dj4 == 0xFFFF_FFFF { r.skip(78) }
                }
            }
            r.skip(4 + 8)
            if version != v2 { r.skip(1) }
        }
        return offsets
    }

    nonisolated private static func readAt(_ handle: FileHandle, offset: UInt64, count: Int) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.read(upToCount: count)
    }

    /// Little-endian cursor over a Data buffer; every read is bounds-checked.
    private struct ByteReader {
        private let data: Data
        private var index: Int

        init(_ data: Data) {
            self.data = data
            self.index = 0
        }

        mutating func skip(_ n: Int) { index += n }

        mutating func u8() -> UInt8? {
            guard index >= 0, index < data.count else { return nil }
            defer { index += 1 }
            return data[data.startIndex + index]
        }

        mutating func u16() -> UInt16? {
            guard let lo = u8(), let hi = u8() else { return nil }
            return UInt16(lo) | (UInt16(hi) << 8)
        }

        mutating func u32() -> UInt32? {
            guard let lo = u16(), let hi = u16() else { return nil }
            return UInt32(lo) | (UInt32(hi) << 16)
        }

        mutating func match(_ bytes: [UInt8]) -> Bool {
            for expected in bytes {
                guard let b = u8(), b == expected else { return false }
            }
            return true
        }
    }

    // MARK: - Field layout (Aaru / GDMENUCardManager compatible)

    /// Parse a 256–512 byte IP.BIN header slice starting at SEGA SEGAKATANA.
    nonisolated static func parse(ipData: Data) -> IpBinInfo? {
        guard ipData.count >= 0xB0 else { return nil }
        // Must start with SEGA SEGAKATANA (allow leading offset already stripped).
        let head = String(decoding: ipData.prefix(16), as: UTF8.self)
        guard head.hasPrefix("SEGA SEGAKATANA") else { return nil }

        // Offsets match Aaru Dreamcast IP.BIN layout:
        // 0x025 media "GD-ROM" (6), 0x02B disc_no, 0x02D disc_total
        // 0x030 region (8), 0x038 peripherals (7) — VGA at [5] ASCII '1'
        // 0x040 product (10), 0x04A version (6), 0x050 date (8)
        // 0x060 boot filename (12), 0x080 product name (128)

        let discNo = ipData[0x2B]
        let discTotal = ipData[0x2D]
        let disc: String
        if discNo == 32 || discTotal == 32 {
            disc = "1/1"
        } else {
            disc = "\(Character(UnicodeScalar(discNo)))/\(Character(UnicodeScalar(discTotal)))"
        }

        let region = field(ipData, 0x30, 8)
        // Peripherals hex string at 0x38 (7 chars typically "0799A10"); VGA is index 5 == '1'
        let vga: Bool
        if ipData.count > 0x3D {
            vga = ipData[0x3D] == 0x31 // '1'
        } else {
            vga = true
        }

        let productNumber = field(ipData, 0x40, 10)
        let version = field(ipData, 0x4A, 6)
        let releaseDate = field(ipData, 0x50, 8)
        let name = field(ipData, 0x80, 128)
        let media = field(ipData, 0x25, 6) // "GD-ROM" / "FCD   " etc.
        let boot = field(ipData, 0x60, 12)
        // Device / CRC field (4 chars) immediately before media at 0x20 — GCM shows this as “CRC”.
        let crc = field(ipData, 0x20, 4)

        let isCodeBreaker = media.hasPrefix("FCD")
            && releaseDate == "20000627"
            && version == "V1.000"
            && boot.hasPrefix("PELICAN.BIN")

        guard !name.isEmpty || !productNumber.isEmpty else { return nil }

        return IpBinInfo(
            name: name.isEmpty ? productNumber : name,
            productNumber: productNumber,
            disc: disc,
            region: region.isEmpty ? "JUE" : region,
            vga: vga,
            version: version.isEmpty ? "V1.000" : version,
            releaseDate: releaseDate.isEmpty ? "19990909" : releaseDate,
            crc: crc,
            isCodeBreaker: isCodeBreaker
        )
    }

    nonisolated private static func field(_ data: Data, _ offset: Int, _ length: Int) -> String {
        guard offset + length <= data.count else { return "" }
        let slice = data.subdata(in: offset..<(offset + length))
        // Trim NULs and spaces.
        if let end = slice.firstIndex(of: 0) {
            return String(decoding: slice[..<end], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(decoding: slice, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Data {
    /// Little-endian UInt32 at `offset` relative to `startIndex` (caller checks bounds).
    func leU32(_ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(self[startIndex + offset + i]) << (8 * i)
        }
        return value
    }
}
