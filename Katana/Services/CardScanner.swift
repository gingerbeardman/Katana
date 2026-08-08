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
/// - No IP.BIN open on the fast path (name.txt / serial.txt + GameDB is enough for first paint).
/// - Folder/payload sizes and hash sidecars load afterward via `loadFolderDetails`.
enum CardScanner: Sendable {
    private nonisolated static let nameFile = "name.txt"
    private nonisolated static let serialFile = "serial.txt"
    private nonisolated static let preferredImageNames = ["disc.gdi", "disc.cdi", "disc.ccd"]

    /// How many folders to deliver to the UI in one MainActor hop (avoids 1-hop-per-row thrash).
    private nonisolated static let progressBatchSize = 24

    /// Concurrent folder workers. Moderate on purpose — FAT/exFAT SD hates high fan-out.
    private nonisolated static let defaultMaxConcurrent = 8

    /// Progress event for live table fill (always off the main actor).
    struct ProgressEvent: Sendable {
        /// One or more entries to insert (same batch → one UI update).
        var entries: [GameEntry]
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
    /// - Parameter preferSnapshotCache: When true (default), if a saved `CardCache` for this volume
    ///   lists the exact same slot folders as the live card, return that snapshot without per-folder I/O.
    ///   Pass false for Rescan / Clear Cache so fingerprints and names are refreshed from disk.
    /// - Parameter preferredVolumeUUID: Identity from recents / an earlier resolve in the same open so
    ///   path-only roots keep one cache key across renames (see `VolumeIdentity.resolve`).
    /// - Parameter onProgress: Invoked in batches as folders are identified (UI should insert by slot).
    nonisolated static func scan(
        rootURL: URL,
        maxConcurrent: Int = defaultMaxConcurrent,
        preferSnapshotCache: Bool = true,
        preferredVolumeUUID: String? = nil,
        onProgress: (@Sendable (ProgressEvent) async -> Void)? = nil
    ) async throws -> ScanResult {
        // Explicit detach: default MainActor isolation + SD I/O must never beachball the UI
        // during resolve / root listing / cache decode before first progress.
        try await Task.detached(priority: .userInitiated) {
            try await performScan(
                rootURL: rootURL,
                maxConcurrent: maxConcurrent,
                preferSnapshotCache: preferSnapshotCache,
                preferredVolumeUUID: preferredVolumeUUID,
                onProgress: onProgress
            )
        }.value
    }

    /// Load a previously saved card cache if the live slot-folder set still matches.
    /// Used for recent-card reopen — one root directory listing, no per-game stats.
    nonisolated static func loadSnapshotIfValid(
        rootURL: URL,
        preferredVolumeUUID: String? = nil
    ) async throws -> ScanResult? {
        let started = Date()
        let volume = try VolumeIdentity.resolve(rootURL: rootURL, preferredUUID: preferredVolumeUUID)
        let liveFolders = try numberedFolderNames(at: rootURL)
        guard let cache = try? await CardCacheStore.shared.load(volumeUUID: volume.volumeUUID) else {
            return nil
        }
        guard let result = snapshotResultIfValid(
            rootURL: rootURL,
            volume: volume,
            cache: cache,
            liveFolderNames: liveFolders,
            started: started
        ) else { return nil }
        return result
    }

    /// Build a snapshot scan result when the on-disk slot-folder set matches the cache.
    nonisolated private static func snapshotResultIfValid(
        rootURL: URL,
        volume: CardVolume,
        cache: CardCache,
        liveFolderNames: Set<String>,
        started: Date
    ) -> ScanResult? {
        guard !cache.entries.isEmpty else { return nil }
        let cachedFolders = Set(cache.entries.map(\.fingerprint.folderName))
        guard liveFolderNames == cachedFolders else { return nil }

        let entries: [GameEntry] = cache.entries.compactMap { cached in
            var entry = cached.entry
            let folderName = cached.fingerprint.folderName
            guard let number = FolderNumbering.parse(folderName) else { return nil }
            entry.number = number
            entry.folderPath = rootURL.appendingPathComponent(folderName, isDirectory: true).path
            // Keep stored `detailsLoaded` — do not treat provisional image-only sizes
            // (tiny GDI cue files) as final, or Size stays at 0 MB forever.
            return entry
        }
        .sorted { $0.number < $1.number }

        guard entries.count == liveFolderNames.count, !entries.isEmpty else { return nil }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return ScanResult(
            volume: volume,
            entries: entries,
            cacheHits: entries.count,
            cacheMisses: 0,
            durationMilliseconds: ms
        )
    }

