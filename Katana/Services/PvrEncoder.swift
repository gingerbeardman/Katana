import Foundation

/// Encodes a loose `0GDTEX.PVR`: 256×256 square-twiddled, GBIX + PVRT.
///
/// Pixel format follows the alpha channel. Opaque images use RGB565, on/off
/// alpha uses ARGB1555, and partial alpha uses ARGB4444.
enum PvrEncoder: Sendable {
    nonisolated static let side = 256

    /// Center-crops `rgba` to a square, scales it to 256×256, and encodes.
    /// Pixels are straight RGBA8888 with row 0 at the top.
    nonisolated static func encodeCover(rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let square = centerCrop(rgba, width: width, height: height)
        let scaled = square.side == side
            ? square.pixels
            : scale(square.pixels, from: square.side, to: side)
        return encode(scaled256: scaled)
    }

    // MARK: - Crop and scale

    private nonisolated static func centerCrop(
        _ rgba: [UInt8],
        width: Int,
        height: Int
    ) -> (pixels: [UInt8], side: Int) {
        let side = min(width, height)
        let x0 = (width - side) / 2
        let y0 = (height - side) / 2
        var out = [UInt8](repeating: 0, count: side * side * 4)
        for row in 0..<side {
            let src = ((y0 + row) * width + x0) * 4
            let dst = row * side * 4
            out.replaceSubrange(dst..<(dst + side * 4), with: rgba[src..<(src + side * 4)])
        }
        return (out, side)
    }

    /// Bilinear scale of a square image. `from` and `to` are the side length.
    private nonisolated static func scale(_ rgba: [UInt8], from: Int, to: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: to * to * 4)
        let maxIndex = from - 1
        for y in 0..<to {
            let sy = (Double(y) + 0.5) * Double(from) / Double(to) - 0.5
            let y0 = min(max(Int(floor(sy)), 0), maxIndex)
            let y1 = min(y0 + 1, maxIndex)
            let fy = sy - Double(y0)
            for x in 0..<to {
                let sx = (Double(x) + 0.5) * Double(from) / Double(to) - 0.5
                let x0 = min(max(Int(floor(sx)), 0), maxIndex)
                let x1 = min(x0 + 1, maxIndex)
                let fx = sx - Double(x0)
                let i00 = (y0 * from + x0) * 4
                let i10 = (y0 * from + x1) * 4
                let i01 = (y1 * from + x0) * 4
                let i11 = (y1 * from + x1) * 4
                let dest = (y * to + x) * 4
                for channel in 0..<4 {
                    let v00 = Double(rgba[i00 + channel])
                    let v10 = Double(rgba[i10 + channel])
                    let v01 = Double(rgba[i01 + channel])
                    let v11 = Double(rgba[i11 + channel])
                    let top = v00 + (v10 - v00) * fx
                    let bottom = v01 + (v11 - v01) * fx
                    let value = top + (bottom - top) * fy
                    out[dest + channel] = UInt8(min(255, max(0, value.rounded())))
                }
            }
        }
        return out
    }

    // MARK: - PVR

    private nonisolated static func encode(scaled256 rgba: [UInt8]) -> Data {
        let pixelFormat = choosePixelFormat(rgba)
        let twiddleMap = makeTwiddleMap(size: side)
        var pixels = [UInt8](repeating: 0, count: side * side * 2)
        for y in 0..<side {
            for x in 0..<side {
                let src = (y * side + x) * 4
                let packed = pack(
                    pixelFormat,
                    r: rgba[src],
                    g: rgba[src + 1],
                    b: rgba[src + 2],
                    a: rgba[src + 3]
                )
                let index = ((twiddleMap[x] << 1) | twiddleMap[y]) << 1
                pixels[index] = UInt8(packed & 0xFF)
                pixels[index + 1] = UInt8(packed >> 8)
            }
        }

        var data = Data()
        data.reserveCapacity(32 + pixels.count)
        data.append(contentsOf: [0x47, 0x42, 0x49, 0x58]) // GBIX
        data.append(contentsOf: le32(8))
        data.append(contentsOf: [UInt8](repeating: 0, count: 8))
        data.append(contentsOf: [0x50, 0x56, 0x52, 0x54]) // PVRT
        data.append(contentsOf: le32(8 + UInt32(pixels.count)))
        data.append(pixelFormat)
        data.append(0x01) // square twiddled
        data.append(contentsOf: [0, 0])
        data.append(contentsOf: le16(UInt16(side)))
        data.append(contentsOf: le16(UInt16(side)))
        data.append(contentsOf: pixels)
        return data
    }

    /// Opaque → RGB565, binary alpha → ARGB1555, partial alpha → ARGB4444.
    private nonisolated static func choosePixelFormat(_ rgba: [UInt8]) -> UInt8 {
        var hasTransparency = false
        var index = 3
        while index < rgba.count {
            let alpha = rgba[index]
            if alpha != 255 {
                hasTransparency = true
                if alpha != 0 { return 0x02 }
            }
            index += 4
        }
        return hasTransparency ? 0x00 : 0x01
    }

    private nonisolated static func pack(_ format: UInt8, r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> UInt16 {
        switch format {
        case 0x00:
            let alpha: UInt16 = a >= 128 ? 1 : 0
            return (alpha << 15) | (UInt16(r >> 3) << 10) | (UInt16(g >> 3) << 5) | UInt16(b >> 3)
        case 0x02:
            return (UInt16(a >> 4) << 12) | (UInt16(r >> 4) << 8) | (UInt16(g >> 4) << 4) | UInt16(b >> 4)
        default:
            return (UInt16(r >> 3) << 11) | (UInt16(g >> 2) << 5) | UInt16(b >> 3)
        }
    }

    /// Same map `PvrDecoder` uses to untwiddle a 16-bit square texture.
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

    private nonisolated static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private nonisolated static func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }
}
