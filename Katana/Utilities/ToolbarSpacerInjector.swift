import AppKit
import ObjectiveC
import SwiftUI

// MARK: - Native toolbar spacers
//
// SwiftUI’s customizable toolbar doesn’t surface the system Space / Flexible
// Space items in the Customize sheet, and a custom SwiftUI item can’t render the
// native (invisible-in-toolbar, labeled-in-palette) spacer. So we wrap the
// toolbar’s delegate and add the standard space identifiers to its allowed list,
// giving the genuine AppKit “Space” / “Flexible Space” tiles that can be dragged
// in repeatedly — matching Finder, Brutify, and other standard apps.
//
// Pattern from ~/Projects/brutify (ToolbarSpacerInjector).

final class ToolbarSpacerInjector: NSObject, NSToolbarDelegate {
    private let wrapped: NSToolbarDelegate

    init(wrapping delegate: NSToolbarDelegate) {
        self.wrapped = delegate
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var ids = wrapped.toolbarAllowedItemIdentifiers?(toolbar) ?? []
        for spacer in [NSToolbarItem.Identifier.space, .flexibleSpace] where !ids.contains(spacer) {
            ids.append(spacer)
        }
        return ids
    }

    // Forward every other NSToolbarDelegate method to SwiftUI’s delegate.
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || wrapped.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? { wrapped }
}

private var toolbarInjectorKey: UInt8 = 0

extension NSWindow {
    /// Inject native Space / Flexible Space into this window’s toolbar palette.
    /// Retries because SwiftUI may attach the toolbar a run loop or two later.
    func installNativeToolbarSpacers(retries: Int = 12) {
        guard let toolbar = toolbar, let existing = toolbar.delegate else {
            if retries > 0 {
                DispatchQueue.main.async { self.installNativeToolbarSpacers(retries: retries - 1) }
            }
            return
        }
        guard !(existing is ToolbarSpacerInjector) else { return }
        let injector = ToolbarSpacerInjector(wrapping: existing)
        toolbar.delegate = injector
        // NSToolbar.delegate is weak — retain the injector for the window’s lifetime.
        objc_setAssociatedObject(self, &toolbarInjectorKey, injector, .OBJC_ASSOCIATION_RETAIN)
    }
}

// MARK: - SwiftUI install hook

/// Attaches to a view’s window and installs native toolbar spacers once available.
private struct ToolbarSpacerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.installNativeToolbarSpacers()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.installNativeToolbarSpacers()
        }
    }
}

extension View {
    /// Makes AppKit Space / Flexible Space available in Customize Toolbar…
    func installNativeToolbarSpacers() -> some View {
        background(ToolbarSpacerInstaller().frame(width: 0, height: 0))
    }
}
