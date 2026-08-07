import AppKit

/// Intercepts app quit so we can rebuild the menu and eject the SD card first.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        return appState.handleApplicationShouldTerminate()
    }

    /// Single-window utility: closing the main window quits (after the same terminate checks).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
