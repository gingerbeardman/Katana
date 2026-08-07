import Foundation

enum VolumeIdentity: Sendable {
    /// Resolve volume metadata for a user-selected card root.
    nonisolated static func resolve(rootURL: URL) throws -> CardVolume {
        let values = try rootURL.resourceValues(forKeys: [
            .volumeUUIDStringKey,
            .volumeNameKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
            .volumeIsReadOnlyKey,
            .isDirectoryKey,
        ])

        guard values.isDirectory == true else {
            throw ScanError.notADirectory(rootURL)
        }

        // Prefer volume UUID; fall back to a stable path-based key for non-volume folders (dev fixtures).
        let uuid = values.volumeUUIDString
            ?? "path:" + rootURL.standardizedFileURL.path

        let name = values.volumeName
            ?? rootURL.lastPathComponent

        // Prefer the volume flag (covers hardware write-protect). Fall back to path writability
        // for non-volume folders (dev fixtures) or when the key is unavailable.
        let isReadOnly: Bool
        if let volumeRO = values.volumeIsReadOnly {
            isReadOnly = volumeRO
        } else {
            isReadOnly = !FileManager.default.isWritableFile(atPath: rootURL.path)
        }

        return CardVolume(
            rootURL: rootURL.standardizedFileURL,
            volumeUUID: uuid,
            volumeName: name,
            freeBytes: values.volumeAvailableCapacity.map { Int64($0) },
            totalBytes: values.volumeTotalCapacity.map { Int64($0) },
            isReadOnly: isReadOnly
        )
    }
}

enum ScanError: LocalizedError {
    case notADirectory(URL)
    case unreadable(URL, String)
    case noDiscImage(URL)

    var errorDescription: String? {
        switch self {
        case .notADirectory(let url):
            return "Not a directory: \(url.path)"
        case .unreadable(let url, let reason):
            return "Cannot read \(url.path): \(reason)"
        case .noDiscImage(let url):
            return "No disc image found in \(url.lastPathComponent)"
        }
    }
}
