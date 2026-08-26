import Foundation

/// Cover-art / metadata DAT files baked into openMenu’s slot-01 GDI (`menu_data`).
///
/// GDMENU Card Manager stores these in the menu image, not as loose files on the card.
/// Katana’s bundled pack has none, so a rebuild must copy them out of the current
/// menu GDI and write them back or openMenu loses every assigned cover.
enum MenuArtworkDat: Sendable {
    /// Root-level names inside the high-density ISO (ISO 9660 8.3).
    nonisolated static let fileNames: [String] = [
        "BOX.DAT",
        "ICON.DAT",
        "META.DAT",
        "FOLDRART.DAT",
        "FOLDRART.MAP",
    ]

    /// Pull any DATs present in a menu slot folder’s GDI (and loose copies if any).
    nonisolated static func extract(fromMenuFolder folderURL: URL, imageFileName: String) -> [String: Data] {
        var found: [String: Data] = [:]
        found.merge(looseFiles(in: folderURL)) { current, _ in current }
        found.merge(extractFromGDI(folderURL: folderURL, imageFileName: imageFileName)) { current, incoming in
            current.count >= incoming.count ? current : incoming
        }
        return found.filter { !$0.value.isEmpty }
    }

    // MARK: - Loose files (unusual; kept for completeness)

    nonisolated private static func looseFiles(in folderURL: URL) -> [String: Data] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folderURL.path) else {
            return [:]
        }
        var result: [String: Data] = [:]
        for wanted in fileNames {
            guard let name = names.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame })
            else { continue }
            let url = folderURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            result[wanted] = data
        }
        return result
    }

    // MARK: - GDI high-density ISO

    nonisolated private static func extractFromGDI(
        folderURL: URL,
        imageFileName: String
    ) -> [String: Data] {
        let gdiName = imageFileName.lowercased().hasSuffix(".gdi")
            ? imageFileName
            : "disc.gdi"
        let gdiURL = folderURL.appendingPathComponent(gdiName)
        let text = (try? String(contentsOf: gdiURL, encoding: .utf8))
            ?? (try? String(contentsOf: gdiURL, encoding: .isoLatin1))
        guard let text else { return [:] }

        var tracks: [Iso9660FileExtractor.DataTrack] = []
        for track in GdiCue.parseTracks(in: text) where track.type == 4 {
            let trackURL = folderURL.appendingPathComponent(track.fileName)
            guard FileManager.default.fileExists(atPath: trackURL.path) else { continue }
            tracks.append(.init(lba: UInt32(track.lba), url: trackURL))
        }
        guard !tracks.isEmpty else { return [:] }
        return Iso9660FileExtractor.extract(named: fileNames, tracks: tracks)
            .filter { !$0.value.isEmpty }
    }
}
