import Foundation
import Testing
@testable import Katana

struct GameEntryTests {
    private func entry(
        format: DiscFormat = .gdi,
        byteSize: Int64,
        detailsLoaded: Bool,
        ipHeader: IpBinInfo? = nil
    ) -> GameEntry {
        GameEntry(
            id: UUID(),
            number: 2,
            name: "Test",
            serial: "MK-1",
            format: format,
            imageFileName: format == .gdi ? "disc.gdi" : "disc.cdi",
            folderPath: "/tmp/02",
            byteSize: byteSize,
            payloadByteSize: byteSize,
            contentSHA256: nil,
            isMenu: false,
            detailsLoaded: detailsLoaded,
            ipHeader: ipHeader
        )
    }

    @Test func needsEnrichmentWhenDetailsNotLoaded() {
        #expect(entry(byteSize: 50, detailsLoaded: false).needsDetailEnrichment)
    }

    @Test func needsEnrichmentForTinyGDIEvenIfMarkedLoaded() {
        // disc.gdi cue file size mistaken for full size in older caches.
        #expect(entry(format: .gdi, byteSize: 512, detailsLoaded: true).needsDetailEnrichment)
        #expect(entry(format: .gdi, byteSize: 999_999, detailsLoaded: true).needsDetailEnrichment)
    }

    @Test func fullyLoadedGDIDoesNotNeedEnrichment() {
        let ip = IpBinInfo.fallback(name: "Test", serial: "MK-1")
        #expect(!entry(format: .gdi, byteSize: 1_188_000_000, detailsLoaded: true, ipHeader: ip).needsDetailEnrichment)
    }

    @Test func loadedEntryWithoutIpHeaderStillEnriches() {
        // Warm menu rebuilds: enrichment must backfill missing IP.BIN headers.
        #expect(entry(format: .gdi, byteSize: 1_188_000_000, detailsLoaded: true).needsDetailEnrichment)
    }

    @Test func largeProvisionalCDIStillEnrichesUntilFlagSet() {
        let g = entry(format: .cdi, byteSize: 800_000_000, detailsLoaded: false)
        #expect(g.needsDetailEnrichment)
    }

    @Test func loadedCDIDoesNotNeedEnrichment() {
        let ip = IpBinInfo.fallback(name: "Test", serial: "MK-1")
        #expect(!entry(format: .cdi, byteSize: 800_000_000, detailsLoaded: true, ipHeader: ip).needsDetailEnrichment)
    }
}

struct OpenMenuRegionTests {
    @Test func cleanedJUEOrderAndStripsJunk() {
        #expect(OpenMenuRegion.cleaned("eu") == "UE")
        #expect(OpenMenuRegion.cleaned("J U E extra") == "JUE")
        #expect(OpenMenuRegion.cleaned("xyz") == "")
        #expect(OpenMenuRegion.cleaned("") == "")
    }
}

struct OpenMenuFolderPathTests {
    @Test func cleanedNormalizesSlashesAndDropsEmpties() {
        #expect(OpenMenuFolderPath.cleaned("Games/RPGs") == "Games\\RPGs")
        #expect(OpenMenuFolderPath.cleaned(" \\Games\\ \\JP\\ ") == "Games\\JP")
        #expect(OpenMenuFolderPath.cleaned("") == "")
    }

    @Test func knownFoldersUniquesAndSortsPrimaryAndExtras() {
        func game(_ number: Int, folder: String, extras: [String] = [], isMenu: Bool = false) -> GameEntry {
            GameEntry(
                id: UUID(),
                number: number,
                name: isMenu ? "openMenu" : "Game \(number)",
                serial: "",
                format: .cdi,
                imageFileName: "disc.cdi",
                folderPath: "/tmp/\(number)",
                byteSize: 1,
                payloadByteSize: 1,
                contentSHA256: nil,
                isMenu: isMenu,
                virtualFolder: folder,
                extraFolders: extras
            )
        }
        let folders = OpenMenuFolderPath.knownFolders(in: [
            game(1, folder: "Games\\RPGs", isMenu: true),
            game(2, folder: "Games\\RPGs", extras: ["Favorites", "Games\\A-Z"]),
            game(3, folder: "games\\rpgs"),
            game(4, folder: "", extras: ["Favorites"]),
            game(5, folder: "Homebrew"),
        ])
        #expect(Set(folders) == Set([
            "Favorites", "Games", "Games\\A-Z", "Games\\RPGs", "Homebrew", "games", "games\\rpgs",
        ]))
        #expect(folders == folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func prefixesWalksNestedSegments() {
        #expect(OpenMenuFolderPath.prefixes(of: "Games/RPGs/Shenmue") == [
            "Games", "Games\\RPGs", "Games\\RPGs\\Shenmue",
        ])
        #expect(OpenMenuFolderPath.prefixes(of: "") == [])
    }

    @Test func extrasDedupAgainstPrimaryAndCapAtFive() {
        let extras = OpenMenuFolderPath.cleanedExtras(
            ["Games\\RPGs", "A", "B", "C", "D", "E", "F"],
            excluding: "Games\\RPGs"
        )
        #expect(extras == ["A", "B", "C", "D", "E"])
    }
}
