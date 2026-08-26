import AppKit
import SwiftUI

/// Trailing inspector (~280pt) following macOS iWork inspector layout patterns.
/// Single-game: Title → IP.BIN → Cover → On Card → Actions (no repeated fields).
///
/// Reads `AppState.inspectorSnapshot` only — not the full `games` array — so lazy
/// size enrichment of other rows does not rebuild this entire tree (Instruments thrash).
struct InspectorView: View {
    @Bindable var state: AppState

    @State private var draftName: String = ""
    @State private var draftFolder: String = ""
    @State private var draftExtras: String = ""
    @State private var draftSerial: String = ""
    @State private var draftDisc: String = ""
    @State private var draftRegion: String = ""
    @State private var ipInfo: IpBinInfo?
    @State private var gdtexImage: NSImage?
    @State private var gdtexStatus: String = ""
    @State private var detailLoadToken: UUID = UUID()
    @FocusState private var nameFieldFocused: Bool
    @FocusState private var extrasFieldFocused: Bool
    @FocusState private var serialFieldFocused: Bool
    @FocusState private var discFieldFocused: Bool
    @FocusState private var regionFieldFocused: Bool

    private var snap: InspectorSnapshot { state.inspectorSnapshot }

    /// Fixed label column width — same idea as iWork slider/field labels (72pt).
    private let labelWidth: CGFloat = 72

