import AppKit
import Foundation

/// Loads 0GDTEX.PVR artwork for a game folder (loose file or from GDI high-density ISO).
enum GdtexLoader: Sendable {
    private nonisolated static let candidateNames = ["0GDTEX.PVR", "0gdtex.pvr", "0Gdtex.pvr"]

    struct Result: Sendable {
        var image: NSImage?
        var status: String
    }

    /// Shown when neither a per-game texture nor a menu `BOX.DAT` entry exists.
    nonisolated static let missingCoverStatus = "No cover"

    /// Resolve cover art for a game entry. Safe off the main actor.
    ///
    /// `0GDTEX.PVR` on the game wins. Otherwise the slot-01 openMenu `BOX.DAT` is
    /// searched by serial — that is the art openMenu shows, and most CDI games have no texture of their own.
    nonisolated static func load(
        for game: GameEntry,
        menuFolder: URL? = nil,
        menuImageFileName: String? = nil,
        serials: [String] = []
    ) -> Result {
        load(
            folderURL: game.folderURL,
            imageFileName: game.imageFileName,
            format: game.format,
            menuFolder: menuFolder,
            menuImageFileName: menuImageFileName,
            serials: serials
        )
    }

    nonisolated static func load(
        folderURL: URL,
        imageFileName: String,
        format: DiscFormat,
        menuFolder: URL? = nil,
        menuImageFileName: String? = nil,
        serials: [String] = []
    ) -> Result {
        // 1) Loose file next to the disc image (common after Easy 0GDTEX tools).
        if let data = readLoosePVR(in: folderURL) {
            return decode(data, fallbackStatus: "Decode failed")
        }

        // 2) GDI: try high-density ISO tracks (skip track01 low-density / audio .raw).
        if format == .gdi || imageFileName.lowercased().hasSuffix(".gdi") {
            if let data = extractFromGDI(folderURL: folderURL, gdiFileName: imageFileName) {
                return decode(data, fallbackStatus: "Decode failed")
            }
        }

        // 3) openMenu box database on slot 01, keyed by serial.
        if let menuFolder,
           let box = OpenMenuBoxArt.imageData(
               matching: serials,
               menuFolder: menuFolder,
               imageFileName: menuImageFileName ?? "disc.gdi"
           ),
           let image = try? PvrDecoder.decodeImage(from: box)
        {
            return Result(image: image, status: "")
        }

        return Result(image: nil, status: missingCoverStatus)
    }

    // MARK: -

    private nonisolated static func decode(_ data: Data, fallbackStatus: String) -> Result {
        do {
            let image = try PvrDecoder.decodeImage(from: data)
            return Result(image: image, status: "")
        } catch {
            return Result(image: nil, status: error.localizedDescription)
        }
    }

    private nonisolated static func readLoosePVR(in folder: URL) -> Data? {
        let fm = FileManager.default
        // Exact names first.
        for name in candidateNames {
            let url = folder.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
        }
        // Case-insensitive scan of small folders.
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        for name in names where name.uppercased() == "0GDTEX.PVR" {
            let url = folder.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
        }
        return nil
    }

    /// Pull 0GDTEX.PVR from GDI data tracks via ISO 9660 (multi-track aware).
    private nonisolated static func extractFromGDI(folderURL: URL, gdiFileName: String) -> Data? {
        let tracks = dataTracks(folderURL: folderURL, gdiFileName: gdiFileName)
        guard !tracks.isEmpty else { return nil }
        return Iso9660FileExtractor.extract(named: "0GDTEX.PVR", tracks: tracks)
    }

    /// True when a GDI’s data track has a `0GDTEX.PVR` directory entry. Does not read the texture.
    nonisolated static func discHasTexture(
        folderURL: URL,
        imageFileName: String,
        format: DiscFormat
    ) -> Bool {
        guard format == .gdi || imageFileName.lowercased().hasSuffix(".gdi") else { return false }
        let tracks = dataTracks(folderURL: folderURL, gdiFileName: imageFileName)
        guard !tracks.isEmpty else { return false }
        return Iso9660FileExtractor.locate(named: ["0GDTEX.PVR"], tracks: tracks)["0GDTEX.PVR"] != nil
    }

    private nonisolated static func dataTracks(
        folderURL: URL,
        gdiFileName: String
    ) -> [Iso9660FileExtractor.DataTrack] {
        let gdiURL = folderURL.appendingPathComponent(gdiFileName)
        let text = (try? String(contentsOf: gdiURL, encoding: .utf8))
            ?? (try? String(contentsOf: gdiURL, encoding: .isoLatin1))
        guard let text else { return [] }
        var tracks: [Iso9660FileExtractor.DataTrack] = []
        for track in GdiCue.parseTracks(in: text) where track.type == 4 {
            let trackURL = folderURL.appendingPathComponent(track.fileName)
            guard FileManager.default.fileExists(atPath: trackURL.path) else { continue }
            tracks.append(.init(lba: UInt32(track.lba), url: trackURL))
        }
        return tracks
    }
}
