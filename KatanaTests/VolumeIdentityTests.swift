import Foundation
import Testing
@testable import Katana

struct VolumeIdentityTests {
    @Test func stableVolumeUUIDPrefersDiskOverPreferred() {
        let id = VolumeIdentity.stableVolumeUUID(
            diskUUID: "DISK-123",
            preferredUUID: VolumeIdentity.stableIDPrefix + "old"
        )
        #expect(id == "DISK-123")
    }

    @Test func stableVolumeUUIDKeepsPreferredWhenNoDisk() {
        let preferred = VolumeIdentity.stableIDPrefix + "remembered"
        let id = VolumeIdentity.stableVolumeUUID(diskUUID: nil, preferredUUID: preferred)
        #expect(id == preferred)
    }

    @Test func stableVolumeUUIDMintsWhenNothingKnown() {
        let a = VolumeIdentity.stableVolumeUUID(diskUUID: nil, preferredUUID: nil)
        let b = VolumeIdentity.stableVolumeUUID(diskUUID: nil, preferredUUID: nil)
        #expect(VolumeIdentity.isMintedStableID(a))
        #expect(VolumeIdentity.isMintedStableID(b))
        #expect(a != b)
    }

    @Test func stableVolumeUUIDIgnoresBlankDisk() {
        let preferred = VolumeIdentity.stableIDPrefix + "kept"
        let id = VolumeIdentity.stableVolumeUUID(diskUUID: "  ", preferredUUID: preferred)
        #expect(id == preferred)
    }

    @Test func resolveNeverMintsPathDerivedKeys() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("katana-id-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let volume = try VolumeIdentity.resolve(rootURL: root)
        #expect(!VolumeIdentity.isPathDerivedID(volume.volumeUUID))
        // Temp dirs usually inherit the boot volume UUID; either that or a minted stable: id.
        #expect(
            VolumeIdentity.isMintedStableID(volume.volumeUUID)
                || !volume.volumeUUID.isEmpty
        )
    }

    @Test func preferredPinsIdentityAcrossDoubleResolve() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("katana-id-pin-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let preferred = VolumeIdentity.stableIDPrefix + UUID().uuidString
        let first = try VolumeIdentity.resolve(rootURL: root, preferredUUID: preferred)
        let second = try VolumeIdentity.resolve(rootURL: root, preferredUUID: preferred)
        #expect(first.volumeUUID == second.volumeUUID)
        #expect(!VolumeIdentity.isPathDerivedID(first.volumeUUID))

        // When the OS exposes a disk UUID, it wins over preferred (correct).
        // When it doesn't, preferred is kept so renames don't orphan the cache.
        if first.volumeUUID != preferred {
            let bare = try VolumeIdentity.resolve(rootURL: root)
            #expect(first.volumeUUID == bare.volumeUUID)
        }
    }

    @Test func scanCacheKeyStableWithPreferredUUID() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("katana-cache-id-\(UUID().uuidString)", isDirectory: true)
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
        #expect(!VolumeIdentity.isPathDerivedID(first.volume.volumeUUID))

        // Same preferred → same identity → snapshot hits.
        let snap = try await CardScanner.loadSnapshotIfValid(
            rootURL: root,
            preferredVolumeUUID: preferred
        )
        #expect(snap != nil)
        #expect(snap?.volume.volumeUUID == first.volume.volumeUUID)
        #expect(snap?.entries.count == 1)
        #expect(snap?.cacheMisses == 0)

        try await CardCacheStore.shared.clear(volumeUUID: first.volume.volumeUUID)
    }
}
