import Foundation
import Testing
@testable import Katana

struct CardOperationsTests {
    @Test func renameWritesNameTxt() throws {
        let root = try makeFixture(names: ["GDMENU", "Sonic", "Crazy Taxi"])
        defer { try? FileManager.default.removeItem(at: root) }

        let sonic = root.appendingPathComponent("02")
        let game = GameEntry(
            id: UUID(),
            number: 2,
            name: "Sonic",
            serial: "MK-1",
            format: .cdi,
            imageFileName: "disc.cdi",
            folderPath: sonic.path,
            byteSize: 4,
            payloadByteSize: 4,
            contentSHA256: nil,
            isMenu: false
        )

        let previous = try CardOperations.rename(game: game, to: "Sonic Adventure")
        #expect(previous == "Sonic")
        let written = try String(contentsOf: sonic.appendingPathComponent("name.txt"), encoding: .utf8)
        #expect(written == "Sonic Adventure")
    }

    @Test func writeOpenMenuMetaRoundTripsFolderTypeAndExtras() throws {
        let root = try makeFixture(names: ["openMenu", "Shenmue"])
        defer { try? FileManager.default.removeItem(at: root) }

        let games = try loadEntries(root: root)
        let game = games[1]
        let previous = try CardOperations.writeOpenMenuMeta(
            game: game,
            virtualFolder: "Games/RPGs",
            extraFolders: ["Games\\A-Z", "Favorites", "Games\\RPGs"],
            discType: .psx
        )
        #expect(previous.virtualFolder.isEmpty)
        #expect(previous.discType == .game)

        let folder = try String(contentsOf: game.folderURL.appendingPathComponent("folder.txt"), encoding: .utf8)
        #expect(folder == "Games\\RPGs")
        let alt1 = try String(contentsOf: game.folderURL.appendingPathComponent("folder_alt1.txt"), encoding: .utf8)
        #expect(alt1 == "Games\\A-Z")
        let alt2 = try String(contentsOf: game.folderURL.appendingPathComponent("folder_alt2.txt"), encoding: .utf8)
        #expect(alt2 == "Favorites")
        #expect(!FileManager.default.fileExists(atPath: game.folderURL.appendingPathComponent("folder_alt3.txt").path))
        let type = try String(contentsOf: game.folderURL.appendingPathComponent("type.txt"), encoding: .utf8)
        #expect(type == "psx")

        _ = try CardOperations.writeOpenMenuMeta(
            game: game,
            virtualFolder: "",
            extraFolders: [],
            discType: .game
        )
        #expect(!FileManager.default.fileExists(atPath: game.folderURL.appendingPathComponent("folder.txt").path))
        #expect(!FileManager.default.fileExists(atPath: game.folderURL.appendingPathComponent("folder_alt1.txt").path))
        let clearedType = try String(contentsOf: game.folderURL.appendingPathComponent("type.txt"), encoding: .utf8)
        #expect(clearedType == "game")
    }

    @Test func writeDiscAndRegionSidecars() throws {
        let root = try makeFixture(names: ["openMenu", "Shenmue"])
        defer { try? FileManager.default.removeItem(at: root) }

        let games = try loadEntries(root: root)
        let game = games[1]
        _ = try CardOperations.writeDiscLabel(game: game, to: " 2 / 4 ")
        _ = try CardOperations.writeRegionLabel(game: game, to: "eu j")
        _ = try CardOperations.writeSerial(game: game, to: "MK-51059-extra")

        let disc = try String(contentsOf: game.folderURL.appendingPathComponent("disc.txt"), encoding: .utf8)
        #expect(disc == "2 / 4")
        let region = try String(contentsOf: game.folderURL.appendingPathComponent("region.txt"), encoding: .utf8)
        #expect(region == "JUE")
        let serial = try String(contentsOf: game.folderURL.appendingPathComponent("serial.txt"), encoding: .utf8)
        #expect(serial == "MK-51059-ext")

        _ = try CardOperations.writeDiscLabel(game: game, to: "")
        _ = try CardOperations.writeRegionLabel(game: game, to: "xyz")
        #expect(!FileManager.default.fileExists(atPath: game.folderURL.appendingPathComponent("disc.txt").path))
        #expect(!FileManager.default.fileExists(atPath: game.folderURL.appendingPathComponent("region.txt").path))
    }

