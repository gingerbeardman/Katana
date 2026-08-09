import AppKit

/// SwiftUI has no API for macOS “alternate” menu items, so we wire them on the
/// native `NSMenu` when tracking starts (same approach as 2UP’s
/// `OpenWithMenuIconRegistry`).
///
/// **Delete** ↔ **Delete Immediately…** — AppKit shows only Delete by default and
/// swaps to the permanent erase while ⌥ is held. Main menu keeps ⌫ / ⌥⌫; context
/// menus swap on Option alone with no shortcut glyph.
@MainActor
enum MenuOptionAlternates {
    private static var trackingObserver: NSObjectProtocol?
    private static var itemObserver: NSObjectProtocol?
    private static var installed = false

    /// Call once at launch (e.g. `KatanaApp.init`).
    static func install() {
        guard !installed else { return }
        installed = true

        trackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let menu = notification.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                configure(menu)
            }
        }

        // First open of a SwiftUI context menu: the bridged NSMenu is still empty
        // when tracking begins. didAddItem fires as items land, before layout —
        // re-wire then so isAlternate hides the alternate instead of showing both.
        itemObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let menu = notification.object as? NSMenu,
                  let index = notification.userInfo?["NSMenuItemIndex"] as? Int else { return }
            MainActor.assumeIsolated {
                guard menu.items.indices.contains(index),
                      isDeleteImmediatelyTitle(menu.items[index].title) else { return }
                configure(menu)
            }
        }
    }

    private static func configure(_ menu: NSMenu) {
        configureDeleteImmediatelyAlternate(in: menu)
    }

    private static func configureDeleteImmediatelyAlternate(in menu: NSMenu) {
        let items = menu.items
        for i in items.indices where isDeleteImmediatelyTitle(items[i].title) {
            guard i > 0, isSoftDeleteTitle(items[i - 1].title) else { continue }
            let primary = items[i - 1]
            let alternate = items[i]

            if primary.keyEquivalent.isEmpty {
                // Context menu: swap on ⌥ alone; no shortcut glyph.
                alternate.keyEquivalent = ""
                alternate.keyEquivalentModifierMask = [.option]
            } else {
                // Main menu: same base key (⌫), primary plain, alternate + Option.
                alternate.keyEquivalent = primary.keyEquivalent
                var mask = primary.keyEquivalentModifierMask
                mask.insert(.option)
                alternate.keyEquivalentModifierMask = mask
            }
            alternate.isAlternate = true
        }
        for item in items {
            if let submenu = item.submenu {
                configureDeleteImmediatelyAlternate(in: submenu)
            }
        }
    }

    /// Soft-delete primary titles used in Game menu + context menus.
    private static func isSoftDeleteTitle(_ title: String) -> Bool {
        if title == "Delete" || title == "Delete Selected" || title == "Delete from Card" {
            return true
        }
        // "Delete 3 Games"
        guard title.hasPrefix("Delete "), title.hasSuffix(" Games") else { return false }
        let middle = title.dropFirst("Delete ".count).dropLast(" Games".count)
        return !middle.isEmpty && middle.allSatisfy(\.isNumber)
    }

    /// Permanent-erase alternate titles (with or without ellipsis / count).
    private static func isDeleteImmediatelyTitle(_ title: String) -> Bool {
        if title == "Delete Immediately…" || title == "Delete Immediately" {
            return true
        }
        // "Delete 3 Games Immediately…" / "Delete 3 Immediately…"
        guard title.hasPrefix("Delete "),
              title.contains("Immediately") else { return false }
        return true
    }
}
