import Foundation
import Testing
@testable import Katana

struct MenuRebuildAssetsTests {
    @Test func bundleContainsMenuAssetZips() throws {
        for name in ["gdMenu", "openMenu"] {
            let url =
                Bundle.main.url(forResource: name, withExtension: "zip", subdirectory: "MenuAssets")
                ?? Bundle.main.url(forResource: name, withExtension: "zip")
            #expect(url != nil, "missing \(name).zip in test host bundle")
            if let url {
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    @Test func assetsURLExtractsBothMenusWithIPBIN() throws {
        for kind in MenuKind.allCases {
            let assets = try MenuRebuildService.assetsURL(for: kind)
            let ip = assets.appendingPathComponent("IP.BIN").path
            #expect(FileManager.default.fileExists(atPath: ip))
            #expect(FileManager.default.fileExists(atPath: assets.appendingPathComponent("menu_data").path))
            #expect(FileManager.default.fileExists(atPath: assets.appendingPathComponent("menu_gdi").path))
        }
    }

    @Test func assetsURLWorksOffMainActor() async throws {
        let assets = try await Task.detached {
            try MenuRebuildService.assetsURL(for: .gdMenu)
        }.value
        #expect(FileManager.default.fileExists(atPath: assets.appendingPathComponent("IP.BIN").path))
    }
}
