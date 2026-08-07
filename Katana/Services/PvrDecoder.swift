import AppKit
import Foundation

/// Minimal Dreamcast PVR (PVRT) decoder for 0GDTEX previews.
/// Supports RGB565 / ARGB1555 / ARGB4444 with square-twiddled, rectangle, and rectangle-twiddled layouts.
enum PvrDecoder: Sendable {
    enum DecodeError: LocalizedError {
        case notPvr
        case unsupportedFormat(String)
        case truncated

        var errorDescription: String? {
            switch self {
            case .notPvr: return "Not a PVR texture"
            case .unsupportedFormat(let s): return "Unsupported PVR format: \(s)"
            case .truncated: return "PVR data truncated"
            }
        }
    }

    /// Decode PVR bytes to an `NSImage`.
    ///
    /// `NSBitmapImageRep` + `.deviceRGB` stores samples as **RGBA** (not BGRA).
    nonisolated static func decodeImage(from data: Data) throws -> NSImage {
        let (rgba, width, height) = try decodeRGBA(from: data)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let plane = rep.bitmapData else {
            throw DecodeError.truncated
        }
        rgba.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            memcpy(plane, base, min(rgba.count, width * height * 4))
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    /// RGBA8888 pixels, width, height (alpha last, non-premultiplied).
    nonisolated static func decodeRGBA(from data: Data) throws -> (Data, Int, Int) {
        let bytes = [UInt8](data)
        guard bytes.count >= 16 else { throw DecodeError.notPvr }

        let pvrtOffset = findPVRTOffset(in: bytes)
        guard pvrtOffset >= 0, pvrtOffset + 16 <= bytes.count else { throw DecodeError.notPvr }

        let pixelFormat = bytes[pvrtOffset + 0x08]
        let dataFormat = bytes[pvrtOffset + 0x09]
        let width = Int(UInt16(bytes[pvrtOffset + 0x0C]) | (UInt16(bytes[pvrtOffset + 0x0D]) << 8))
        let height = Int(UInt16(bytes[pvrtOffset + 0x0E]) | (UInt16(bytes[pvrtOffset + 0x0F]) << 8))
        guard width > 0, height > 0, width <= 2048, height <= 2048 else {
            throw DecodeError.unsupportedFormat("size \(width)×\(height)")
        }

        var dataOffset = pvrtOffset + 0x10
        // Square twiddled + mipmaps: optional 1-texel pad, then smaller levels, then largest.
        if dataFormat == 0x02 || dataFormat == 0x12 {
            let bpp = 16
            let fullLevels = mipmapPrefixBytes(width: width, bpp: bpp) + width * height * (bpp / 8)
            let remaining = bytes.count - dataOffset
            // Spec pad is 1 texel (2 bytes). Some files omit it and only have trailing padding.
            if remaining >= fullLevels + (bpp / 8) {
                dataOffset += bpp / 8
            }
            dataOffset += mipmapPrefixBytes(width: width, bpp: bpp)
        }

        let bpp = 16
        let pixelCount = width * height
        let needed = dataOffset + pixelCount * (bpp / 8)
        guard needed <= bytes.count else { throw DecodeError.truncated }

        let source = Array(bytes[dataOffset..<needed])
        let rgba: [UInt8]
        switch dataFormat {
        case 0x01, 0x02, 0x12: // SquareTwiddled (+ mipmaps)
            rgba = decodeTwiddled(source: source, width: width, height: height, pixelFormat: pixelFormat)
        case 0x09: // Rectangle (linear)
            rgba = decodeLinear(source: source, width: width, height: height, pixelFormat: pixelFormat)
        case 0x0D: // RectangleTwiddled
            rgba = decodeTwiddled(source: source, width: width, height: height, pixelFormat: pixelFormat)
        default:
            throw DecodeError.unsupportedFormat(String(format: "0x%02X", dataFormat))
        }
        return (Data(rgba), width, height)
    }

    /// Back-compat alias.
    nonisolated static func decodeBGRA(from data: Data) throws -> (Data, Int, Int) {
        try decodeRGBA(from: data)
    }

    // MARK: - Layout

    private nonisolated static func findPVRTOffset(in bytes: [UInt8]) -> Int {
        let pvrt: [UInt8] = [0x50, 0x56, 0x52, 0x54] // PVRT
        let gbix: [UInt8] = [0x47, 0x42, 0x49, 0x58] // GBIX
        if match(bytes, at: 0, fourCC: gbix) {
            let chunk = le32(bytes, 4)
            return 8 + Int(chunk)
        }
        if bytes.count > 8, match(bytes, at: 4, fourCC: gbix) {
            let chunk = le32(bytes, 8)
            return 12 + Int(chunk)
        }
        if match(bytes, at: 0, fourCC: pvrt) { return 0 }
        if bytes.count > 4, match(bytes, at: 4, fourCC: pvrt) { return 4 }
        // Scan a little for PVRT
        let limit = min(bytes.count - 4, 64)
        var i = 0
        while i <= limit {
            if match(bytes, at: i, fourCC: pvrt) { return i }
            i += 1
        }
        return -1
    }

    /// Bytes to skip before largest mip level for square twiddled mipmaps.
    private nonisolated static func mipmapPrefixBytes(width: Int, bpp: Int) -> Int {
        var total = 0
        var w = 1
        while w < width {
            total += w * w * (bpp / 8)
            w <<= 1
        }
        return total
    }

    private nonisolated static func makeTwiddleMap(size: Int) -> [Int] {
        var map = Array(repeating: 0, count: size)
        for i in 0..<size {
            var v = 0
            var j = 0
            var k = 1
            while k <= i {
                v |= (i & k) << j
                j += 1
                k <<= 1
            }
            map[i] = v
        }
        return map
    }

    private nonisolated static func decodeTwiddled(
        source: [UInt8],
        width: Int,
        height: Int,
        pixelFormat: UInt8
    ) -> [UInt8] {
        let mapSize = max(width, height)
        let twiddleMap = makeTwiddleMap(size: mapSize)
        var dest = Array(repeating: UInt8(0), count: width * height * 4)
        var di = 0
        for y in 0..<height {
            for x in 0..<width {
                // ((twiddleMap[x] << 1) | twiddleMap[y]) << (bpp >> 4) with bpp=16 → << 1
                let srcIndex = ((twiddleMap[x] << 1) | twiddleMap[y]) << 1
                decodePixel(pixelFormat, source: source, sourceIndex: srcIndex, dest: &dest, destIndex: di)
                di += 4
            }
        }
        return dest
    }

    private nonisolated static func decodeLinear(
        source: [UInt8],
        width: Int,
        height: Int,
        pixelFormat: UInt8
    ) -> [UInt8] {
        var dest = Array(repeating: UInt8(0), count: width * height * 4)
        var di = 0
        var si = 0
        for _ in 0..<(width * height) {
            decodePixel(pixelFormat, source: source, sourceIndex: si, dest: &dest, destIndex: di)
            si += 2
            di += 4
        }
        return dest
    }

    /// Expand 5-bit channel to 8-bit (bit replicate).
    private nonisolated static func expand5(_ v: UInt16) -> UInt8 {
        let x = UInt8(v & 0x1F)
        return (x << 3) | (x >> 2)
    }

    /// Expand 6-bit channel to 8-bit.
    private nonisolated static func expand6(_ v: UInt16) -> UInt8 {
        let x = UInt8(v & 0x3F)
        return (x << 2) | (x >> 4)
    }

    /// Expand 4-bit channel to 8-bit.
    private nonisolated static func expand4(_ v: UInt16) -> UInt8 {
        let x = UInt8(v & 0x0F)
        return (x << 4) | x
    }

    /// Writes **RGBA** into dest (matches `NSBitmapImageRep` + `.deviceRGB`).
    /// Dreamcast 16-bit packed order is little-endian: low bits = blue.
    private nonisolated static func decodePixel(
        _ format: UInt8,
        source: [UInt8],
        sourceIndex: Int,
        dest: inout [UInt8],
        destIndex: Int
    ) {
        guard sourceIndex + 1 < source.count else { return }
        let pixel = UInt16(source[sourceIndex]) | (UInt16(source[sourceIndex + 1]) << 8)
        switch format {
        case 0x00: // ARGB1555: A RRRRR GGGGG BBBBB
            let b = expand5(pixel >> 0)
            let g = expand5(pixel >> 5)
            let r = expand5(pixel >> 10)
            let a: UInt8 = ((pixel >> 15) & 1) == 1 ? 0xFF : 0x00
            dest[destIndex + 0] = r
            dest[destIndex + 1] = g
            dest[destIndex + 2] = b
            dest[destIndex + 3] = a
        case 0x01: // RGB565: RRRRR GGGGGG BBBBB
            let b = expand5(pixel >> 0)
            let g = expand6(pixel >> 5)
            let r = expand5(pixel >> 11)
            dest[destIndex + 0] = r
            dest[destIndex + 1] = g
            dest[destIndex + 2] = b
            dest[destIndex + 3] = 0xFF
        case 0x02: // ARGB4444: AAAA RRRR GGGG BBBB
            let b = expand4(pixel >> 0)
            let g = expand4(pixel >> 4)
            let r = expand4(pixel >> 8)
            let a = expand4(pixel >> 12)
            dest[destIndex + 0] = r
            dest[destIndex + 1] = g
            dest[destIndex + 2] = b
            dest[destIndex + 3] = a
        default:
            dest[destIndex + 0] = 0
            dest[destIndex + 1] = 0
            dest[destIndex + 2] = 0
            dest[destIndex + 3] = 0xFF
        }
    }

    private nonisolated static func match(_ bytes: [UInt8], at index: Int, fourCC: [UInt8]) -> Bool {
        guard index + fourCC.count <= bytes.count else { return false }
        for i in 0..<fourCC.count where bytes[index + i] != fourCC[i] { return false }
        return true
    }

    private nonisolated static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
