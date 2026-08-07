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

        // Spot-check known titles from this card.
        let names = Set(second.entries.map(\.name))
        #expect(names.contains("GDMENU") || names.contains { $0.localizedCaseInsensitiveContains("menu") })
    }

    @Test func scanFixtureCard() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dcgdsd-fixture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try makeGameFolder(at: root.appendingPathComponent("01"), name: "GDMENU", serial: "MK6969", image: "disc.gdi")
        try makeGameFolder(at: root.appendingPathComponent("02"), name: "Sonic Adventure", serial: "MK-51000", image: "disc.cdi")
        try makeGameFolder(at: root.appendingPathComponent("03"), name: "Crazy Taxi", serial: "MK-51035", image: "disc.gdi")

        let result = try await CardScanner.scan(rootURL: root)
        #expect(result.entries.count == 3)
        #expect(result.entries[0].name == "GDMENU")
        #expect(result.entries[0].isMenu)
        #expect(result.entries[1].format == .cdi)
        #expect(result.entries[2].format == .gdi)
        #expect(result.entries[1].serial == "MK-51000")
    }

    private func makeGameFolder(at url: URL, name: String, serial: String, image: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try name.write(to: url.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
        try serial.write(to: url.appendingPathComponent("serial.txt"), atomically: true, encoding: .utf8)
        // Tiny fake disc image so size/mtime exist.
        try Data("fake".utf8).write(to: url.appendingPathComponent(image))
    }
}
