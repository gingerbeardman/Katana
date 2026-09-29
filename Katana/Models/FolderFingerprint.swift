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
    /// openMenu `folder.txt` (empty/nil = unfiled).
    var folderTxt: String? = nil
    /// openMenu `type.txt` (`game` / `other` / `psx`).
    var typeTxt: String? = nil
    /// `folder_alt1.txt`…`folder_alt5.txt` values that exist on disk.
    var extraFolderTxt: [String] = []
    /// `disc.txt` (multi-disc `2/4`).
    var discTxt: String? = nil
    /// `region.txt` (`J`/`U`/`E`).
    var regionTxt: String? = nil
    /// `vga.txt` (`1`/`0`).
    var vgaTxt: String? = nil
    /// `version.txt`.
    var versionTxt: String? = nil
    /// `date.txt`.
    var dateTxt: String? = nil
    /// Number of regular files in the folder (from a cheap name listing).
    var fileCount: Int

    nonisolated static func modTimeSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    /// Same disc image file: name, size, and whole-second modification time.
    /// Sidecars and file count can change without this.
    nonisolated func identifiesSameDiscImage(as other: FolderFingerprint) -> Bool {
        imageFileName.caseInsensitiveCompare(other.imageFileName) == .orderedSame
            && imageSize == other.imageSize
            && imageModTimeSeconds == other.imageModTimeSeconds
    }

    /// Product code with case and punctuation removed (`DS-400BETA` == `ds400beta`).
    nonisolated static func normalizedSerial(_ raw: String?) -> String {
        guard let raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let allowed = CharacterSet.alphanumerics
        let collapsed = trimmed.uppercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(collapsed))
    }

    /// `serial.txt` names the disc. When it disagrees with the cached serial, the
    /// saved IP header belongs to the previous image — a save can stamp a new
    /// fingerprint onto that old entry, so fingerprint equality never sees it.
    /// Display name is left alone (GameDB titles and renames must survive).
    nonisolated static func adoptingSerial(
        _ entry: GameEntry,
        from fingerprint: FolderFingerprint
    ) -> GameEntry {
        let sidecar = fingerprint.serialTxt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let disk = normalizedSerial(sidecar)
        guard !disk.isEmpty, disk != normalizedSerial(entry.serial) else { return entry }
        var next = entry
        next.serial = sidecar
        next.ipHeader = nil
        return next
    }

    /// Entry to write after probing the card. A changed image or `serial.txt`
    /// invalidates the IP header that belonged to `stored`.
    nonisolated static func reconciling(
        _ game: GameEntry,
        stored: FolderFingerprint?,
        probed: FolderFingerprint
    ) -> (entry: GameEntry, correction: StaleDiscCorrection?) {
        var saved = adoptingSerial(game, from: probed)
        if let stored {
            let imageChanged = !stored.identifiesSameDiscImage(as: probed)
            let serialFileChanged = normalizedSerial(stored.serialTxt) != normalizedSerial(probed.serialTxt)
            if imageChanged || serialFileChanged {
                saved.ipHeader = nil
            }
        }
        guard saved.serial != game.serial || saved.ipHeader != game.ipHeader else {
            return (saved, nil)
        }
        return (
            saved,
            StaleDiscCorrection(
                id: game.id,
                previousSerial: game.serial,
                previousHeader: game.ipHeader,
                serial: saved.serial,
                ipHeader: saved.ipHeader
            )
        )
    }
}

/// In-memory row to update after a cache save dropped a stale IP header or serial.
/// Applied only when the row still matches `previousSerial` / `previousHeader`,
/// so a newer disc read is not overwritten.
nonisolated struct StaleDiscCorrection: Sendable, Equatable {
    var id: UUID
    var previousSerial: String
    var previousHeader: IpBinInfo?
    var serial: String
    var ipHeader: IpBinInfo?
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
