import SwiftUI

struct GameRowView: View {
    let game: GameEntry
    let maxNumber: Int
    var duplicate: DuplicateInfo?
    var isHashing: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text(FolderNumbering.format(game.number, maxNumber: maxNumber))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                if isHashing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 2)
                if game.isMenu {
                    MenuChip()
                        .layoutPriority(1)
                }
                if let duplicate {
                    DuplicateBadge(info: duplicate)
                        .layoutPriority(1)
                }
            }
            .frame(minWidth: 72, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .fontWeight(game.isMenu ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !game.serial.isEmpty {
                    Text(game.serial)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            FormatBadge(format: game.format)

            Text(game.needsDetailEnrichment && game.byteSize < 1_000_000
                 ? "—"
                 : ByteCount.gameSizeString(for: game.byteSize, integerMegabytes: true))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

/// Slot column: number (and optional hash spinner) leading; MENU / duplicate chips trailing.
struct NumberColumnCell: View {
    let game: GameEntry
    let maxNumber: Int
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 4) {
            Text(FolderNumbering.format(game.number, maxNumber: maxNumber))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            if state.isHashingGame(game) {
                ProgressView()
                    .controlSize(.small)
                    .help("Computing content hash…")
            }
            Spacer(minLength: 2)
            if game.isMenu {
                MenuChip()
                    .layoutPriority(1)
            }
            if let badge = state.listDuplicateBadge(for: game.id) {
                DuplicateBadge(badge)
                    .layoutPriority(1)
            }
        }
        .opacity(state.isDeemphasizedInList(game) ? 0.38 : 1)
    }
}

struct MenuChip: View {
    var body: some View {
        Text("MENU")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.14), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// List badge for a flagged duplicate (grade + index only — no blank placeholders).
enum DuplicateListBadge: Equatable {
    case ready(DuplicateInfo)
}

struct DuplicateBadge: View {
    let badge: DuplicateListBadge

    init(_ badge: DuplicateListBadge) {
        self.badge = badge
    }

    /// Convenience for call sites that already have a resolved `DuplicateInfo`.
    init(info: DuplicateInfo) {
        self.badge = .ready(info)
    }

    var body: some View {
        switch badge {
        case .ready(let info):
            chipLabel("\(info.grade.shortLabel) \(info.indexInGroup)/\(info.groupSize)")
                .background(color(for: info).opacity(0.18), in: Capsule())
                .foregroundStyle(color(for: info))
                .help(helpText(for: info))
        }
    }

    private func chipLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold).monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
    }

    private func helpText(for info: DuplicateInfo) -> String {
        let signals = info.signals.map { "\($0.kind.rawValue): \($0.detail)" }.joined(separator: ", ")
        let role = info.isPrimary ? "keep (lowest slot)" : "extra"
        return "\(info.grade.label) · \(role) · \(signals)"
    }

    private func color(for info: DuplicateInfo) -> Color {
        switch info.grade {
        case .exact:
            return info.isPrimary ? .purple : .pink
        case .strong:
            return info.isPrimary ? .orange : .red
        case .likely:
            return info.isPrimary ? .yellow : .orange
        case .weak:
            return info.isPrimary ? .secondary : .orange
        }
    }
}

struct FormatBadge: View {
    let format: DiscFormat

    var body: some View {
        // Stubs / not-yet-scanned rows use `.unknown` — leave the cell empty (no "?").
        if format == .unknown {
            Color.clear
                .frame(width: 36, height: 1)
        } else {
            Text(format.displayName)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .foregroundStyle(color)
                .frame(width: 36)
        }
    }

    private var color: Color {
        switch format {
        case .gdi: return .green
        case .cdi: return .orange
        case .ccd: return .purple
        case .unknown: return .gray
        }
    }
}
