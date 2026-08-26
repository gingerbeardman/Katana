import Foundation
import Testing
@testable import Katana

struct CardScannerIntegrationTests {
    @Test func scanRealCardIfMounted() async throws {
        let url = URL(fileURLWithPath: "/Volumes/200GB", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Skip when the card isn't plugged in.
            return
        }

        // Cold-ish: clear cache first.
        if let volume = try? VolumeIdentity.resolve(rootURL: url) {
            try? await CardCacheStore.shared.clear(volumeUUID: volume.volumeUUID)
        }

        let first = try await CardScanner.scan(rootURL: url)
        #expect(first.entries.count >= 1)
        #expect(first.entries.first?.isMenu == true || first.entries.first?.number == 1)
        #expect(first.cacheMisses == first.entries.count)

        let second = try await CardScanner.scan(rootURL: url)
        #expect(second.entries.count == first.entries.count)
        #expect(second.cacheHits == second.entries.count)
        #expect(second.durationMilliseconds <= first.durationMilliseconds + 5_000)

        // Snapshot path (recent reopen): folder set match → no per-folder I/O.
        let snap = try await CardScanner.loadSnapshotIfValid(rootURL: url)
        #expect(snap != nil)
        #expect(snap?.entries.count == first.entries.count)
        #expect(snap?.cacheMisses == 0)
        #expect((snap?.durationMilliseconds ?? 9_999) < first.durationMilliseconds)

        // Force full rescan ignores snapshot preference still works via preferSnapshotCache: false
        let forced = try await CardScanner.scan(rootURL: url, preferSnapshotCache: false)
        #expect(forced.entries.count == first.entries.count)

        // Spot-check known titles from this card.
        let names = Set(second.entries.map(\.name))
        #expect(names.contains("GDMENU") || names.contains { $0.localizedCaseInsensitiveContains("menu") })
    }

    @Test func scanFixtureCard() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("katana-fixture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try makeGameFolder(at: root.appendingPathComponent("01"), name: "GDMENU", serial: "MK6969", image: "disc.gdi")
        try makeGameFolder(at: root.appendingPathComponent("02"), name: "Sonic Adventure", serial: "MK-51000", image: "disc.cdi")
        try makeGameFolder(at: root.appendingPathComponent("03"), name: "Crazy Taxi", serial: "MK-51035", image: "disc.gdi")

        let preferred = VolumeIdentity.stableIDPrefix + UUID().uuidString
        let result = try await CardScanner.scan(
            rootURL: root,
            preferredVolumeUUID: preferred
        )
        // #require: cache keyed by volume UUID can cross-pollinate from parallel tests on the
        // same volume — fail cleanly instead of crashing the host on out-of-bounds indexing.
        try #require(result.entries.count == 3)
        #expect(result.entries[0].name == "GDMENU")
        #expect(result.entries[0].isMenu)
        #expect(result.entries[1].format == .cdi)
        #expect(result.entries[2].format == .gdi)
        #expect(result.entries[1].serial == "MK-51000")
        #expect(result.entries[1].virtualFolder.isEmpty)
        #expect(result.entries[1].discType == .game)

        // Second open uses snapshot when folder set is unchanged.
        let snap = try await CardScanner.loadSnapshotIfValid(
            rootURL: root,
            preferredVolumeUUID: preferred
        )
        #expect(snap?.entries.count == 3)
        #expect(snap?.entries.map(\.name) == result.entries.map(\.name))

        try await CardCacheStore.shared.clear(volumeUUID: result.volume.volumeUUID)
    }

    private func makeGameFolder(at url: URL, name: String, serial: String, image: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try name.write(to: url.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
        try serial.write(to: url.appendingPathComponent("serial.txt"), atomically: true, encoding: .utf8)
        // Tiny fake disc image so size/mtime exist.
        try Data("fake".utf8).write(to: url.appendingPathComponent(image))
    }

    @Test func scanReadsOpenMenuSidecars() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("katana-om-meta-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try makeGameFolder(at: root.appendingPathComponent("01"), name: "openMenu", serial: "NEODC1", image: "disc.gdi")
        let game = root.appendingPathComponent("02")
        try makeGameFolder(at: game, name: "Shenmue", serial: "MK-51059", image: "disc.gdi")
        try "Games\\RPGs".write(to: game.appendingPathComponent("folder.txt"), atomically: true, encoding: .utf8)
        try "Games\\A-Z".write(to: game.appendingPathComponent("folder_alt1.txt"), atomically: true, encoding: .utf8)
        try "other".write(to: game.appendingPathComponent("type.txt"), atomically: true, encoding: .utf8)
        try "2/4".write(to: game.appendingPathComponent("disc.txt"), atomically: true, encoding: .utf8)
        try "UE".write(to: game.appendingPathComponent("region.txt"), atomically: true, encoding: .utf8)
        try "1".write(to: game.appendingPathComponent("vga.txt"), atomically: true, encoding: .utf8)
        try "V1.000".write(to: game.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        try "19991201".write(to: game.appendingPathComponent("date.txt"), atomically: true, encoding: .utf8)

        // Unique cache key — temp dirs share the Mac volume UUID and would
        // otherwise collide with scanFixtureCard / other parallel tests.
        let preferred = VolumeIdentity.stableIDPrefix + UUID().uuidString
        let result = try await CardScanner.scan(
            rootURL: root,
            preferSnapshotCache: false,
            preferredVolumeUUID: preferred
        )
        try #require(result.entries.count == 2)
        #expect(result.entries[0].isMenu)
        #expect(result.entries[0].virtualFolder.isEmpty)
        #expect(result.entries[1].virtualFolder == "Games\\RPGs")
        #expect(result.entries[1].extraFolders == ["Games\\A-Z"])
        #expect(result.entries[1].discType == .other)
        #expect(result.entries[1].discLabel == "2/4")
        #expect(result.entries[1].regionLabel == "UE")
        #expect(result.entries[1].ipHeader?.disc == "2/4")
        #expect(result.entries[1].ipHeader?.region == "UE")

        let items = MenuListGenerator.items(for: result.entries, menuKind: .openMenuExtended)
        let text = MenuListGenerator.makeList(kind: .openMenuExtended, items: items)
        #expect(text.contains("02.folder=Games\\RPGs\n"))
        #expect(text.contains("02.folder_alt1=Games\\A-Z\n"))
        #expect(text.contains("02.type=other\n"))
        #expect(text.contains("02.disc=2/4\n"))
        #expect(text.contains("02.region=UE\n"))

        try await CardCacheStore.shared.clear(volumeUUID: result.volume.volumeUUID)
    }
}
