import AppKit
import SwiftUI

/// Trailing inspector (~280pt) following macOS iWork inspector layout patterns.
struct InspectorView: View {
    @Bindable var state: AppState

    @State private var draftName: String = ""
    @FocusState private var nameFieldFocused: Bool

    private var maxNumber: Int {
        state.games.map(\.number).max() ?? 1
    }

    private var selected: [GameEntry] { state.selectedGames }
    private var game: GameEntry? { state.selectedGame }

    /// Fixed label column width — same idea as iWork slider/field labels (72pt).
    private let labelWidth: CGFloat = 72

    var body: some View {
        Group {
            if selected.isEmpty {
                emptyState
            } else if let game, selected.count == 1 {
                singleInspector(game)
            } else {
                multiInspector(selected)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Single

    private func singleInspector(_ game: GameEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                titleSection(game)
                if let dup = state.duplicateInfo(for: game.id) {
                    sectionDivider
                    duplicateSection(game, info: dup)
                }
                sectionDivider
                detailsSection(game)
                sectionDivider
                filesSection(game)
                sectionDivider
                actionsSection(game)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .disabled(state.isBusy)
        .onAppear { syncDraft(from: game) }
        .onChange(of: game.id) { _, _ in
            syncDraft(from: game)
        }
        .onChange(of: game.name) { _, new in
            if !nameFieldFocused, draftName != new {
                draftName = new
            }
        }
        .onChange(of: state.focusNameFieldToken) { _, _ in
            nameFieldFocused = true
        }
    }

    // MARK: - Multi

    private func multiInspector(_ games: [GameEntry]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Selection")

                    Text("\(games.count) games")
                        .font(.title3.weight(.semibold))

                    Text(ByteCount.string(for: state.selectedBytes))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)

                    // Compact list of names (read-only).
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(games.prefix(12)) { g in
                            HStack(spacing: 8) {
                                Text(FolderNumbering.format(g.number, maxNumber: maxNumber))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                                Text(g.name)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                                FormatBadge(format: g.format)
                            }
                        }
                        if games.count > 12 {
                            Text("+\(games.count - 12) more")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                sectionDivider

                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Actions")

                    HStack(spacing: 8) {
                        Button {
                            state.sentenceCaseSelection()
                        } label: {
                            Text("Sentence Case")
                                .frame(maxWidth: .infinity)
                        }

                        Button {
                            let urls = games.map(\.folderURL)
                            NSWorkspace.shared.activateFileViewerSelecting(urls)
                        } label: {
                            Text("Reveal")
                                .frame(maxWidth: .infinity)
                        }
                    }

                    Button(role: .destructive) {
                        state.deleteSelected()
                    } label: {
                        Text("Delete \(games.count) Games")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(state.isBusy)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .disabled(state.isBusy)
    }

    // MARK: - Title

    private func titleSection(_ game: GameEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Title")

            TextField("Game name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .focused($nameFieldFocused)
                .onSubmit { commitName(for: game) }
                .onChange(of: nameFieldFocused) { _, focused in
                    if !focused { commitName(for: game) }
                }
                .help("Displayed name (name.txt). Press Return to save.")

            Text(titleStatusLine(for: game))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func titleStatusLine(for game: GameEntry) -> String {
        let slot = FolderNumbering.format(game.number, maxNumber: maxNumber)
        if game.isMenu {
            return "Slot \(slot) · \(state.menuKind.displayName)"
        }
        return "Slot \(slot)"
    }

    // MARK: - Duplicates

    private func duplicateSection(_ game: GameEntry, info: DuplicateInfo) -> some View {
        let peers = state.games.filter {
            state.duplicateInfo(for: $0.id)?.groupKey == info.groupKey
        }

        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Duplicate")

            Text(info.grade.label)
                .font(.callout)
                .foregroundStyle(.secondary)

            if !info.signals.isEmpty {
                Text(info.signals.map { "\($0.kind.rawValue) \($0.detail)" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text(info.isPrimary
                 ? "Copy \(info.indexInGroup) of \(info.groupSize) · lowest slot (keep)"
                 : "Copy \(info.indexInGroup) of \(info.groupSize) · redundant")
                .font(.callout)
                .foregroundStyle(info.isPrimary ? .orange : .red)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

            Text("Multi-disc sets that share a serial are ignored unless size/hash also match.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(peers) { peer in
                    HStack(spacing: 8) {
                        Text(FolderNumbering.format(peer.number, maxNumber: maxNumber))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                        Text(peer.name)
                            .font(.callout)
                            .lineLimit(1)
                            .fontWeight(peer.id == game.id ? .semibold : .regular)
                        Spacer(minLength: 0)
                        if peer.id == game.id {
                            Image(systemName: "checkmark")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Button {
                state.selection = Set(peers.map(\.id))
                state.showDuplicatesOnly = true
            } label: {
                Text("Select Group")
                    .frame(maxWidth: .infinity)
            }

            if info.isRedundant || peers.count > 1 {
                Button {
                    // Select other members of this group that are not the primary.
                    let group = peers.compactMap { g -> GameEntry? in
                        guard let d = state.duplicateInfo(for: g.id), d.isRedundant else { return nil }
                        return g
                    }
                    state.selection = Set(group.map(\.id))
                } label: {
                    Text("Select Redundant in Group")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Details

    private func detailsSection(_ game: GameEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Details")

            inspectorRow("Serial") {
                Text(game.serial.isEmpty ? "—" : game.serial)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            inspectorRow("Format") {
                FormatBadge(format: game.format)
            }

            inspectorRow("Size") {
                Text(ByteCount.string(for: game.byteSize))
                    .font(.body)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            if game.isMenu {
                inspectorRow("Role") {
                    Text("Menu")
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Files

    private func filesSection(_ game: GameEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Files")

            inspectorRow("Image") {
                Text(game.imageFileName)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            inspectorRow("Folder") {
                Text(game.folderURL.lastPathComponent)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Path")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(game.folderPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Actions (single)

    private func actionsSection(_ game: GameEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Actions")

            HStack(spacing: 8) {
                Button {
                    applySentenceCase(to: game)
                } label: {
                    Text("Sentence Case")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    revealInFinder(game)
                } label: {
                    Text("Reveal")
                        .frame(maxWidth: .infinity)
                }
            }

            Button(role: .destructive) {
                state.delete(id: game.id)
            } label: {
                Text("Delete from Card")
                    .frame(maxWidth: .infinity)
            }
            .disabled(state.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "opticaldisc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("Select one or more games.\n⌘-click and ⇧-click for multi-select.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Chrome

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
    }

    private func inspectorRow<Content: View>(
        _ label: String,
        @ViewBuilder value: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
                .layoutPriority(1)

            value()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: - Actions

    private func syncDraft(from game: GameEntry) {
        draftName = game.name
    }

    private func commitName(for game: GameEntry) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            draftName = game.name
            return
        }
        guard trimmed != game.name else { return }
        state.rename(id: game.id, to: trimmed)
    }

    private func applySentenceCase(to game: GameEntry) {
        state.selectOnly(game.id)
        state.sentenceCaseSelection()
        if let updated = state.games.first(where: { $0.id == game.id }) {
            draftName = updated.name
        } else {
            draftName = game.name.sentenceCasedTitle
        }
    }

    private func revealInFinder(_ game: GameEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([game.folderURL])
    }
}
