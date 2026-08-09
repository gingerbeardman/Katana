import Foundation
import SwiftUI

/// View-only table sort, persisted per card volume.
nonisolated struct DisplaySortPreference: Codable, Hashable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable {
        case number
        case name
        case serial
        case format
        case size
    }

    var field: Field
    /// `true` = ascending (A→Z, 1→n); `false` = descending (newest slots first when field is number).
    var ascending: Bool

    /// Preferred default: highest slot numbers first (usually the most recently added games).
    static let mostRecentFirst = DisplaySortPreference(field: .number, ascending: false)

    static let discOrder = DisplaySortPreference(field: .number, ascending: true)

    var comparators: [KeyPathComparator<GameEntry>] {
        let order: SortOrder = ascending ? .forward : .reverse
        switch field {
        case .number:
            return [KeyPathComparator(\.number, order: order)]
        case .name:
            return [KeyPathComparator(\.name, order: order)]
        case .serial:
            return [KeyPathComparator(\.serial, order: order)]
        case .format:
            return [KeyPathComparator(\.formatSortKey, order: order)]
        case .size:
            return [KeyPathComparator(\.byteSize, order: order)]
        }
    }

    /// Map SwiftUI Table sort state back to a storable preference.
    static func from(sortOrder: [KeyPathComparator<GameEntry>]) -> DisplaySortPreference? {
        guard let first = sortOrder.first else { return nil }
        let ascending = first.order == .forward
        let field: Field
        switch first.keyPath {
        case \GameEntry.number: field = .number
        case \GameEntry.name: field = .name
        case \GameEntry.serial: field = .serial
        case \GameEntry.formatSortKey: field = .format
        case \GameEntry.byteSize: field = .size
        default: return nil
        }
        return DisplaySortPreference(field: field, ascending: ascending)
    }

    var isMostRecentFirst: Bool {
        field == .number && !ascending
    }

    var isDiscSlotOrder: Bool {
        field == .number && ascending
    }

    var summary: String {
        let dir = ascending ? "ascending" : "descending"
        switch field {
        case .number:
            return ascending ? "Slot order" : "Newest slots first"
        case .name: return "Title \(dir)"
        case .serial: return "Serial \(dir)"
        case .format: return "Format \(dir)"
        case .size: return "Size \(dir)"
        }
    }
}
