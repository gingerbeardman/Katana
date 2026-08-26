import Foundation

/// openMenu `type=` / `type.txt` value. `Other` skips the game boot and returns
/// to the BIOS (audio CDs, VCDs); `PSX` uses the Bleemcast/Bloom launcher.
nonisolated enum OpenMenuItemType: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case game
    case other
    case psx

    var id: String { rawValue }

    /// Value written to `type.txt` and `OPENMENU.INI`.
    var fileValue: String { rawValue }

    var displayName: String {
        switch self {
        case .game: return "Game"
        case .other: return "Other"
        case .psx: return "PSX"
        }
    }

    var helpText: String {
        switch self {
        case .game: return "Standard Dreamcast game."
        case .other: return "Non-game disc (audio CD, VCD). openMenu exits to BIOS."
        case .psx: return "PlayStation disc for Bleemcast! or Bloom."
        }
    }

    static func parse(_ raw: String?) -> OpenMenuItemType {
        guard let raw else { return .game }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "other": return .other
        case "psx": return .psx
        default: return .game
        }
    }
}

/// Virtual-folder path helpers matching openMenu / GDMENU Card Manager on-disk layout.
enum OpenMenuFolderPath: Sendable {
    /// Complete path including backslashes (openMenu limit).
    static let maxLength = 256
    /// Nested subfolder depth supported by openMenu.
    static let maxDepth = 8

    /// Normalize a user or sidecar path: backslashes, ASCII, trimmed empty segments.
    nonisolated static func cleaned(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "/", with: "\\")
            .replacingOccurrences(of: "\n", with: "\\")
        var segments: [String] = []
        for part in normalized.split(separator: "\\", omittingEmptySubsequences: false) {
            let trimmed = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let ascii = String(trimmed.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F })
            let clipped = ascii.count > 256 ? String(ascii.prefix(256)) : ascii
            if !clipped.isEmpty { segments.append(clipped) }
            if segments.count >= maxDepth { break }
        }
        var joined = segments.joined(separator: "\\")
        if joined.count > maxLength {
            joined = String(joined.prefix(maxLength))
            if let last = joined.lastIndex(of: "\\") {
                joined = String(joined[..<last])
            }
        }
        return joined
    }

    /// `Games\RPGs` → `["Games", "Games\\RPGs"]`.
    nonisolated static func prefixes(of path: String) -> [String] {
        let cleanedPath = cleaned(path)
        guard !cleanedPath.isEmpty else { return [] }
        let parts = cleanedPath.split(separator: "\\").map(String.init)
        var acc: [String] = []
        var result: [String] = []
        result.reserveCapacity(parts.count)
        for part in parts {
            acc.append(part)
            result.append(acc.joined(separator: "\\"))
        }
        return result
    }

    /// Distinct virtual-folder paths already used on the card (primary + extras + parents), sorted.
    nonisolated static func knownFolders(in games: [GameEntry]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for game in games {
            if game.isMenu || game.number == 1 { continue }
            for raw in [game.virtualFolder] + game.extraFolders {
                for prefix in prefixes(of: raw) {
                    guard !seen.contains(prefix) else { continue }
                    seen.insert(prefix)
                    result.append(prefix)
                }
            }
        }
        result.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return result
    }

    /// Up to five extra paths, cleaned and de-duplicated (case-sensitive, same as GCM).
    nonisolated static func cleanedExtras(_ raw: [String], excluding primary: String) -> [String] {
        var seen = Set<String>()
        if !primary.isEmpty { seen.insert(primary) }
        var result: [String] = []
        for item in raw {
            let path = cleaned(item)
            guard !path.isEmpty, !seen.contains(path) else { continue }
            seen.insert(path)
            result.append(path)
            if result.count == 5 { break }
        }
        return result
    }
}

/// `serial.txt` / `N.product=` — printable ASCII, max 12 (GDMENU Card Manager).
enum OpenMenuSerial: Sendable {
    static let maxLength = 12

    nonisolated static func cleaned(_ raw: String) -> String {
        let ascii = String(
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .unicodeScalars
                .filter { $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }
        )
        if ascii.count <= maxLength { return ascii }
        return String(ascii.prefix(maxLength))
    }
}

/// `disc.txt` / `N.disc=` (e.g. `1/4`). Empty means “use the IP.BIN disc field”.
enum OpenMenuDiscLabel: Sendable {
    static let maxLength = 12

    nonisolated static func cleaned(_ raw: String) -> String {
        let ascii = String(
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .unicodeScalars
                .filter { $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }
        )
        if ascii.count <= maxLength { return ascii }
        return String(ascii.prefix(maxLength))
    }
}

/// `region.txt` / `N.region=` — any mix of J/U/E, stored in JUE order.
enum OpenMenuRegion: Sendable {
    nonisolated static func cleaned(_ raw: String) -> String {
        var j = false, u = false, e = false
        for ch in raw.uppercased() {
            switch ch {
            case "J": j = true
            case "U": u = true
            case "E": e = true
            default: break
            }
        }
        return (j ? "J" : "") + (u ? "U" : "") + (e ? "E" : "")
    }
}
