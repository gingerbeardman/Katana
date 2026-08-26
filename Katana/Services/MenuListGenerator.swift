import Foundation

/// Builds GDmenu `LIST.INI` / openMenu `OPENMENU.INI` text from the on-card game order.
enum MenuListGenerator: Sendable {
    /// One LIST.INI / OPENMENU.INI entry.
    nonisolated struct Item: Sendable {
        var number: Int
        var name: String
        var serial: String
        var ip: IpBinInfo
        var virtualFolder: String = ""
        var extraFolders: [String] = []
        var discType: OpenMenuItemType = .game
        var discLabel: String = ""
        var regionLabel: String = ""
    }

    /// Format a list key to match **on-disk** folder names: `01`…`99`, then `100`….
    nonisolated static func formatFolderNumber(_ number: Int) -> String {
        FolderNumbering.format(number)
    }

    /// Generate LIST.INI body for GDmenu.
    nonisolated static func makeGDMenuList(items: [Item]) -> String {
        var sb = "[GDMENU]\n"
        for item in items {
            appendEntry(to: &sb, item: item, kind: .gdMenu)
        }
        return sb
    }

    /// Generate OPENMENU.INI body. Extended adds `folder=` / `folder_altN=` / `type=`.
    nonisolated static func makeOpenMenuList(items: [Item], extended: Bool = false) -> String {
        var sb = "[OPENMENU]\n"
        sb += "num_items=\(items.count)\n\n"
        sb += "[ITEMS]\n"
        for item in items {
            appendEntry(to: &sb, item: item, kind: extended ? .openMenuExtended : .openMenu)
        }
        return sb
    }

    nonisolated static func makeList(kind: MenuKind, items: [Item]) -> String {
        switch kind {
        case .gdMenu: return makeGDMenuList(items: items)
        case .openMenu: return makeOpenMenuList(items: items, extended: false)
        case .openMenuExtended: return makeOpenMenuList(items: items, extended: true)
        }
    }

    nonisolated private static func appendEntry(
        to sb: inout String,
        item: Item,
        kind: MenuKind = .gdMenu
    ) {
        let n = formatFolderNumber(item.number)
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = item.ip

        sb += "\(n).name=\(name)\n"
        if ip.isCodeBreaker {
            sb += "\(n).disc=\n"
        } else {
            let disc = item.discLabel.isEmpty ? (ip.disc.isEmpty ? "1/1" : ip.disc) : item.discLabel
            sb += "\(n).disc=\(disc)\n"
        }
        sb += "\(n).vga=\(ip.vga ? "1" : "0")\n"
        let region = item.regionLabel.isEmpty ? (ip.region.isEmpty ? "JUE" : ip.region) : item.regionLabel
        sb += "\(n).region=\(region)\n"
        sb += "\(n).version=\(ip.version)\n"
        sb += "\(n).date=\(ip.releaseDate)\n"
        if kind.isOpenMenuFamily {
            // openMenu product id: strip dashes, first token only.
            let product = item.serial
                .replacingOccurrences(of: "-", with: "")
                .split(whereSeparator: \.isWhitespace)
                .first
                .map(String.init) ?? ""
            sb += "\(n).product=\(product)\n"
            if kind.supportsVirtualFolders {
                sb += "\(n).folder=\(item.virtualFolder)\n"
                for (index, extra) in item.extraFolders.prefix(5).enumerated() {
                    sb += "\(n).folder_alt\(index + 1)=\(extra)\n"
                }
                sb += "\(n).type=\(item.discType.fileValue)\n"
            }
        }
        sb += "\n"
    }

    /// Headers filled from disk during this pass (misses) so callers can cache them on `GameEntry`.
    struct HeaderFill: Sendable {
        var gameID: UUID
        var ip: IpBinInfo
    }

    /// Build items for every game in card slot order (slot numbers as-is).
    /// Prefers `GameEntry.ipHeader`; only hits the card when the cache is cold.
    /// Progress reports `(done, total, readFromCard)` so callers can show the source split.
    nonisolated static func items(
        for games: [GameEntry],
        menuKind: MenuKind,
        progress: (@Sendable (Int, Int, Int) -> Void)? = nil
    ) -> [Item] {
        itemsWithHeaderFills(for: games, menuKind: menuKind, progress: progress).items
    }

    /// Same as `items`, plus any IP headers read from disk (for write-back into the list cache).
    nonisolated static func itemsWithHeaderFills(
        for games: [GameEntry],
        menuKind: MenuKind,
        progress: (@Sendable (Int, Int, Int) -> Void)? = nil
    ) -> (items: [Item], filledHeaders: [HeaderFill]) {
        let total = games.count
        var result: [Item] = []
        result.reserveCapacity(total)
        var fills: [HeaderFill] = []
        fills.reserveCapacity(min(total, 8))

        for (index, game) in games.enumerated() {
            progress?(index, total, fills.count)

            let ip: IpBinInfo
            if game.isMenu || game.number == 1 {
                // Menu slot: prefer cache, then on-card image, then stock defaults.
                if let cached = game.ipHeader {
                    ip = cached
                } else if let read = IpBinReader.read(from: game) {
                    ip = read
                    fills.append(HeaderFill(gameID: game.id, ip: read))
                } else {
                    switch menuKind {
                    case .gdMenu:
                        ip = IpBinInfo.menuDefaults
                    case .openMenu, .openMenuExtended:
                        // Matches stock openMenu IP.BIN product fields when unreadable.
                        ip = IpBinInfo(
                            name: menuKind.menuFolderName,
                            productNumber: "NEODC_1",
                            disc: "1/1",
                            region: "JUE",
                            vga: true,
                            version: "V0.1.0",
                            releaseDate: "20230101",
                            isCodeBreaker: false
                        )
                    }
                }
            } else if let cached = game.ipHeader {
                ip = cached
            } else if let read = IpBinReader.read(from: game) {
                ip = read
                fills.append(HeaderFill(gameID: game.id, ip: read))
            } else {
                ip = .fallback(name: game.name, serial: game.serial)
            }

            result.append(
                Item(
                    number: game.number,
                    name: game.name,
                    serial: game.serial.isEmpty ? ip.productNumber : game.serial,
                    ip: ip,
                    virtualFolder: game.isMenu ? "" : game.virtualFolder,
                    extraFolders: game.isMenu ? [] : game.extraFolders,
                    discType: game.isMenu ? .game : game.discType,
                    discLabel: game.isMenu ? "" : game.discLabel,
                    regionLabel: game.isMenu ? "" : game.regionLabel
                )
            )
        }
        progress?(total, total, fills.count)
        LaunchTrace.mark(
            "menu headers: \(total - fills.count)/\(total) cached, \(fills.count) read from card"
        )
        return (result, fills)
    }
}
