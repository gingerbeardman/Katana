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
        // Begin-editing only fires after the first character. Click-to-focus must
        // still flip `isTextInputFocused` so menu key equivalents are dropped
        // before ⌘A / ⌫ hit a disabled Game-menu item (which beeps).
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { event in
            DispatchQueue.main.async { [weak self] in
                self?.syncTextInputFocusNow()
            }
            return event
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
            self?.syncTextInputFocusNow()
        }
    }

    private func syncTextInputFocusNow() {
        guard let appState else { return }
        let editing = Self.isEditingText(in: NSApp.keyWindow)
        if appState.isTextInputFocused != editing {
            appState.isTextInputFocused = editing
        }
    }

    /// Field editor, editable `NSTextField` / `NSComboBox` / search field.
    private static func isEditingText(in window: NSWindow?) -> Bool {
        var responder: NSResponder? = window?.firstResponder
        while let current = responder {
            if let textView = current as? NSTextView, textView.isEditable {
                return true
            }
            if let field = current as? NSTextField, field.isEditable {
                return true
            }
            responder = current.nextResponder
        }
        return false
    }
}
