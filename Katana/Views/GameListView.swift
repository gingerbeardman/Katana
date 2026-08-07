import AppKit
import SwiftUI

/// Game table with **display-only** column sorting (Brutify / 2UP style).
/// `AppState.games` stays in on-disc slot order; table sort never renumbers folders.
/// Sort preference is remembered per card volume across sessions.
struct GameListView: View {
    @Bindable var state: AppState

    /// SwiftUI Table sort state — view only, not disc order.
    @State private var sortOrder: [KeyPathComparator<GameEntry>] = DisplaySortPreference.mostRecentFirst.comparators

    private var maxNumber: Int {
        state.games.map(\.number).max() ?? 1
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
        Table(displayedGames, selection: $state.selection, sortOrder: $sortOrder) {
            TableColumn("#", value: \.number) { game in
                HStack(spacing: 4) {
                    Text(FolderNumbering.format(game.number, maxNumber: maxNumber))
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, alignment: .trailing)
                    if state.isHashingGame(game) {
                        ProgressView()
                            .controlSize(.small)
                            .help("Computing content hash…")
                    }
                }
            }
            .width(min: 52, ideal: 64, max: 80)

            TableColumn("Title", value: \.name) { game in
                HStack(spacing: 6) {
                    Text(game.name)
                        .fontWeight(game.isMenu ? .semibold : .regular)
                        .lineLimit(1)
                    if game.isMenu {
                        Text("MENU")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                    if let dup = state.listDuplicateBadge(for: game.id) {
                        DuplicateBadge(info: dup)
                    }
                }
            }
            .width(min: 160, ideal: 280)

            TableColumn("Serial", value: \.serial) { game in
                Text(game.serial.isEmpty ? "—" : game.serial)
                    .font(.body.monospaced())
                    .foregroundStyle(game.serial.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
            }
            .width(min: 72, ideal: 100, max: 140)

            TableColumn("Format", value: \.formatSortKey) { game in
                FormatBadge(format: game.format)
            }
            .width(min: 52, ideal: 64, max: 80)

            TableColumn("Size", value: \.byteSize) { game in
                Text(ByteCount.string(for: game.byteSize))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 72, ideal: 88, max: 110)
        }
        // Keep rows visible while scanning; block interaction only.
        .disabled(state.isScanning || state.isBusy)
        .opacity(state.isScanning ? 0.72 : 1)
        .contextMenu(forSelectionType: GameEntry.ID.self) { selectedIDs in
            selectionContextMenu(selectedIDs)
        } primaryAction: { selectedIDs in
            if selectedIDs.count == 1, let id = selectedIDs.first {
                state.focusRenameInInspector(for: id)
            }
        }
        .searchable(
            text: $state.searchText,
            placement: .toolbar,
            prompt: "Name, serial, number…"
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            // Caption lives in the window subtitle; only the bar is needed here.
            if state.isScanning, let progress = state.scanProgress, progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
        .overlay {
            // Do not cover the table while scanning — rows fill in as progress.
            if let busy = state.busyMessage, !state.isScanning {
                busyOverlay(busy)
            } else if state.volume == nil, !state.isScanning {
                ContentUnavailableView {
                    Label("No Card Open", systemImage: "sdcard")
                } description: {
                    Text("Open a GDEMU SD card root (the folder that contains 01, 02, …). Changes write immediately.")
                } actions: {
                    Button("Open Card…") { state.openCard() }
                        .buttonStyle(.borderedProminent)
                }
            } else if state.filteredGames.isEmpty, !state.isScanning, state.volume != nil {
                ContentUnavailableView.search(text: state.searchText)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if state.volume != nil, isNonSlotSort {
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
            }
        }
        .onChange(of: state.selection) { _, newValue in
            if !newValue.isEmpty {
                state.isInspectorPresented = true
            }
        }
        // Restore saved sort when a card opens / changes.
        .onChange(of: state.volume?.volumeUUID) { _, _ in
            sortOrder = state.displaySort.comparators
        }
        .onChange(of: state.displaySort) { _, new in
            // External load after open — sync Table chevrons.
            let next = new.comparators
            if !sortOrdersMatch(sortOrder, next) {
                sortOrder = next
            }
        }
        // Persist when the user clicks a column header.
        .onChange(of: sortOrder) { _, new in
            guard let pref = DisplaySortPreference.from(sortOrder: new) else { return }
            if pref != state.displaySort {
                state.saveDisplaySort(pref)
            }
        }
        .onAppear {
            sortOrder = state.displaySort.comparators
        }
    }

    private func applyAndSave(_ pref: DisplaySortPreference) {
        sortOrder = pref.comparators
        state.saveDisplaySort(pref)
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
            Button("Rename…") {
                state.focusRenameInInspector(for: id)
            }
        }

        Button(multi ? "Sentence Case (\(count))" : "Sentence Case") {
            state.selection = selectedIDs
            state.sentenceCaseSelection()
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
}
