import Foundation

/// Bundled Dreamcast title lookup keyed by IP.BIN product / Redump serial.
///
/// Source: [GameDB-Dreamcast](https://github.com/niemasd/GameDB-Dreamcast) (GPL-3.0),
/// rebuilt via `Tools/scripts/build-gamedb.py` into `Resources/GameDB/dreamcast-titles.json`.
/// Opt out of default MainActor isolation — title lookup runs during card scan off-main.
nonisolated enum GameDatabase: Sendable {
    struct Entry: Sendable, Hashable {
        var title: String
        var region: String
        /// Canonical catalog / Redump ID from the source database.
        var id: String
    }

    /// Prefer on-disk `name.txt`, then DB title for a serial, then IP.BIN name, then fallbacks.
    nonisolated static func resolveDisplayName(
        nameTxt: String?,
        serialTxt: String?,
        ip: IpBinInfo?,
        imageFileName: String,
        folderName: String
    ) -> (name: String, serial: String) {
        let serialFromDisk = serialTxt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let serialFromIP = ip?.productNumber.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let serial = !serialFromDisk.isEmpty ? serialFromDisk : serialFromIP

        if let nameTxt {
            let n = nameTxt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty {
                return (n, serial)
            }
        }

        if let hit = lookup(serial: serial) {
            return (hit.title, serial)
        }
        // Retry with IP product if serial.txt was garbage / non-matching.
        if serial != serialFromIP, let hit = lookup(serial: serialFromIP) {
            return (hit.title, serialFromIP.isEmpty ? serial : serialFromIP)
        }

        if let ipName = ip?.name.trimmingCharacters(in: .whitespacesAndNewlines), !ipName.isEmpty {
            // IP.BIN product names are often ALL CAPS; light title-case for display only.
            return (ipName.localizedCapitalized, serial)
        }

        let base = (imageFileName as NSString).deletingPathExtension
        if base.lowercased() != "disc", !base.isEmpty {
            return (base, serial)
        }
        return (folderName, serial)
    }

    /// Look up a pretty title by product serial (tries normalized aliases).
    nonisolated static func lookup(serial: String?) -> Entry? {
        guard let serial else { return nil }
        let keys = lookupKeys(for: serial)
        guard !keys.isEmpty else { return nil }
        let table = sharedTitles
        for key in keys {
            if let entry = table[key] {
                return entry
            }
        }
        return nil
    }

    nonisolated static func title(for serial: String?) -> String? {
        lookup(serial: serial)?.title
    }

    // MARK: - Keys

    /// Ordered candidate keys for a product string from the card / IP.BIN.
    nonisolated static func lookupKeys(for raw: String) -> [String] {
        let s = normalize(raw)
        guard !s.isEmpty else { return [] }

        var keys: [String] = []
        var seen = Set<String>()

        func add(_ x: String) {
            let k = normalize(x)
            guard !k.isEmpty, !seen.contains(k) else { return }
            seen.insert(k)
            keys.append(k)
        }

        add(s)
        add(s.replacingOccurrences(of: "-", with: ""))

        if s.hasPrefix("MK-") {
            let rest = String(s.dropFirst(3))
            add(rest)
            add(rest.replacingOccurrences(of: "-", with: ""))
            add("MK" + rest.replacingOccurrences(of: "-", with: ""))
        } else if s.hasPrefix("MK"), s.count > 2 {
            let rest = String(s.dropFirst(2))
            add(rest)
            add("MK-" + rest)
        }

        if s.hasPrefix("T-") {
            let rest = String(s.dropFirst(2))
            add(rest)
            add(rest.replacingOccurrences(of: "-", with: ""))
            add("T" + rest.replacingOccurrences(of: "-", with: ""))
        } else if s.hasPrefix("T"), s.count > 1, s.dropFirst().first?.isNumber == true {
            let rest = String(s.dropFirst())
            add(rest)
            add("T-" + rest)
        }

        if s.hasPrefix("HDR-") {
            let rest = String(s.dropFirst(4))
            add(rest)
            add(rest.replacingOccurrences(of: "-", with: ""))
            add("HDR" + rest.replacingOccurrences(of: "-", with: ""))
        } else if s.hasPrefix("HDR"), s.count > 3 {
            let rest = String(s.dropFirst(3))
            add(rest)
            add("HDR-" + rest)
        }

        if s.allSatisfy(\.isNumber) {
            add("MK-" + s)
            add("MK" + s)
        }

        return keys
    }

    nonisolated static func normalize(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Load

    private struct FileRoot: Decodable, Sendable {
        var version: Int?
        var titles: [String: FileEntry]
    }

    private struct FileEntry: Decodable, Sendable {
        var title: String
        var region: String?
        var id: String?
    }

    /// Lazy, process-wide table (immutable after load).
    private static let sharedTitles: [String: Entry] = {
        LaunchTrace.mark("GameDatabase.sharedTitles lazy init")
        return loadFromBundle()
    }()

    nonisolated private static func loadFromBundle() -> [String: Entry] {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "dreamcast-titles", withExtension: "json", subdirectory: "GameDB"),
            Bundle.main.url(forResource: "dreamcast-titles", withExtension: "json"),
            Bundle.main.resourceURL?.appendingPathComponent("GameDB/dreamcast-titles.json"),
            Bundle.main.resourceURL?.appendingPathComponent("dreamcast-titles.json"),
        ]
        for case let url? in candidates {
            if let map = LaunchTrace.measure("GameDatabase.loadTitles \(url.lastPathComponent)", {
                loadTitles(from: url)
            }) {
                LaunchTrace.mark("GameDatabase loaded \(map.count) titles from \(url.path)")
                return map
            }
        }
        LaunchTrace.mark("GameDatabase.loadFromBundle: empty")
        return [:]
    }

    /// Load a titles map from disk (tests / tooling).
    nonisolated static func loadTitles(from url: URL) -> [String: Entry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return loadTitles(data: data)
    }

    nonisolated static func loadTitles(data: Data) -> [String: Entry]? {
        guard let root = try? JSONDecoder().decode(FileRoot.self, from: data) else { return nil }
        var map: [String: Entry] = [:]
        map.reserveCapacity(root.titles.count)
        for (key, value) in root.titles {
            let title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            map[normalize(key)] = Entry(
                title: title,
                region: value.region ?? "",
                id: value.id ?? key
            )
        }
        return map
    }

    /// Test helper: entry count after load.
    nonisolated static var entryCount: Int { sharedTitles.count }
}
