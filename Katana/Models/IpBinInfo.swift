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
}

enum MenuKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case gdMenu
    case openMenu

    var id: String { rawValue }

    var volumeIdentifier: String {
        switch self {
        case .gdMenu: return "GDMENU"
        case .openMenu: return "OPENMENU"
        }
    }

    /// Canonical `name.txt` / list entry for slot 01.
    var menuFolderName: String {
        switch self {
        case .gdMenu: return "GDMENU"
        case .openMenu: return "openMenu"
        }
    }

    var listFileName: String {
        switch self {
        case .gdMenu: return "LIST.INI"
        case .openMenu: return "OPENMENU.INI"
        }
    }

    var displayName: String {
        switch self {
        case .gdMenu: return "GDmenu"
        case .openMenu: return "openMenu"
        }
    }

    /// Short help for pickers / settings.
    var helpText: String {
        switch self {
        case .gdMenu:
            return "Classic GDmenu (LIST.INI in slot 01)."
        case .openMenu:
            return "openMenu (OPENMENU.INI, themes, product IDs)."
        }
    }

    /// Detect from a display / `name.txt` string.
    static func detect(fromName name: String) -> MenuKind? {
        let n = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        if n.isEmpty { return nil }
        if n == "gdmenu" || n == "gdemu" { return .gdMenu }
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
