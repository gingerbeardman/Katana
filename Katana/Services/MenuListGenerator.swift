import Foundation

/// Builds GDmenu `LIST.INI` / openMenu `OPENMENU.INI` text from the on-disc game order.
enum MenuListGenerator: Sendable {
    /// One LIST.INI / OPENMENU.INI entry.
    nonisolated struct Item: Sendable {
        var number: Int
        var name: String
        var serial: String
        var ip: IpBinInfo
    }

    /// Format folder number the same way GDMENUCardManager does (width by magnitude).
    nonisolated static func formatFolderNumber(_ number: Int) -> String {
        if number < 100 { return String(format: "%02d", number) }
        if number < 1000 { return String(format: "%03d", number) }
        if number < 10000 { return String(format: "%04d", number) }
        return String(number)
    }

    /// Generate LIST.INI body for GDmenu.
    nonisolated static func makeGDMenuList(items: [Item]) -> String {
        var sb = "[GDMENU]\n"
        for item in items {
            appendEntry(to: &sb, item: item, openMenu: false)
        }
        return sb
    }

    /// Generate OPENMENU.INI body for openMenu.
    nonisolated static func makeOpenMenuList(items: [Item]) -> String {
        var sb = "[OPENMENU]\n"
        sb += "num_items=\(items.count)\n\n"
        sb += "[ITEMS]\n"
        for item in items {
            appendEntry(to: &sb, item: item, openMenu: true)
        }
        return sb
    }

    nonisolated static func makeList(kind: MenuKind, items: [Item]) -> String {
        switch kind {
        case .gdMenu: return makeGDMenuList(items: items)
        case .openMenu: return makeOpenMenuList(items: items)
        }
    }

    nonisolated private static func appendEntry(to sb: inout String, item: Item, openMenu: Bool) {
        let n = formatFolderNumber(item.number)
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = item.ip

        sb += "\(n).name=\(name)\n"
        if ip.isCodeBreaker {
            sb += "\(n).disc=\n"
        } else {
            sb += "\(n).disc=\(ip.disc)\n"
        }
        sb += "\(n).vga=\(ip.vga ? "1" : "0")\n"
        sb += "\(n).region=\(ip.region)\n"
        sb += "\(n).version=\(ip.version)\n"
        sb += "\(n).date=\(ip.releaseDate)\n"
        if openMenu {
            // openMenu product id: strip dashes, first token only.
            let product = item.serial
                .replacingOccurrences(of: "-", with: "")
                .split(whereSeparator: \.isWhitespace)
                .first
                .map(String.init) ?? ""
            sb += "\(n).product=\(product)\n"
        }
        sb += "\n"
    }

    /// Build items for every game in disc order (slot numbers as-is).
    /// Reads IP.BIN off the main actor for fields GDmenu displays.
    nonisolated static func items(
        for games: [GameEntry],
        menuKind: MenuKind,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> [Item] {
        let total = games.count
        var result: [Item] = []
        result.reserveCapacity(total)

        for (index, game) in games.enumerated() {
            progress?(index, total)

            let ip: IpBinInfo
            if game.isMenu || game.number == 1 {
                // Prefer fields from the stock menu IP.BIN when present in the bundle;
                // fall back to reading the on-card menu image.
                if let read = IpBinReader.read(from: game) {
                    ip = read
                } else {
                    switch menuKind {
                    case .gdMenu:
                        ip = IpBinInfo.menuDefaults
                    case .openMenu:
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
            } else if let read = IpBinReader.read(from: game) {
                ip = read
            } else {
                ip = .fallback(name: game.name, serial: game.serial)
            }

            result.append(
                Item(
                    number: game.number,
                    name: game.name,
                    serial: game.serial.isEmpty ? ip.productNumber : game.serial,
                    ip: ip
                )
            )
        }
        progress?(total, total)
        return result
    }
}
