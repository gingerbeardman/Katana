import AppKit
import SwiftUI

/// Feature row for the first-launch welcome window (Brutify / Ditto style).
struct WelcomeFeature: Sendable {
    let icon: String
    let title: String
    let description: String
}

struct WelcomeView: View {
    var features: [WelcomeFeature]
    var onDismiss: (() -> Void)?

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Katana"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 12)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Welcome to \(appName)")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 16)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                    featureRow(icon: feature.icon, title: feature.title, description: feature.description)
                }
            }
            .padding(.top, 28)
            .padding(.horizontal, 8)

            Spacer()
                .frame(minHeight: 32)

            Button("Get Started") {
                onDismiss?()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)

            Spacer()
                .frame(height: 32)
        }
        .padding(.horizontal, 36)
        .frame(width: 440)
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 28, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body).fontWeight(.semibold)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Window

/// Presents the welcome window. `showIfFirstLaunch()` runs once per install;
/// `show()` always presents it (Help menu).
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?
    private static let seenKey = "has_seen_welcome"

    private static let features = [
        WelcomeFeature(
            icon: "sdcard",
            title: "Open a GDEMU Card",
            description: "Point Katana at the root of your SD card (the folder with 01, 02, …). Recents reopen the last card automatically."
        ),
        WelcomeFeature(
            icon: "pencil.and.list.clipboard",
            title: "Rename & Reorder",
            description: "Edit names, sort A–Z, or drag order onto the disc. Changes write immediately — undo with ⌘Z."
        ),
        WelcomeFeature(
            icon: "square.stack.3d.up.badge.a",
            title: "Find Duplicates",
            description: "Spot same-size, same-serial, and hash-matched copies. Hash missing games when you want exact matches."
        ),
        WelcomeFeature(
            icon: "oven",
            title: "Rebuild the Menu",
            description: "Bake names and order into GDmenu or openMenu in slot 01 (⌘S) so the menu matches the card."
        ),
    ]

    /// Show only on first launch; afterwards this is a no-op.
    func showIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.seenKey) else { return }
        show()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = WelcomeView(features: Self.features) { [weak self] in
            self?.window?.close()
        }

        let win = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.contentView = NSHostingView(rootView: view)
        win.setContentSize(win.contentView!.fittingSize)
        win.isReleasedWhenClosed = false
        win.delegate = self
        window = win

        // Centre over the main window when available (early launch can leave center() off-screen).
        let host = NSApp.windows.first { $0 !== win && $0.isVisible && !($0 is NSPanel) }
        if let frame = host?.frame ?? NSScreen.main?.visibleFrame {
            let size = win.frame.size
            win.setFrameOrigin(
                NSPoint(
                    x: frame.midX - size.width / 2,
                    y: frame.midY - size.height / 2
                )
            )
        } else {
            win.center()
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        window = nil
    }
}
