import Foundation

/// Parse Dreamcast `.gdi` cue sheets (including Redump-style quoted filenames with spaces).
enum GdiCue: Sendable {
    /// One track line: `index LBA type sectorSize filename [offset]`
    struct Track: Sendable, Equatable {
        var index: Int
        var lba: Int
        /// 0 = audio/raw, 4 = data (typical).
        var type: Int
        var sectorSize: Int
        var fileName: String
        var fileOffset: Int
    }

    /// All track lines in file order.
    nonisolated static func parseTracks(in text: String) -> [Track] {
        var tracks: [Track] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Track-count header is a single integer.
            if Int(line) != nil, !line.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) {
                continue
            }
            guard let track = parseTrackLine(line) else { continue }
            tracks.append(track)
        }
        return tracks
    }

    /// Leaf file names referenced by the cue (order preserved, de-duplicated).
    nonisolated static func referencedFileNames(in text: String) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for track in parseTracks(in: text) {
            let key = track.fileName.lowercased()
            if seen.insert(key).inserted {
                names.append(track.fileName)
            }
        }
        return names
    }

    /// Data tracks (type 4), high-density (LBA ≥ 45000) first — best places for IP.BIN.
    nonisolated static func dataTracksForIPBIN(in text: String) -> [Track] {
        let data = parseTracks(in: text).filter { $0.type == 4 }
        return data.sorted { a, b in
            let aHi = a.lba >= 45_000
            let bHi = b.lba >= 45_000
            if aHi != bHi { return aHi && !bHi }
            return a.lba < b.lba
        }
    }

    // MARK: - Line parse

    nonisolated private static func parseTrackLine(_ line: String) -> Track? {
        // Prefer quoted filename (Redump: … 2352 "Game (Track 1).bin" 0).
        let fileName: String
        let beforeFile: String
        let afterFile: String
        if let q1 = line.firstIndex(of: "\""),
           let q2 = line[line.index(after: q1)...].firstIndex(of: "\"")
        {
            fileName = normalizeFileName(String(line[line.index(after: q1)..<q2]))
            beforeFile = String(line[..<q1])
            afterFile = String(line[line.index(after: q2)...])
        } else {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // track LBA type sectorSize filename [offset]
            guard parts.count >= 5 else { return nil }
            fileName = normalizeFileName(parts[4])
            beforeFile = parts.prefix(4).joined(separator: " ")
            afterFile = parts.count > 5 ? parts[5...].joined(separator: " ") : "0"
        }

        let head = beforeFile.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard head.count >= 4,
              let index = Int(head[0]),
              let lba = Int(head[1]),
              let type = Int(head[2]),
              let sectorSize = Int(head[3])
        else { return nil }

        let tail = afterFile.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let fileOffset = tail.first.flatMap(Int.init) ?? 0
        guard !fileName.isEmpty else { return nil }

        return Track(
            index: index,
            lba: lba,
            type: type,
            sectorSize: sectorSize,
            fileName: fileName,
            fileOffset: fileOffset
        )
    }

    nonisolated private static func normalizeFileName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "\\", with: "/")
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        return name
    }
}
