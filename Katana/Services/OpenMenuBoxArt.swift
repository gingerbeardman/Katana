import Foundation

/// Cover image from an openMenu `BOX.DAT`, matched by serial.
///
/// The file is a `DAT` version-1 table: 16-byte header, then 16-byte entries
/// (12-byte id + chunk index). Each image is `chunkSize` bytes at
/// `index * chunkSize`. Index 0 is the header, not a picture. The database on a
/// real card is about 150 MB, so only the table and one chunk are read.
nonisolated enum OpenMenuBoxArt: Sendable {
    private static let headerSize = 16
    private static let entrySize = 16
    private static let idSize = 12
    private static let maxEntries = 50_000
    private static let maxChunkSize = 2 * 1024 * 1024
    /// Product-code region letters openMenu treats as the same game, tried in this order.
    private static let regionLetters: [Character] = ["N", "M", "E", "J"]

    /// PVR chunk for the first serial that has a box, from a loose `BOX.DAT` or the menu GDI.
    nonisolated static func imageData(
        matching serials: [String],
        menuFolder: URL,
        imageFileName: String
    ) -> Data? {
        guard let origin = origin(menuFolder: menuFolder, imageFileName: imageFileName) else {
            return nil
        }
        return imageData(matching: serials, origin: origin)
    }

    /// True when the menu `BOX.DAT` has a chunk for any of `serials`. Does not read the picture.
    nonisolated static func contains(
        matching serials: [String],
        menuFolder: URL,
        imageFileName: String
    ) -> Bool {
        guard let origin = origin(menuFolder: menuFolder, imageFileName: imageFileName),
              let index = Cache.shared.index(for: origin)
        else { return false }
        for serial in serials {
            for key in lookupKeys(for: serial) where index.chunks[key] != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Origin

    private enum Origin: Sendable {
        case file(URL, length: Int)
        case disc(Iso9660FileExtractor.LocatedFile)

        var cacheKey: String {
            switch self {
            case let .file(url, length):
                return "f:\(url.path)#\(length)"
            case let .disc(file):
                let tracks = file.tracks.map { "\($0.lba):\($0.url.path)" }.joined(separator: "|")
                return "d:\(tracks)#\(file.startLBA)#\(file.length)"
            }
        }

        var length: Int {
            switch self {
            case let .file(_, length): return length
            case let .disc(file): return file.length
            }
        }

        func read(offset: Int, count: Int) -> Data? {
            switch self {
            case let .file(url, _):
                return OpenMenuBoxArt.readFile(url, offset: offset, count: count)
            case let .disc(file):
                return Iso9660FileExtractor.read(file: file, offset: offset, count: count)
            }
        }
    }

    private struct Index {
        var chunkSize: Int
        var chunks: [String: Int]
    }

    private nonisolated static func imageData(matching serials: [String], origin: Origin) -> Data? {
        guard let index = Cache.shared.index(for: origin) else { return nil }
        for serial in serials {
            for key in lookupKeys(for: serial) {
                guard let chunk = index.chunks[key] else { continue }
                guard chunk <= origin.length / index.chunkSize else { continue }
                return origin.read(offset: chunk * index.chunkSize, count: index.chunkSize)
            }
        }
        return nil
    }

    private nonisolated static func origin(menuFolder: URL, imageFileName: String) -> Origin? {
        if let loose = looseBox(in: menuFolder) { return loose }
        return discBox(menuFolder: menuFolder, imageFileName: imageFileName)
    }

    private nonisolated static func looseBox(in folder: URL) -> Origin? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              let name = names.first(where: { $0.caseInsensitiveCompare("BOX.DAT") == .orderedSame })
        else { return nil }
        let url = folder.appendingPathComponent(name)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > headerSize
        else { return nil }
        return .file(url, length: size)
    }

    private nonisolated static func discBox(menuFolder: URL, imageFileName: String) -> Origin? {
        let gdiName = imageFileName.lowercased().hasSuffix(".gdi") ? imageFileName : "disc.gdi"
        let gdiURL = menuFolder.appendingPathComponent(gdiName)
        let text = (try? String(contentsOf: gdiURL, encoding: .utf8))
            ?? (try? String(contentsOf: gdiURL, encoding: .isoLatin1))
        guard let text else { return nil }
        var tracks: [Iso9660FileExtractor.DataTrack] = []
        for track in GdiCue.parseTracks(in: text) where track.type == 4 {
            let trackURL = menuFolder.appendingPathComponent(track.fileName)
            guard FileManager.default.fileExists(atPath: trackURL.path) else { continue }
            tracks.append(.init(lba: UInt32(track.lba), url: trackURL))
        }
        guard let located = Iso9660FileExtractor.locate(named: ["BOX.DAT"], tracks: tracks)["BOX.DAT"] else {
            return nil
        }
        return .disc(located)
    }

    private nonisolated static func loadIndex(origin: Origin) -> Index? {
        guard let header = origin.read(offset: 0, count: headerSize), header.count == headerSize else {
            return nil
        }
        let bytes = [UInt8](header)
        guard bytes[0] == UInt8(ascii: "D"),
              bytes[1] == UInt8(ascii: "A"),
              bytes[2] == UInt8(ascii: "T"),
              bytes[3] == 1
        else { return nil }
        let chunkSize = Int(le32(bytes, 4))
        let count = Int(le32(bytes, 8))
        guard chunkSize > 0, chunkSize <= maxChunkSize, count > 0, count <= maxEntries else {
            return nil
        }
        let tableBytes = count * entrySize
        guard headerSize + tableBytes <= origin.length,
              let table = origin.read(offset: headerSize, count: tableBytes),
              table.count == tableBytes
        else { return nil }

        var chunks: [String: Int] = [:]
        chunks.reserveCapacity(count)
        let raw = [UInt8](table)
        for i in 0..<count {
            let base = i * entrySize
            let id = String(bytes: raw[base..<(base + idSize)].prefix { $0 != 0 }, encoding: .ascii) ?? ""
            let key = normalize(id)
            let chunk = Int(le32(raw, base + idSize))
            guard !key.isEmpty, chunk > 0, chunks[key] == nil else { continue }
            guard chunk <= origin.length / chunkSize else { continue }
            chunks[key] = chunk
        }
        guard !chunks.isEmpty else { return nil }
        return Index(chunkSize: chunkSize, chunks: chunks)
    }

    /// Hyphenated IP serials (`T-9705N`) and the DAT id (`T9705N`) are the same key.
    /// A region-letter miss tries the other openMenu region letters for that stem.
    private nonisolated static func lookupKeys(for serial: String) -> [String] {
        let key = normalize(serial)
        guard !key.isEmpty else { return [] }
        var keys = [key]
        if key.count >= 5, let last = key.last, regionLetters.contains(last) {
            let stem = key.dropLast()
            for letter in regionLetters where letter != last {
                keys.append(stem + String(letter))
            }
        }
        return keys
    }

    private nonisolated static func normalize(_ raw: String) -> String {
        raw.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private nonisolated static func readFile(_ url: URL, offset: Int, count: Int) -> Data? {
        guard offset >= 0, count > 0, let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            guard UInt64(offset) < size else { return nil }
            let want = min(count, Int(size - UInt64(offset)))
            guard want == count else { return nil }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: want)
            return data?.count == want ? data : nil
        } catch {
            return nil
        }
    }

    private nonisolated static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private nonisolated final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private var key: String?
        private var index: Index?

        func index(for origin: Origin) -> Index? {
            lock.lock()
            if key == origin.cacheKey, let index {
                lock.unlock()
                return index
            }
            lock.unlock()
            let loaded = OpenMenuBoxArt.loadIndex(origin: origin)
            lock.lock()
            key = origin.cacheKey
            index = loaded
            lock.unlock()
            return loaded
        }
    }
}
