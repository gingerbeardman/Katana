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
    /// SHA-256 of payload when known (from `hash.dcgdsd` sidecar).
    var contentSHA256: String?
    var isMenu: Bool
    /// False after a fast scan until sizes / stored hashes are filled in the background.
    var detailsLoaded: Bool = true

    var folderURL: URL {
        URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    /// Sort key for the Format table column (display-only sorting).
    var formatSortKey: String { format.displayName }

    var hasContentHash: Bool {
        contentSHA256 != nil && !(contentSHA256?.isEmpty ?? true)
    }

    nonisolated static func isMenuName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.caseInsensitiveCompare("GDMENU") == .orderedSame
            || n.caseInsensitiveCompare("openMenu") == .orderedSame
    }
}
