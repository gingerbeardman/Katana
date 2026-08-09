import AppKit
import SwiftUI

// MARK: - View modifier (2UP-style AppKit drop)

extension View {
    /// Finder file-URL drops via an AppKit dragging destination behind the content.
    /// Same approach as 2UP’s `paneDragAndDrop`: read URLs from the drag pasteboard
    /// (`readObjects` + `urlReadingFileURLsOnly`) so multi-select Finder drops work
    /// reliably — SwiftUI `.onDrop` / `NSItemProvider` loading is flakier here.
    /// `onDrop` second argument is true when Option was held (skip auto-rename).
    func gameListFileDrop(
        enabled: Bool,
        isTargeted: Binding<Bool>,
        onDrop: @escaping ([URL], Bool) -> Void
    ) -> some View {
        background {
            GameListDropDestination(
                enabled: enabled,
                isTargeted: isTargeted,
                onDrop: onDrop
            )
        }
    }
}

// MARK: - Representable

private struct GameListDropDestination: NSViewRepresentable {
    var enabled: Bool
    var isTargeted: Binding<Bool>
    var onDrop: ([URL], Bool) -> Void

    func makeNSView(context: Context) -> GameListDropDestinationView {
        let view = GameListDropDestinationView()
        view.configure(enabled: enabled, isTargeted: isTargeted, onDrop: onDrop)
        return view
    }

    func updateNSView(_ view: GameListDropDestinationView, context: Context) {
        view.configure(enabled: enabled, isTargeted: isTargeted, onDrop: onDrop)
    }
}

/// Transparent AppKit drop target. Reports `.copy` so Finder shows the green + badge,
/// and resolves file URLs from the in-flight drag pasteboard (not async providers).
final class GameListDropDestinationView: NSView {
    private var enabled = false
    private var isTargeted: Binding<Bool>?
    private var onDrop: (([URL], Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        enabled: Bool,
        isTargeted: Binding<Bool>,
        onDrop: @escaping ([URL], Bool) -> Void
    ) {
        self.enabled = enabled
        self.isTargeted = isTargeted
        self.onDrop = onDrop
    }

    /// Synchronous file URLs from the drag pasteboard — matches 2UP pane drops.
    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        enabled && !fileURLs(from: sender).isEmpty
    }

    private func setTargeted(_ targeted: Bool) {
        if isTargeted?.wrappedValue != targeted {
            isTargeted?.wrappedValue = targeted
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(sender) else {
            setTargeted(false)
            return []
        }
        setTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(sender) else {
            setTargeted(false)
            return []
        }
        setTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setTargeted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAccept(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setTargeted(false)
        guard enabled else { return false }
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        // Option held at drop → keep source file/folder names (skip GameDB auto-rename).
        let skipAutoRename = NSEvent.modifierFlags.contains(.option)
        onDrop?(urls, skipAutoRename)
        return true
    }
}
