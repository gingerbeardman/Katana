import AppKit
import SwiftUI

/// Game table with **display-only** column sorting (Brutify / 2UP style).
/// `AppState.games` stays in on-card slot order; table sort never renumbers folders.
/// Sort preference is remembered per card volume across sessions.
struct GameListView: View {
    @Bindable var state: AppState

    /// SwiftUI Table sort state — view only, not card slot order.
    @State private var sortOrder: [KeyPathComparator<GameEntry>] = DisplaySortPreference.mostRecentFirst.comparators
    /// Bumped when we must remount the Table so column header chevrons match `sortOrder`.
    /// SwiftUI Table often keeps stale NSTableView sort indicators when `sortOrder` is
    /// set programmatically (cold open of a new/renamed volume was the worst case).
    @State private var tableRemountToken: UInt64 = 0
    /// Finder drag highlight (AppKit drop destination, same idea as 2UP pane drops).
    @State private var isDropTargeted = false

    /// Filtered list sorted for display. Does not mutate card slot order.
    private var displayedGames: [GameEntry] {
        state.filteredGames.sorted(using: sortOrder)
    }

    /// True when not sorting by slot number (either direction).
    private var isNonSlotSort: Bool {
        guard let first = sortOrder.first else { return false }
        return first.keyPath != \GameEntry.number
    }

