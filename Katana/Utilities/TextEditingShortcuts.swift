import SwiftUI

extension View {
    /// Attach a menu key equivalent only when a text field is **not** focused.
    ///
    /// A *disabled* SwiftUI `Button` with `.keyboardShortcut` still owns that key in
    /// the menu bar — AppKit beeps instead of sending ⌘A / ⌫ / ⌘Z to the field editor.
    @ViewBuilder
    func keyboardShortcutUnlessTextEditing(
        _ key: KeyEquivalent,
        modifiers: EventModifiers = .command,
        textEditing: Bool
    ) -> some View {
        if textEditing {
            self
        } else {
            self.keyboardShortcut(key, modifiers: modifiers)
        }
    }
}