    private nonisolated static func performScan(
        rootURL: URL,
        maxConcurrent: Int,
        preferSnapshotCache: Bool,
        preferredVolumeUUID: String?,
        onProgress: (@Sendable (ProgressEvent) async -> Void)?
    ) async throws -> ScanResult {
        let started = Date()
        LaunchTrace.mark("CardScanner.performScan begin preferSnapshot=\(preferSnapshotCache)")
        let volume = try LaunchTrace.measure("CardScanner VolumeIdentity.resolve") {
            try VolumeIdentity.resolve(rootURL: rootURL, preferredUUID: preferredVolumeUUID)
        }

        // One root inventory + one cache load — shared by snapshot check and full scan.
        let numbered = try LaunchTrace.measure("CardScanner.numberedFolderURLs") {
            try numberedFolderURLs(at: rootURL)
        }
        let liveFolderNames = Set(numbered.map { $0.1.lastPathComponent })
        LaunchTrace.mark("CardScanner numbered folders=\(numbered.count)")

        let cached = try await LaunchTrace.measureAsync("CardCacheStore.load") {
            try? await CardCacheStore.shared.load(volumeUUID: volume.volumeUUID)
        }
        LaunchTrace.mark("CardCacheStore.load entries=\(cached?.entries.count ?? 0)")

        if preferSnapshotCache, let cached {
            let snapshot = LaunchTrace.measure("CardScanner snapshot check") {
                snapshotResultIfValid(
                    rootURL: rootURL,
                    volume: volume,
                    cache: cached,
                    liveFolderNames: liveFolderNames,
                    started: started
                )
            }
            if let snapshot {
                LaunchTrace.mark("CardScanner snapshot HIT \(snapshot.entries.count) entries")
                // Paint every row at once so “Show duplicates only” / markers never sit on an empty table.
                if let onProgress, !snapshot.entries.isEmpty {
                    await onProgress(
                        ProgressEvent(
                            entries: snapshot.entries,
                            completed: snapshot.entries.count,
                            total: snapshot.entries.count
                        )
                    )
                }
                return snapshot
            }
            LaunchTrace.mark("CardScanner snapshot MISS")
        }

        // uniquingKeysWith: corrupt caches may repeat folder names after partial renumbers.
        let cacheByFolder: [String: CachedEntry] = {
            guard let cached else { return [:] }
            return Dictionary(
                cached.entries.map { ($0.fingerprint.folderName, $0) },
                uniquingKeysWith: { _, last in last }
            )
        }()

        let total = numbered.count
        var hits = 0
        var misses = 0
        var collected: [GameEntry] = []
        var cacheEntries: [CachedEntry] = []
        collected.reserveCapacity(total)
        cacheEntries.reserveCapacity(total)

        var progressBatch: [GameEntry] = []
        progressBatch.reserveCapacity(progressBatchSize)

        func flushProgress(force: Bool = false) async {
            guard let onProgress else {
                progressBatch.removeAll(keepingCapacity: true)
                return
            }
            guard force ? !progressBatch.isEmpty : progressBatch.count >= progressBatchSize else { return }
            let batch = progressBatch
            progressBatch.removeAll(keepingCapacity: true)
            await onProgress(
                ProgressEvent(entries: batch, completed: collected.count, total: total)
            )
        }

        // First paint: one row per slot (cache hit → real data, else stub) so the list
        // height is final immediately — no row insertion jump while workers run.
        if let onProgress, total > 0 {
            let firstPaint: [GameEntry] = LaunchTrace.measure("CardScanner build firstPaint") {
                numbered.map { number, url in
                    let folderName = url.lastPathComponent
                    if var entry = cacheByFolder[folderName]?.entry {
                        entry.number = number
                        entry.folderPath = url.path
                        // Respect stored detailsLoaded (provisional GDI sizes stay pending).
                        return entry
                    }
                    return GameEntry(
                        id: UUID(),
                        number: number,
                        name: "…",
                        serial: "",
                        format: .unknown,
                        imageFileName: "",
                        folderPath: url.path,
                        byteSize: 0,
                        payloadByteSize: 0,
                        contentSHA256: nil,
                        isMenu: number == 1,
                        detailsLoaded: false
                    )
                }
            }
            await LaunchTrace.measureAsync("CardScanner firstPaint onProgress") {
                await onProgress(
                    ProgressEvent(entries: firstPaint, completed: 0, total: total)
                )
            }
        }

        try await withThrowingTaskGroup(of: (Int, GameEntry, FolderFingerprint, Bool).self) { group in
            var iterator = numbered.makeIterator()
            let limit = max(1, min(maxConcurrent, total))

            func enqueueNext() -> Bool {
                guard let (number, url) = iterator.next() else { return false }
                let folderName = url.lastPathComponent
                let cachedEntry = cacheByFolder[folderName]
                group.addTask(priority: .userInitiated) {
                    let result = try scanFolderFast(
                        number: number,
                        folderURL: url,
                        cached: cachedEntry
                    )
                    return (number, result.entry, result.fingerprint, result.cacheHit)
                }
                return true
            }

            for _ in 0..<limit {
                _ = enqueueNext()
            }

            for try await (_, entry, fingerprint, cacheHit) in group {
                // Keep workers fed *before* waiting on UI — MainActor hops used to starve the pool.
                _ = enqueueNext()

                if cacheHit { hits += 1 } else { misses += 1 }
                collected.append(entry)
                cacheEntries.append(CachedEntry(fingerprint: fingerprint, entry: entry))
                progressBatch.append(entry)
                await flushProgress()
            }
        }

        await flushProgress(force: true)

        collected.sort { $0.number < $1.number }
        let byFolder = Dictionary(
            cacheEntries.map { ($0.fingerprint.folderName, $0) },
            uniquingKeysWith: { _, last in last }
        )
        let orderedCache = collected.compactMap { entry in
            byFolder[URL(fileURLWithPath: entry.folderPath).lastPathComponent]
        }

        let cache = CardCache(
            volumeUUID: volume.volumeUUID,
            volumeName: volume.volumeName,
            rootPath: volume.rootPath,
            scannedAt: Date(),
            entries: orderedCache
        )
        // Don't block returning the list on cache write.
        Task.detached(priority: .utility) {
            try? await CardCacheStore.shared.save(cache)
        }

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

    /// Name listing + image stat + name/serial only. No full size walk, no IP.BIN, no hash validation.
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
        let imageValues = try imageURL.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
        ])
        guard imageValues.isRegularFile == true else {
            throw ScanError.noDiscImage(folderURL)
        }
        let imageSize = Int64(imageValues.fileSize ?? 0)
        let imageMod = imageValues.contentModificationDate ?? .distantPast

