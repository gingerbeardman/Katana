import AppKit

/// Intercepts app quit so we can rebuild the menu and eject the SD card first.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep `isTextInputFocused` in sync so menu key equivalents (⌘A, ⌫, ⌘Z…)
        // don't steal keystrokes from TextField / search / field editors.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidUpdateForTextFocus(_:)),
            name: NSWindow.didUpdateNotification,
            object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        return appState.handleApplicationShouldTerminate()
    }

    /// Single-window utility: closing the main window quits (after the same terminate checks).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func windowDidUpdateForTextFocus(_ notification: Notification) {
        let editing = Self.isEditingText(in: NSApp.keyWindow)
        guard let appState, appState.isTextInputFocused != editing else { return }
        appState.isTextInputFocused = editing
    }

    /// Field editor (`NSTextView`) or an editable `NSTextField` owns typing shortcuts.
    private static func isEditingText(in window: NSWindow?) -> Bool {
        guard let first = window?.firstResponder else { return false }
        if let textView = first as? NSTextView {
            return textView.isEditable
        }
        if let textField = first as? NSTextField {
            return textField.isEditable
        }
        return false
    }
}
