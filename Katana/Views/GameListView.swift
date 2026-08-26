import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    /// Row IDs that were selected when the mouse went down. NSTableView selects the
    /// clicked row before asking for a drag, so this is the only way to tell “drag the
    /// selected block” from “drag to extend the selection”.
    @State private var selectionAtMouseDown = MouseDownSelectionSnapshot()

    /// Filtered list sorted for display. Does not mutate card slot order.
    /// While arranging, the pending order *is* the display order.
    private var displayedGames: [GameEntry] {
        if state.isArranging { return state.arrangedGames }
        return state.filteredGames.sorted(using: sortOrder)
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
            if let err = state.lastError {
                errorBar(err)
            }
            if state.availableUpdate != nil {
                updateBar
            }
            if state.isArranging {
                arrangeBar
            } else if state.volume != nil, state.menuNeedsRebuild, !state.isRebuildingMenu {
                menuRebuildBar
            }

            // Column widths, visibility, and reorder use SwiftUI’s native
            // `columnCustomization` (same pattern as 2UP): Control-click a header
            // to show/hide columns. Persisted per menu type.
            // One Table for browsing *and* Arrange. Row drag is NSTableView’s own
            // (`TableRow.itemProvider` / `onInsert`): rows that were not selected at
            // mouse-down return no provider, so dragging them extends the selection
            // natively; dragging an already-selected block reorders it and enters Arrange.
            Table(
                of: GameEntry.self,
                selection: $state.selection,
                // Header clicks are ignored while arranging — the pending order is the sort.
                sortOrder: state.isArranging ? .constant(sortOrder) : $sortOrder,
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

                TableColumn("Folder", value: \.virtualFolderSortKey) { game in
                    Text(game.virtualFolder.isEmpty ? "—" : game.virtualFolder)
                        .foregroundStyle(game.virtualFolder.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(game.extraFolders.isEmpty
                              ? "openMenu virtual folder"
                              : "Also in: \(game.extraFolders.joined(separator: "; "))")
                        .opacity(state.isDeemphasizedInList(game) ? 0.38 : 1)
                }
                .width(min: 80, ideal: 140, max: 220)
                .customizationID("folder")
                .defaultVisibility(state.menuKind.supportsVirtualFolders ? .visible : .hidden)

                TableColumn("Type", value: \.discTypeSortKey) { game in
                    Text(game.isMenu || game.number == 1 ? "—" : game.discType.displayName)
                        .foregroundStyle((game.isMenu || game.number == 1) ? .tertiary : .primary)
                        .opacity(state.isDeemphasizedInList(game) ? 0.38 : 1)
                }
                .width(min: 52, ideal: 64, max: 80)
                .customizationID("type")
                .defaultVisibility(state.menuKind.supportsVirtualFolders ? .visible : .hidden)

                TableColumn("Disc", value: \.discLabelSortKey) { game in
                    Text(game.isMenu || game.number == 1 ? "—" : game.resolvedDisc())
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .opacity(state.isDeemphasizedInList(game) ? 0.38 : 1)
                }
                .width(min: 44, ideal: 52, max: 64)
                .customizationID("disc")

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
            } rows: {
                ForEach(displayedGames) { game in
                    TableRow(game)
                        .itemProvider { rowDragProvider(for: game) }
                }
                .onInsert(of: [.text]) { index, _ in
                    acceptRowDrop(at: index)
                }
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
                      !state.isArranging,
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
                if state.volume != nil, isNonSlotSort, !state.isArranging {
                    displaySortBar
                }
            }
        }
        .searchable(
            text: $state.searchText,
            placement: .toolbar,
            prompt: state.menuKind.supportsVirtualFolders
                ? "Name, serial, folder, disc…"
                : "Name, serial, disc…"
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
            selectionAtMouseDown.install { state.selection }
        }
        .onDisappear {
            selectionAtMouseDown.uninstall()
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
        return "\(vol)|\(state.menuKind.rawValue)|\(tableRemountToken)"
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

    // MARK: Row drag reorder

    /// Called by NSTableView when a drag starts on `game`. `nil` = not draggable, so the
    /// table extends the selection instead (native drag-select). Only a row that was
    /// already selected before the click starts a reorder drag.
    private func rowDragProvider(for game: GameEntry) -> NSItemProvider? {
        guard !state.isBusy,
              state.renamingGameID == nil,
              !game.isMenu, game.number != 1,
              selectionAtMouseDown.ids.contains(game.id)
        else { return nil }
        return NSItemProvider(object: game.id.uuidString as NSString)
    }

    /// Drop between rows: enters Arrange (Apply / Cancel bar) and stages the move.
    /// The whole selection moves as a block when the dragged row was part of it.
    private func acceptRowDrop(at index: Int) {
        let rows = displayedGames
        let dragged = rows.filter { selectionAtMouseDown.ids.contains($0.id) && !$0.isMenu && $0.number != 1 }
        guard let source = dragged.first else { return }
        let target: UUID? = index < rows.count ? rows[index].id : nil
        if !state.selection.contains(source.id) {
            state.selection = Set(dragged.map(\.id))
        }
        state.acceptReorderDrop(sourceID: source.id, before: target)
    }

    /// Window-chrome overlay on NavigationSplitView sat in the titlebar; these
    /// strips are table siblings (same as Arrange / Rebuild) so they sit under
    /// the toolbar and push the list down.
    private func errorBar(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .imageScale(.medium)
                .padding(.top, 1)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .numericText()
            Spacer(minLength: 8)
            Button("Dismiss") { state.lastError = nil }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Rectangle().fill(.bar)
            Rectangle().fill(Color.yellow.opacity(0.16))
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var updateBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
                .imageScale(.medium)
            if let update = state.availableUpdate {
                (Text("Katana \(update.version) is available")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    + Text(" — you have \(UpdateChecker.currentVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
            Button("View Release") {
                state.openAvailableUpdate()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("Dismiss") {
                state.dismissAvailableUpdate()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle().fill(.bar)
            Rectangle().fill(Color.accentColor.opacity(0.10))
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var arrangeBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .imageScale(.medium)
            (Text("Drag rows to rearrange")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                + Text(" — drag selected rows to a new position, then Apply")
                .font(.callout)
                .foregroundStyle(.secondary))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Button("Cancel") {
                state.cancelArrange()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.isBusy)
            .keyboardShortcut(.cancelAction)
            Button("Apply") {
                state.commitArrange()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(state.isBusy || !state.arrangeIsDirty)
            .keyboardShortcut(.defaultAction)
            .help("Rename numbered folders once to match this order")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle().fill(.bar)
            Rectangle().fill(Color.accentColor.opacity(0.10))
        }
        .overlay(alignment: .bottom) { Divider() }
    }


    /// Compact strip under the toolbar — warning chrome (not inverted white-on-orange).
    private var menuRebuildBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.medium)
            (Text("\(state.menuKind.displayName) list is out of date")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                + Text(" — rebuild so the menu matches the card")
                .font(.callout)
                .foregroundStyle(.secondary))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Button("Rebuild…") {
                state.rebuildMenuList()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
            .disabled(!state.canRebuildMenu)
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
            .disabled(state.isBusy || state.isScanning || state.isArranging)
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

        let assignable = selectedGames.filter { !$0.isMenu && $0.number != 1 }
        if state.menuKind.supportsVirtualFolders, !assignable.isEmpty {
            let ids = Set(assignable.map(\.id))
            let shared = Set(assignable.map(\.virtualFolder))
            let currentFolder = shared.count == 1 ? shared.first : nil
            Menu("Assign Folder") {
                Button("None") {
                    state.assignVirtualFolder(ids: ids, to: "")
                }
                let known = state.knownVirtualFolders
                if !known.isEmpty {
                    Divider()
                    ForEach(known, id: \.self) { path in
                        Button(path) {
                            state.assignVirtualFolder(ids: ids, to: path)
                        }
                    }
                }
                Divider()
                Button("Type a Path…") {
                    if let path = OpenMenuFolderPrompt.askPath(
                        seed: currentFolder ?? "",
                        suggestions: known
                    ) {
                        state.assignVirtualFolder(ids: ids, to: path)
                    }
                }
            }
            .disabled(state.isBusy)
            .help("Assign the same openMenu folder to every selected game. None unfiles. Type a Path… uses autocomplete like the inspector.")
        }

        Divider()

        if !state.isArranging {
            Button("Arrange…") {
                if let id = selectedIDs.first {
                    state.selection = selectedIDs
                    state.beginArrange(selecting: id)
                }
            }
            .disabled(state.isBusy || !state.canArrange)
            .help("Drag selected rows, or use this, to reorder. Apply writes folders.")
        }

        Button(state.moveUpTitle) {
            state.selection = selectedIDs
            state.moveSelectionTowardTop()
        }
        .disabled(state.isBusy || !state.canMoveSelection(towardTop: true, ids: selectedIDs))
        .help(state.moveUpHelp)

        Button(state.moveDownTitle) {
            state.selection = selectedIDs
            state.moveSelectionTowardBottom()
        }
        .disabled(state.isBusy || !state.canMoveSelection(towardTop: false, ids: selectedIDs))
        .help(state.moveDownHelp)

        Button("Move to Top") {
            state.selection = selectedIDs
            state.moveSelectionToTop()
        }
        .disabled(state.isBusy || !state.canLowerSlot(ids: selectedIDs))
        .help(state.moveToTopHelp)

        Button("Move to Bottom") {
            state.selection = selectedIDs
            state.moveSelectionToBottom()
        }
        .disabled(state.isBusy || !state.canRaiseSlot(ids: selectedIDs))
        .help(state.moveToBottomHelp)

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

}


/// Snapshots the table selection on every left mouse-down (a local event monitor sees the
/// event before NSTableView changes the selection). See `GameListView.rowDragProvider`.
@MainActor
final class MouseDownSelectionSnapshot {
    private(set) var ids: Set<GameEntry.ID> = []
    private var monitor: Any?

    func install(_ selection: @escaping () -> Set<GameEntry.ID>) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.ids = selection()
            return event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
