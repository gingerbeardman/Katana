import AppKit
import SwiftUI

/// Leading column: card status, recents, and duplicate tools.
/// Layout follows layout-inspector section rhythm (headers, 16/14 padding, full-width buttons)
/// while staying appropriate as a NavigationSplitView sidebar.
struct SidebarView: View {
    @Bindable var state: AppState

    /// Fixed label column for metric rows (inspector pattern).
    private let labelWidth: CGFloat = 72

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cardSection
                sectionDivider
                if !state.recentVolumes.isEmpty {
                    recentSection
                    sectionDivider
                }
                if state.volume != nil {
                    duplicatesSection
                    sectionDivider
                }
                if let stats = state.lastScanStats {
                    scanSection(stats)
                    sectionDivider
                }
                notesSection
            }
            .padding(.bottom, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    }

    // MARK: - Card

    private var cardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Card")

            if let volume = state.volume {
                HStack(spacing: 8) {
                    Image(systemName: "sdcard.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(volume.volumeName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if volume.isReadOnly {
                        Text("Read-only")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }

                if volume.isReadOnly {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .imageScale(.small)
                        Text("This card is read-only. Check the lock switch on the SD card — renames, deletes, and menu rebuilds will fail.")
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                if let free = volume.freeBytes, let total = volume.totalBytes, total > 0 {
                    let used = total - free
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(used), total: Double(total))
                        Text("\(ByteCount.string(for: free)) free of \(ByteCount.string(for: total))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                }

                Text(volume.rootPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Picker("Menu", selection: Binding(
                    get: { state.menuKind },
                    set: { state.setMenuKind($0) }
                )) {
                    ForEach(MenuKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(state.isBusy)
                .help("Console menu baked into slot 01. Switch and rebuild (⇧⌘R) to convert.")

                if state.isScanning, let progress = state.scanProgress, progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                }

                Button {
                    Task { await state.eject() }
                } label: {
                    Text("Eject")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!state.canEject)
            } else {
                Text("No card open")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 8)

                Button {
                    state.openCard()
                } label: {
                    Text("Open Card…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .disabled(state.isBusy && !state.isScanning)
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Recent")

            VStack(alignment: .leading, spacing: 2) {
                ForEach(state.recentVolumes) { recent in
                    recentRow(recent)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func recentRow(_ recent: RememberedVolume) -> some View {
        let isCurrent = state.volume?.volumeUUID == recent.volumeUUID
        return Button {
            // Same card already open — no rescan (openRemembered also guards).
            guard !isCurrent else { return }
            Task { await state.openRemembered(recent) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recent.volumeName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(recent.lastPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy || state.isScanning)
        .contextMenu {
            Button("Open") {
                Task { await state.openRemembered(recent) }
            }
            Button("Forget", role: .destructive) {
                Task { await state.forgetRecent(recent) }
            }
        }
    }

    // MARK: - Duplicates

    private var duplicatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Duplicates")

            if state.duplicateGameCount > 0 {
                metricRow("Groups", value: "\(state.duplicateGroupCount)")
                metricRow("Flagged", value: "\(state.duplicateGameCount)")
                metricRow("Exact", value: "\(state.exactDuplicateCount)", valueColor: .pink)
                metricRow("Extras", value: "\(state.redundantDuplicateCount)", valueColor: .red)
            } else {
                Text("No duplicates flagged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }

            metricRow("Unhashed", value: "\(state.unhashedGameCount)")

            if state.isHashing {
                HStack(alignment: .top, spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 1)
                    Text(state.hashingStatusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(state.hashingProgress.map { progress in
                    var lines = ["\(progress.completedCount) of \(progress.totalCount) hashed"]
                    if progress.hashedBytes > 0 {
                        lines.append("\(ByteCount.string(for: progress.hashedBytes)) hashed")
                    }
                    if progress.remainingBytes > 0 {
                        lines.append("\(ByteCount.string(for: progress.remainingBytes)) remaining")
                    }
                    if let bps = progress.bytesPerSecond {
                        lines.append(ByteCount.throughput(bytesPerSecond: bps))
                    }
                    if let eta = progress.etaSeconds {
                        lines.append("ETA \(ByteCount.etaString(seconds: eta))")
                    }
                    return lines.joined(separator: "\n")
                } ?? "Hashing disc content")

                Button {
                    state.stopContentHashing()
                } label: {
                    Text(state.isStoppingHashing ? "Stopping…" : "Stop Hashing")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!state.canStopHashing)
            } else {
                Button {
                    state.startContentHashing()
                } label: {
                    Text("Compute Missing Hashes…")
                        .frame(maxWidth: .infinity)
                }
                .disabled(state.isBusy || state.isHashing || state.unhashedGameCount == 0)
                .help("Background SHA-256; writes sidecars. Never automatic.")
            }

            Toggle("Show duplicate markers", isOn: $state.showDuplicateMarkers)
                .help("Grade badges on titles in the game list (Exact 1/2, …). Off by default.")

            Toggle("Show duplicates only", isOn: $state.showDuplicatesOnly)

            VStack(spacing: 8) {
                Button {
                    state.selectAllDuplicates()
                } label: {
                    Text("Select All Duplicates")
                        .frame(maxWidth: .infinity)
                }
                .disabled(state.isBusy || state.duplicateGameCount == 0)

                HStack(spacing: 8) {
                    Button {
                        state.selectExactRedundantDuplicates()
                    } label: {
                        Text("Exact Extras")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(state.isBusy || state.exactDuplicateCount == 0)
                    .help("Redundant copies with matching content hash")

                    Button {
                        state.selectRedundantDuplicates()
                    } label: {
                        Text("All Extras")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(state.isBusy || state.redundantDuplicateCount == 0)
                    .help("Every non-primary copy in any group")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .disabled(state.isScanning)
    }

    // MARK: - Scan / notes

    private func scanSection(_ stats: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Last Scan")
            Text(stats)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                state.volume?.isReadOnly == true
                    ? "Card is read-only — unlock the SD write-protect switch to make changes."
                    : "Writes go straight to the card.\nUndo with ⌘Z."
            )
                .font(.callout)
                .foregroundStyle(state.volume?.isReadOnly == true ? Color.orange : Color.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            Text(
                state.menuNeedsRebuild
                    ? "\(state.menuKind.displayName) list is out of date — Rebuild Menu (⇧⌘R), or you’ll be asked on quit."
                    : "Rebuild Menu (⇧⌘R) updates \(state.menuKind.displayName) in slot 01."
            )
                .font(.callout)
                .foregroundStyle(state.menuNeedsRebuild ? Color.orange : Color.secondary.opacity(0.8))
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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

    private func metricRow(
        _ label: String,
        value: String,
        valueColor: Color = .primary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Spacer(minLength: 4)
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
    }
}
