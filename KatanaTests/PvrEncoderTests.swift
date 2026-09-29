import AppKit
import Foundation
import Testing
@testable import Katana

struct PvrEncoderTests {
    @Test func opaqueImageUsesRgb565AndRoundTripsTwiddle() throws {
        var pixels = [UInt8](repeating: 0, count: 256 * 256 * 4)
        // One red pixel, so a wrong twiddle shows up as black at that coordinate.
        let index = (5 * 256 + 3) * 4
        pixels[index] = 255
        pixels[index + 3] = 255
        for offset in stride(from: 3, to: pixels.count, by: 4) where offset != index + 3 {
            pixels[offset] = 255
        }

        let data = try #require(PvrEncoder.encodeCover(rgba: pixels, width: 256, height: 256))
        #expect(data.count == 131_104)
        let pvrt = try #require(data.range(of: Data("PVRT".utf8)))
        #expect(data[data.index(pvrt.lowerBound, offsetBy: 8)] == 0x01)

        let decoded = try PvrDecoder.decodeRGBA(from: data)
        #expect(decoded.1 == 256)
        #expect(decoded.2 == 256)
        let red = (5 * 256 + 3) * 4
        let rgba = [UInt8](decoded.0)
        #expect(rgba[red] == 255)
        #expect(rgba[red + 1] == 0)
        #expect(rgba[red + 2] == 0)
        #expect(rgba[0] == 0)
        #expect(rgba[1] == 0)
        #expect(rgba[2] == 0)
    }

    @Test func partialAlphaUsesArgb4444() throws {
        var pixels = [UInt8](repeating: 255, count: 16)
        pixels[3] = 100
        let data = try #require(PvrEncoder.encodeCover(rgba: pixels, width: 2, height: 2))
        let pvrt = try #require(data.range(of: Data("PVRT".utf8)))
        #expect(data[data.index(pvrt.lowerBound, offsetBy: 8)] == 0x02)
    }

    @Test func centerCropKeepsTheMiddleOfAWideImage() throws {
        // 4×2: green, blue, blue, green on each row. The square crop is the two blue columns.
        var pixels = [UInt8]()
        for _ in 0..<2 {
            pixels.append(contentsOf: [0, 255, 0, 255])
            pixels.append(contentsOf: [0, 0, 255, 255])
            pixels.append(contentsOf: [0, 0, 255, 255])
            pixels.append(contentsOf: [0, 255, 0, 255])
        }
        let data = try #require(PvrEncoder.encodeCover(rgba: pixels, width: 4, height: 2))
        let decoded = try PvrDecoder.decodeRGBA(from: data)
        let rgba = [UInt8](decoded.0)
        let center = (128 * 256 + 128) * 4
        #expect(rgba[center + 2] > rgba[center])
        #expect(rgba[center + 2] > rgba[center + 1])
    }

    @Test func pictureKeepsItsOrientation() throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 32 * 4,
            bitsPerPixel: 32
        ))
        let pixels = try #require(rep.bitmapData)
        for y in 0..<32 {
            for x in 0..<32 {
                let i = (y * 32 + x) * 4
                let top = y < 16
                let left = x < 16
                if top && left {
                    pixels[i] = 255; pixels[i + 1] = 0; pixels[i + 2] = 0
                } else if top && !left {
                    pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 255
                } else if !top && left {
                    pixels[i] = 0; pixels[i + 1] = 255; pixels[i + 2] = 0
                } else {
                    pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 0
                }
                pixels[i + 3] = 255
            }
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("katana-orient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let jpeg = try #require(rep.representation(using: .jpeg, properties: [.compressionFactor: 1]))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try jpeg.write(to: folder.appendingPathComponent("art.jpg"))
        try png.write(to: folder.appendingPathComponent("art.png"))

        for name in ["art.jpg", "art.png"] {
            let data = try LooseCover.coverData(from: folder.appendingPathComponent(name))
            let decoded = try PvrDecoder.decodeRGBA(from: data)
            let rgba = [UInt8](decoded.0)
            func channel(_ x: Int, _ y: Int, _ c: Int) -> UInt8 {
                rgba[(y * 256 + x) * 4 + c]
            }
            // Quadrant centers. Red stays top-left; a y-flip would put green there.
            #expect(channel(64, 64, 0) > 200)
            #expect(channel(64, 64, 1) < 40)
            #expect(channel(192, 64, 2) > 200)
            #expect(channel(64, 192, 1) > 200)
            #expect(channel(192, 192, 0) > 200)
            #expect(channel(192, 192, 1) > 200)
            #expect(channel(192, 192, 2) < 40)
        }
    }

    @Test func pvrFileIsCopiedWhenItDecodes() throws {
        var pixels = [UInt8](repeating: 255, count: 4)
        pixels[0] = 10
        let encoded = try #require(PvrEncoder.encodeCover(rgba: pixels, width: 1, height: 1))

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("katana-pvr-pick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("art.pvr")
        try encoded.write(to: source)
        let copied = try LooseCover.coverData(from: source)
        #expect(copied == encoded)

        let bad = folder.appendingPathComponent("bad.pvr")
        try Data("nope".utf8).write(to: bad)
        #expect(throws: PvrDecoder.DecodeError.self) {
            try LooseCover.coverData(from: bad)
        }
    }

    @Test func looseFileIsWhatCoverLoadsAndRemoveFallsBack() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("katana-cover-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        var pixels = [UInt8](repeating: 0, count: 4)
        pixels[0] = 255
        pixels[3] = 255
        let data = try #require(PvrEncoder.encodeCover(rgba: pixels, width: 1, height: 1))
        try LooseCover.write(data, to: folder)
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("0GDTEX.PVR").path))

        let shown = GdtexLoader.load(
            folderURL: folder,
            imageFileName: "disc.gdi",
            format: .gdi
        )
        #expect(shown.image?.size == NSSize(width: 256, height: 256))
        #expect(shown.status.isEmpty)

        #expect(try LooseCover.remove(from: folder))
        #expect(LooseCover.exists(in: folder) == false)
        let missing = GdtexLoader.load(
            folderURL: folder,
            imageFileName: "disc.cdi",
            format: .cdi
        )
        #expect(missing.image == nil)
        #expect(missing.status == GdtexLoader.missingCoverStatus)
    }
}
