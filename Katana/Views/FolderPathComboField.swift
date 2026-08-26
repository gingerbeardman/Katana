import AppKit
import SwiftUI

/// Editable combo matching ateam GCM’s Folder cell: type a path or pick one already on the card.
/// Autocompletes from `suggestions`; empty string unfiles. Commits on Return, click-away, or a list pick.
struct FolderPathComboField: NSViewRepresentable {
    var text: String
    var suggestions: [String]
    var placeholder: String = "Games\\RPGs"
    var onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit)
    }

    func makeNSView(context: Context) -> InspectorComboBox {
        let combo = InspectorComboBox()
        combo.isEditable = true
        combo.isSelectable = true
        combo.completes = true
        combo.isButtonBordered = true
        combo.hasVerticalScroller = true
        combo.numberOfVisibleItems = 12
        combo.placeholderString = placeholder
        combo.font = .systemFont(ofSize: NSFont.systemFontSize)
        combo.delegate = context.coordinator
        combo.stringValue = text
        combo.addItems(withObjectValues: suggestions)
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        combo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return combo
    }

    func updateNSView(_ combo: InspectorComboBox, context: Context) {
        context.coordinator.onCommit = onCommit
        if combo.placeholderString != placeholder {
            combo.placeholderString = placeholder
        }
        let existing = (0..<combo.numberOfItems).compactMap { combo.itemObjectValue(at: $0) as? String }
        if existing != suggestions {
            let typed = combo.stringValue
            let editing = combo.currentEditor() != nil || combo.window?.firstResponder === combo
            combo.removeAllItems()
            combo.addItems(withObjectValues: suggestions)
            if editing {
                combo.stringValue = typed
            }
        }
        // Never clobber while the user is typing — SwiftUI refresh used to reset the field.
        let editing = combo.currentEditor() != nil || combo.window?.firstResponder === combo
        if !editing, combo.stringValue != text {
            combo.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var onCommit: (String) -> Void

        init(onCommit: @escaping (String) -> Void) {
            self.onCommit = onCommit
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            // Autocomplete changes the selection while typing — only commit a real list pick
            // (field editor already gone) so we don't rebuild the inspector mid-keystroke.
            DispatchQueue.main.async { [weak self, weak combo] in
                guard let self, let combo else { return }
                guard combo.currentEditor() == nil else { return }
                self.onCommit(combo.stringValue)
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let combo = obj.object as? NSComboBox else { return }
            onCommit(combo.stringValue)
        }
    }
}

/// Fills the inspector row; click focuses the field so keys go to the combo, not the table.
final class InspectorComboBox: NSComboBox {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(super.intrinsicContentSize.height, 21))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            NotificationCenter.default.post(
                name: NSControl.textDidBeginEditingNotification,
                object: self
            )
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            NotificationCenter.default.post(
                name: NSControl.textDidEndEditingNotification,
                object: self
            )
        }
        return ok
    }
}
