import Foundation

struct ScanResult: Sendable {
    var volume: CardVolume
    var entries: [GameEntry]
    var cacheHits: Int
    var cacheMisses: Int
    /// Wall-clock scan duration in milliseconds.
    var durationMilliseconds: Int
}

/// Disc scanning runs **off the main actor** (project defaults to MainActor isolation).
///
/// Initial scan is intentionally **lazy**:
/// - Lists file *names*, finds the disc image, reads `name.txt` / `serial.txt`, stats the image only.
/// - Folder/payload sizes and hash sidecars load afterward via `loadFolderDetails`.
enum CardScanner: Sendable {
    private nonisolated static let nameFile = "name.txt"
    private nonisolated static let serialFile = "serial.txt"
    private nonisolated static let preferredImageNames = ["disc.gdi", "disc.cdi", "disc.ccd"]

    /// Progress event for live table fill (always off the main actor).
    struct ProgressEvent: Sendable {
        var entry: GameEntry
        var completed: Int
        var total: Int
    }

    /// Lightweight sizes + optional stored content hash (no disc payload hashing).
    struct FolderDetails: Sendable {
        var byteSize: Int64
        var payloadByteSize: Int64
        var contentSHA256: String?
    }

    /// Scan a GDEMU card root. Safe to call from any isolation domain.
    /// - Parameter onProgress: Invoked as each folder is identified (any order; UI should insert by slot).
    nonisolated static func scan(
        rootURL: URL,
        maxConcurrent: Int = 16,
        onProgress: (@Sendable (ProgressEvent) async -> Void)? = nil
    ) async throws -> ScanResult {
        // Entire scan body is nonisolated; hop to the cache actor only for load/save.
        try await Task.detached(priority: .userInitiated) {
            try await performScan(
                rootURL: rootURL,
                maxConcurrent: maxConcurrent,
                onProgress: onProgress
            )
        }.value
    }

    private nonisolated static func performScan(
        rootURL: URL,
        maxConcurrent: Int,
        onProgress: (@Sendable (ProgressEvent) async -> Void)?
    ) async throws -> ScanResult {
        let started = Date()
        let volume = try VolumeIdentity.resolve(rootURL: rootURL)
        let fm = FileManager.default

        let cached = try? await CardCacheStore.shared.load(volumeUUID: volume.volumeUUID)
        let cacheByFolder: [String: CachedEntry] = {
            guard let cached else { return [:] }
            return Dictionary(uniqueKeysWithValues: cached.entries.map { ($0.fingerprint.folderName, $0) })
        }()

        let children = try fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        )

