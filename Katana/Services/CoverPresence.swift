import Foundation

/// Where a game’s own `0GDTEX.PVR` lives. Menu `BOX.DAT` is not one of these.
nonisolated enum CoverSource: String, Codable, Hashable, Sendable {
    case none
    case disc
    case custom

    var displayName: String {
        switch self {
        case .none: return "None"
        case .disc: return "Disc"
        case .custom: return "Custom"
        }
    }

    var helpText: String {
        switch self {
        case .none: return "No cover"
        case .disc: return "Cover inside the disc"
        case .custom: return "Custom cover next to the disc"
        }
    }
}

/// Cover column value for one game.
///
/// A loose `0GDTEX.PVR` is **custom** and wins over a texture inside the disc.
/// The menu slot is always **none**. Does not consult `BOX.DAT`.
enum CoverPresence: Sendable {
    nonisolated static func source(for game: GameEntry) -> CoverSource {
        guard !game.isMenu, game.number != 1 else { return .none }
        if LooseCover.exists(in: game.folderURL) { return .custom }
        if GdtexLoader.discHasTexture(
            folderURL: game.folderURL,
            imageFileName: game.imageFileName,
            format: game.format
        ) { return .disc }
        return .none
    }
}