    var body: some View {
        // Rebuild strip is a *top* sibling of the Table (not bottom safeAreaInset).
        // Bottom insets on NavigationSplitView detail + Table were clipped unless
        // the window was extremely tall — users never saw the bar.
        VStack(spacing: 0) {
            if state.volume != nil, state.menuNeedsRebuild, !state.isRebuildingMenu {
                menuRebuildBar
            }

            // Column widths, visibility, and reorder use SwiftUI’s native
            // `columnCustomization` (same pattern as 2UP): Control-click a header
            // to show/hide columns. Persisted via `AppState.tableColumnCustomizationData`.
            Table(
                displayedGames,
                selection: $state.selection,
                sortOrder: $sortOrder,
                columnCustomization: columnCustomizationBinding
            ) {
                TableColumn("#", value: \.number) { game in
                    // Slot + trailing chips (MENU / duplicate). Observes AppState for pending badges.
                    NumberColumnCell(game: game, state: state)
                }
                .width(min: 110, ideal: 110, max: 110)
                .customizationID("number")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("Title", value: \.name) { game in
                    // Observe rename state inside the cell (Table caches closures).
                    RenameAwareTitleCell(game: game, state: state)
                        .opacity(state.isDeemphasizedInList(game) ? 0.38 : 1)
                }
                // No max — absorbs leftover width (2UP Name column).
                .width(min: 160, ideal: 280)
                .customizationID("title")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("Serial", value: \.serial) { game in
                    Text(game.serial.isEmpty ? "—" : game.serial)
                        .font(.body.monospaced())
                        .foregroundStyle(game.serial.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .opacity(state.isDeemphasizedInList(game) ? 0.38 : 1)
                }
                .width(min: 72, ideal: 100, max: 140)
                .customizationID("serial")

                TableColumn("Format", value: \.formatSortKey) { game in
                    FormatBadge(format: game.format)
                        .opacity(state.isDeemphasizedInList(game) ? 0.38 : 1)
                }
                .width(min: 52, ideal: 64, max: 80)
                .customizationID("format")

                TableColumn("Size", value: \.byteSize) { game in
                    Text(state.formatGameSize(game))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .opacity(state.isDeemphasizedInList(game) ? 0.38 : 1)
                }
                .width(min: 72, ideal: 88, max: 110)
                .customizationID("size")
            }
            // Keep rows visible while scanning / rebuilding / mutating — block interaction only.
            // Imports paint placeholders with row spinners; no center blocking card.
            // No card: empty chrome only (open from sidebar); don’t allow sort/select.
            .disabled(state.volume == nil || state.isScanning || state.isRebuildingMenu || state.isBusy)
            .opacity(
                state.volume == nil
                    ? 0.55
                    // Light dim only for full-card scan/rebuild; mutations stay fully opaque.
                    : (state.isScanning || state.isRebuildingMenu) ? 0.72 : 1
            )
            // Remount when volume or programmed sort changes so header chevrons match data order.
            .id(tableIdentity)
            .contextMenu(forSelectionType: GameEntry.ID.self) { selectedIDs in
                selectionContextMenu(selectedIDs)
            } primaryAction: { selectedIDs in
                // Double-click: Finder-style inline rename (not inspector).
                if selectedIDs.count == 1, let id = selectedIDs.first {
                    state.beginInlineRename(id)
                }
            }
            .onKeyPress(.return) {
                guard state.renamingGameID == nil,
                      !state.isBusy,
                      !state.isScanning,
                      !state.isRebuildingMenu,
                      state.selection.count == 1,
                      let id = state.selection.first
                else { return .ignored }
                state.beginInlineRename(id)
                return .handled
            }
            .overlay(alignment: .top) {
                // Shared chunked edge bar — scan / rebuild / mutations all use the same chrome.
                if state.isScanning, let progress = state.scanProgress, progress.total > 0 {
                    EdgeProgressBar(
                        fraction: min(1, max(0, Double(progress.completed) / Double(progress.total))),
                        color: .accentColor,
                        segmentEnds: EdgeProgressBar.equalEnds(count: progress.total)
                    )
                } else if state.isRebuildingMenu {
                    EdgeProgressBar(
                        fraction: state.rebuildProgress ?? 0,
                        color: .orange,
                        segmentEnds: EdgeProgressBar.rebuildStageEnds
                    )
                } else if state.isMutating {
                    if let fraction = state.mutationProgress {
                        EdgeProgressBar(
                            fraction: fraction,
                            color: .accentColor,
                            segmentEnds: state.mutationProgressSegments ?? []
                        )
                    } else {
                        IndeterminateEdgeProgressBar(color: .accentColor)
                    }
                }
            }
            .overlay {
                // Empty search only — mutations use the edge bar, not a center card.
                // No-card empty state lives in the sidebar (Open / Reopen).
                if state.volume != nil,
                   state.filteredGames.isEmpty,
                   !state.isScanning,
                   !state.isMutating
                {
                    ContentUnavailableView.search(text: state.searchText)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if state.volume != nil, isNonSlotSort {
                    displaySortBar
                }
            }
        }
        .searchable(
            text: $state.searchText,
            placement: .toolbar,
            prompt: "Name, serial, number…"
        )
        .onChange(of: state.selection) { _, newValue in
            // Leave rename mode if the renamed row is no longer selected.
            if let id = state.renamingGameID, !newValue.contains(id) {
                state.cancelInlineRename()
            }
        }
        .onChange(of: state.isBusy) { _, busy in
            if busy { state.cancelInlineRename() }
        }
        .onChange(of: state.isScanning) { _, scanning in
            if scanning { state.cancelInlineRename() }
        }
        // Restore saved sort when a card opens / changes; drop any in-flight rename.
        .onChange(of: state.volume?.volumeUUID) { _, newUUID in
            state.cancelInlineRename()
            applySortFromState(remount: true)
            if newUUID == nil {
                // Clean empty-state headers (default newest-first).
                sortOrder = DisplaySortPreference.mostRecentFirst.comparators
            }
        }
        .onChange(of: state.displaySort) { _, new in
            // External load after open — sync Table chevrons (remount if needed).
            let next = new.comparators
            if !sortOrdersMatch(sortOrder, next) {
                sortOrder = next
                tableRemountToken &+= 1
            }
        }
        // Persist when the user clicks a column header.
        .onChange(of: sortOrder) { _, new in
            guard state.volume != nil else { return }
            guard let pref = DisplaySortPreference.from(sortOrder: new) else { return }
            if pref != state.displaySort {
                state.saveDisplaySort(pref)
            }
        }
        .onAppear {
            applySortFromState(remount: false)
        }
        // Finder → Add Games (2UP-style AppKit pasteboard drop, not SwiftUI `.onDrop`).
        .overlay {
            // Thin accent ring while targeted — same chrome language as 2UP panes.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isDropTargeted && state.canAddGames ? 2 : 0)
                .allowsHitTesting(false)
        }
        .gameListFileDrop(
            enabled: state.canAddGames,
            isTargeted: $isDropTargeted
        ) { urls, skipAutoRename in
            state.handleDroppedURLs(urls, skipAutoRename: skipAutoRename)
        }
    }

    /// Identity that forces a fresh `NSTableView` when volume opens or sort is applied
    /// programmatically. Do **not** key on `displaySort` alone — user header clicks already
    /// update chevrons natively, and remounting would throw away scroll position.
    private var tableIdentity: String {
        let vol = state.volume?.volumeUUID ?? "none"
        return "\(vol)|\(tableRemountToken)"
    }

    /// Persist widths / visibility / order through AppState (UserDefaults), 2UP-style.
    private var columnCustomizationBinding: Binding<TableColumnCustomization<GameEntry>> {
        Binding(
            get: { state.tableColumnCustomization },
            set: { state.setTableColumnCustomization($0) }
        )
    }

    private func applySortFromState(remount: Bool) {
        let next = state.displaySort.comparators
        if !sortOrdersMatch(sortOrder, next) {
            sortOrder = next
            if remount { tableRemountToken &+= 1 }
        } else if remount {
            // Same comparators, but headers may still be stale from the previous card.
            tableRemountToken &+= 1
        }
    }

    private func applyAndSave(_ pref: DisplaySortPreference) {
        sortOrder = pref.comparators
        tableRemountToken &+= 1
        state.saveDisplaySort(pref)
    }

    /// Compact strip under the toolbar — warning chrome (not inverted white-on-orange).
    private var menuRebuildBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.medium)
            Text("\(state.menuKind.displayName) list is out of date")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("— rebuild so the menu matches the card")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Button("Rebuild…") {
                state.rebuildMenuList()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
            .disabled(!state.canRebuildMenu || state.isTextInputFocused)
            .help("Bake names and order into \(state.menuKind.displayName) in slot 01 (⌘S)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle().fill(.bar)
            Rectangle().fill(Color.orange.opacity(0.14))
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var displaySortBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .foregroundStyle(.secondary)
            Text("Sorted by \(state.displaySort.summary) — card slot numbers unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Newest First") {
                applyAndSave(.mostRecentFirst)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            Button("Slot Order") {
                applyAndSave(.discOrder)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func sortOrdersMatch(
        _ a: [KeyPathComparator<GameEntry>],
        _ b: [KeyPathComparator<GameEntry>]
    ) -> Bool {
        guard let aa = a.first, let bb = b.first else { return a.isEmpty && b.isEmpty }
        return aa.keyPath == bb.keyPath && aa.order == bb.order
    }

    @ViewBuilder
    private func selectionContextMenu(_ selectedIDs: Set<GameEntry.ID>) -> some View {
        let count = selectedIDs.count
        let multi = count > 1

        if count == 1, let id = selectedIDs.first {
            Button("Rename") {
                state.beginInlineRename(id)
            }
            .disabled(state.isBusy || state.isScanning)
        }

        Button("Show Details") {
            state.selection = selectedIDs
            state.isInspectorPresented = true
        }
        .disabled(count == 0)

        let selectedGames = state.games.filter { selectedIDs.contains($0.id) }
        if state.duplicatesEnabled {
            let anyDup = selectedGames.contains { state.duplicateInfo(for: $0.id) != nil }
            let anyMarked = selectedGames.contains { state.isMarkedNotDuplicate($0) }
            if anyDup {
                Button(multi ? "Mark Not Duplicates" : "Not a Duplicate") {
                    state.markNotDuplicate(ids: selectedIDs)
                }
            }
            if anyMarked {
                Button("Restore Duplicate Detection") {
                    state.clearNotDuplicateMark(ids: selectedIDs)
                }
            }
        }

        Menu(multi ? "Manually Rename (\(count))" : "Manually Rename") {
            Button("Sentence Case") {
                state.selection = selectedIDs
                state.sentenceCaseSelection()
            }
            Button("Title Case") {
                state.selection = selectedIDs
                state.titleCaseSelection()
            }
            Button("Uppercase") {
                state.selection = selectedIDs
                state.uppercaseSelection()
            }
            Button("Lowercase") {
                state.selection = selectedIDs
                state.lowercaseSelection()
            }
        }
        .disabled(count == 0 || state.isBusy)

        Menu("Automatically Rename") {
            ForEach(AutoRenameSource.allCases) { source in
                Button(source.menuTitle) {
                    state.selection = selectedIDs
                    state.autoRename(ids: selectedIDs, from: source)
                }
                .help(source.helpText)
            }
        }
        .disabled(count == 0 || state.isBusy)

        Divider()

        Button("Move Up on Card") {
            state.selection = selectedIDs
            state.moveSelection(up: true)
        }
        .disabled(state.isBusy || !canMove(selectedIDs, up: true))
        .help("Changes SD folder numbers (not table sort)")

        Button("Move Down on Card") {
            state.selection = selectedIDs
            state.moveSelection(up: false)
        }
        .disabled(state.isBusy || !canMove(selectedIDs, up: false))
        .help("Changes SD folder numbers (not table sort)")

        Divider()

        Button("Reveal in Finder") {
            let urls = state.games.filter { selectedIDs.contains($0.id) }.map(\.folderURL)
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        .disabled(count == 0)

        Divider()

        // Adjacent pair: MenuOptionAlternates marks Immediately as ⌥-alternate of Delete.
        Button(multi ? "Delete \(count) Games" : "Delete", role: .destructive) {
            state.delete(ids: selectedIDs, permanent: false)
        }
        .disabled(count == 0 || state.isBusy)
        .help("Soft-delete to card trash (fast, undoable). Hold ⌥ for Delete Immediately.")

        Button(multi ? "Delete \(count) Games Immediately…" : "Delete Immediately…", role: .destructive) {
            state.delete(ids: selectedIDs, permanent: true)
        }
        .disabled(count == 0 || state.isBusy)
        .help("Erase from the card now — slow for large games; cannot be undone")
    }

    private func canMove(_ ids: Set<GameEntry.ID>, up: Bool) -> Bool {
        let indices = state.games.indices.filter { ids.contains(state.games[$0].id) }
        guard let first = indices.first, let last = indices.last else { return false }
        return up ? first > 0 : last < state.games.count - 1
    }

}

