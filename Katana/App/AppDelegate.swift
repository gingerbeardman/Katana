import AppKit

/// Intercepts app quit so we can rebuild the menu and eject the SD card first.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("applicationWillFinishLaunching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("applicationDidFinishLaunching")
        // Keep `isTextInputFocused` in sync so menu key equivalents (⌘A, ⌫, ⌘Z…)
        // don't steal keystrokes from TextField / search / field editors.
        // Prefer editing begin/end (+ key-window changes) — *not* didUpdate, which
        // fires every layout pass and caused a brief main-thread hitch at launch.
        let nc = NotificationCenter.default
        for name in [
            NSText.didBeginEditingNotification,
            NSText.didEndEditingNotification,
            NSControl.textDidBeginEditingNotification,
            NSControl.textDidEndEditingNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            nc.addObserver(
                self,
                selector: #selector(syncTextInputFocus(_:)),
                name: name,
                object: nil
            )
        }
        LaunchTrace.mark("applicationDidFinishLaunching (observers installed)")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        return appState.handleApplicationShouldTerminate()
    }

    /// Single-window utility: closing the main window quits (after the same terminate checks).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func syncTextInputFocus(_ notification: Notification) {
        // Defer one turn so the field editor is installed before we sample firstResponder.
        DispatchQueue.main.async { [weak self] in
            guard let self, let appState = self.appState else { return }
            let editing = Self.isEditingText(in: NSApp.keyWindow)
            if appState.isTextInputFocused != editing {
                appState.isTextInputFocused = editing
            }
        }
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
