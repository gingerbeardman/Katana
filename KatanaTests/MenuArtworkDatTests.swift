import Foundation
import Testing
@testable import Katana

struct MenuArtworkDatTests {
    @Test func extractReadsLooseDatsInMenuFolder() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(
            "katana-dat-loose-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let box = Data("BOX-ART-BYTES".utf8)
        let meta = Data("META-BYTES".utf8)
        try box.write(to: folder.appendingPathComponent("BOX.DAT"))
        try meta.write(to: folder.appendingPathComponent("meta.dat"))
        try Data().write(to: folder.appendingPathComponent("ICON.DAT"))
        try Data("not-a-gdi".utf8).write(to: folder.appendingPathComponent("disc.gdi"))

        let found = MenuArtworkDat.extract(fromMenuFolder: folder, imageFileName: "disc.gdi")
        #expect(found["BOX.DAT"] == box)
        #expect(found["META.DAT"] == meta)
        #expect(found["ICON.DAT"] == nil)
    }

    @Test func bakeOverlaysBoxDatAndExtractorFindsIt() throws {
        let assets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/MenuAssets/openMenu")
        try #require(FileManager.default.fileExists(atPath: assets.appendingPathComponent("IP.BIN").path))

        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent(
            "katana-dat-bake-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: out) }

        let marker = Data("KATANA-BOX-DAT-PRESERVE-\(UUID().uuidString)".utf8)
        try MenuGDIBake.build(
            MenuGDIBake.Options(
                kind: .openMenu,
                listText: "01.name=openMenu\n",
                assetsRoot: assets,
                outDir: out,
                truncate: true,
                extraMenuDataFiles: ["BOX.DAT": marker, "FOLDRART.MAP": Data("map".utf8)]
            )
        )

        let found = MenuArtworkDat.extract(fromMenuFolder: out, imageFileName: "disc.gdi")
        #expect(found["BOX.DAT"] == marker)
        #expect(found["FOLDRART.MAP"] == Data("map".utf8))
    }
}
