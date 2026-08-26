import AppKit
import Foundation

/// Sheet for **Assign Folder → Type a Path…** — same editable combo as the inspector.
enum OpenMenuFolderPrompt {
    @MainActor
    static func askPath(seed: String = "", suggestions: [String] = []) -> String? {
        let alert = NSAlert()
        alert.messageText = "Assign Folder"
        alert.informativeText = "Pick a folder already on the card, or type a path. Nested folders use backslashes (Games\\RPGs)."
        alert.addButton(withTitle: "Assign")
        alert.addButton(withTitle: "Cancel")

        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        combo.isEditable = true
        combo.isSelectable = true
        combo.completes = true
        combo.hasVerticalScroller = true
        combo.numberOfVisibleItems = 12
        combo.placeholderString = "Games\\RPGs"
        combo.font = .systemFont(ofSize: NSFont.systemFontSize)
        combo.addItems(withObjectValues: suggestions)
        combo.stringValue = seed
        alert.accessoryView = combo
        alert.window.initialFirstResponder = combo

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let cleaned = OpenMenuFolderPath.cleaned(combo.stringValue)
        return cleaned.isEmpty ? nil : cleaned
    }
}
