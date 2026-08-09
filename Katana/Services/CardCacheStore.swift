import Foundation

actor CardCacheStore {
    static let shared = CardCacheStore()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private var cacheDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Katana", isDirectory: true)
            .appendingPathComponent("Cache", isDirectory: true)
    }

    private func cacheURL(for volumeUUID: String) -> URL {
        // Volume UUIDs are safe path components; still sanitize.
        let safe = volumeUUID.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory.appendingPathComponent("\(safe).json", isDirectory: false)
    }

    func load(volumeUUID: String) throws -> CardCache? {
        let url = cacheURL(for: volumeUUID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(CardCache.self, from: data)
    }

    func save(_ cache: CardCache) throws {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(cache)
        try data.write(to: cacheURL(for: cache.volumeUUID), options: .atomic)
    }

    func clear(volumeUUID: String) throws {
        let url = cacheURL(for: volumeUUID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try clearDuplicates(volumeUUID: volumeUUID)
    }

    /// Patch display names after a name-only rename without dropping the rest of the cache.
    ///
    /// Folder set is unchanged, so the next launch can still take the snapshot path.
    /// Updates both `entry.name` / `isMenu` and `fingerprint.nameTxt` so per-folder
    /// fingerprint hits still match `name.txt` on disk.
    func applyNameUpdates(
        volumeUUID: String,
        namesByFolder: [String: (name: String, isMenu: Bool)]
    ) throws {
        guard !namesByFolder.isEmpty else { return }
        guard var cache = try load(volumeUUID: volumeUUID), !cache.entries.isEmpty else { return }

        var changed = false
        for i in cache.entries.indices {
            let folder = cache.entries[i].fingerprint.folderName
            guard let update = namesByFolder[folder] else { continue }
            if cache.entries[i].entry.name != update.name
                || cache.entries[i].entry.isMenu != update.isMenu
                || cache.entries[i].fingerprint.nameTxt != update.name
            {
                cache.entries[i].entry.name = update.name
                cache.entries[i].entry.isMenu = update.isMenu
                cache.entries[i].fingerprint.nameTxt = update.name
                changed = true
            }
        }
        guard changed else { return }
        cache.scannedAt = Date()
        try save(cache)
    }

    /// Patch IP.BIN headers into cached entries without touching fingerprints.
    ///
    /// Headers live inside the disc image the fingerprint already validates
    /// (size + mod time), so a header read from the card is valid for as long
    /// as the fingerprint matches. Lets menu rebuilds stay on SSD across launches.
    func applyIpHeaders(
        volumeUUID: String,
        headersByFolder: [String: IpBinInfo]
    ) throws {
        guard !headersByFolder.isEmpty else { return }
        guard var cache = try load(volumeUUID: volumeUUID), !cache.entries.isEmpty else { return }

        var patched = 0
        for i in cache.entries.indices {
            let folder = cache.entries[i].fingerprint.folderName
            guard let ip = headersByFolder[folder] else { continue }
            if cache.entries[i].entry.ipHeader != ip {
                cache.entries[i].entry.ipHeader = ip
                patched += 1
            }
        }
        LaunchTrace.mark("cache patch: \(patched)/\(headersByFolder.count) headers into \(cache.entries.count) entries")
        guard patched > 0 else { return }
        try save(cache)
    }

    // MARK: - Duplicate analysis cache

    private func duplicateCacheURL(for volumeUUID: String) -> URL {
        let safe = volumeUUID.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory.appendingPathComponent("\(safe).duplicates.json", isDirectory: false)
    }

    func loadDuplicates(volumeUUID: String) throws -> DuplicateCacheRecord? {
        let url = duplicateCacheURL(for: volumeUUID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(DuplicateCacheRecord.self, from: data)
    }

    func saveDuplicates(_ record: DuplicateCacheRecord) throws {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(record)
        try data.write(to: duplicateCacheURL(for: record.volumeUUID), options: .atomic)
    }

    func clearDuplicates(volumeUUID: String) throws {
        let url = duplicateCacheURL(for: volumeUUID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