        // Prefer path existence from the name listing — avoids an extra stat per sidecar.
        let nameOnDisk = names.contains(where: { $0.caseInsensitiveCompare(nameFile) == .orderedSame })
            ? readSidecar(named: nameFile, in: folderURL)
            : nil
        let serialOnDisk = names.contains(where: { $0.caseInsensitiveCompare(serialFile) == .orderedSame })
            ? readSidecar(named: serialFile, in: folderURL)
            : nil

        let fingerprint = FolderFingerprint(
            folderName: folderName,
            imageFileName: imageName,
            imageSize: imageSize,
            imageModTimeSeconds: FolderFingerprint.modTimeSeconds(imageMod),
            nameTxt: nameOnDisk,
            serialTxt: serialOnDisk,
            fileCount: fileCount
        )

        // Cache hit: reuse entry fields; only trust sizes when details were fully enriched.
        if let cached, cached.fingerprint == fingerprint {
            var entry = cached.entry
            entry.number = number
            entry.folderPath = folderURL.path
            // Never promote provisional image-only sizes to “loaded” — GDI cue files are tiny.
            return FolderScan(entry: entry, fingerprint: fingerprint, cacheHit: true)
        }

        let format = formatForImage(imageName)

        // Fast path: never open disc images. name.txt → GameDB(serial.txt) → folder/image.
        // IP.BIN is reserved for rebuild list generation / inspector, not first paint.
        let resolved = GameDatabase.resolveDisplayName(
            nameTxt: nameOnDisk,
            serialTxt: serialOnDisk,
            ip: nil,
            imageFileName: imageName,
            folderName: folderName
        )
        let displayName = resolved.name
        let serial = resolved.serial
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

        // Prefer cheap aggregate JSON; skip full validHash re-walk on first enrich.
        let hash = ContentHashSidecar.readAggregate(in: folderURL)?.sha256

        return FolderDetails(
            byteSize: folderByteSize,
            payloadByteSize: payloadByteSize > 0 ? payloadByteSize : folderByteSize,
            contentSHA256: hash
        )
    }

    // MARK: - Root inventory

    /// Slot folder names currently on the card (one root readdir).
    nonisolated static func numberedFolderNames(at rootURL: URL) throws -> Set<String> {
        Set(try numberedFolderURLs(at: rootURL).map { $0.1.lastPathComponent })
    }

    /// One folder per slot number; prefers ideal width (`01` vs `001`).
    nonisolated private static func numberedFolderURLs(at rootURL: URL) throws -> [(Int, URL)] {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var bestByNumber: [Int: URL] = [:]
        bestByNumber.reserveCapacity(children.count)
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let name = child.lastPathComponent
            guard let number = FolderNumbering.parse(name) else { continue }
            if let existing = bestByNumber[number] {
                let existingName = existing.lastPathComponent
                let ideal = FolderNumbering.format(number)
                let preferNew = name == ideal
                    || (existingName != ideal && name.count > existingName.count)
                if preferNew {
                    bestByNumber[number] = child
                }
            } else {
                bestByNumber[number] = child
            }
        }
        return bestByNumber.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    // MARK: - Helpers

    private nonisolated static func detectImageName(in names: [String]) -> String? {
        // Prefer O(n) scan over building a full dictionary for tiny folders.
        var byLower: [String: String] = [:]
        byLower.reserveCapacity(min(names.count, 16))
        for name in names {
            byLower[name.lowercased()] = name
        }
        for preferred in preferredImageNames {
            if let name = byLower[preferred] { return name }
        }
        let priority: [String: Int] = ["gdi": 0, "cdi": 1, "ccd": 2]
        var best: (String, Int)?
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            guard let rank = priority[ext] else { continue }
            if best == nil || rank < best!.1 {
                best = (name, rank)
            }
        }
        return best?.0
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
        // No prior fileExists — try read and treat missing as nil.
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let raw = String(data: data, encoding: .isoLatin1)
        else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
