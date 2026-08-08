import Foundation
import Testing
@testable import Katana

struct VolumeStoreTests {
    @Test func rememberAndLoadLast() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("katana-vol-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let volume = CardVolume(
            rootURL: root,
            volumeUUID: "test-\(UUID().uuidString)",
            volumeName: "TestCard",
            freeBytes: nil,
            totalBytes: nil,
            isReadOnly: false
        )

        try await VolumeStore.shared.remember(volume: volume, rootURL: root, existingBookmark: nil)

        let last = try await VolumeStore.shared.lastRemembered()
        #expect(last?.volumeUUID == volume.volumeUUID)
        #expect(last?.volumeName == "TestCard")

        let byUUID = try await VolumeStore.shared.remembered(uuid: volume.volumeUUID)
        #expect(byUUID?.lastPath == root.standardizedFileURL.path)

        let resolved = try VolumeStore.resolveURL(from: byUUID!)
        #expect(resolved.url.standardizedFileURL.path == root.standardizedFileURL.path)
    }
}
