import Foundation

/// Cheap identity of a numbered game folder for cache invalidation.
/// Avoids reading multi-hundred-MB disc images when nothing changed.
///
/// Intentionally does **not** sum every file’s size (expensive on FAT USB).
/// Uses image size/mtime + sidecar text + file *count* from a name listing.
nonisolated struct FolderFingerprint: Codable, Hashable, Sendable {
    var folderName: String
    var imageFileName: String
    var imageSize: Int64
    /// Whole seconds since reference date — avoids JSON date precision misses on cache hits.
    var imageModTimeSeconds: Int64
    var nameTxt: String?
    var serialTxt: String?
    /// Number of regular files in the folder (from a cheap name listing).
    var fileCount: Int

    nonisolated static func modTimeSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }
}

nonisolated struct CachedEntry: Codable, Hashable, Sendable {
    var fingerprint: FolderFingerprint
    var entry: GameEntry
}

nonisolated struct CardCache: Codable, Sendable {
    var volumeUUID: String
    var volumeName: String
    var rootPath: String
    var scannedAt: Date
    var entries: [CachedEntry]
}
