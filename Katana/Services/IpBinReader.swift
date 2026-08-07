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
        guard let text = try? String(contentsOf: gdiURL, encoding: .utf8) else { return nil }
        // GDI lines: track LBA type sectorSize filename offset
        // Prefer the first high-density data track (type 4, LBA >= 45000), else second data track.
        var candidates: [(lba: Int, file: String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 5, let lba = Int(parts[1]), let type = Int(parts[2]), type == 4 else { continue }
            candidates.append((lba, parts[4]))
        }
        // High-density first (LBA >= 45000), then any other data track after the first low-density.
        let ordered = candidates.sorted { a, b in
            let aHi = a.lba >= 45000
            let bHi = b.lba >= 45000
            if aHi != bHi { return aHi && !bHi }
            return a.lba < b.lba
        }
        for cand in ordered {
            let trackURL = folderURL.appendingPathComponent(cand.file)
            if let info = readHeader(from: trackURL, maxSearch: 64 * 1024) {
                return info
            }
        }
        return nil
    }

    // MARK: - CDI / raw binary search

    nonisolated private static func readFromBinaryImage(_ url: URL) -> IpBinInfo? {
        // Search up to 8 MB for the SEGAKATANA marker (covers most CDI layouts).
        readHeader(from: url, maxSearch: 8 * 1024 * 1024)
    }

    nonisolated private static func readHeader(from url: URL, maxSearch: Int) -> IpBinInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let toRead = min(Int(fileSize), maxSearch)
        guard toRead > 256 else { return nil }
        guard let data = try? handle.read(upToCount: toRead), data.count > 256 else { return nil }

        // Fast path: header at offset 0.
        if let info = parse(ipData: data) { return info }

        // Scan for marker.
        guard let offset = findKatana(in: data) else { return nil }
        let end = min(offset + 512, data.count)
        return parse(ipData: data.subdata(in: offset..<end))
    }

    nonisolated private static func findKatana(in data: Data) -> Int? {
        let marker = katanaMarker
        guard data.count >= marker.count else { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let n = data.count - marker.count
            var i = 0
            while i <= n {
                var matched = true
                for j in 0..<marker.count {
                    if base[i + j] != marker[j] {
                        matched = false
                        break
                    }
                }
                if matched { return i }
                i += 1
            }
            return nil
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
