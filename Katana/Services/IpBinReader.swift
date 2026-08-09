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

    nonisolated private static func readFromBinaryImage(_ url: URL) -> IpBinInfo? {
        // Scan the whole image. Homebrew CDIs (NG:DEV, Sturmwind, Ghost Blade…)
        // put big CDDA sessions first, so IP.BIN can sit hundreds of MB in —
        // an 8 MB cap silently fell back to placeholder headers for those games.
        readHeader(from: url, maxSearch: .max)
    }

    nonisolated private static func readHeader(from url: URL, maxSearch: Int) -> IpBinInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Fast path: header at offset 0 (2048-byte-sector data tracks).
        guard let head = try? handle.read(upToCount: 512), head.count > 256 else { return nil }
        if let info = parse(ipData: head) { return info }

        // Stream in chunks scanning for the marker (never loads the image whole).
        let marker = Data(katanaMarker)
        let chunkSize = 4 * 1024 * 1024
        try? handle.seek(toOffset: 0)
        var chunkStart = 0
        var carry = Data() // tail of previous chunk so a marker spanning chunks still matches
        while chunkStart < maxSearch {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            let windowStart = chunkStart - carry.count
            var window = carry
            window.append(chunk)
            var searchRange = window.startIndex..<window.endIndex
            while let found = window.range(of: marker, in: searchRange) {
                let absolute = windowStart + window.distance(from: window.startIndex, to: found.lowerBound)
                try? handle.seek(toOffset: UInt64(absolute))
                if let slice = try? handle.read(upToCount: 512),
                   let info = parse(ipData: slice) {
                    return info
                }
                searchRange = window.index(after: found.lowerBound)..<window.endIndex
            }
            try? handle.seek(toOffset: UInt64(chunkStart + chunk.count))
            chunkStart += chunk.count
            carry = Data(window.suffix(marker.count - 1))
        }
        return nil
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
