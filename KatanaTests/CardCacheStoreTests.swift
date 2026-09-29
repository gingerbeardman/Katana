import Foundation
import Testing
@testable import Katana

struct CardCacheStoreTests {
    @Test func applyNameUpdatesPatchesEntryWithoutClearingCache() async throws {
        let uuid = "test-cache-\(UUID().uuidString)"

        var entry = GameEntry(
            id: UUID(),
            number: 2,
            name: "Old Name",
            serial: "MK-51000",
            format: .gdi,
            imageFileName: "disc.gdi",
            folderPath: "/Volumes/Card/02",
            byteSize: 1_000,
            payloadByteSize: 900,
            contentSHA256: nil,
            isMenu: false,
            detailsLoaded: true
        )
        entry.coverSource = .custom
        let fingerprint = FolderFingerprint(
            folderName: "02",
            imageFileName: "disc.gdi",
            imageSize: 900,
            imageModTimeSeconds: 1_700_000_000,
            nameTxt: "Old Name",
            serialTxt: "MK-51000",
            fileCount: 4
        )
        let cache = CardCache(
            volumeUUID: uuid,
            volumeName: "TestCard",
            rootPath: "/Volumes/Card",
            scannedAt: Date(),
            entries: [CachedEntry(fingerprint: fingerprint, entry: entry)]
        )
        try await CardCacheStore.shared.save(cache)

        try await CardCacheStore.shared.applyNameUpdates(
            volumeUUID: uuid,
            namesByFolder: ["02": (name: "New Name", isMenu: false)]
        )

        let loaded = try await CardCacheStore.shared.load(volumeUUID: uuid)
        #expect(loaded?.entries.count == 1)
        #expect(loaded?.entries.first?.entry.name == "New Name")
        #expect(loaded?.entries.first?.fingerprint.nameTxt == "New Name")
        #expect(loaded?.entries.first?.entry.serial == "MK-51000")
        #expect(loaded?.entries.first?.entry.coverSource == .custom)
        #expect(loaded?.entries.first?.fingerprint.folderName == "02")

        try await CardCacheStore.shared.clear(volumeUUID: uuid)
    }

    @Test func applyIpHeadersPatchesEntryWithoutTouchingFingerprint() async throws {
        let uuid = "test-cache-\(UUID().uuidString)"

        let entry = GameEntry(
            id: UUID(),
            number: 2,
            name: "Crazy Taxi",
            serial: "MK-51035",
            format: .gdi,
            imageFileName: "disc.gdi",
            folderPath: "/Volumes/Card/02",
            byteSize: 1_000,
            payloadByteSize: 900,
            contentSHA256: nil,
            isMenu: false,
            detailsLoaded: true
        )
        let fingerprint = FolderFingerprint(
            folderName: "02",
            imageFileName: "disc.gdi",
            imageSize: 900,
            imageModTimeSeconds: 1_700_000_000,
            nameTxt: "Crazy Taxi",
            serialTxt: "MK-51035",
            fileCount: 4
        )
        let cache = CardCache(
            volumeUUID: uuid,
            volumeName: "TestCard",
            rootPath: "/Volumes/Card",
            scannedAt: Date(),
            entries: [CachedEntry(fingerprint: fingerprint, entry: entry)]
        )
        try await CardCacheStore.shared.save(cache)

        let ip = IpBinInfo.fallback(name: "Crazy Taxi", serial: "MK-51035")
        try await CardCacheStore.shared.applyIpHeaders(
            volumeUUID: uuid,
            headersByFolder: ["02": ip]
        )

        let loaded = try await CardCacheStore.shared.load(volumeUUID: uuid)
        #expect(loaded?.entries.count == 1)
        #expect(loaded?.entries.first?.entry.ipHeader == ip)
        #expect(loaded?.entries.first?.fingerprint == fingerprint)

        try await CardCacheStore.shared.clear(volumeUUID: uuid)
    }

    @Test func snapshotStillValidAfterNameUpdate() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("katana-snap-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let folder = root.appendingPathComponent("01", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try "GDMENU".write(to: folder.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
        try "MK6969".write(to: folder.appendingPathComponent("serial.txt"), atomically: true, encoding: .utf8)
        try Data("fake".utf8).write(to: folder.appendingPathComponent("disc.gdi"))

        let preferred = VolumeIdentity.stableIDPrefix + UUID().uuidString
        let first = try await CardScanner.scan(
            rootURL: root,
            preferSnapshotCache: false,
            preferredVolumeUUID: preferred
        )
        #expect(first.entries.count == 1)

        let volumeUUID = first.volume.volumeUUID
        // Scan writes the cache on a detached task so the list can return first.
        let stored = await cacheStored(volumeUUID: volumeUUID)
        #expect(stored)

        try await CardCacheStore.shared.applyNameUpdates(
            volumeUUID: volumeUUID,
            namesByFolder: ["01": (name: "Custom Menu", isMenu: true)]
        )

        let snap = try await CardScanner.loadSnapshotIfValid(
            rootURL: root,
            preferredVolumeUUID: preferred
        )
        #expect(snap != nil)
        #expect(snap?.entries.first?.name == "Custom Menu")
        #expect(snap?.cacheMisses == 0)

        try await CardCacheStore.shared.clear(volumeUUID: volumeUUID)
    }