    @Test func deleteSoftTrashesAndRenumbers() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: root) }

        let games = try loadEntries(root: root)
        let remove = games[2] // B at 03

        let result = try CardOperations.delete(gameID: remove.id, games: games, rootURL: root)
        #expect(result.trashed.count == 1)
        #expect(FileManager.default.fileExists(atPath: result.trashed[0].trashURL.path))

        // Remaining should be 01, 02, 03
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("01").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("02").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("03").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("04").path))

        let name02 = try String(contentsOf: root.appendingPathComponent("02/name.txt"), encoding: .utf8)
        let name03 = try String(contentsOf: root.appendingPathComponent("03/name.txt"), encoding: .utf8)
        #expect(name02 == "A")
        #expect(name03 == "C")
    }

    @Test func deleteMultipleSoftTrashesAndRenumbers() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C", "D"])
        defer { try? FileManager.default.removeItem(at: root) }

        let games = try loadEntries(root: root)
        // Remove A and C (indices 1 and 3)
        let ids: Set<UUID> = [games[1].id, games[3].id]
        let result = try CardOperations.delete(gameIDs: ids, games: games, rootURL: root)
        #expect(result.trashed.count == 2)
        #expect(result.updatedGames.count == 3)
        #expect(result.updatedGames.map(\.name) == ["GDMENU", "B", "D"])
        #expect(result.updatedGames.map(\.number) == [1, 2, 3])

        // Remaining: GDMENU, B, D → 01, 02, 03
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("01").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("02").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("03").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("04").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("05").path))

        let name02 = try String(contentsOf: root.appendingPathComponent("02/name.txt"), encoding: .utf8)
        let name03 = try String(contentsOf: root.appendingPathComponent("03/name.txt"), encoding: .utf8)
        #expect(name02 == "B")
        #expect(name03 == "D")

        // Paths on updatedGames point at final folders.
        #expect(result.updatedGames[1].folderURL.lastPathComponent == "02")
        #expect(result.updatedGames[2].folderURL.lastPathComponent == "03")
    }

    @Test func deleteLastGameSkipsRenumber() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B"])
        defer { try? FileManager.default.removeItem(at: root) }

        let games = try loadEntries(root: root)
        let last = games[2]
        let result = try CardOperations.delete(gameID: last.id, games: games, rootURL: root)
        #expect(result.updatedGames.count == 2)
        #expect(result.updatedGames.map(\.folderURL.lastPathComponent) == ["01", "02"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("01").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("02").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("03").path))
    }

    @Test func reorderSwapsFolders() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B"])
        defer { try? FileManager.default.removeItem(at: root) }

        var games = try loadEntries(root: root)
        // Swap A and B → GDMENU, B, A
        let order = [games[0].id, games[2].id, games[1].id]
        try CardOperations.applyOrder(orderedIDs: order, games: games, rootURL: root)

        let n2 = try String(contentsOf: root.appendingPathComponent("02/name.txt"), encoding: .utf8)
        let n3 = try String(contentsOf: root.appendingPathComponent("03/name.txt"), encoding: .utf8)
        #expect(n2 == "B")
        #expect(n3 == "A")
    }

    @Test func reorderDoesNotRewriteUnchangedPaddedFolders() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("katana-pad-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 3-digit names under 100, plus 100 — a 2-slot swap must not park 001–099.
        for n in 1...100 {
            let folder = root.appendingPathComponent(String(format: "%03d", n), isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try "G\(n)".write(to: folder.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
            try Data("x".utf8).write(to: folder.appendingPathComponent("disc.cdi"))
        }
        let games = try loadEntries(root: root)
        #expect(games.count == 100)
        var order = games.map(\.id)
        order.swapAt(98, 99)
        try CardOperations.applyOrder(orderedIDs: order, games: games, rootURL: root)

        #expect(fm.fileExists(atPath: root.appendingPathComponent("001").path))
        let g1 = try String(contentsOf: root.appendingPathComponent("001/name.txt"), encoding: .utf8)
        #expect(g1 == "G1")
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".katana-tmp").path))
        let n99 = try String(contentsOf: root.appendingPathComponent("99/name.txt"), encoding: .utf8)
        let n100 = try String(contentsOf: root.appendingPathComponent("100/name.txt"), encoding: .utf8)
        #expect(n99 == "G100")
        #expect(n100 == "G99")
    }

    @Test func recoverParkedRenumberFoldersRestoresToFreeSlots() throws {
        let root = try makeFixture(names: ["GDMENU", "Keep"])
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let tmp = root.appendingPathComponent(CardOperations.tmpFolderName, isDirectory: true)
        let parked = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: parked, withIntermediateDirectories: true)
        try "Lost".write(to: parked.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
        try Data("x".utf8).write(to: parked.appendingPathComponent("disc.cdi"))

        let restored = try CardOperations.recoverParkedRenumberFolders(rootURL: root)
        #expect(restored == 1)
        #expect(fm.fileExists(atPath: root.appendingPathComponent("03").path))
        let name = try String(contentsOf: root.appendingPathComponent("03/name.txt"), encoding: .utf8)
        #expect(name == "Lost")
        #expect(!fm.fileExists(atPath: parked.path))
    }

    @Test func recoverParkedRenumberFoldersRestoresManyGames() throws {
        let root = try makeFixture(names: ["GDMENU"])
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let tmp = root.appendingPathComponent(CardOperations.tmpFolderName, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for title in ["Sonic", "Crazy Taxi", "Jet Set Radio", "Shenmue"] {
            let parked = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: parked, withIntermediateDirectories: true)
            try title.write(to: parked.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
            try Data("x".utf8).write(to: parked.appendingPathComponent("disc.cdi"))
        }
        let restored = try CardOperations.recoverParkedRenumberFolders(rootURL: root)
        #expect(restored == 4)
        let games = try loadEntries(root: root)
        #expect(games.count == 5)
        #expect(Set(games.map(\.name)).isSuperset(of: ["GDMENU", "Sonic", "Crazy Taxi", "Jet Set Radio", "Shenmue"]))
    }

    @Test func overlappingApplyOrderStillLeavesEveryFolder() async throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C", "D", "E"])
        defer { try? FileManager.default.removeItem(at: root) }
        let games = try loadEntries(root: root)
        let ids = games.map(\.id)
        var swapLast = ids
        swapLast.swapAt(4, 5)
        var swapMid = ids
        swapMid.swapAt(2, 3)

        async let first: Void = {
            try CardOperations.applyOrder(orderedIDs: swapLast, games: games, rootURL: root)
        }()
        async let second: Void = {
            try CardOperations.applyOrder(orderedIDs: swapMid, games: games, rootURL: root)
        }()
        _ = try? await first
        _ = try? await second
        let recovered = try CardOperations.recoverParkedRenumberFolders(rootURL: root)
        _ = recovered
        let remaining = try loadEntries(root: root)
        #expect(remaining.count == 6)
        #expect(Set(remaining.map(\.name)) == ["GDMENU", "A", "B", "C", "D", "E"])
    }

    @Test func importCDICreatesNextSlotWithNameAndSerial() throws {
        let root = try makeFixture(names: ["GDMENU", "Sonic"])
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        let sourceDir = fm.temporaryDirectory
            .appendingPathComponent("katana-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sourceDir) }

        let cdi = sourceDir.appendingPathComponent("CrazyTaxi.cdi")
        try Data(repeating: 0x5A, count: 64).write(to: cdi)

        let games = try loadEntries(root: root)
        let result = try CardOperations.importDiscs(
            sources: [cdi],
            games: games,
            rootURL: root
        )

        #expect(result.added.count == 1)
        #expect(result.games.count == 3)
        #expect(result.added[0].number == 3)
        #expect(result.added[0].imageFileName == "disc.cdi")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("03/disc.cdi").path))
        let name = try String(
            contentsOf: root.appendingPathComponent("03/name.txt"),
            encoding: .utf8
        )
        // GCM-style: title from source filename, not a collapsed GameDB name.
        #expect(name == "CrazyTaxi")
        #expect(result.added[0].name == "CrazyTaxi")
    }

    @Test func importEmitsPreparedSlotBeforeCopyFinishes() throws {
        let root = try makeFixture(names: ["GDMENU"])
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        let sourceDir = fm.temporaryDirectory
            .appendingPathComponent("katana-import-ev-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sourceDir) }
        let cdi = sourceDir.appendingPathComponent("SoulCalibur.cdi")
        try Data(repeating: 0x11, count: 128).write(to: cdi)

        var sawPrepared = false
        var preparedName: String?
        var sawFinished = false
        var lastFraction: Double = -1
        var sawSegmentedProgress = false

        let games = try loadEntries(root: root)
        let result = try CardOperations.importDiscs(
            sources: [cdi],
            games: games,
            rootURL: root,
            onEvent: { event in
                switch event {
                case .slotPrepared(let entry):
                    sawPrepared = true
                    preparedName = entry.name
                    // Folder + name exist before the disc payload is fully written.
                    #expect(fm.fileExists(atPath: entry.folderPath))
                    #expect(fm.fileExists(atPath: (entry.folderPath as NSString).appendingPathComponent("name.txt")))
                case .slotFinished:
                    sawFinished = true
                case .fraction(let f):
                    lastFraction = f
                case .copyProgress(let f, let ends):
                    lastFraction = f
                    if ends.count >= 1 { sawSegmentedProgress = true }
                default:
                    break
                }
            }
        )

        #expect(sawPrepared)
        #expect(preparedName == "SoulCalibur")
        #expect(sawFinished)
        #expect(lastFraction == 1)
        #expect(sawSegmentedProgress)
        #expect(result.added.count == 1)
        #expect(result.added[0].name == "SoulCalibur")
    }

    @Test func importDisplayNamePrefersSourceFileOverIP() {
        let source = CardOperations.DiscImportSource(
            packageURL: URL(fileURLWithPath: "/tmp"),
            fileNames: ["BELTRUNNER-SHIPPLAY-DC.cdi"],
            imageFileName: "BELTRUNNER-SHIPPLAY-DC.cdi",
            hintName: "BELTRUNNER-SHIPPLAY-DC"
        )
        let ip = IpBinInfo(
            name: "BELTRUNNER",
            productNumber: "IND-743215",
            disc: "1/1",
            region: "JUE",
            vga: true,
            version: "V1.000",
            releaseDate: "20200101",
            isCodeBreaker: false
        )
        let resolved = CardOperations.importDisplayName(source: source, ip: ip)
        #expect(resolved.name == "BELTRUNNER-SHIPPLAY-DC")
        #expect(resolved.serial == "IND-743215")
    }

    @Test func importDisplayNamePrefersDatabaseWhenAutoRenaming() {
        // Plain retail-style base name (no build tags) → IP/GameDB product title.
        let source = CardOperations.DiscImportSource(
            packageURL: URL(fileURLWithPath: "/tmp"),
            fileNames: ["Beltrunner.cdi"],
            imageFileName: "Beltrunner.cdi",
            hintName: "Beltrunner"
        )
        let ip = IpBinInfo(
            name: "BELTRUNNER",
            productNumber: "IND-743215",
            disc: "1/1",
            region: "JUE",
            vga: true,
            version: "V1.000",
            releaseDate: "20200101",
            isCodeBreaker: false
        )
        let resolved = CardOperations.importDisplayName(
            source: source,
            ip: ip,
            preferDatabaseNames: true
        )
        #expect(resolved.name == "Beltrunner")
        #expect(resolved.serial == "IND-743215")

        // No IP.BIN at all → keep the source-derived name.
        let unresolved = CardOperations.importDisplayName(
            source: source,
            ip: nil,
            preferDatabaseNames: true
        )
        #expect(unresolved.name == "Beltrunner")
    }

    @Test func importDisplayNameFallsBackToSourceWhenNameReserved() {
        // Plain retail-style file name that matches a catalog title — auto-rename may use DB.
        let retail = CardOperations.DiscImportSource(
            packageURL: URL(fileURLWithPath: "/tmp"),
            fileNames: ["SoulCalibur.cdi"],
            imageFileName: "SoulCalibur.cdi",
            hintName: "SoulCalibur"
        )
        let soulIP = IpBinInfo(
            name: "SOULCALIBUR",
            productNumber: "MK-5100",
            disc: "1/1",
            region: "JUE",
            vga: true,
            version: "V1.000",
            releaseDate: "19990909",
            isCodeBreaker: false
        )
        // If GameDB has a title and reserved already claims it → source file base.
        let collision = CardOperations.importDisplayName(
            source: retail,
            ip: soulIP,
            preferDatabaseNames: true,
            reservedNames: ["Soulcalibur", "SoulCalibur", "Soul Calibur"]
        )
        #expect(collision.name == "SoulCalibur")
    }

    @Test func importDisplayNameKeepsHyphenatedBuildTags() {
        // Different homebrew serials, same IP product name — source has build tags.
        let source = CardOperations.DiscImportSource(
            packageURL: URL(fileURLWithPath: "/tmp"),
            fileNames: ["beltrunner-shipplay-f64-dc.cdi"],
            imageFileName: "beltrunner-shipplay-f64-dc.cdi",
            hintName: "beltrunner-shipplay-f64-dc"
        )
        let ip = IpBinInfo(
            name: "BELTRUNNER",
            productNumber: "IND-891378",
            disc: "1/1",
            region: "JUE",
            vga: true,
            version: "V1.000",
            releaseDate: "20200101",
            isCodeBreaker: false
        )
        let resolved = CardOperations.importDisplayName(
            source: source,
            ip: ip,
            preferDatabaseNames: true,
            reservedNames: []
        )
        #expect(resolved.name == "beltrunner-shipplay-f64-dc")
        #expect(resolved.serial == "IND-891378")
        #expect(CardOperations.prefersSourceLabel("beltrunner-busy4-stats-f32-dc", overDatabaseName: "Beltrunner"))
        #expect(!CardOperations.prefersSourceLabel("Beltrunner", overDatabaseName: "Beltrunner"))
    }

    @Test func importDisplayNameUsesFolderWhenImageIsDisc() {
        let source = CardOperations.DiscImportSource(
            packageURL: URL(fileURLWithPath: "/tmp/BELTRUNNER-COMBAT-STATS-DC"),
            fileNames: nil,
            imageFileName: "disc.gdi",
            hintName: "BELTRUNNER-COMBAT-STATS-DC"
        )
        let resolved = CardOperations.importDisplayName(source: source, ip: nil)
        #expect(resolved.name == "BELTRUNNER-COMBAT-STATS-DC")
    }

    @Test func importGameFolderCopiesPackage() throws {
        let root = try makeFixture(names: ["GDMENU"])
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        let package = fm.temporaryDirectory
            .appendingPathComponent("katana-pkg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: package) }

        try Data("gdi".utf8).write(to: package.appendingPathComponent("disc.gdi"))
        try Data("t1".utf8).write(to: package.appendingPathComponent("track01.bin"))

        let games = try loadEntries(root: root)
        let result = try CardOperations.importDiscs(
            sources: [package],
            games: games,
            rootURL: root
        )

        #expect(result.added.count == 1)
        #expect(result.games.count == 2)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("02/disc.gdi").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("02/track01.bin").path))
    }

    /// Empty in-memory list must not clobber slot 01 when the card already has folders on disk.
    @Test func importWithStaleEmptyGamesUsesNextDiskSlot() throws {
        let root = try makeFixture(names: ["GDMENU", "Sonic"])
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        let package = fm.temporaryDirectory
            .appendingPathComponent("katana-pkg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: package) }
        try Data("cdi".utf8).write(to: package.appendingPathComponent("disc.cdi"))

        // Pretend UI state is empty / desynced — disk still has 01 and 02.
        let result = try CardOperations.importDiscs(
            sources: [package],
            games: [],
            rootURL: root
        )

        #expect(result.added.count == 1)
        #expect(result.added[0].number == 3)
        #expect(fm.fileExists(atPath: root.appendingPathComponent("03/disc.cdi").path))
        // Menu slot untouched.
        #expect(fm.fileExists(atPath: root.appendingPathComponent("01/name.txt").path))
    }

    /// Deleting the last two slots then adding one must fill the first hole, not skip it.
    @Test func importFillsGapAfterDeletingLastTwoSlots() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C", "D"])
        defer { try? FileManager.default.removeItem(at: root) }

        let games = try loadEntries(root: root)
        let lastTwo = Set(games.suffix(2).map(\.id))
        let deleted = try CardOperations.delete(gameIDs: lastTwo, games: games, rootURL: root)
        #expect(deleted.updatedGames.map(\.number) == [1, 2, 3])

        let cdi = try makeTempCDI(named: "NewGame.cdi")
        defer { try? FileManager.default.removeItem(at: cdi.deletingLastPathComponent()) }

        let result = try CardOperations.importDiscs(
            sources: [cdi],
            games: deleted.updatedGames,
            rootURL: root
        )
        #expect(result.added.count == 1)
        #expect(result.added[0].number == 4)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("04/disc.cdi").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("05").path))
    }

    /// Empty leftover folder at the first hole (name.txt only) must be reused, not skipped.
    @Test func importReusesEmptyLeftoverSlotInsteadOfSkipping() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C", "D"])
        defer { try? FileManager.default.removeItem(at: root) }

        let games = try loadEntries(root: root)
        let lastTwo = Set(games.suffix(2).map(\.id))
        let deleted = try CardOperations.delete(gameIDs: lastTwo, games: games, rootURL: root)

        let leftover = root.appendingPathComponent("04", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try "stale".write(
            to: leftover.appendingPathComponent("name.txt"),
            atomically: true,
            encoding: .utf8
        )

        let cdi = try makeTempCDI(named: "FillHole.cdi")
        defer { try? FileManager.default.removeItem(at: cdi.deletingLastPathComponent()) }

        let result = try CardOperations.importDiscs(
            sources: [cdi],
            games: deleted.updatedGames,
            rootURL: root
        )
        #expect(result.added.count == 1)
        #expect(result.added[0].number == 4)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("04/disc.cdi").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("05").path))
        let name = try String(
            contentsOf: root.appendingPathComponent("04/name.txt"),
            encoding: .utf8
        )
        #expect(name == "FillHole")
    }

    /// A hole in numbering (01–03, 05) must pack then append at 05, not jump to 06.
    @Test func importAfterNumberingHoleAppendsContiguously() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.moveItem(
            at: root.appendingPathComponent("04", isDirectory: true),
            to: root.appendingPathComponent("05", isDirectory: true)
        )
        let games = try loadEntries(root: root)
        #expect(games.map(\.number) == [1, 2, 3, 5])

        let cdi = try makeTempCDI(named: "Packed.cdi")
        defer { try? FileManager.default.removeItem(at: cdi.deletingLastPathComponent()) }

        let result = try CardOperations.importDiscs(
            sources: [cdi],
            games: games,
            rootURL: root
        )
        #expect(result.added.count == 1)
        #expect(result.added[0].number == 5)
        let name04 = try String(
            contentsOf: root.appendingPathComponent("04/name.txt"),
            encoding: .utf8
        )
        #expect(name04 == "C")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("05/disc.cdi").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("06").path))
    }

    @Test func gdiReferencedFileNamesParsesCue() {
        let text = """
        3
        1 0 4 2048 track01.bin 0
        2 45000 4 2048 "track 03.iso" 0
        3 50000 0 2352 subdir\\track04.raw 0
        """
        let names = CardOperations.gdiReferencedFileNames(in: text)
        #expect(names == ["track01.bin", "track 03.iso", "track04.raw"])
    }

    /// Redump Power Smash cue: quoted names with spaces; IP.BIN lives on data tracks.
    @Test func redumpQuotedGdiCueAndIPBIN() throws {
        let text = """
        3
        1     0 4 2352 "Power Smash - Sega Professional Tennis (Japan) (Track 1).bin" 0
        2   300 0 2352 "Power Smash - Sega Professional Tennis (Japan) (Track 2).bin" 0
        3 45000 4 2352 "Power Smash - Sega Professional Tennis (Japan) (Track 3).bin" 0
        """
        let names = GdiCue.referencedFileNames(in: text)
        #expect(names.count == 3)
        #expect(names[0].contains("(Track 1).bin"))
        #expect(names[1].contains("(Track 2).bin"))
        #expect(names[2].contains("(Track 3).bin"))
        let dataTracks = GdiCue.dataTracksForIPBIN(in: text)
        #expect(dataTracks.count == 2)
        #expect(dataTracks[0].lba >= 45_000) // HD first
        #expect(dataTracks.map(\.fileName) == [names[2], names[0]])

        let folder = URL(fileURLWithPath:
            "/Users/matt/Downloads/1234_JD/almstcmpltdrmcst/almstcmpltdrmcst/Power Smash - Sega Professional Tennis (Japan)",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: folder.path) else { return }

        let gdiName = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .first { $0.lowercased().hasSuffix(".gdi") && !$0.hasPrefix(".") }
        guard let gdiName else { return }

        let ip = IpBinReader.read(folderURL: folder, imageFileName: gdiName, format: .gdi)
        #expect(ip != nil, "IP.BIN should resolve via quoted GDI track names")
        #expect(ip?.productNumber == "HDR-0113")
        #expect(ip?.name.uppercased().contains("POWER SMASH") == true)
    }

    @Test func copyProgressSegmentsAreByteWeighted() throws {
        // Cue + two tracks → chunk widths follow file sizes; fill never crosses the active
        // file's notch before it completes; hold under 1 during finalize.
        let fm = FileManager.default
        let root = try makeFixture(names: ["GDMENU"])
        defer { try? fm.removeItem(at: root) }
        let src = fm.temporaryDirectory.appendingPathComponent("katana-seg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: src) }

        let gdi = """
        2
        1 0 4 2048 small.bin 0
        2 45000 4 2048 large.bin 0
        """
        try gdi.write(to: src.appendingPathComponent("game.gdi"), atomically: true, encoding: .utf8)
        // small.bin is far below the 2% visibility floor; large.bin dominates by bytes.
        try Data(repeating: 1, count: 5).write(to: src.appendingPathComponent("small.bin"))
        try Data(repeating: 2, count: 900).write(to: src.appendingPathComponent("large.bin"))

        let gdiSize = Double((try Data(contentsOf: src.appendingPathComponent("game.gdi"))).count)
        // Mirror the import weighting: copy time per file (size ÷ write rate) plus one
        // trailing hash unit per slot (payload ÷ hash rate), with a 2% visibility floor
        // on file chunks. Explicit rates keep the math deterministic.
        let rates = CardOperations.TransferRateEstimates(
            writeBytesPerSecond: 100,
            hashBytesPerSecond: 1000
        )
        let sizes: [Double] = [gdiSize, 5, 900]
        let rawFileWeights = sizes.map { $0 / 100 }
        let hashWeight = sizes.reduce(0, +) / 1000
        let rawTotal = rawFileWeights.reduce(0, +) + hashWeight
        let floorWeight = 0.02 * rawTotal
        let fileWeights = rawFileWeights.map { max($0, floorWeight) }
        let totalWeight = fileWeights.reduce(0, +) + hashWeight
        let expectedEnds = [
            fileWeights[0] / totalWeight,
            (fileWeights[0] + fileWeights[1]) / totalWeight,
            (fileWeights[0] + fileWeights[1] + fileWeights[2]) / totalWeight,
        ]

        var lastEnds: [Double] = []
        var maxFraction: Double = 0
        var sawSubFullHold = false
        var monotonic = true
        var previousFraction = -1.0
        let games = try loadEntries(root: root)
        _ = try CardOperations.importDiscs(
            sources: [src.appendingPathComponent("game.gdi")],
            games: games,
            rootURL: root,
            rates: rates,
            onEvent: { event in
                if case .copyProgress(let f, let ends) = event {
                    maxFraction = max(maxFraction, f)
                    if f < previousFraction { monotonic = false }
                    previousFraction = f
                    if ends.count >= 2 { lastEnds = ends }
                    if abs(f - 0.99) < 0.001 { sawSubFullHold = true }
                }
            }
        )
        #expect(maxFraction == 1)
        #expect(monotonic)
        #expect(lastEnds.count == 3) // one marker per file (hash stretch has no marker)
        // Time-weighted with floor: large.bin dominates, small files keep ≥2% chunks,
        // and the last marker sits short of 1 — the hash stretch fills the tail.
        guard lastEnds.count == 3 else { return }
        #expect(abs(lastEnds[0] - expectedEnds[0]) < 0.001)
        #expect(abs(lastEnds[1] - expectedEnds[1]) < 0.001)
        #expect(abs(lastEnds[2] - expectedEnds[2]) < 0.001)
        #expect(lastEnds[1] - lastEnds[0] >= 0.019) // floor keeps tiny files' notches visible
        #expect(lastEnds[2] < 0.999) // hash tail reserved after the last file
        #expect(sawSubFullHold) // cap before finalize / final 1.0
    }

    @Test func resolveGDIPackageCopiesOnlyCueTracks() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("katana-gdi-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let gdi = """
        2
        1 0 4 2048 track01.bin 0
        2 45000 4 2048 track03.bin 0
        """
        try gdi.write(to: dir.appendingPathComponent("game.gdi"), atomically: true, encoding: .utf8)
        try Data("a".utf8).write(to: dir.appendingPathComponent("track01.bin"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("track03.bin"))
        try Data("noise".utf8).write(to: dir.appendingPathComponent("readme.txt"))
        try Data("other".utf8).write(to: dir.appendingPathComponent("other.cdi"))

        let source = try CardOperations.resolveGDIPackage(gdiURL: dir.appendingPathComponent("game.gdi"))
        #expect(source.imageFileName == "game.gdi")
        #expect(Set(source.fileNames ?? []) == Set(["game.gdi", "track01.bin", "track03.bin"]))
        #expect(!(source.fileNames ?? []).contains("readme.txt"))
        #expect(!(source.fileNames ?? []).contains("other.cdi"))
    }

    @Test func multiSelectGroupsGDIAndTracksIntoOnePackage() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("katana-multi-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let gdi = """
        2
        1 0 4 2048 track01.bin 0
        2 45000 4 2048 track03.bin 0
        """
        let gdiURL = dir.appendingPathComponent("set.gdi")
        try gdi.write(to: gdiURL, atomically: true, encoding: .utf8)
        let t1 = dir.appendingPathComponent("track01.bin")
        let t3 = dir.appendingPathComponent("track03.bin")
        try Data("a".utf8).write(to: t1)
        try Data("b".utf8).write(to: t3)

        // Simulate Finder multi-select of cue + tracks (order shouldn't matter).
        let discovery = CardOperations.resolveImportSources([t3, gdiURL, t1])
        #expect(discovery.sources.count == 1)
        #expect(discovery.skipped.isEmpty)
        #expect(Set(discovery.sources[0].fileNames ?? []) == Set(["set.gdi", "track01.bin", "track03.bin"]))
    }

    /// Real Redump-style set with quoted track names (spaces + parentheses).
    @Test func resolvePowerSmashExampleIfPresent() throws {
        let folder = URL(fileURLWithPath:
            "/Users/matt/Downloads/1234_JD/almstcmpltdrmcst/almstcmpltdrmcst/Power Smash - Sega Professional Tennis (Japan)",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: folder.path) else { return }

        let source = try CardOperations.resolveImportSource(folder)
        #expect(source.imageFileName.hasSuffix(".gdi"))
        let names = Set(source.fileNames ?? [])
        #expect(names.contains(source.imageFileName))
        #expect(names.contains { $0.contains("(Track 1).bin") })
        #expect(names.contains { $0.contains("(Track 2).bin") })
        #expect(names.contains { $0.contains("(Track 3).bin") })
        // Must not pull the sibling .7z into the game folder.
        #expect(!names.contains { $0.lowercased().hasSuffix(".7z") })

        // Multi-select cue + tracks (no folder) should group to one package.
        let gdi = folder.appendingPathComponent(source.imageFileName)
        let tracks = (source.fileNames ?? []).filter { $0 != source.imageFileName }.map {
            folder.appendingPathComponent($0)
        }
        let discovery = CardOperations.resolveImportSources([tracks[0], gdi] + Array(tracks.dropFirst()))
        #expect(discovery.sources.count == 1)
        #expect(Set(discovery.sources[0].fileNames ?? []) == names)
    }

    @Test func importZipWithGameFolder() throws {
        let root = try makeFixture(names: ["GDMENU"])
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("katana-zip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let gameDir = work.appendingPathComponent("SHIPPLAY", isDirectory: true)
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try Data("gdi".utf8).write(to: gameDir.appendingPathComponent("disc.gdi"))
        try Data("track".utf8).write(to: gameDir.appendingPathComponent("track01.bin"))

        // Build a store-only ZIP (method 0) with local file headers ZipExtractor understands.
        let zipURL = work.appendingPathComponent("pack.zip")
        try writeMinimalStoreZip(
            at: zipURL,
            entries: [
                ("SHIPPLAY/disc.gdi", Data("gdi".utf8)),
                ("SHIPPLAY/track01.bin", Data("track".utf8)),
            ]
        )

        let games = try loadEntries(root: root)
        let result = try CardOperations.importDiscs(
            sources: [zipURL],
            games: games,
            rootURL: root
        )
        #expect(result.added.count == 1)
        #expect(result.skipped.isEmpty)
        #expect(fm.fileExists(atPath: root.appendingPathComponent("02/disc.gdi").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("02/track01.bin").path))
    }

    // MARK: - Fixtures

    private func makeTempCDI(named fileName: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("katana-cdi-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let cdi = dir.appendingPathComponent(fileName)
        try Data(repeating: 0x5A, count: 64).write(to: cdi)
        return cdi
    }

    private func makeFixture(names: [String]) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("katana-ops-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for (i, name) in names.enumerated() {
            let n = i + 1
            let folder = root.appendingPathComponent(FolderNumbering.format(n), isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try name.write(to: folder.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
            try "S\(n)".write(to: folder.appendingPathComponent("serial.txt"), atomically: true, encoding: .utf8)
            try Data("x".utf8).write(to: folder.appendingPathComponent("disc.cdi"))
        }
        return root
    }

    /// Minimal ZIP with store (method 0) entries for import tests.
    private func writeMinimalStoreZip(at url: URL, entries: [(String, Data)]) throws {
        var data = Data()
        var central = Data()
        var offsets: [UInt32] = []

        for (name, payload) in entries {
            let nameData = Data(name.utf8)
            offsets.append(UInt32(data.count))
            // Local file header
            data.append(contentsOf: u32(0x0403_4b50))
            data.append(contentsOf: u16(20)) // version
            data.append(contentsOf: u16(0)) // flags
            data.append(contentsOf: u16(0)) // method store
            data.append(contentsOf: u16(0)) // time
            data.append(contentsOf: u16(0)) // date
            data.append(contentsOf: u32(0)) // crc (0 ok for our reader)
            data.append(contentsOf: u32(UInt32(payload.count)))
            data.append(contentsOf: u32(UInt32(payload.count)))
            data.append(contentsOf: u16(UInt16(nameData.count)))
            data.append(contentsOf: u16(0)) // extra
            data.append(nameData)
            data.append(payload)

            // Central directory header
            central.append(contentsOf: u32(0x0201_4b50))
            central.append(contentsOf: u16(20))
            central.append(contentsOf: u16(20))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u32(0))
            central.append(contentsOf: u32(UInt32(payload.count)))
            central.append(contentsOf: u32(UInt32(payload.count)))
            central.append(contentsOf: u16(UInt16(nameData.count)))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u32(0))
            central.append(contentsOf: u32(offsets.last!))
            central.append(nameData)
        }

        let centralOffset = UInt32(data.count)
        data.append(central)
        // End of central directory
        data.append(contentsOf: u32(0x0605_4b50))
        data.append(contentsOf: u16(0))
        data.append(contentsOf: u16(0))
        data.append(contentsOf: u16(UInt16(entries.count)))
        data.append(contentsOf: u16(UInt16(entries.count)))
        data.append(contentsOf: u32(UInt32(central.count)))
        data.append(contentsOf: u32(centralOffset))
        data.append(contentsOf: u16(0))
        try data.write(to: url)
    }

    private func u16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }

    private func u32(_ v: UInt32) -> [UInt8] {
        [
            UInt8(v & 0xff),
            UInt8((v >> 8) & 0xff),
            UInt8((v >> 16) & 0xff),
            UInt8((v >> 24) & 0xff),
        ]
    }

    private func loadEntries(root: URL) throws -> [GameEntry] {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var games: [GameEntry] = []
        for child in children {
            guard let number = FolderNumbering.parse(child.lastPathComponent) else { continue }
            let name = (try? String(contentsOf: child.appendingPathComponent("name.txt"), encoding: .utf8)) ?? child.lastPathComponent
            let serial = (try? String(contentsOf: child.appendingPathComponent("serial.txt"), encoding: .utf8)) ?? ""
            games.append(
                GameEntry(
                    id: UUID(),
                    number: number,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    serial: serial.trimmingCharacters(in: .whitespacesAndNewlines),
                    format: .cdi,
                    imageFileName: "disc.cdi",
                    folderPath: child.path,
                    byteSize: 1,
                    payloadByteSize: 1,
                    contentSHA256: nil,
                    isMenu: GameEntry.isMenuName(name) || number == 1
                )
            )
        }
        return games.sorted { $0.number < $1.number }
    }
}
