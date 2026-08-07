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

    // MARK: - Fixtures

    private func makeFixture(names: [String]) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dcgdsd-ops-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let max = names.count
        for (i, name) in names.enumerated() {
            let n = i + 1
            let folder = root.appendingPathComponent(FolderNumbering.format(n, maxNumber: max), isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try name.write(to: folder.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
            try "S\(n)".write(to: folder.appendingPathComponent("serial.txt"), atomically: true, encoding: .utf8)
            try Data("x".utf8).write(to: folder.appendingPathComponent("disc.cdi"))
        }
        return root
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
