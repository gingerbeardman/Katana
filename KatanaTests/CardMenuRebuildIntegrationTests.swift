import Foundation
import Testing
@testable import Katana

/// Optional live-card bake (sandbox-friendly).
/// Set `KATANA_REBUILD_CARD=/Volumes/200GB` — bakes to `/tmp/katana-menu-bake` for shell install.
struct CardMenuRebuildIntegrationTests {
    @Test func bakeLiveCardListToTempWhenEnvSet() async throws {
        guard let path = ProcessInfo.processInfo.environment["KATANA_REBUILD_CARD"], !path.isEmpty else {
            return
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try #require(FileManager.default.fileExists(atPath: root.path))

        let scan = try await CardScanner.scan(
            rootURL: root,
            preferSnapshotCache: false
        )
        #expect(!scan.entries.isEmpty)

        let ordered = scan.entries.sorted { $0.number < $1.number }
        let maxNumber = ordered.map(\.number).max() ?? ordered.count
        let items = MenuListGenerator.items(for: ordered, menuKind: .gdMenu)
        let listText = MenuListGenerator.makeList(kind: .gdMenu, items: items, maxNumber: maxNumber)

        // Prefer Tools tree (always present in test host); fall back to bundle zip.
        let toolsAssets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/MenuAssets/gdMenu")
        let assets: URL
        if FileManager.default.fileExists(atPath: toolsAssets.appendingPathComponent("IP.BIN").path) {
            assets = toolsAssets
        } else {
            assets = try MenuRebuildService.assetsURL(for: .gdMenu)
        }

        // Sandboxed test host: only the container temp is writable.
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("katana-menu-bake", isDirectory: true)
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        try MenuGDIBake.build(
            MenuGDIBake.Options(
                kind: .gdMenu,
                listText: listText,
                assetsRoot: assets,
                outDir: outDir,
                truncate: true
            )
        )

        // Sanity: card-wide 3-digit keys when max ≥ 100.
        let track05 = try Data(contentsOf: outDir.appendingPathComponent("track05.iso"))
        let text = String(decoding: track05, as: UTF8.self)
        let sample = FolderNumbering.format(1, maxNumber: maxNumber) + ".name="
        #expect(text.contains(sample), "expected \(sample) in LIST for max=\(maxNumber)")
        if maxNumber >= 100 {
            #expect(!text.hasPrefix("01.name="))
            #expect(!text.contains("\n01.name="))
        }

        // Marker + copy of bake for host shell install (outside the sandbox).
        let marker = """
        out=\(outDir.path)
        max=\(maxNumber)
        items=\(items.count)
        sample=\(sample)
        """
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("katana-menu-bake-ready.txt")
        try marker.write(to: markerURL, atomically: true, encoding: .utf8)
        // Also echo for the build log.
        fputs(marker + "\n", stderr)
    }
}