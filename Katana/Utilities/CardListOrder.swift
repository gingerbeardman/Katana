import Foundation

/// In-memory game-list order. Slot 01 (the menu) stays first until Apply writes folders.
enum CardListOrder: Sendable {
    /// Menu id first when present; other ids keep relative order.
    nonisolated static func pinningMenu(ids: [UUID], menuID: UUID?) -> [UUID] {
        guard let menuID, ids.contains(menuID) else { return ids }
        return [menuID] + ids.filter { $0 != menuID }
    }

    /// Map a *display* order (what Arrange shows) to on-card slot order (menu in 01).
    /// Newest First lists high slots at the top, so the visual list is reversed onto the card.
    nonisolated static func cardOrder(
        fromDisplayOrder ids: [UUID],
        menuID: UUID?,
        newestFirst: Bool
    ) -> [UUID] {
        let gamesOnly = ids.filter { $0 != menuID }
        let body = newestFirst ? Array(gamesOnly.reversed()) : gamesOnly
        guard let menuID else { return body }
        return [menuID] + body
    }

    /// `Array.move` then pin the menu. Menu rows in `fromOffsets` are ignored.
    /// When `selected` includes a dragged row, the whole selection moves as a block.
    nonisolated static func moving(
        ids: [UUID],
        fromOffsets: IndexSet,
        toOffset: Int,
        menuID: UUID?,
        selected: Set<UUID>? = nil
    ) -> [UUID] {
        var offsets = fromOffsets
        if let selected, !selected.isEmpty {
            let selectedOffsets = IndexSet(ids.indices.filter { selected.contains(ids[$0]) })
            if !selectedOffsets.intersection(fromOffsets).isEmpty {
                offsets = selectedOffsets
            }
        }
        let movable = IndexSet(offsets.filter { idx in
            ids.indices.contains(idx) && ids[idx] != menuID
        })
        guard !movable.isEmpty else { return ids }
        var next = ids
        let lockMenuFront = menuID != nil && ids.first == menuID
        var dest = toOffset
        if lockMenuFront {
            dest = max(dest, 1)
        }
        move(&next, fromOffsets: movable, toOffset: dest)
        if lockMenuFront, let menuID, let menuIdx = next.firstIndex(of: menuID), menuIdx != 0 {
            next.remove(at: menuIdx)
            next.insert(menuID, at: 0)
        }
        return next
    }

    /// Move selected ids as a contiguous block to right after the menu, or to the end.
    nonisolated static func movingSelectionToExtreme(
        ids: [UUID],
        selected: Set<UUID>,
        toTop: Bool,
        menuID: UUID?
    ) -> [UUID] {
        let selectedIDs = ids.filter { selected.contains($0) && $0 != menuID }
        guard !selectedIDs.isEmpty else { return ids }
        let otherIDs = ids.filter { !selectedIDs.contains($0) }
        let floor = (menuID != nil && otherIDs.first == menuID) ? 1 : 0
        let insertAt = toTop ? floor : otherIDs.count
        var next = otherIDs
        next.insert(contentsOf: selectedIDs, at: insertAt)
        return next
    }

    /// Move selected ids as a contiguous block up or down one slot (skipping the menu).
    nonisolated static func movingSelection(
        ids: [UUID],
        selected: Set<UUID>,
        up: Bool,
        menuID: UUID?
    ) -> [UUID] {
        let selectedIDs = ids.filter { selected.contains($0) && $0 != menuID }
        guard !selectedIDs.isEmpty else { return ids }
        let otherIDs = ids.filter { !selectedIDs.contains($0) }
        guard let firstSelected = ids.firstIndex(where: { selectedIDs.contains($0) }) else {
            return ids
        }
        let othersBefore = ids[0..<firstSelected].filter { !selectedIDs.contains($0) }.count
        let floor = (menuID != nil && otherIDs.first == menuID) ? 1 : 0
        let insertAt: Int
        if up {
            insertAt = max(floor, othersBefore - 1)
        } else {
            insertAt = min(otherIDs.count, othersBefore + 1)
        }
        var next = otherIDs
        next.insert(contentsOf: selectedIDs, at: insertAt)
        return next
    }

    /// Same semantics as SwiftUI `Array.move(fromOffsets:toOffset:)`.
    nonisolated private static func move(_ ids: inout [UUID], fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.sorted().map { ids[$0] }
        for index in fromOffsets.sorted(by: >) {
            ids.remove(at: index)
        }
        var dest = toOffset
        dest -= fromOffsets.filter { $0 < toOffset }.count
        dest = min(max(dest, 0), ids.count)
        ids.insert(contentsOf: moving, at: dest)
    }
}
