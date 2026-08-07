import AppKit
import Foundation

/// Loads 0GDTEX.PVR artwork for a game folder (loose file or from GDI high-density ISO).
enum GdtexLoader: Sendable {
    private nonisolated static let candidateNames = ["0GDTEX.PVR", "0gdtex.pvr", "0Gdtex.pvr"]

    struct Result: Sendable {
        var image: NSImage?
        var status: String
    }

    /// Resolve cover art for a game entry. Safe off the main actor.
    nonisolated static func load(for game: GameEntry) -> Result {
        load(folderURL: game.folderURL, imageFileName: game.imageFileName, format: game.format)
    }

    nonisolated static func load(
        folderURL: URL,
        imageFileName: String,
        format: DiscFormat
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

        // 3) Single-file images: not supported without a full image library.
        if format == .cdi || format == .ccd {
            return Result(image: nil, status: "No 0GDTEX.PVR in folder")
        }

        return Result(image: nil, status: "File not found")
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
        let gdiURL = folderURL.appendingPathComponent(gdiFileName)
        guard let text = try? String(contentsOf: gdiURL, encoding: .utf8) else { return nil }

        var tracks: [Iso9660FileExtractor.DataTrack] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 5,
                  let lba = UInt32(parts[1]),
                  let type = Int(parts[2]),
                  type == 4
            else { continue }
            let trackURL = folderURL.appendingPathComponent(parts[4])
            guard FileManager.default.fileExists(atPath: trackURL.path) else { continue }
            tracks.append(.init(lba: lba, url: trackURL))
        }
        guard !tracks.isEmpty else { return nil }
        return Iso9660FileExtractor.extract(named: "0GDTEX.PVR", tracks: tracks)
    }
}
