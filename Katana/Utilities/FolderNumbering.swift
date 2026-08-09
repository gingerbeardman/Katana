import Foundation

enum FolderNumbering: Sendable {
    /// GDEMU / GDMENU Card Manager folder names and LIST.INI keys.
    ///
    /// Zero-padded to 2 digits (`01`…`99`), then natural width (`100`, `101`…) —
    /// regardless of how many games are on the card. GCM writes `02.name=` even on
    /// a 283-game card; 3-digit keys for slots under 100 corrupt the menu.
    nonisolated static func format(_ number: Int) -> String {
        precondition(number >= 1)
        return String(format: "%02d", number)
    }

    nonisolated static func parse(_ folderName: String) -> Int? {
        guard !folderName.isEmpty,
              folderName.allSatisfy(\.isNumber),
              let value = Int(folderName),
              value >= 1
        else { return nil }
        return value
    }
}
