import Foundation

/// A previously opened GDEMU card root, with a security-scoped bookmark when available.
struct RememberedVolume: Codable, Identifiable, Hashable, Sendable {
    var volumeUUID: String
    var volumeName: String
    var lastPath: String
    var bookmarkData: Data?
    var lastOpenedAt: Date

    var id: String { volumeUUID }

    var displayPath: String { lastPath }
}

private struct VolumePreferences: Codable, Sendable {
    var lastVolumeUUID: String?
    var recents: [RememberedVolume]
    /// Per-volume visual table sort (does not affect disc numbering).
    var displaySortByVolume: [String: DisplaySortPreference]
    /// Per-volume GDmenu vs openMenu preference (rebuild target).
    var menuKindByVolume: [String: MenuKind]

    init(
        lastVolumeUUID: String?,
        recents: [RememberedVolume],
        displaySortByVolume: [String: DisplaySortPreference],
        menuKindByVolume: [String: MenuKind] = [:]
    ) {
        self.lastVolumeUUID = lastVolumeUUID
        self.recents = recents
        self.displaySortByVolume = displaySortByVolume
        self.menuKindByVolume = menuKindByVolume
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastVolumeUUID = try c.decodeIfPresent(String.self, forKey: .lastVolumeUUID)
        recents = try c.decodeIfPresent([RememberedVolume].self, forKey: .recents) ?? []
        displaySortByVolume = try c.decodeIfPresent(
            [String: DisplaySortPreference].self,
            forKey: .displaySortByVolume
        ) ?? [:]
        menuKindByVolume = try c.decodeIfPresent(
            [String: MenuKind].self,
            forKey: .menuKindByVolume
        ) ?? [:]
    }
}

/// Persists last/recent SD card volumes under Application Support.
actor VolumeStore {
    static let shared = VolumeStore()

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

    private var storeURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Katana", isDirectory: true)
            .appendingPathComponent("volumes.json", isDirectory: false)
    }

    private var prefs: VolumePreferences = VolumePreferences(
        lastVolumeUUID: nil,
        recents: [],
        displaySortByVolume: [:],
        menuKindByVolume: [:]
    )
    private var loaded = false

    // MARK: - Public API

    func lastVolumeUUID() throws -> String? {
        try ensureLoaded()
        return prefs.lastVolumeUUID
    }

    func recents() throws -> [RememberedVolume] {
        try ensureLoaded()
        return prefs.recents.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    func remembered(uuid: String) throws -> RememberedVolume? {
        try ensureLoaded()
        return prefs.recents.first { $0.volumeUUID == uuid }
    }

    func lastRemembered() throws -> RememberedVolume? {
        try ensureLoaded()
        if let uuid = prefs.lastVolumeUUID,
           let match = prefs.recents.first(where: { $0.volumeUUID == uuid }) {
            return match
        }
        return prefs.recents.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.first
    }

    /// Visual sort for a volume; defaults to newest slots first.
    func displaySort(for volumeUUID: String) throws -> DisplaySortPreference {
        try ensureLoaded()
        return prefs.displaySortByVolume[volumeUUID] ?? .mostRecentFirst
    }

    func setDisplaySort(_ sort: DisplaySortPreference, for volumeUUID: String) throws {
        try ensureLoaded()
        prefs.displaySortByVolume[volumeUUID] = sort
        try save()
    }

    /// Preferred menu system for a volume, if the user has chosen one.
    func menuKind(for volumeUUID: String) throws -> MenuKind? {
        try ensureLoaded()
        return prefs.menuKindByVolume[volumeUUID]
    }

    func setMenuKind(_ kind: MenuKind, for volumeUUID: String) throws {
        try ensureLoaded()
        prefs.menuKindByVolume[volumeUUID] = kind
        try save()
    }

    /// Record a successful open. Creates a security-scoped bookmark when possible.
    func remember(
        volume: CardVolume,
        rootURL: URL,
        existingBookmark: Data? = nil
    ) throws {
        try ensureLoaded()

        let bookmark = existingBookmark ?? Self.makeBookmark(for: rootURL)

        var next = RememberedVolume(
            volumeUUID: volume.volumeUUID,
            volumeName: volume.volumeName,
            lastPath: rootURL.standardizedFileURL.path,
            bookmarkData: bookmark,
            lastOpenedAt: Date()
        )

        // Preserve prior bookmark if new creation failed.
        if next.bookmarkData == nil,
           let old = prefs.recents.first(where: { $0.volumeUUID == volume.volumeUUID })?.bookmarkData {
            next.bookmarkData = old
        }

        prefs.recents.removeAll { $0.volumeUUID == volume.volumeUUID }
        prefs.recents.insert(next, at: 0)
        // Cap recents.
        if prefs.recents.count > 12 {
            prefs.recents = Array(prefs.recents.prefix(12))
        }
        prefs.lastVolumeUUID = volume.volumeUUID
        try save()
    }

    /// Clear last-selection pointer (e.g. after eject) but keep recents/bookmarks for remount.
    func clearLastSelection() throws {
        try ensureLoaded()
        prefs.lastVolumeUUID = nil
        try save()
    }

    func forget(uuid: String) throws {
        try ensureLoaded()
        prefs.recents.removeAll { $0.volumeUUID == uuid }
        if prefs.lastVolumeUUID == uuid {
            prefs.lastVolumeUUID = prefs.recents.first?.volumeUUID
        }
        try save()
    }

    /// Resolve a remembered volume to a file URL and whether security-scope was started by the caller.
    /// Caller must call `startAccessingSecurityScopedResource()` on the returned URL when `needsSecurityScope` is true.
    nonisolated static func resolveURL(from remembered: RememberedVolume) throws -> (url: URL, isSecurityScoped: Bool) {
        if let data = remembered.bookmarkData {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, true)
        }

        let url = URL(fileURLWithPath: remembered.lastPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VolumeStoreError.notMounted(remembered.volumeName)
        }
        return (url, false)
    }

    nonisolated static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    // MARK: - Persistence

    private func ensureLoaded() throws {
        guard !loaded else { return }
        loaded = true
        guard fileManager.fileExists(atPath: storeURL.path) else {
            prefs = VolumePreferences(lastVolumeUUID: nil, recents: [], displaySortByVolume: [:])
            return
        }
        let data = try Data(contentsOf: storeURL)
        prefs = try decoder.decode(VolumePreferences.self, from: data)
    }

    private func save() throws {
        try fileManager.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(prefs)
        try data.write(to: storeURL, options: .atomic)
    }
}

enum VolumeStoreError: LocalizedError {
    case notMounted(String)
    case unreadableBookmark

    var errorDescription: String? {
        switch self {
        case .notMounted(let name):
            return "“\(name)” is not mounted."
        case .unreadableBookmark:
            return "Could not restore access to the saved card."
        }
    }
}
