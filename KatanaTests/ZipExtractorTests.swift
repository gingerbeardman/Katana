import Foundation
import Testing
@testable import Katana

struct ZipExtractorTests {
    @Test func extractsGdMenuZipWithIPAndTracks() throws {
        let zip = projectRoot()
            .appendingPathComponent("Katana/Resources/MenuAssets/gdMenu.zip")
        try #require(FileManager.default.fileExists(atPath: zip.path))

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-extract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        try ZipExtractor.extract(zipURL: zip, to: dest)

        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("IP.BIN").path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("menu_data/1ST_READ.BIN").path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("menu_gdi/disc.gdi").path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("menu_gdi/track01.iso").path))

        let ipSize = try dest.appendingPathComponent("IP.BIN")
            .resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(ipSize == 32_768)
    }

    @Test func extractsOpenMenuZipWithThemes() throws {
        let zip = projectRoot()
            .appendingPathComponent("Katana/Resources/MenuAssets/openMenu.zip")
        try #require(FileManager.default.fileExists(atPath: zip.path))

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-extract-om-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        try ZipExtractor.extract(zipURL: zip, to: dest)

        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("IP.BIN").path))
        #expect(
            FileManager.default.fileExists(
                atPath: dest.appendingPathComponent("menu_data/theme").path
            )
        )
    }

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
