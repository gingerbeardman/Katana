import Foundation

/// Sources for bulk “Automatically Rename” (GDMENU Card Manager parity).
enum AutoRenameSource: String, CaseIterable, Identifiable, Sendable {
    case ipBin
    case folderName
    case fileName

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .ipBin: return "Using IP.BIN Info"
        case .folderName: return "Using Folder Name"
        case .fileName: return "Using File Name"
        }
    }

    var helpText: String {
        switch self {
        case .ipBin:
            return "GameDB title for the game serial, or the product name from IP.BIN."
        case .folderName:
            return "Use the on-card folder name (slot number unless you renamed the folder)."
        case .fileName:
            return "Use the disc image file name without extension (e.g. track03.iso → track03)."
        }
    }

    /// Suggested `name.txt` for this game, or `nil` if this source has nothing useful.
    nonisolated func suggestedName(for game: GameEntry) -> String? {
        switch self {
        case .ipBin:
            let ip = IpBinReader.read(from: game)
            if let title = GameDatabase.title(for: game.serial)
                ?? GameDatabase.title(for: ip?.productNumber)
            {
                return title
            }
            if let raw = ip?.name.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                return raw.localizedCapitalized
            }
            return nil

        case .folderName:
            let name = game.folderURL.lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            // Pure GDEMU slot folders (01, 002, …) are not useful titles.
            if FolderNumbering.parse(name) != nil { return nil }
            return Self.prettify(name)

        case .fileName:
            let base = (game.imageFileName as NSString)
                .deletingPathExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else { return nil }
            // Generic manager names — not useful as a game title.
            if base.lowercased() == "disc" { return nil }
            return Self.prettify(base)
        }
    }

    /// Underscores/dots → spaces; collapse runs of whitespace.
    nonisolated private static func prettify(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: ".", with: " ")
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
