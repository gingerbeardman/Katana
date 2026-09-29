import AppKit
import Foundation

/// A loose `0GDTEX.PVR` sitting next to a game’s disc image.
enum LooseCover: Sendable {
    nonisolated static let canonicalName = "0GDTEX.PVR"

    enum CoverError: LocalizedError {
        case unreadableImage

        var errorDescription: String? {
            switch self {
            case .unreadableImage: return "Can’t read that image."
            }
        }
    }

    nonisolated static func exists(in folder: URL) -> Bool {
        fileURL(in: folder) != nil
    }

    nonisolated static func read(in folder: URL) -> Data? {
        guard let url = fileURL(in: folder) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Replaces any `0GDTEX.PVR` in the folder, regardless of case.
    nonisolated static func write(_ data: Data, to folder: URL) throws {
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: folder.path) {
            for name in names where name.uppercased() == canonicalName && name != canonicalName {
                try? fm.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        let dest = folder.appendingPathComponent(canonicalName)
        // Non-atomic: FAT atomic replace is flaky under the App Sandbox.
        try data.write(to: dest, options: [])
        removeAppleDouble(in: folder)
    }

    /// Deletes a loose cover. A texture inside the disc image is left alone.
    @discardableResult
    nonisolated static func remove(from folder: URL) throws -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
        var removed = false
        for name in names where name.uppercased() == canonicalName {
            try fm.removeItem(at: folder.appendingPathComponent(name))
            removed = true
        }
        if removed { removeAppleDouble(in: folder) }
        return removed
    }

    /// A picture is scaled to a square 256×256 texture.
    /// A `.pvr` file is returned unchanged when Katana can decode it.
    nonisolated static func coverData(from url: URL) throws -> Data {
        if url.pathExtension.lowercased() == "pvr" {
            let data = try Data(contentsOf: url)
            _ = try PvrDecoder.decodeRGBA(from: data)
            return data
        }
        guard let image = NSImage(contentsOf: url) else {
            throw CoverError.unreadableImage
        }
        return try pvrData(from: image)
    }

    /// Scales `image` to a square 256×256 texture.
    nonisolated static func pvrData(from image: NSImage) throws -> Data {
        let raster = try rasterize(image)
        guard let data = PvrEncoder.encodeCover(rgba: raster.pixels, width: raster.width, height: raster.height) else {
            throw CoverError.unreadableImage
        }
        return data
    }

    nonisolated static func fileURL(in folder: URL) -> URL? {
        let fm = FileManager.default
        let exact = folder.appendingPathComponent(canonicalName)
        if fm.fileExists(atPath: exact.path) { return exact }
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        guard let name = names.first(where: { $0.uppercased() == canonicalName }) else { return nil }
        return folder.appendingPathComponent(name)
    }

    // MARK: -

    private nonisolated static func removeAppleDouble(in folder: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix("._") && name.dropFirst(2).uppercased() == canonicalName {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Straight RGBA, row 0 at the top, at the image’s pixel size.
    private nonisolated static func rasterize(_ image: NSImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CoverError.unreadableImage
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { throw CoverError.unreadableImage }

        let bytesPerRow = width * 4
        var storage = Data(count: height * bytesPerRow)
        let drew: Bool = storage.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { throw CoverError.unreadableImage }
        return (unpremultiply(storage), width, height)
    }

    private nonisolated static func unpremultiply(_ data: Data) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index + 3 < src.count {
                let alpha = src[index + 3]
                if alpha == 0 || alpha == 255 {
                    out[index] = src[index]
                    out[index + 1] = src[index + 1]
                    out[index + 2] = src[index + 2]
                } else {
                    out[index] = UInt8(min(255, Int(src[index]) * 255 / Int(alpha)))
                    out[index + 1] = UInt8(min(255, Int(src[index + 1]) * 255 / Int(alpha)))
                    out[index + 2] = UInt8(min(255, Int(src[index + 2]) * 255 / Int(alpha)))
                }
                out[index + 3] = alpha
                index += 4
            }
        }
        return out
    }
}