        var numbered: [(Int, URL)] = []
        numbered.reserveCapacity(children.count)
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let name = child.lastPathComponent
            guard let number = FolderNumbering.parse(name) else { continue }
            numbered.append((number, child))
        }
        numbered.sort { $0.0 < $1.0 }

        let total = numbered.count
        var hits = 0
        var misses = 0
        var collected: [GameEntry] = []
        var cacheEntries: [CachedEntry] = []
        collected.reserveCapacity(total)
        cacheEntries.reserveCapacity(total)

        try await withThrowingTaskGroup(of: (Int, GameEntry, FolderFingerprint, Bool).self) { group in
            var iterator = numbered.makeIterator()

            func enqueueNext() -> Bool {
                guard let (number, url) = iterator.next() else { return false }
                let folderName = url.lastPathComponent
                let cachedEntry = cacheByFolder[folderName]
                group.addTask {
                    let result = try scanFolderFast(
                        number: number,
                        folderURL: url,
                        cached: cachedEntry
                    )
                    return (number, result.entry, result.fingerprint, result.cacheHit)
                }
                return true
            }

            for _ in 0..<min(maxConcurrent, total) {
                _ = enqueueNext()
            }

            for try await (_, entry, fingerprint, cacheHit) in group {
                if cacheHit { hits += 1 } else { misses += 1 }
                collected.append(entry)
                cacheEntries.append(CachedEntry(fingerprint: fingerprint, entry: entry))
                if let onProgress {
                    await onProgress(
                        ProgressEvent(entry: entry, completed: collected.count, total: total)
                    )
                }
                _ = enqueueNext()
            }
        }

        collected.sort { $0.number < $1.number }
        let byNumber = Dictionary(uniqueKeysWithValues: cacheEntries.map { ($0.entry.number, $0) })
        let orderedCache = collected.compactMap { byNumber[$0.number] }

        let cache = CardCache(
            volumeUUID: volume.volumeUUID,
            volumeName: volume.volumeName,
            rootPath: volume.rootPath,
            scannedAt: Date(),
            entries: orderedCache
        )
        try? await CardCacheStore.shared.save(cache)

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return ScanResult(
            volume: volume,
            entries: collected,
            cacheHits: hits,
            cacheMisses: misses,
            durationMilliseconds: ms
        )
    }

    // MARK: - Fast per-folder (initial scan)

    private struct FolderScan: Sendable {
        var entry: GameEntry
        var fingerprint: FolderFingerprint
        var cacheHit: Bool
    }

    /// Name listing + image stat + name/serial only. No full size walk, no hash validation.
    private nonisolated static func scanFolderFast(
        number: Int,
        folderURL: URL,
        cached: CachedEntry?
    ) throws -> FolderScan {
        let folderName = folderURL.lastPathComponent
        let fm = FileManager.default

        // Cheap: names only (no per-file size/mtime on the whole directory).
        let names = try fm.contentsOfDirectory(atPath: folderURL.path)
            .filter { !$0.hasPrefix(".") }
        let fileCount = names.count

        guard let imageName = detectImageName(in: names) else {
            throw ScanError.noDiscImage(folderURL)
        }
        let imageURL = folderURL.appendingPathComponent(imageName)
        let imageValues = try imageURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard imageValues.isRegularFile == true else {
            throw ScanError.noDiscImage(folderURL)
        }
        let imageSize = Int64(imageValues.fileSize ?? 0)
        let imageMod = imageValues.contentModificationDate ?? .distantPast

        let nameOnDisk = readSidecar(named: nameFile, in: folderURL)
        let serialOnDisk = readSidecar(named: serialFile, in: folderURL)

        let fingerprint = FolderFingerprint(
            folderName: folderName,
            imageFileName: imageName,
            imageSize: imageSize,
            imageModTimeSeconds: FolderFingerprint.modTimeSeconds(imageMod),
            nameTxt: nameOnDisk,
            serialTxt: serialOnDisk,
            fileCount: fileCount
        )

        // Cache hit: reuse full sizes/hash from last scan without re-walking the folder.
        if let cached, cached.fingerprint == fingerprint {
            var entry = cached.entry
            entry.number = number
            entry.folderPath = folderURL.path
            // Old cache rows may predate `detailsLoaded`; treat filled sizes as loaded.
            if !entry.detailsLoaded, entry.byteSize > 0 {
                entry.detailsLoaded = true
            }
            return FolderScan(entry: entry, fingerprint: fingerprint, cacheHit: true)
        }

        let format = formatForImage(imageName)
        let displayName: String = {
            if let nameOnDisk, !nameOnDisk.isEmpty { return nameOnDisk }
            let base = (imageName as NSString).deletingPathExtension
            if base.lowercased() != "disc" { return base }
            return folderName
        }()

        let serial = serialOnDisk ?? ""
        let isMenu = number == 1 || GameEntry.isMenuName(displayName)

        // Provisional sizes = image only; real totals fill in via loadFolderDetails.
        let entry = GameEntry(
            id: cached?.entry.id ?? UUID(),
            number: number,
            name: displayName,
            serial: serial,
            format: format,
            imageFileName: imageName,
            folderPath: folderURL.path,
            byteSize: imageSize,
            payloadByteSize: imageSize,
            contentSHA256: nil,
            isMenu: isMenu,
            detailsLoaded: false
        )

        return FolderScan(entry: entry, fingerprint: fingerprint, cacheHit: false)
    }

    // MARK: - Lazy details (after list is visible)

    /// Full folder size + payload size + stored hash sidecar (still no content hashing).
    nonisolated static func loadFolderDetails(folderURL: URL) throws -> FolderDetails {
        let contents = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var folderByteSize: Int64 = 0
        var payloadByteSize: Int64 = 0
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let size = Int64(values?.fileSize ?? 0)
            folderByteSize += size
            let lower = url.lastPathComponent.lowercased()
            if ContentHashSidecar.metadataNames.contains(lower) { continue }
            let ext = url.pathExtension.lowercased()
            if ContentHashSidecar.hashExtensions.contains(ext) { continue }
            if ContentHashSidecar.payloadExtensions.contains(ext) {
                payloadByteSize += size
            }
        }

        // Prefer cheap aggregate JSON; full validHash re-walks the folder for validation.
        let hash = ContentHashSidecar.readAggregate(in: folderURL)?.sha256
            ?? ContentHashSidecar.validHash(in: folderURL)?.sha256

        return FolderDetails(
            byteSize: folderByteSize,
            payloadByteSize: payloadByteSize > 0 ? payloadByteSize : folderByteSize,
            contentSHA256: hash
        )
    }

    // MARK: - Helpers

    private nonisolated static func detectImageName(in names: [String]) -> String? {
        let byLower = Dictionary(uniqueKeysWithValues: names.map { ($0.lowercased(), $0) })
        for preferred in preferredImageNames {
            if let name = byLower[preferred] { return name }
        }
        let priority: [String: Int] = ["gdi": 0, "cdi": 1, "ccd": 2]
        let ranked = names.compactMap { name -> (String, Int)? in
            let ext = (name as NSString).pathExtension.lowercased()
            guard let rank = priority[ext] else { return nil }
            return (name, rank)
        }
        return ranked.sorted { $0.1 < $1.1 }.first?.0
    }

    private nonisolated static func formatForImage(_ fileName: String) -> DiscFormat {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "gdi": return .gdi
        case "cdi": return .cdi
        case "ccd": return .ccd
        default: return .unknown
        }
    }

    private nonisolated static func readSidecar(named name: String, in folder: URL) -> String? {
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .isoLatin1)
        else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
