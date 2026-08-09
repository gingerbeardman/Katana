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

    var folderURL: URL {
        URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    /// Sort key for the Format table column (display-only sorting).
    var formatSortKey: String { format.displayName }

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
