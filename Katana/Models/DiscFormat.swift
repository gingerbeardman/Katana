import Foundation

nonisolated enum DiscFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case gdi
    case cdi
    case ccd
    case unknown

    var displayName: String {
        switch self {
        case .gdi: return "GDI"
        case .cdi: return "CDI"
        case .ccd: return "CCD"
        case .unknown: return "?"
        }
    }

    var preferredExtension: String {
        rawValue
    }
}
