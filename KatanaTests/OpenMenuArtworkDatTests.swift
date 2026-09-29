import AppKit
import Foundation
import Testing
@testable import Katana

struct OpenMenuArtworkDatTests {
    @Test func newDatIsFoundBySerialAndKeepsAnExistingEntry() throws {
        let first = pvr(width: 2, height: 2, pixel: [0x00, 0xF8])
        let second = pvr(width: 2, height: 2, pixel: [0x1F, 0x00])
        let created = try #require(OpenMenuArtworkDat.merge(
            covers: ["MK51035": first],
            into: nil
        ))
        let merged = try #require(OpenMenuArtworkDat.merge(
            covers: ["T9705N": second],
            into: created
        ))

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("katana-art-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try merged.write(to: folder.appendingPathComponent("BOX.DAT"))

        let crazy = GdtexLoader.load(
            for: game(folder: folder, serial: "MK-51035"),
            menuFolder: folder,
            serials: ["MK-51035"]
        )
        let rayman = GdtexLoader.load(
            for: game(folder: folder, serial: "T-9705N"),
            menuFolder: folder,
            serials: ["T-9705N"]
        )
        #expect(crazy.image?.size == NSSize(width: 2, height: 2))
        #expect(rayman.image?.size == NSSize(width: 2, height: 2))

        let crazyPixels = try PvrDecoder.decodeRGBA(from: try #require(
            OpenMenuBoxArtImage.bytes(matching: "MK51035", in: merged)
        ))
        #expect(crazyPixels.0[0] > 200)
        #expect(crazyPixels.0[2] < 40)
    }

    @Test func replaceKeepsTheChunkAndDropsAnOversizedTexture() throws {
        let original = pvr(width: 2, height: 2, pixel: [0xE0, 0x07])
        let replacement = pvr(width: 2, height: 2, pixel: [0x00, 0xF8])
        let tooBig = original + Data(repeating: 1, count: 64)
        let dat = try #require(OpenMenuArtworkDat.merge(covers: ["MK51035": original], into: nil))
        let replaced = try #require(OpenMenuArtworkDat.merge(covers: ["MK51035": replacement], into: dat))
        let kept = try #require(OpenMenuArtworkDat.merge(covers: ["MK51035": tooBig], into: replaced))

        let bytes = try #require(OpenMenuBoxArtImage.bytes(matching: "MK51035", in: kept))
        let rgba = try PvrDecoder.decodeRGBA(from: bytes).0
        #expect(rgba[0] > 200)
        #expect(rgba[2] < 40)
    }

    @Test func iconIs128Square() throws {
        let box = try #require(PvrEncoder.encodeCover(
            rgba: [UInt8](repeating: 255, count: 4),
            width: 1,
            height: 1
        ))
        let icon = try #require(OpenMenuArtworkDat.iconTexture(from: box))
        let decoded = try PvrDecoder.decodeRGBA(from: icon)
        #expect(decoded.1 == 128)
        #expect(decoded.2 == 128)
    }

    @Test func looseCoverIsKeyedLikeTheMenuProductId() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("katana-loose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let art = pvr(width: 2, height: 2, pixel: [0xFF, 0xFF])
        try LooseCover.write(art, to: folder)

        let covers = MenuArtworkDat.looseCovers(in: [
            game(folder: folder, serial: "MK-51035"),
            game(folder: folder, serial: "NEODC_1", number: 1, menu: true),
        ])
        #expect(covers.keys.sorted() == ["MK51035"])
        #expect(covers["MK51035"] == art)
    }

    private func game(
        folder: URL,
        serial: String,
        number: Int = 36,
        menu: Bool = false
    ) -> GameEntry {
        GameEntry(
            id: UUID(),
            number: number,
            name: "Game",
            serial: serial,
            format: .gdi,
            imageFileName: "disc.gdi",
            folderPath: folder.path,
            byteSize: 1,
            payloadByteSize: 1,
            contentSHA256: nil,
            isMenu: menu
        )
    }

    /// Rectangle RGB565, one flat color (`pixel` is little-endian).
    private func pvr(width: Int, height: Int, pixel: [UInt8]) -> Data {
        var data = Data()
        data.append(contentsOf: [0x50, 0x56, 0x52, 0x54])
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(0x01)
        data.append(0x09)
        data.append(contentsOf: [0, 0])
        data.append(contentsOf: [UInt8(width & 0xFF), UInt8((width >> 8) & 0xFF)])
        data.append(contentsOf: [UInt8(height & 0xFF), UInt8((height >> 8) & 0xFF)])
        for _ in 0..<(width * height) {
            data.append(contentsOf: pixel)
        }
        return data
    }
}

/// Reads one chunk back out of a DAT the same way openMenu does: id → chunk index.
private enum OpenMenuBoxArtImage {
    static func bytes(matching id: String, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes[0] == UInt8(ascii: "D") else { return nil }
        let chunkSize = Int(UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24)
        let count = Int(UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24)
        guard chunkSize > 0, count > 0 else { return nil }
        for index in 0..<count {
            let base = 16 + index * 16
            guard base + 16 <= bytes.count else { return nil }
            let key = String(bytes: bytes[base..<(base + 12)].prefix { $0 != 0 }, encoding: .ascii)
            guard key == id else { continue }
            let offset = Int(UInt32(bytes[base + 12]) | UInt32(bytes[base + 13]) << 8 | UInt32(bytes[base + 14]) << 16 | UInt32(bytes[base + 15]) << 24)
            let at = offset * chunkSize
            guard at + chunkSize <= data.count else { return nil }
            return data.subdata(in: at..<(at + min(chunkSize, 64)))
        }
        return nil
    }
}
