import AppKit
import SwiftUI

/// Finder / 2UP-style borderless rename field for table/list cells.
///
/// - Retries first-responder until the field is in a window (context menu / Table lag).
/// - Preselects once; never re-steals selection after the user edits.
/// - Return commits; Escape cancels and asks to restore table focus;
///   focus loss within the key window cancels without restore; losing key window commits
///   (Finder-style).
struct InlineRenameField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = NSFont.systemFontSize
    var alignment: NSTextAlignment = .natural
    /// Preselected range on first focus. `nil` selects all.
    var initialSelection: NSRange?
    let onCommit: () -> Void
    /// `restoreFocus` is true for Escape; false when focus already moved elsewhere.
    let onCancel: (_ restoreFocus: Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onChange: { text = $0 },
            onCommit: onCommit,
            onCancel: onCancel,
            initialSelection: initialSelection
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.lineBreakMode = .byTruncatingMiddle
        field.alignment = alignment
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("Katana.renameField")
        focus(field, coordinator: context.coordinator, attempts: 12)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onChange = { text = $0 }
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        context.coordinator.initialSelection = initialSelection
        if field.stringValue != text { field.stringValue = text }
        if field.font?.pointSize != fontSize { field.font = .systemFont(ofSize: fontSize) }
        if field.alignment != alignment { field.alignment = alignment }
        // Retry focus only until the first editing session begins. Refocusing after
        // that would steal first responder back from a row the user clicked.
        if field.currentEditor() == nil && !context.coordinator.hasBegunEditing {
            focus(field, coordinator: context.coordinator, attempts: 12)
        }
    }

    private func focus(_ field: NSTextField, coordinator: Coordinator, attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.async {
            guard let window = field.window else {
                // Not in the hierarchy yet (cold Table hosting / first rename of session).
                focus(field, coordinator: coordinator, attempts: attempts - 1)
                return
            }
            guard window.isKeyWindow else {
                // Same pattern as 2UP table focus: wait briefly for key status.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
                    focus(field, coordinator: coordinator, attempts: attempts - 1)
                }
                return
            }
            // makeNSView and the first updateNSView can both schedule focus. Once the
            // field editor is open, a second makeFirstResponder ends that brand-new
            // session with NSTextMovementOther — make retries idempotent (2UP).
            if let editor = field.currentEditor() as? NSTextView {
                coordinator.applyInitialSelection(in: editor)
                return
            }
            if window.makeFirstResponder(field),
               let editor = field.currentEditor() as? NSTextView
            {
                coordinator.applyInitialSelection(in: editor)
            } else {
                // Table still settling first-responder (common on the first rename).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
                    focus(field, coordinator: coordinator, attempts: attempts - 1)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onChange: (String) -> Void
        var onCommit: () -> Void
        var onCancel: (_ restoreFocus: Bool) -> Void
        var initialSelection: NSRange?
        private(set) var hasBegunEditing = false
        private var hasAppliedInitialSelection = false
        private var finished = false

        init(
            onChange: @escaping (String) -> Void,
            onCommit: @escaping () -> Void,
            onCancel: @escaping (_ restoreFocus: Bool) -> Void,
            initialSelection: NSRange?
        ) {
            self.onChange = onChange
            self.onCommit = onCommit
            self.onCancel = onCancel
            self.initialSelection = initialSelection
        }

        func applyInitialSelection(in editor: NSTextView) {
            guard !hasAppliedInitialSelection else { return }
            hasAppliedInitialSelection = true
            selectInitialRange(initialSelection, in: editor)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            hasBegunEditing = true
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            applyInitialSelection(in: editor)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onChange(field.stringValue)
        }

        /// Editing ended without an explicit Return. Losing key window → commit
        /// (Finder). Focus moved within the app → cancel.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard !finished else { return }
            finished = true
            let field = notification.object as? NSTextField
            if field?.window?.isKeyWindow == false {
                onCommit()
            } else {
                onCancel(false)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                finished = true
                onCommit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finished = true
                onCancel(true)
                return true
            default:
                return false
            }
        }
    }
}

/// Applies a rename field's preselection, falling back to select-all when missing/stale.
private func selectInitialRange(_ range: NSRange?, in editor: NSTextView) {
    guard let range, NSMaxRange(range) <= (editor.string as NSString).length else {
        editor.selectAll(nil)
        return
    }
    editor.setSelectedRange(range)
}

// MARK: - Title cell (observes AppState so Table cell cache still updates)

/// SwiftUI `Table` caches custom cell content while row identity is unchanged.
/// Observe rename state *inside* the cell so context menu / Return swap the label
/// for the editor immediately (2UP `RenameAwareName` pattern).
struct RenameAwareTitleCell: View {
    let game: GameEntry
    @Bindable var state: AppState

    @State private var draft: String

    init(game: GameEntry, state: AppState) {
        self.game = game
        self.state = state
        // Seed in init so the field has the right string the moment it becomes first
        // responder (and can preselect). Seeding from onChange is one frame too late.
        _draft = State(initialValue: game.name)
    }

    var body: some View {
        Group {
            if state.renamingGameID == game.id {
                InlineRenameField(
                    text: $draft,
                    initialSelection: Self.stemRange(for: draft),
                    onCommit: {
                        let name = draft
                        state.commitInlineRename(id: game.id, to: name)
                    },
                    onCancel: { _ in
                        guard state.renamingGameID == game.id else { return }
                        state.cancelInlineRename()
                    }
                )
            } else {
                Text(game.name)
                    .fontWeight(game.isMenu ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Table caches cells by row identity — re-seed the draft when rename starts
        // so a recycled cell does not open with a stale string.
        .onChange(of: state.renamingGameID) { _, newID in
            if newID == game.id {
                draft = game.name
            }
        }
    }

    /// Full name when there is no extension; otherwise stem only (Finder-style).
    private static func stemRange(for name: String) -> NSRange {
        let ns = name as NSString
        let stem = ns.deletingPathExtension
        return NSRange(location: 0, length: (stem as NSString).length)
    }
}
