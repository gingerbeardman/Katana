import Foundation

nonisolated struct GameEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// Current GDEMU slot number (1 = menu).
    var number: Int
    var name: String
    var serial: String
    var format: DiscFormat
    /// Primary image filename inside the folder, e.g. `disc.gdi`.
    var imageFileName: String
    /// On-disk folder path.
    var folderPath: String
    /// Total size of folder contents (including sidecars). May be provisional until `detailsLoaded`.
    var byteSize: Int64
    /// Disc payload only (tracks/images) — used for size-based duplicate matching.
    var payloadByteSize: Int64
    /// SHA-256 of payload when known (from `katana.sha` or per-file sidecars).
    var contentSHA256: String?
    var isMenu: Bool
    /// False after a fast scan until sizes / stored hashes are filled in the background.
    /// Default **false** so missing JSON keys (older caches) re-enrich instead of sticking at 0 MB.
    var detailsLoaded: Bool = false
    /// Cached IP.BIN fields for LIST.INI rebuild (avoids re-reading every GDI on the card).
    /// Filled on import / enrichment / inspector; cleared when the disc image hash changes.
    var ipHeader: IpBinInfo? = nil
    /// openMenu virtual folder path (`Games\RPGs`), from `folder.txt` / `OPENMENU.INI`.
    var virtualFolder: String = ""
    /// Extra openMenu folder paths (up to 5) so a disc can appear in more than one folder.
    var extraFolders: [String] = []
    /// openMenu disc kind (`type.txt` / `type=`). Ignored by GDmenu.
    var discType: OpenMenuItemType = .game
    /// Override for `N.disc=` / `disc.txt` (e.g. `2/4`). Empty → IP.BIN disc field.
    var discLabel: String = ""
    /// Override for `N.region=` / `region.txt` (JUE). Empty → IP.BIN region field.
    var regionLabel: String = ""

    var folderURL: URL {
        URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    /// Sort key for the Format table column (display-only sorting).
    var formatSortKey: String { format.displayName }

    /// Sort key for the Folder table column (display-only).
    var virtualFolderSortKey: String { virtualFolder }

    /// Sort key for the Type table column (display-only).
    var discTypeSortKey: String { discType.displayName }

    /// Sort key for the Disc table column (display-only).
    var discLabelSortKey: String { resolvedDisc() }

    /// Sidecars that only openMenu Extended bakes (`folder.txt` / extras / non-game type).
    var hasOpenMenuFolderMeta: Bool {
        guard !isMenu, number != 1 else { return false }
        return !virtualFolder.isEmpty || !extraFolders.isEmpty || discType != .game
    }

    /// Disc number written to LIST/OPENMENU (`2/4`), preferring `disc.txt`.
    func resolvedDisc(ip: IpBinInfo? = nil) -> String {
        if !discLabel.isEmpty { return discLabel }
        let fromIP = (ip ?? ipHeader)?.disc ?? ""
        return fromIP.isEmpty ? "1/1" : fromIP
    }

    /// Region flags written to LIST/OPENMENU (`JUE`), preferring `region.txt`.
    func resolvedRegion(ip: IpBinInfo? = nil) -> String {
        if !regionLabel.isEmpty { return regionLabel }
        let fromIP = (ip ?? ipHeader)?.region ?? ""
        return fromIP.isEmpty ? "JUE" : fromIP
    }

    var hasContentHash: Bool {
        contentSHA256 != nil && !(contentSHA256?.isEmpty ?? true)
    }

    /// Whether lazy folder walk should still run for sizes / hash sidecars / missing IP header.
    ///
    /// GDI `disc.gdi` is a tiny cue file; provisional fast-scan size is often &lt; 1 MB and
    /// used to be mistaken for “fully loaded,” leaving the Size column at **0 MB**.
    var needsDetailEnrichment: Bool {
        if !detailsLoaded { return true }
        if byteSize <= 0 { return true }
        // Provisional GDI image-only size (cue text), not full track payload.
        if format == .gdi, byteSize < 1_000_000 { return true }
        // Warm menu rebuilds: fill IP headers while sizes load (skip menu slot defaults).
        if ipHeader == nil, !isMenu, number != 1 { return true }
        return false
    }

    nonisolated static func isMenuName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.caseInsensitiveCompare("GDMENU") == .orderedSame
            || n.caseInsensitiveCompare("openMenu") == .orderedSame
    }
}
