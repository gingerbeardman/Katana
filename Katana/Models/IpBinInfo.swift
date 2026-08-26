import Foundation

/// Parsed Dreamcast IP.BIN header fields used by GDmenu LIST.INI.
nonisolated struct IpBinInfo: Hashable, Sendable, Codable {
    var name: String
    var productNumber: String
    var disc: String
    var region: String
    var vga: Bool
    var version: String
    var releaseDate: String
    /// 4-char header CRC field at IP.BIN 0x20 (shown in GCM as “CRC: B0F4”).
    var crc: String = ""
    var isCodeBreaker: Bool

    static let menuDefaults = IpBinInfo(
        name: "GDMENU",
        productNumber: "MK-0000",
        disc: "1/1",
        region: "JUE",
        vga: true,
        version: "V0.6.0",
        releaseDate: "20160812",
        isCodeBreaker: false
    )

    /// Sensible fallbacks when a disc has no readable IP.BIN.
    static func fallback(name: String, serial: String) -> IpBinInfo {
        IpBinInfo(
            name: name,
            productNumber: serial,
            disc: "1/1",
            region: "JUE",
            vga: true,
            version: "V1.000",
            releaseDate: "19990909",
            isCodeBreaker: false
        )
    }

    /// One-line summary matching GCM’s Info window.
    var detailSummary: String {
        var lines: [String] = [name]
        let vgaMark = vga ? "   VGA" : ""
        lines.append("\(version)   DISC \(disc)\(vgaMark)")
        let crcPart = crc.isEmpty ? "—" : crc
        let product = productNumber.isEmpty ? "—" : productNumber
        lines.append("CRC: \(crcPart)   Product: \(product)")
        return lines.joined(separator: "\n")
    }
}

nonisolated enum MenuKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case gdMenu
    /// Stock openMenu (`OPENMENU.INI` without virtual-folder keys).
    case openMenu
    /// ateam Virtual Folder Bundle (folders, disc types, Folders themes).
    case openMenuExtended

    var id: String { rawValue }

    var isOpenMenuFamily: Bool {
        switch self {
        case .gdMenu: return false
        case .openMenu, .openMenuExtended: return true
        }
    }

    /// Folder / Type columns, inspector, and `folder=` / `type=` in OPENMENU.INI.
    var supportsVirtualFolders: Bool {
        self == .openMenuExtended
    }

    var volumeIdentifier: String {
        switch self {
        case .gdMenu: return "GDMENU"
        case .openMenu, .openMenuExtended: return "OPENMENU"
        }
    }

    /// Canonical `name.txt` / list entry for slot 01.
    var menuFolderName: String {
        switch self {
        case .gdMenu: return "GDMENU"
        case .openMenu, .openMenuExtended: return "openMenu"
        }
    }

    var listFileName: String {
        switch self {
        case .gdMenu: return "LIST.INI"
        case .openMenu, .openMenuExtended: return "OPENMENU.INI"
        }
    }

    var displayName: String {
        switch self {
        case .gdMenu: return "GDmenu"
        case .openMenu: return "openMenu"
        case .openMenuExtended: return "openMenu Extended"
        }
    }

    /// Segmented-control labels — keep the three segments similar width.
    var segmentTitle: String {
        switch self {
        case .gdMenu: return "GDmenu"
        case .openMenu: return "openMenu"
        case .openMenuExtended: return "Extended"
        }
    }

    /// Short help for pickers / settings.
    var helpText: String {
        switch self {
        case .gdMenu:
            return "Classic GDmenu (LIST.INI in slot 01). Folder and Type columns stay hidden."
        case .openMenu:
            return "Stock openMenu (OPENMENU.INI). Folder and Type columns stay hidden."
        case .openMenuExtended:
            return "openMenu 1.6.3-ateam Virtual Folder Bundle — folders, disc types, and Folders themes."
        }
    }

    /// 2.1 stored ateam as `openMenu`. Schema 1 keeps `openMenu` for stock.
    static func migratingFromPreExtendedSchema(_ kind: MenuKind) -> MenuKind {
        kind == .openMenu ? .openMenuExtended : kind
    }

    /// Detect from a display / `name.txt` string.
    /// Slot-01 is still named `openMenu` for both stock and Extended; callers refine via
    /// `supportsVirtualFolders` metadata on the card.
    static func detect(fromName name: String) -> MenuKind? {
        let n = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        if n.isEmpty { return nil }
        if n == "gdmenu" || n == "gdemu" { return .gdMenu }
        if n.contains("ateam") || n.contains("extended") { return .openMenuExtended }
        if n == "openmenu" { return .openMenu }
        return nil
    }

    /// Detect from IP.BIN product name / product code (stock menu images).
    static func detect(fromIP ip: IpBinInfo) -> MenuKind? {
        if let fromName = detect(fromName: ip.name) { return fromName }
        let product = ip.productNumber
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if product == "GDMENU" { return .gdMenu }
        // openMenu stock IP.BIN uses product code NEODC_1.
        if product.hasPrefix("NEODC") { return .openMenu }
        if let fromProduct = detect(fromName: product) { return fromProduct }
        return nil
    }
}
