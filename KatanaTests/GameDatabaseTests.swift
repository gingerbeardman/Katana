import Foundation
import Testing
@testable import Katana

struct GameDatabaseTests {
    @Test func normalizeStripsSpacesAndCase() {
        #expect(GameDatabase.normalize(" mk-51000 ") == "MK-51000")
        #expect(GameDatabase.normalize("t-17704n") == "T-17704N")
    }

    @Test func lookupKeysExpandMKAliases() {
        let keys = GameDatabase.lookupKeys(for: "MK-51000")
        #expect(keys.contains("MK-51000"))
        #expect(keys.contains("51000"))
        #expect(keys.contains("MK51000"))
    }

    @Test func lookupKeysExpandTAliases() {
        let keys = GameDatabase.lookupKeys(for: "T-17704N")
        #expect(keys.contains("T-17704N"))
        #expect(keys.contains("17704N"))
        #expect(keys.contains("T17704N"))
    }

    private var repoGameDBURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Katana/Resources/GameDB/dreamcast-titles.json")
    }

    @Test func bundledDatabaseFileLoads() throws {
        let map = try #require(GameDatabase.loadTitles(from: repoGameDBURL))
        #expect(map.count > 1000)
        #expect(map["51000"]?.title == "Sonic Adventure")
        #expect(map["MK-51000"]?.title == "Sonic Adventure")
        #expect(map["T-17704N"]?.title == "Rayman 2: The Great Escape")
        #expect(map["17704N"]?.title == "Rayman 2: The Great Escape")
    }

    @Test func resolvePrefersNameTxt() {
        let resolved = GameDatabase.resolveDisplayName(
            nameTxt: "My Custom Name",
            serialTxt: "MK-51000",
            ip: nil,
            imageFileName: "disc.gdi",
            folderName: "02"
        )
        #expect(resolved.name == "My Custom Name")
        #expect(resolved.serial == "MK-51000")
    }

    @Test func resolveFallsBackToIPNameWhenUnknownSerial() {
        let ip = IpBinInfo(
            name: "SOME HOMEBREW",
            productNumber: "HB_NOT_IN_DB",
            disc: "1/1",
            region: "JUE",
            vga: true,
            version: "V1.000",
            releaseDate: "20200101",
            isCodeBreaker: false
        )
        let resolved = GameDatabase.resolveDisplayName(
            nameTxt: nil,
            serialTxt: nil,
            ip: ip,
            imageFileName: "disc.gdi",
            folderName: "02"
        )
        #expect(resolved.name == ip.name.localizedCapitalized)
        #expect(resolved.serial == "HB_NOT_IN_DB")
    }
}
