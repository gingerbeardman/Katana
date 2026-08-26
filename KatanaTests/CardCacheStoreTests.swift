import Foundation
import Testing
@testable import Katana

struct CardCacheStoreTests {
    @Test func applyNameUpdatesPatchesEntryWithoutClearingCache() async throws {
        let uuid = "test-cache-\(UUID().uuidString)"

        let entry = GameEntry(
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
}
