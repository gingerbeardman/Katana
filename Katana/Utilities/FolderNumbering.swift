import Foundation

enum FolderNumbering: Sendable {
    /// GDEMU / GDMENU Card Manager folder names.
    ///
    /// - **Slot 1 (menu)** is always `01` — even on 100+ game cards. GCM installs the
    ///   menu into `01`, never `001`; LIST.INI keys must match.
    /// - **Slots 2…n** use 2 digits to 99, 3 to 999, 4 to 9999 based on `maxNumber`.
    nonisolated static func format(_ number: Int, maxNumber: Int) -> String {
        precondition(number >= 1)
        if number == 1 {
            return "01"
        }
        if maxNumber < 100 {
            return String(format: "%02d", number)
        }
        if maxNumber < 1000 {
            return String(format: "%03d", number)
        }
        return String(format: "%04d", number)
    }

    /// Width based on a single number's magnitude (when max is unknown).
    /// Slot 1 is still always `01`.
    nonisolated static func format(_ number: Int) -> String {
        format(number, maxNumber: number)
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
