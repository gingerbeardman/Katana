import Foundation
import Testing
@testable import Katana

struct CardListOrderTests {
    private let menu = UUID()
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    @Test func pinningMenuMovesMenuFirst() {
        let ids = [a, menu, b]
        #expect(CardListOrder.pinningMenu(ids: ids, menuID: menu) == [menu, a, b])
        #expect(CardListOrder.pinningMenu(ids: ids, menuID: nil) == ids)
    }

    @Test func movingIgnoresMenuRowAndPinsResult() {
        // [menu, a, b, c] move c before a → [menu, c, a, b]
        let ids = [menu, a, b, c]
        let next = CardListOrder.moving(
            ids: ids,
            fromOffsets: IndexSet(integer: 3),
            toOffset: 1,
            menuID: menu
        )
        #expect(next == [menu, c, a, b])
    }

    @Test func movingCannotPlaceGamesBeforeMenu() {
        let ids = [menu, a, b]
        let next = CardListOrder.moving(
            ids: ids,
            fromOffsets: IndexSet(integer: 2),
            toOffset: 0,
            menuID: menu
        )
        #expect(next.first == menu)
        #expect(next.contains(b))
    }

    @Test func movingSelectionUpStopsAfterMenu() {
        let ids = [menu, a, b, c]
        let upOnce = CardListOrder.movingSelection(
            ids: ids,
            selected: [a],
            up: true,
            menuID: menu
        )
        #expect(upOnce == [menu, a, b, c])

        let upB = CardListOrder.movingSelection(
            ids: ids,
            selected: [b],
            up: true,
            menuID: menu
        )
        #expect(upB == [menu, b, a, c])
    }

    @Test func movingSelectionDownMovesBlock() {
        let ids = [menu, a, b, c]
        let next = CardListOrder.movingSelection(
            ids: ids,
            selected: [a, b],
            up: false,
            menuID: menu
        )
        #expect(next == [menu, c, a, b])
    }

    @Test func movingSelectionToTopSitsAfterMenu() {
        let ids = [menu, a, b, c]
        let next = CardListOrder.movingSelectionToExtreme(
            ids: ids,
            selected: [c],
            toTop: true,
            menuID: menu
        )
        #expect(next == [menu, c, a, b])
        let alreadyTop = CardListOrder.movingSelectionToExtreme(
            ids: ids,
            selected: [a],
            toTop: true,
            menuID: menu
        )
        #expect(alreadyTop == ids)
    }

    @Test func movingSelectionToBottomGoesLast() {
        let ids = [menu, a, b, c]
        let next = CardListOrder.movingSelectionToExtreme(
            ids: ids,
            selected: [a],
            toTop: false,
            menuID: menu
        )
        #expect(next == [menu, b, c, a])
    }

    @Test func movingSelectionToTopPacksMultiSelect() {
        let ids = [menu, a, b, c]
        let next = CardListOrder.movingSelectionToExtreme(
            ids: ids,
            selected: [a, c],
            toTop: true,
            menuID: menu
        )
        #expect(next == [menu, a, c, b])
    }

    @Test func movingSelectionToExtremeIgnoresMenu() {
        let ids = [menu, a, b]
        let next = CardListOrder.movingSelectionToExtreme(
            ids: ids,
            selected: [menu, b],
            toTop: true,
            menuID: menu
        )
        #expect(next.first == menu)
        #expect(next == [menu, b, a])
    }

    @Test func movingExpandsToWholeSelectionWhenDragIncludesOne() {
        let ids = [menu, a, b, c]
        // Drag only `b` while `a` and `b` are selected → move the block.
        let next = CardListOrder.moving(
            ids: ids,
            fromOffsets: IndexSet(integer: 2),
            toOffset: 4,
            menuID: menu,
            selected: [a, b]
        )
        #expect(next == [menu, c, a, b])
    }

    @Test func movingUnselectedRowDoesNotPullTheSelection() {
        let ids = [menu, a, b, c]
        // Drag `c` while `a` is selected — only `c` moves.
        let next = CardListOrder.moving(
            ids: ids,
            fromOffsets: IndexSet(integer: 3),
            toOffset: 1,
            menuID: menu,
            selected: [a]
        )
        #expect(next == [menu, c, a, b])
    }

    @Test func movingSelectionToBottomPacksMultiSelect() {
        let ids = [menu, a, b, c]
        let next = CardListOrder.movingSelectionToExtreme(
            ids: ids,
            selected: [a, b],
            toTop: false,
            menuID: menu
        )
        #expect(next == [menu, c, a, b])
    }

    @Test func severalPendingMovesStayInMemory() {
        var ids = [menu, a, b, c]
        ids = CardListOrder.movingSelection(ids: ids, selected: [c], up: true, menuID: menu)
        #expect(ids == [menu, a, c, b])
        ids = CardListOrder.movingSelectionToExtreme(ids: ids, selected: [c], toTop: true, menuID: menu)
        #expect(ids == [menu, c, a, b])
        ids = CardListOrder.movingSelectionToExtreme(ids: ids, selected: [c], toTop: false, menuID: menu)
        #expect(ids == [menu, a, b, c])
        #expect(ids.first == menu)
    }

    @Test func cardOrderFromNewestFirstIsSlotOrder() {
        let display = [c, b, a, menu]
        let card = CardListOrder.cardOrder(
            fromDisplayOrder: display,
            menuID: menu,
            newestFirst: true
        )
        #expect(card == [menu, a, b, c])
    }

    @Test func cardOrderNewestFirstSwapAtTopOnlySwapsHighestSlots() {
        // Newest first: C, B, A, menu. Swap C and B.
        let display = [b, c, a, menu]
        let card = CardListOrder.cardOrder(
            fromDisplayOrder: display,
            menuID: menu,
            newestFirst: true
        )
        #expect(card == [menu, a, c, b])
    }

    @Test func cardOrderFromSlotDisplayIsUnchanged() {
        let display = [menu, a, b, c]
        let card = CardListOrder.cardOrder(
            fromDisplayOrder: display,
            menuID: menu,
            newestFirst: false
        )
        #expect(card == [menu, a, b, c])
    }

    @Test func newestFirstMoveUpDoesNotJumpMenuToTop() {
        let display = [c, b, a, menu]
        let next = CardListOrder.movingSelection(
            ids: display,
            selected: [b],
            up: true,
            menuID: menu
        )
        #expect(next == [b, c, a, menu])
        #expect(next.last == menu)
    }

    @Test func newestFirstMoveToVisualTop() {
        let display = [c, b, a, menu]
        let next = CardListOrder.movingSelectionToExtreme(
            ids: display,
            selected: [a],
            toTop: true,
            menuID: menu
        )
        #expect(next == [a, c, b, menu])
        #expect(next.last == menu)
    }
}

struct DisplaySortPreferenceTests {
    @Test func newestFirstVisualUpRaisesSlot() {
        #expect(!DisplaySortPreference.mostRecentFirst.visualUpLowersSlot)
        #expect(DisplaySortPreference.mostRecentFirst.followsSlotOrder)
        #expect(DisplaySortPreference.discOrder.visualUpLowersSlot)
        #expect(DisplaySortPreference(field: .name, ascending: true).visualUpLowersSlot)
        #expect(DisplaySortPreference(field: .name, ascending: false).visualUpLowersSlot)
    }
}