    @Test func staleSerialDropsCachedIpHeader() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("katana-stale-ip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let folder = root.appendingPathComponent("01", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try "openMenu".write(to: folder.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
        try "NEODC_1".write(to: folder.appendingPathComponent("serial.txt"), atomically: true, encoding: .utf8)
        try Data("gdi".utf8).write(to: folder.appendingPathComponent("disc.gdi"))

        let preferred = VolumeIdentity.stableIDPrefix + UUID().uuidString
        let volume = try VolumeIdentity.resolve(rootURL: root, preferredUUID: preferred)
        let fingerprint = try CardScanner.onDiskFingerprint(for: folder)
        let poisoned = GameEntry(
            id: UUID(),
            number: 1,
            name: "openMenu",
            serial: "DS-400BETA",
            format: .gdi,
            imageFileName: "disc.gdi",
            folderPath: folder.path,
            byteSize: 28_000_000,
            payloadByteSize: 28_000_000,
            contentSHA256: nil,
            isMenu: true,
            detailsLoaded: true,
            ipHeader: Self.dreamShellHeader
        )
        let cache = CardCache(
            volumeUUID: volume.volumeUUID,
            volumeName: volume.volumeName,
            rootPath: root.path,
            scannedAt: Date(),
            entries: [CachedEntry(fingerprint: fingerprint, entry: poisoned)]
        )
        try await CardCacheStore.shared.save(cache)
        defer { Task { try? await CardCacheStore.shared.clear(volumeUUID: volume.volumeUUID) } }

        let snap = try await CardScanner.loadSnapshotIfValid(
            rootURL: root,
            preferredVolumeUUID: preferred
        )
        let snapped = try #require(snap?.entries.first)
        #expect(snapped.name == "openMenu")
        #expect(snapped.serial == "NEODC_1")
        #expect(snapped.ipHeader == nil)

        let trusted = try await CardScanner.scan(
            rootURL: root,
            preferSnapshotCache: true,
            preferredVolumeUUID: preferred
        )
        #expect(trusted.cacheMisses == 0)
        #expect(trusted.entries.first?.serial == "NEODC_1")
        #expect(trusted.entries.first?.ipHeader == nil)
        #expect(trusted.entries.first?.name == "openMenu")

        let rescanned = try await CardScanner.scan(
            rootURL: root,
            preferSnapshotCache: false,
            preferredVolumeUUID: preferred
        )
        #expect(rescanned.entries.first?.serial == "NEODC_1")
        #expect(rescanned.entries.first?.ipHeader == nil)
        #expect(rescanned.entries.first?.name == "openMenu")

        var healed: CardCache?
        for _ in 0..<50 {
            let loaded = try await CardCacheStore.shared.load(volumeUUID: volume.volumeUUID)
            if loaded?.entries.first?.entry.serial == "NEODC_1",
               loaded?.entries.first?.entry.ipHeader == nil {
                healed = loaded
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(healed?.entries.first?.entry.name == "openMenu")
        #expect(healed?.entries.first?.fingerprint.serialTxt == "NEODC_1")
    }

    @Test func matchingSerialKeepsCachedIpHeader() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("katana-warm-ip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let folder = root.appendingPathComponent("02", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Crazy Taxi".write(to: folder.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
        try "MK51035".write(to: folder.appendingPathComponent("serial.txt"), atomically: true, encoding: .utf8)
        try Data("gdi".utf8).write(to: folder.appendingPathComponent("disc.gdi"))

        let preferred = VolumeIdentity.stableIDPrefix + UUID().uuidString
        let volume = try VolumeIdentity.resolve(rootURL: root, preferredUUID: preferred)
        let fingerprint = try CardScanner.onDiskFingerprint(for: folder)
        let ip = IpBinInfo.fallback(name: "Crazy Taxi", serial: "MK-51035")
        let entry = GameEntry(
            id: UUID(),
            number: 2,
            name: "Crazy Taxi",
            serial: "MK-51035",
            format: .gdi,
            imageFileName: "disc.gdi",
            folderPath: folder.path,
            byteSize: 1_000,
            payloadByteSize: 900,
            contentSHA256: nil,
            isMenu: false,
            detailsLoaded: true,
            ipHeader: ip
        )
        let cache = CardCache(
            volumeUUID: volume.volumeUUID,
            volumeName: volume.volumeName,
            rootPath: root.path,
            scannedAt: Date(),
            entries: [CachedEntry(fingerprint: fingerprint, entry: entry)]
        )
        try await CardCacheStore.shared.save(cache)
        defer { Task { try? await CardCacheStore.shared.clear(volumeUUID: volume.volumeUUID) } }

        let snap = try await CardScanner.loadSnapshotIfValid(
            rootURL: root,
            preferredVolumeUUID: preferred
        )
        #expect(snap?.entries.first?.serial == "MK-51035")
        #expect(snap?.entries.first?.ipHeader == ip)
        #expect(snap?.entries.first?.name == "Crazy Taxi")
    }

    @Test func replacedImageDropsIpHeaderOnSave() {
        let stored = Self.fingerprint(imageSize: 100, mtime: 1, serialTxt: "NEODC_1", nameTxt: "openMenu")
        var probed = stored
        probed.imageSize = 143
        probed.imageModTimeSeconds = 2
        let game = Self.menuEntry(serial: "NEODC_1", ip: Self.dreamShellHeader)
        let (saved, correction) = FolderFingerprint.reconciling(game, stored: stored, probed: probed)
        #expect(saved.ipHeader == nil)
        #expect(saved.serial == "NEODC_1")
        #expect(saved.name == "openMenu")
        #expect(correction?.ipHeader == nil)
        #expect(correction?.previousHeader == Self.dreamShellHeader)
    }

    @Test func unchangedImageKeepsIpHeaderOnSave() {
        let stored = Self.fingerprint(imageSize: 143, mtime: 5, serialTxt: "MK-51035", nameTxt: "Crazy Taxi")
        let ip = IpBinInfo.fallback(name: "Crazy Taxi", serial: "MK-51035")
        let game = Self.menuEntry(serial: "MK-51035", ip: ip)
        let (saved, correction) = FolderFingerprint.reconciling(game, stored: stored, probed: stored)
        #expect(saved.ipHeader == ip)
        #expect(correction == nil)
    }

    @Test func renamedRowKeepsCustomNameWhenSerialMatches() {
        var fingerprint = Self.fingerprint(imageSize: 10, mtime: 1, serialTxt: "MK6969", nameTxt: "GDMENU")
        fingerprint.folderName = "01"
        var entry = Self.menuEntry(serial: "MK6969", ip: IpBinInfo.menuDefaults)
        entry.name = "Custom Menu"
        let kept = FolderFingerprint.adoptingSerial(entry, from: fingerprint)
        #expect(kept.name == "Custom Menu")
        #expect(kept.ipHeader == IpBinInfo.menuDefaults)
        #expect(kept.serial == "MK6969")
    }

    /// Scan persists the cache after returning the list. Wait until that write lands.
    private func cacheStored(volumeUUID: String) async -> Bool {
        for _ in 0..<50 {
            if let cache = try? await CardCacheStore.shared.load(volumeUUID: volumeUUID),
               !cache.entries.isEmpty {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private static let dreamShellHeader = IpBinInfo(
        name: "DreamShell 4.0",
        productNumber: "DS-400BETA",
        disc: "1/1",
        region: "JUE",
        vga: true,
        version: "V4.000",
        releaseDate: "20090317",
        crc: "400B",
        isCodeBreaker: false
    )

    private static func fingerprint(
        imageSize: Int64,
        mtime: Int64,
        serialTxt: String,
        nameTxt: String
    ) -> FolderFingerprint {
        FolderFingerprint(
            folderName: "01",
            imageFileName: "disc.gdi",
            imageSize: imageSize,
            imageModTimeSeconds: mtime,
            nameTxt: nameTxt,
            serialTxt: serialTxt,
            fileCount: 3
        )
    }

    private static func menuEntry(serial: String, ip: IpBinInfo) -> GameEntry {
        GameEntry(
            id: UUID(),
            number: 1,
            name: "openMenu",
            serial: serial,
            format: .gdi,
            imageFileName: "disc.gdi",
            folderPath: "/tmp/01",
            byteSize: 1,
            payloadByteSize: 1,
            contentSHA256: nil,
            isMenu: true,
            detailsLoaded: true,
            ipHeader: ip
        )
    }
}
