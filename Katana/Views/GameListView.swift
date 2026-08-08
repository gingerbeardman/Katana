import AppKit
import SwiftUI

/// Game table with **display-only** column sorting (Brutify / 2UP style).
/// `AppState.games` stays in on-disc slot order; table sort never renumbers folders.
/// Sort preference is remembered per card volume across sessions.
struct GameListView: View {
    @Bindable var state: AppState

    /// SwiftUI Table sort state — view only, not disc order.
    @State private var sortOrder: [KeyPathComparator<GameEntry>] = DisplaySortPreference.mostRecentFirst.comparators
    /// Bumped when we must remount the Table so column header chevrons match `sortOrder`.
    /// SwiftUI Table often keeps stale NSTableView sort indicators when `sortOrder` is
    /// set programmatically (cold open of a new/renamed volume was the worst case).
    @State private var tableRemountToken: UInt64 = 0

    private var maxNumber: Int {
        state.maxGameNumber
    }

    /// Filtered list sorted for display. Does not mutate disc order.
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

            Table(displayedGames, selection: $state.selection, sortOrder: $sortOrder) {
                TableColumn("#", value: \.number) { game in
                    // Slot + trailing chips (MENU / duplicate). Observes AppState for pending badges.
                    NumberColumnCell(game: game, maxNumber: maxNumber, state: state)
                }
                .width(min: 110, ideal: 110, max: 110)

                TableColumn("Title", value: \.name) { game in
                    // Observe rename state inside the cell (Table caches closures).
                    RenameAwareTitleCell(game: game, state: state)
                        .opacity(state.isDeemphasizedInList(game) ? 0.38 : 1)
                }
                .width(min: 160, ideal: 280)

                TableColumn("Serial", value: \.serial) { game in
                    Text(game.serial.isEmpty ? "—" : game.serial)
                        .font(.body.monospaced())
                        .foregroundStyle(game.serial.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .opacity(state.isDeemphasizedInList(game) ? 0.38 : 1)
                }
                .width(min: 72, ideal: 100, max: 140)

                TableColumn("Format", value: \.formatSortKey) { game in
                    FormatBadge(format: game.format)
                        .opacity(state.isDeemphasizedInList(game) ? 0.38 : 1)
                }
                .width(min: 52, ideal: 64, max: 80)

                TableColumn("Size", value: \.byteSize) { game in
                    Text(state.formatGameSize(game))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .opacity(state.isDeemphasizedInList(game) ? 0.38 : 1)
                }
                .width(min: 72, ideal: 88, max: 110)
            }
            // Keep rows visible while scanning/rebuilding — block interaction only.
            // No card: empty chrome only (open from sidebar); don’t allow sort/select.
            .disabled(state.volume == nil || state.isScanning || state.isRebuildingMenu || state.isBusy)
            .opacity(
                state.volume == nil
                    ? 0.55
                    : (state.isScanning || state.isRebuildingMenu) ? 0.72 : 1
            )
            // Remount when volume or programmed sort changes so header chevrons match data order.
            .id(tableIdentity)
            .background {
                if state.scrollToNewRows {
                    TableSelectionScroller(trigger: state.scrollTargetGameID)
                }
            }
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
                // Edge progress — scan (accent) or menu rebuild (warning orange).
                if state.isScanning, let progress = state.scanProgress, progress.total > 0 {
                    edgeProgressBar(
                        fraction: min(1, max(0, Double(progress.completed) / Double(progress.total))),
                        color: .accentColor
                    )
                } else if state.isRebuildingMenu {
                    edgeProgressBar(
                        fraction: state.rebuildProgress ?? 0,
                        color: .orange
                    )
                }
            }
            .overlay {
                // Center busy card only for non-scan / non-rebuild ops (import, delete, …).
                // No-card empty state lives in the sidebar (Open / Reopen) — no overlay on the table.
                if let busy = state.busyMessage, !state.isScanning, !state.isRebuildingMenu {
                    busyOverlay(busy)
                } else if state.volume != nil, state.filteredGames.isEmpty, !state.isScanning {
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
    }

    /// Identity that forces a fresh `NSTableView` when volume opens or sort is applied
    /// programmatically. Do **not** key on `displaySort` alone — user header clicks already
    /// update chevrons natively, and remounting would throw away scroll position.
    private var tableIdentity: String {
        let vol = state.volume?.volumeUUID ?? "none"
        return "\(vol)|\(tableRemountToken)"
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
            Text("Sorted by \(state.displaySort.summary) — disc slot numbers unchanged.")
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

        Button("Move Up on Disc") {
            state.selection = selectedIDs
            state.moveSelection(up: true)
        }
        .disabled(state.isBusy || !canMove(selectedIDs, up: true))
        .help("Changes SD folder numbers (not table sort)")

        Button("Move Down on Disc") {
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

        Button(multi ? "Delete \(count) Games" : "Delete", role: .destructive) {
            state.delete(ids: selectedIDs)
        }
        .disabled(count == 0 || state.isBusy)
    }

    private func canMove(_ ids: Set<GameEntry.ID>, up: Bool) -> Bool {
        let indices = state.games.indices.filter { ids.contains(state.games[$0].id) }
        guard let first = indices.first, let last = indices.last else { return false }
        return up ? first > 0 : last < state.games.count - 1
    }

    private func busyOverlay(_ message: String) -> some View {
        ProgressView(message)
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 2pt edge progress (scan accent / rebuild orange).
    private func edgeProgressBar(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                Rectangle()
                    .fill(color)
                    .frame(width: geo.size.width * fraction)
                    .animation(.linear(duration: 0.2), value: fraction)
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Scroll selected row into view (SwiftUI Table → AppKit NSTableView)

/// When `trigger` changes, finds the hosting `NSTableView` and scrolls its selection into view.
private struct TableSelectionScroller: NSViewRepresentable {
    var trigger: GameEntry.ID?

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard trigger != nil else { return }
        // Wait a beat so SwiftUI applies the new selection / row before we scroll.
        DispatchQueue.main.async {
            guard let root = view.window?.contentView ?? NSApp.keyWindow?.contentView else { return }
            guard let table = Self.findTableView(in: root) else { return }
            let rows = table.selectedRowIndexes
            guard let row = rows.first, row >= 0, row < table.numberOfRows else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.allowsImplicitAnimation = true
                table.animator().scrollRowToVisible(row)
            }
        }
    }

    private static func findTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.numberOfColumns > 1 {
            return table
        }
        var best: NSTableView?
        for sub in view.subviews {
            if let found = findTableView(in: sub) {
                // Prefer the widest multi-column table (game list, not tiny side widgets).
                if let current = best {
                    if found.bounds.width > current.bounds.width {
                        best = found
                    }
                } else {
                    best = found
                }
            }
        }
        return best
    }
}
