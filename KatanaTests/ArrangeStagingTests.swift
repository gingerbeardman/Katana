import Foundation
import Testing
@testable import Katana

/// Reorder commands must stage in Arrange and leave the card alone until Apply.
@MainActor
struct ArrangeStagingTests {
    @Test func moveToTopEntersArrangeWithoutTouchingDisk() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try seededState(root: root)
        let last = try #require(state.games.last)
        let before = try folderNames(at: root)
        state.selection = [last.id]

        state.moveSelectionToTop()

        #expect(state.isArranging)
        #expect(state.arrangeIsDirty)
        #expect(state.arrangedGames.map(\.name) == ["GDMENU", "C", "A", "B"])
        #expect(state.games.map(\.name) == ["GDMENU", "A", "B", "C"])
        #expect(state.games.map(\.number) == [1, 2, 3, 4])
        #expect(try folderNames(at: root) == before)
        #expect(state.arrangedGames[1].id == last.id)
        #expect(state.pendingSlot(for: last.id) == 2)
    }

    @Test func moveToBottomEntersArrangeWithoutTouchingDisk() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try seededState(root: root)
        let firstGame = state.games[1]
        let before = try folderNames(at: root)
        state.selection = [firstGame.id]

        state.moveSelectionToBottom()

        #expect(state.isArranging)
        #expect(state.arrangedGames.map(\.name) == ["GDMENU", "B", "C", "A"])
        #expect(state.games.map(\.name) == ["GDMENU", "A", "B", "C"])
        #expect(try folderNames(at: root) == before)
        #expect(state.pendingSlot(for: firstGame.id) == 4)
    }

    @Test func moveUpThenTopStayPendingUntilCancel() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try seededState(root: root)
        let before = try folderNames(at: root)
        let c = state.games[3]
        state.selection = [c.id]
        state.displaySort = .discOrder

        state.moveSelectionTowardTop()
        #expect(state.arrangedGames.map(\.name) == ["GDMENU", "A", "C", "B"])
        state.moveSelectionToTop()
        #expect(state.arrangedGames.map(\.name) == ["GDMENU", "C", "A", "B"])
        #expect(try folderNames(at: root) == before)

        state.cancelArrange()
        #expect(!state.isArranging)
        #expect(state.games.map(\.name) == ["GDMENU", "A", "B", "C"])
        #expect(try folderNames(at: root) == before)
    }

    @Test func applyOfStagedOrderWritesFoldersOnce() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try seededState(root: root)
        state.selection = [state.games[3].id]
        state.moveSelectionToTop()
        #expect(state.games.map(\.name) == ["GDMENU", "A", "B", "C"])

        _ = try CardOperations.applyOrder(
            orderedIDs: state.pendingCardOrderIDs,
            games: state.games,
            rootURL: root
        )
        let onDisk = try loadEntries(root: root)
        #expect(onDisk.map(\.name) == ["GDMENU", "C", "A", "B"])
        #expect(onDisk.map(\.folderURL.lastPathComponent) == ["01", "02", "03", "04"])
    }

    @Test func tableDropEntersArrangeAndReordersWithoutWriting() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try seededState(root: root)
        let before = try folderNames(at: root)
        let c = state.games[3]
        let a = state.games[1]
        state.acceptReorderDrop(sourceID: c.id, before: a.id)
        #expect(state.isArranging)
        #expect(state.arrangedGames.map(\.name) == ["GDMENU", "C", "A", "B"])
        #expect(try folderNames(at: root) == before)
    }

    @Test func dropPendingUsesDraggedRowAndSelection() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try seededState(root: root)
        state.beginArrange()
        let a = state.games[1]
        let b = state.games[2]
        state.selection = [a.id, b.id]
        state.dropPending(id: b.id, before: 4)
        #expect(state.arrangedGames.map(\.name) == ["GDMENU", "C", "A", "B"])
    }

    @Test func dragSelectedBlockMovesTogether() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try seededState(root: root)
        state.beginArrange()
        state.selection = [state.games[1].id, state.games[2].id] // A, B
        // Drag only B (index 2) to the end — selection expands to A+B.
        state.movePending(fromOffsets: IndexSet(integer: 2), toOffset: 4)
        #expect(state.arrangedGames.map(\.name) == ["GDMENU", "C", "A", "B"])
        #expect(state.games.map(\.name) == ["GDMENU", "A", "B", "C"])
    }

    @Test func cannotMoveMenuToTop() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B"])
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try seededState(root: root)
        state.selection = [state.games[0].id]
        #expect(!state.canMoveSelectionToTop)
        state.moveSelectionToTop()
        #expect(!state.isArranging)
        #expect(state.games.map(\.name) == ["GDMENU", "A", "B"])
    }

    @Test func arrangeKeepsNewestFirstVisualOrder() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try seededState(root: root)
        state.displaySort = .mostRecentFirst
        state.beginArrange()
        #expect(state.arrangedGames.map(\.name) == ["C", "B", "A", "GDMENU"])
        #expect(!state.arrangeIsDirty)
        #expect(state.pendingSlot(for: state.games[3].id) == 4)
        #expect(state.pendingSlot(for: state.games[0].id) == 1)
    }

    @Test func newestFirstDragSwapsHighestSlotsOnly() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try seededState(root: root)
        state.displaySort = .mostRecentFirst
        state.beginArrange()
        let c = state.games[3]
        let b = state.games[2]
        state.selection = [c.id]
        // Drag C (visual top, index 0) down one row.
        state.movePending(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(state.arrangedGames.map(\.name) == ["B", "C", "A", "GDMENU"])
        #expect(state.pendingCardOrderIDs.map { id in state.games.first { $0.id == id }!.name }
                == ["GDMENU", "A", "C", "B"])
        #expect(state.pendingSlot(for: b.id) == 4)
        #expect(state.pendingSlot(for: c.id) == 3)
        #expect(state.games.map(\.name) == ["GDMENU", "A", "B", "C"])
    }

    @Test func alreadyAtTopDisablesMoveToTop() throws {
        let root = try makeFixture(names: ["GDMENU", "A", "B"])
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try seededState(root: root)
        state.selection = [state.games[1].id]
        #expect(!state.canMoveSelectionToTop)
        #expect(state.canMoveSelectionToBottom)
    }

    private func seededState(root: URL) throws -> AppState {
        let state = AppState()
        state.volume = CardVolume(
            rootURL: root,
            volumeUUID: "test-\(UUID().uuidString)",
            volumeName: "TestCard",
            freeBytes: nil,
            totalBytes: nil,
            isReadOnly: false
        )
        state.games = try loadEntries(root: root)
        state.displaySort = .discOrder
        return state
    }

    private func folderNames(at root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { FolderNumbering.parse($0) != nil }
            .sorted { (FolderNumbering.parse($0) ?? 0) < (FolderNumbering.parse($1) ?? 0) }
    }

    private func makeFixture(names: [String]) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "katana-arrange-\(UUID().uuidString)",
            isDirectory: true
        )
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

    private func loadEntries(root: URL) throws -> [GameEntry] {
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        var games: [GameEntry] = []
        for child in children {
            guard let number = FolderNumbering.parse(child.lastPathComponent) else { continue }
            let name = (try? String(
                contentsOf: child.appendingPathComponent("name.txt"),
                encoding: .utf8
            )) ?? child.lastPathComponent
            games.append(
                GameEntry(
                    id: UUID(),
                    number: number,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    serial: "",
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
