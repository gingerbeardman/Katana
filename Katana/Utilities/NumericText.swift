import SwiftUI

extension View {
    /// Tabular figures for values that change or sit beside other numbers
    /// (sizes, counts, progress, ETAs) so columns and status lines don’t jitter.
    func numericText() -> some View {
        monospacedDigit()
    }
}

extension Text {
    /// Same as `numericText()` when the receiver is already a `Text`.
    func numericText() -> Text {
        monospacedDigit()
    }
}
