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