    var body: some View {
        Group {
            switch snap.content {
            case .empty:
                emptyState
            case .single(let game, let dup, let marked):
                singleInspector(game, duplicate: dup, markedNotDuplicate: marked)
            case .multi(let games, let totalBytes, let anyDup, let anyMarked):
                multiInspector(
                    games,
                    totalBytes: totalBytes,
                    anyDup: anyDup,
                    anyMarked: anyMarked
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Track busy separately (does not depend on `games`).
        .disabled(state.isBusy)
    }

    // MARK: - Single

    private func singleInspector(
        _ game: GameEntry,
        duplicate: DuplicateInfo?,
        markedNotDuplicate: Bool
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                collapsible(.title) {
                    titleSectionBody(game)
                }
                if state.menuKind.supportsVirtualFolders, !game.isMenu, game.number != 1 {
                    sectionDivider
                    collapsible(.openMenu) {
                        openMenuSectionBody(game)
                    }
                }
                if snap.duplicatesEnabled {
                    if let dup = duplicate {
                        sectionDivider
                        collapsible(.duplicate) {
                            duplicateSectionBody(game, info: dup)
                        }
                    } else if markedNotDuplicate {
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
        .onChange(of: game.virtualFolder) { _, new in
            if draftFolder != new {
                draftFolder = new
            }
        }
        .onChange(of: game.extraFolders) { _, new in
            let joined = new.joined(separator: "; ")
            if !extrasFieldFocused, draftExtras != joined {
                draftExtras = joined
            }
        }
        .onChange(of: game.serial) { _, new in
            if !serialFieldFocused, draftSerial != new {
                draftSerial = new
            }
        }
        .onChange(of: game.discLabel) { _, _ in
            if !discFieldFocused {
                draftDisc = game.resolvedDisc(ip: ipInfo)
            }
        }
        .onChange(of: game.regionLabel) { _, _ in
            if !regionFieldFocused {
                draftRegion = game.resolvedRegion(ip: ipInfo)
            }
        }
        .onChange(of: ipInfo) { _, ip in
            if !discFieldFocused {
                draftDisc = game.resolvedDisc(ip: ip)
            }
            if !regionFieldFocused {
                draftRegion = game.resolvedRegion(ip: ip)
            }
        }
        .onChange(of: state.focusNameFieldToken) { _, _ in
            nameFieldFocused = true
        }
    }

    // MARK: - Multi

    private func multiInspector(
        _ games: [GameEntry],
        totalBytes: Int64,
        anyDup: Bool,
        anyMarked: Bool
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                collapsible(.selection) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(games.count) games")
                            .font(.title3.weight(.semibold).monospacedDigit())

                        Text(state.formatSize(totalBytes))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(games.prefix(12)) { g in
                                HStack(spacing: 8) {
                                    Text(FolderNumbering.format(g.number))
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

                        if snap.duplicatesEnabled {
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
                        .help("Soft-delete to card trash")

                        Button(role: .destructive) {
                            state.deleteSelectedImmediately()
                        } label: {
                            Text("Delete \(games.count) Immediately…")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(state.isBusy)
                        .help("Erase from the card now; cannot be undone")
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

    // MARK: - openMenu (virtual folder + disc type)

    private func openMenuSectionBody(_ game: GameEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorRow("Folder") {
                FolderPathComboField(
                    text: draftFolder,
                    suggestions: folderOptions(including: draftFolder),
                    onCommit: { typed in
                        draftFolder = typed
                        state.setVirtualFolder(id: game.id, to: typed)
                        if let updated = state.games.first(where: { $0.id == game.id }) {
                            draftFolder = updated.virtualFolder
                        }
                    }
                )
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .help("Click the field and type a path, or use the arrow to pick one already on the card. Nested folders use backslashes (Games\\RPGs). Clear the field to unfile. Return or click away to save.")
            }

            inspectorRow("Also in") {
                TextField("Games\\A–Z", text: $draftExtras)
                    .textFieldStyle(.roundedBorder)
                    .focused($extrasFieldFocused)
                    .onSubmit { commitOpenMenu(for: game) }
                    .onChange(of: extrasFieldFocused) { _, focused in
                        if !focused { commitOpenMenu(for: game) }
                    }
                    .help("Up to five extra folder paths, separated by semicolons, so the disc appears in more than one folder.")
            }

            inspectorRow("Type") {
                Picker("Type", selection: Binding(
                    get: { game.discType },
                    set: { state.setDiscType(id: game.id, to: $0) }
                )) {
                    ForEach(OpenMenuItemType.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(game.discType.helpText)
            }

            Text(state.menuKind.supportsVirtualFolders
                 ? "Written to folder.txt / type.txt and baked into OPENMENU.INI."
                 : "Saved on the card; used the next time you rebuild as openMenu Extended.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commitOpenMenu(for game: GameEntry) {
        let extras = draftExtras
            .split(whereSeparator: { $0 == ";" || $0 == "," || $0 == "\n" })
            .map(String.init)
        state.setOpenMenuMeta(
            id: game.id,
            virtualFolder: game.virtualFolder,
            extraFolders: extras,
            discType: game.discType
        )
        if let updated = state.games.first(where: { $0.id == game.id }) {
            draftExtras = updated.extraFolders.joined(separator: "; ")
        }
    }

    private func folderOptions(including current: String) -> [String] {
        var folders = state.knownVirtualFolders
        if !current.isEmpty, !folders.contains(current) {
            folders.append(current)
            folders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return folders
    }

    private func titleStatusLine(for game: GameEntry) -> String {
        let slot = FolderNumbering.format(game.number)
        let size = state.formatGameSize(game)
        if game.isMenu {
            return "Slot \(slot) · \(snap.menuDisplayName) · \(size)"
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
                        Text(FolderNumbering.format(peer.number))
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

                Text(ipBinMetaLine(ip, game: game))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if game.isMenu || game.number == 1 {
                    inspectorRow("Serial") {
                        Text(preferredSerial(game: game, ip: ip))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    inspectorRow("Region") {
                        Text(game.resolvedRegion(ip: ip).isEmpty ? "—" : game.resolvedRegion(ip: ip))
                            .font(.body.monospaced())
                            .lineLimit(1)
                    }
                } else {
                    inspectorRow("Serial") {
                        TextField("MK-51000", text: $draftSerial)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .focused($serialFieldFocused)
                            .onSubmit { commitSerial(for: game) }
                            .onChange(of: serialFieldFocused) { _, focused in
                                if !focused { commitSerial(for: game) }
                            }
                            .help("Product ID (serial.txt). Multi-disc sets must share the same serial.")
                    }
                    inspectorRow("Disc") {
                        TextField("1/1", text: $draftDisc)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .focused($discFieldFocused)
                            .onSubmit { commitDisc(for: game) }
                            .onChange(of: discFieldFocused) { _, focused in
                                if !focused { commitDisc(for: game) }
                            }
                            .help("Disc number for openMenu Compact grouping (disc.txt), e.g. 1/4.")
                    }
                    inspectorRow("Region") {
                        TextField("JUE", text: $draftRegion)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .focused($regionFieldFocused)
                            .onSubmit { commitRegion(for: game) }
                            .onChange(of: regionFieldFocused) { _, focused in
                                if !focused { commitRegion(for: game) }
                            }
                            .help("Region flags for openMenu (region.txt). Any mix of J, U, and E.")
                    }
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

    private func ipBinMetaLine(_ ip: IpBinInfo, game: GameEntry) -> String {
        var parts = [ip.version, "DISC \(game.resolvedDisc(ip: ip))"]
        if ip.vga { parts.append("VGA") }
        return parts.joined(separator: " · ")
    }

    private func commitSerial(for game: GameEntry) {
        state.setSerial(id: game.id, to: draftSerial)
        if let updated = state.games.first(where: { $0.id == game.id }) {
            draftSerial = updated.serial
        }
    }

    private func commitDisc(for game: GameEntry) {
        state.setDiscLabel(id: game.id, to: draftDisc)
        if let updated = state.games.first(where: { $0.id == game.id }) {
            draftDisc = updated.resolvedDisc(ip: ipInfo)
        }
    }

    private func commitRegion(for game: GameEntry) {
        state.setRegionLabel(id: game.id, to: draftRegion)
        if let updated = state.games.first(where: { $0.id == game.id }) {
            let resolved = updated.resolvedRegion(ip: ipInfo)
            draftRegion = resolved
        }
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
                state.delete(id: game.id, permanent: false)
            } label: {
                Text("Delete from Card")
                    .frame(maxWidth: .infinity)
            }
            .disabled(state.isBusy)
            .help("Soft-delete to card trash")

            Button(role: .destructive) {
                state.delete(id: game.id, permanent: true)
            } label: {
                Text("Delete Immediately…")
                    .frame(maxWidth: .infinity)
            }
            .disabled(state.isBusy)
            .help("Erase from the card now; cannot be undone")
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
        draftFolder = game.virtualFolder
        draftExtras = game.extraFolders.joined(separator: "; ")
        draftSerial = game.serial
        draftDisc = game.resolvedDisc(ip: ipInfo)
        draftRegion = game.resolvedRegion(ip: ipInfo)
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

        // Prefer in-memory header cache (warm rebuilds / prior inspector visit).
        if let cached = game.ipHeader {
            ipInfo = cached
            Task.detached(priority: .userInitiated) {
                let tex = GdtexLoader.load(for: entry)
                await MainActor.run {
                    guard detailLoadToken == token else { return }
                    gdtexImage = tex.image
                    gdtexStatus = tex.image == nil
                        ? (tex.status.isEmpty ? "File not found" : tex.status)
                        : ""
                }
            }
            return
        }

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
                // Cache for menu rebuild so we don’t re-read every GDI on the card.
                state.applyIpHeader(ip, forGameID: entry.id)
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
