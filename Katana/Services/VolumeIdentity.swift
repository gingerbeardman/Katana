import Foundation

enum VolumeIdentity: Sendable {
    /// Prefix for minted IDs when the filesystem exposes no volume UUID.
    /// Survives path/name renames when persisted on `RememberedVolume`.
    nonisolated static let stableIDPrefix = "stable:"

    /// Legacy path-based keys (pre-stable-ID). Still recognized for continuity.
    nonisolated static let pathIDPrefix = "path:"

    /// Resolve volume metadata for a user-selected card root.
    ///
    /// Identity priority (bookmark = access; this = cache/recents key):
    /// 1. `preferredUUID` from a prior open / remembered card — **wins** so Finder renames
    ///    and flaky FAT volume UUIDs do not orphan the scan cache (cold 5s+ rescan).
    /// 2. Disk volume UUID when the OS provides one and nothing is preferred
    /// 3. Mint `stable:<uuid>` once — caller must persist via `VolumeStore.remember`
    ///
    /// Never keys on volume *name* alone. Path is not used as a new identity.
    /// - Parameter preferredUUID: Known identity from recents / an earlier resolve in the
    ///   same open so path-only roots keep one key across renames and double resolves.
    nonisolated static func resolve(
        rootURL: URL,
        preferredUUID: String? = nil
    ) throws -> CardVolume {
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

        let uuid = stableVolumeUUID(
            diskUUID: values.volumeUUIDString,
            preferredUUID: preferredUUID
        )

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

        // Keep the caller’s URL instance. `.standardizedFileURL` drops security-scope
        // (App Sandbox write access) — same trap 2UP/Brutify avoid for granted roots.
        return CardVolume(
            rootURL: rootURL,
            volumeUUID: uuid,
            volumeName: name,
            freeBytes: values.volumeAvailableCapacity.map { Int64($0) },
            totalBytes: values.volumeTotalCapacity.map { Int64($0) },
            isReadOnly: isReadOnly
        )
    }

    /// Choose a durable cache/recents key.
    /// Preferred (remembered) wins — some SD / FAT stacks report a new `volumeUUIDString`
    /// after remount or Finder rename, which previously fragmented the scan cache.
    nonisolated static func stableVolumeUUID(
        diskUUID: String?,
        preferredUUID: String?
    ) -> String {
        if let preferred = preferredUUID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty
        {
            return preferred
        }
        if let disk = diskUUID?.trimmingCharacters(in: .whitespacesAndNewlines), !disk.isEmpty {
            return disk
        }
        return stableIDPrefix + UUID().uuidString
    }

    /// True when `id` was minted locally (no OS volume UUID).
    nonisolated static func isMintedStableID(_ id: String) -> Bool {
        id.hasPrefix(stableIDPrefix)
    }

    /// True when `id` is a legacy path-derived key.
    nonisolated static func isPathDerivedID(_ id: String) -> Bool {
        id.hasPrefix(pathIDPrefix)
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
            return "No disc image (.gdi / .cdi / .ccd) found in \(url.lastPathComponent)"
        }
    }
}
