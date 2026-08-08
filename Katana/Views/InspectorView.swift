import AppKit
import SwiftUI

/// Trailing inspector (~280pt) following macOS iWork inspector layout patterns.
/// Single-game: Title → IP.BIN → Cover → On Card → Actions (no repeated fields).
struct InspectorView: View {
    @Bindable var state: AppState

    @State private var draftName: String = ""
    @State private var ipInfo: IpBinInfo?
    @State private var gdtexImage: NSImage?
    @State private var gdtexStatus: String = ""
    @State private var detailLoadToken: UUID = UUID()
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
                collapsible(.title) {
                    titleSectionBody(game)
                }
                if state.duplicatesEnabled {
                    if let dup = state.duplicateInfo(for: game.id) {
                        sectionDivider
                        collapsible(.duplicate) {
                            duplicateSectionBody(game, info: dup)
                        }
                    } else if state.isMarkedNotDuplicate(game) {
                        sectionDivider
                        collapsible(.duplicate) {
                            notDuplicateMarkedBody(game)
                        }
                    }
                }
                sectionDivider
                collapsible(.ipBin) {
                    ipBinSectionBody(game)
                }
                sectionDivider
                collapsible(.gdtex) {
                    gdtexSectionBody
                }
                sectionDivider
                collapsible(.onCard) {
                    onCardSectionBody(game)
                }
                sectionDivider
                collapsible(.actions) {
                    actionsSectionBody(game)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .disabled(state.isBusy)
        .onAppear {
            syncDraft(from: game)
            loadDiscDetails(for: game)
        }
        .onChange(of: game.id) { _, _ in
            syncDraft(from: game)
            loadDiscDetails(for: game)
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
                collapsible(.selection) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(games.count) games")
                            .font(.title3.weight(.semibold).monospacedDigit())

                        Text(state.formatSize(state.selectedBytes))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(games.prefix(12)) { g in
                                HStack(spacing: 8) {
                                    Text(FolderNumbering.format(g.number, maxNumber: maxNumber))
                                        .font(.caption.monospacedDigit())
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
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                sectionDivider

                collapsible(.actions) {
                    VStack(alignment: .leading, spacing: 10) {
                        Menu("Manually Rename") {
                            Button("Sentence Case") {
                                state.sentenceCaseSelection()
                            }
                            Button("Title Case") {
                                state.titleCaseSelection()
                            }
                            Button("Uppercase") {
                                state.uppercaseSelection()
                            }
                            Button("Lowercase") {
                                state.lowercaseSelection()
                            }
                        }
                        .disabled(state.isBusy)

                        Menu("Automatically Rename") {
                            ForEach(AutoRenameSource.allCases) { source in
                                Button(source.menuTitle) {
                                    state.autoRenameSelection(from: source)
                                }
                                .help(source.helpText)
                            }
                        }
                        .disabled(state.isBusy)

                        Button {
                            let urls = games.map(\.folderURL)
                            NSWorkspace.shared.activateFileViewerSelecting(urls)
                        } label: {
                            Text("Reveal in Finder")
                                .frame(maxWidth: .infinity)
                        }

                        if state.duplicatesEnabled {
                            let anyDup = games.contains { state.duplicateInfo(for: $0.id) != nil }
                            let anyMarked = games.contains { state.isMarkedNotDuplicate($0) }
                            if anyDup {
                                Button {
                                    state.markNotDuplicate(ids: Set(games.map(\.id)))
                                } label: {
                                    Text("Mark Not Duplicates")
                                        .frame(maxWidth: .infinity)
                                }
                                .help("Stop flagging these games as duplicates on this card")
                            }
                            if anyMarked {
                                Button {
                                    state.clearNotDuplicateMark(ids: Set(games.map(\.id)))
                                } label: {
                                    Text("Restore Duplicate Detection")
                                        .frame(maxWidth: .infinity)
                                }
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
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .disabled(state.isBusy)
    }

    // MARK: - Title

    private func titleSectionBody(_ game: GameEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    private func titleStatusLine(for game: GameEntry) -> String {
        let slot = FolderNumbering.format(game.number, maxNumber: maxNumber)
        let size = state.formatSize(game.byteSize)
        if game.isMenu {
            return "Slot \(slot) · \(state.menuKind.displayName) · \(size)"
        }
        return "Slot \(slot) · \(game.format.displayName) · \(size)"
    }

    // MARK: - Duplicates

    private func duplicateSectionBody(_ game: GameEntry, info: DuplicateInfo) -> some View {
        let peers = state.games.filter {
            state.duplicateInfo(for: $0.id)?.groupKey == info.groupKey
        }

        return VStack(alignment: .leading, spacing: 10) {
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
                .font(.callout.monospacedDigit())
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
                            .font(.caption.monospacedDigit())
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

            Button {
                state.markNotDuplicate(ids: [game.id])
            } label: {
                Text("Not a Duplicate")
                    .frame(maxWidth: .infinity)
            }
            .help("Stop flagging this game as a duplicate on this card (saved with the card)")
        }
    }

    private func notDuplicateMarkedBody(_ game: GameEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Marked not a duplicate on this card.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                state.clearNotDuplicateMark(ids: [game.id])
            } label: {
                Text("Restore Duplicate Detection")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - IP.BIN (disc header only — no name/folder/format overlap with Title / On Card)

    private func ipBinSectionBody(_ game: GameEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let ip = ipInfo {
                // Product title only when it differs from the editable name.txt value.
                let ipTitle = ip.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayTitle = game.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !ipTitle.isEmpty, ipTitle.caseInsensitiveCompare(displayTitle) != .orderedSame {
                    Text(ipTitle)
                        .font(.body.weight(.semibold))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("Product name from IP.BIN (differs from the display name)")
                }

                Text(ipBinMetaLine(ip))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                let serial = preferredSerial(game: game, ip: ip)
                inspectorRow("Serial") {
                    Text(serial)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                inspectorRow("Region") {
                    Text(ip.region.isEmpty ? "—" : ip.region)
                        .font(.body.monospaced())
                        .lineLimit(1)
                }

                inspectorRow("CRC") {
                    Text(ip.crc.isEmpty ? "—" : ip.crc)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                }

                if ip.isCodeBreaker {
                    Text("Detected as Code Breaker")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Reading header…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func ipBinMetaLine(_ ip: IpBinInfo) -> String {
        var parts = [ip.version, "DISC \(ip.disc)"]
        if ip.vga { parts.append("VGA") }
        return parts.joined(separator: " · ")
    }

    private func preferredSerial(game: GameEntry, ip: IpBinInfo) -> String {
        if !ip.productNumber.isEmpty { return ip.productNumber }
        if !game.serial.isEmpty { return game.serial }
        return "—"
    }

    // MARK: - Cover (0GDTEX.PVR)

    private var gdtexSectionBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)

                if let gdtexImage {
                    Image(nsImage: gdtexImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(8)
                } else {
                    Text(gdtexStatus.isEmpty ? "Loading…" : gdtexStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - On Card (path + image only; slot lives under Title)

    private func onCardSectionBody(_ game: GameEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorRow("Image") {
                Text(game.imageFileName)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
    }

    // MARK: - Actions (single)

    private func actionsSectionBody(_ game: GameEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu("Manually Rename") {
                Button("Sentence Case") {
                    applyManualCase(to: game, style: .sentence)
                }
                Button("Title Case") {
                    applyManualCase(to: game, style: .title)
                }
                Button("Uppercase") {
                    applyManualCase(to: game, style: .upper)
                }
                Button("Lowercase") {
                    applyManualCase(to: game, style: .lower)
                }
            }
            .disabled(state.isBusy)

            Menu("Automatically Rename") {
                ForEach(AutoRenameSource.allCases) { source in
                    Button(source.menuTitle) {
                        state.selection = [game.id]
                        state.autoRename(ids: [game.id], from: source)
                        if let updated = state.games.first(where: { $0.id == game.id }) {
                            draftName = updated.name
                        }
                    }
                    .help(source.helpText)
                }
            }
            .disabled(state.isBusy)

            Button {
                revealInFinder(game)
            } label: {
                Text("Reveal in Finder")
                    .frame(maxWidth: .infinity)
            }

            Button(role: .destructive) {
                state.delete(id: game.id)
            } label: {
                Text("Delete from Card")
                    .frame(maxWidth: .infinity)
            }
            .disabled(state.isBusy)
        }
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

    /// Collapsible section with persisted expand/collapse (iWork-style chevron header).
    @ViewBuilder
    private func collapsible<Content: View>(
        _ section: InspectorSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let expanded = state.isInspectorSectionExpanded(section)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    state.toggleInspectorSection(section)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(section.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if expanded {
                content()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
        }
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

    /// Load IP.BIN + 0GDTEX off the main actor when selection changes.
    private func loadDiscDetails(for game: GameEntry) {
        let token = UUID()
        detailLoadToken = token
        ipInfo = nil
        gdtexImage = nil
        gdtexStatus = "Loading…"

        let folder = game.folderURL
        let imageName = game.imageFileName
        let format = game.format
        let entry = game

        Task.detached(priority: .userInitiated) {
            let ip = IpBinReader.read(
                folderURL: folder,
                imageFileName: imageName,
                format: format
            ) ?? IpBinInfo.fallback(name: entry.name, serial: entry.serial)

            let tex = GdtexLoader.load(for: entry)

            await MainActor.run {
                guard detailLoadToken == token else { return }
                ipInfo = ip
                gdtexImage = tex.image
                gdtexStatus = tex.image == nil
                    ? (tex.status.isEmpty ? "File not found" : tex.status)
                    : ""
            }
        }
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

    private enum ManualCaseStyle {
        case sentence
        case title
        case upper
        case lower
    }

    private func applyManualCase(to game: GameEntry, style: ManualCaseStyle) {
        state.selectOnly(game.id)
        switch style {
        case .sentence: state.sentenceCaseSelection()
        case .title: state.titleCaseSelection()
        case .upper: state.uppercaseSelection()
        case .lower: state.lowercaseSelection()
        }
        if let updated = state.games.first(where: { $0.id == game.id }) {
            draftName = updated.name
        } else {
            switch style {
            case .sentence: draftName = game.name.sentenceCasedTitle
            case .title: draftName = game.name.titleCasedName
            case .upper: draftName = game.name.uppercasedName
            case .lower: draftName = game.name.lowercasedName
            }
        }
    }

    private func revealInFinder(_ game: GameEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([game.folderURL])
    }
}
