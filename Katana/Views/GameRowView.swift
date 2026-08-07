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
                    .frame(minWidth: 28, alignment: .trailing)
                if isHashing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 56, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(game.name)
                        .fontWeight(game.isMenu ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if game.isMenu {
                        Text("MENU")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                    }
                    // Caller passes `duplicate` only when markers are enabled.
                    if let duplicate {
                        DuplicateBadge(info: duplicate)
                            .layoutPriority(1)
                    }
                }
                if !game.serial.isEmpty {
                    Text(game.serial)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            FormatBadge(format: game.format)

            Text(ByteCount.string(for: game.byteSize))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

/// List badge for duplicate markers (ready grade, or pending “—” while analysing).
enum DuplicateListBadge: Equatable {
    case pending
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
        case .pending:
            Text("—")
                .font(.caption2.weight(.bold).monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(.tertiary)
                .help("Detecting duplicates…")
        case .ready(let info):
            Text("\(info.grade.shortLabel) \(info.indexInGroup)/\(info.groupSize)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(color(for: info).opacity(0.18), in: Capsule())
                .foregroundStyle(color(for: info))
                .help(helpText(for: info))
        }
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
        Text(format.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(color)
            .frame(width: 36)
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
