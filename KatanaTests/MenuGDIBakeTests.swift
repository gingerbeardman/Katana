import XCTest
@testable import Katana

final class MenuGDIBakeTests: XCTestCase {
    /// Stock assets from Tools/MenuGDIBuilder (repo path relative to test host is fragile;
    /// resolve from the source tree next to the project).
    private var gdMenuAssets: URL? {
        let candidates = [
            // Running under xcodebuild: SRCROOT / project-adjacent
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // KatanaTests
                .deletingLastPathComponent() // project root
                .appendingPathComponent("Tools/MenuGDIBuilder/assets/gdMenu"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.appendingPathComponent("IP.BIN").path) {
            return url
        }
        return nil
    }

    func testNativeBakeGdMenuProducesTracks() throws {
        guard let assets = gdMenuAssets else {
            throw XCTSkip("gdMenu assets not found next to project")
        }

        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent("native-bake-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: out) }

        let list = """
        01.name=Test Game
        01.disc=1/1
        01.region=JUE
        01.version=V1.000
        01.date=20200101
        01.product=TEST0000
        """

        try MenuGDIBake.build(
            MenuGDIBake.Options(
                kind: .gdMenu,
                listText: list,
                assetsRoot: assets,
                outDir: out,
                truncate: true
            )
        )

        let expected = ["disc.gdi", "track01.iso", "track02.raw", "track03.iso", "track04.raw", "track05.iso"]
        for name in expected {
            let url = out.appendingPathComponent(name)
            XCTAssertTrue(fm.fileExists(atPath: url.path), "missing \(name)")
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            XCTAssertGreaterThan(size, 0, "\(name) empty")
        }

        let gdi = try String(contentsOf: out.appendingPathComponent("disc.gdi"), encoding: .utf8)
        let lines = gdi.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(lines.first, "5")
        XCTAssertTrue(lines.contains(where: { $0.hasPrefix("1 ") && $0.contains("track01.iso") }))
        XCTAssertTrue(lines.contains(where: { $0.hasPrefix("3 ") && $0.contains("track03.iso") }))
        XCTAssertTrue(lines.contains(where: { $0.hasPrefix("5 ") && $0.contains("track05.iso") }))

        // Ballpark sizes vs known-good MenuGDIBuilder output (not byte-identical).
        let t1 = try out.appendingPathComponent("track01.iso").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let t3 = try out.appendingPathComponent("track03.iso").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let t5 = try out.appendingPathComponent("track05.iso").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(t1, 20_000)
        XCTAssertLessThan(t1, 200_000)
        XCTAssertGreaterThan(t3, 16_384) // at least IP.BIN
        XCTAssertLessThan(t3, 200_000)
        XCTAssertGreaterThan(t5, 600_000) // 1ST_READ.BIN ~598KB + peers
        XCTAssertLessThan(t5, 2_000_000)

        // IP.BIN system area should lead track03
        let t3Data = try Data(contentsOf: out.appendingPathComponent("track03.iso"))
        let magic = String(data: t3Data.prefix(16), encoding: .ascii) ?? ""
        XCTAssertTrue(magic.hasPrefix("SEGA"), "track03 should start with IP.BIN SEGA header, got \(magic)")
    }

    func testNativeBakeOpenMenuWithNestedDirs() throws {
        let assets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/MenuGDIBuilder/assets/openMenu")
        guard FileManager.default.fileExists(atPath: assets.appendingPathComponent("IP.BIN").path) else {
            throw XCTSkip("openMenu assets not found")
        }

        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent("native-bake-open-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: out) }

        try MenuGDIBake.build(
            MenuGDIBake.Options(
                kind: .openMenu,
                listText: "01.name=openMenu test\n",
                assetsRoot: assets,
                outDir: out,
                truncate: true
            )
        )

        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("track05.iso").path))
        let t5 = try out.appendingPathComponent("track05.iso").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(t5, 100_000)
    }
}
