import Foundation

/// Collapsible inspector sections; expand/collapse is persisted in UserDefaults.
enum InspectorSection: String, CaseIterable, Identifiable, Sendable {
    case title
    case duplicate
    case ipBin
    case gdtex
    case onCard
    case actions
    case selection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: return "Title"
        case .duplicate: return "Duplicate"
        case .ipBin: return "IP.BIN"
        case .gdtex: return "Cover"
        case .onCard: return "On Card"
        case .actions: return "Actions"
        case .selection: return "Selection"
        }
    }

    /// First-launch default (before any UserDefaults write).
    var defaultExpanded: Bool {
        switch self {
        case .title, .duplicate, .ipBin, .gdtex, .onCard, .actions, .selection:
            return true
        }
    }
}
