import AppKit
import Foundation
import Testing
@testable import Katana

struct OpenMenuBoxArtTests {
    @Test func looseBoxDatMatchesHyphenatedSerial() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("katana-box-\(UUID().uuidString)", isDirectory: true)
        let menu = root.appendingPathComponent("01", isDirectory: true)
        let game = root.appendingPathComponent("02", isDirectory: true)
        try fm.createDirectory(at: menu, withIntermediateDirectories: true)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let art = pvr(width: 2, height: 2)
        try boxDat(entries: [("T9705N", art)]).write(to: menu.appendingPathComponent("BOX.DAT"))

        let found = GdtexLoader.load(
            for: entry(folder: game, serial: "T-9705N"),
            menuFolder: menu,
            menuImageFileName: "disc.gdi",
            serials: ["T-9705N"]
        )
        #expect(found.image?.size == NSSize(width: 2, height: 2))
        #expect(found.status.isEmpty)
    }

    @Test func perGameTextureWinsOverBoxDat() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("katana-box-\(UUID().uuidString)", isDirectory: true)
        let menu = root.appendingPathComponent("01", isDirectory: true)
        let game = root.appendingPathComponent("02", isDirectory: true)
        try fm.createDirectory(at: menu, withIntermediateDirectories: true)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try boxDat(entries: [("T9705N", pvr(width: 2, height: 2))]).write(to: menu.appendingPathComponent("BOX.DAT"))
        try pvr(width: 4, height: 4).write(to: game.appendingPathComponent("0GDTEX.PVR"))

        let found = GdtexLoader.load(
            for: entry(folder: game, serial: "T9705N"),
            menuFolder: menu,
            serials: ["T9705N"]
        )
        #expect(found.image?.size == NSSize(width: 4, height: 4))
    }

    @Test func regionLetterFallsBackWhenExactIdIsMissing() throws {
        let fm = FileManager.default
        let menu = fm.temporaryDirectory.appendingPathComponent("katana-box-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: menu, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: menu) }

        let usa = pvr(width: 2, height: 2)
        let japan = pvr(width: 3, height: 3)
        try boxDat(entries: [("T9504N", usa), ("T9504J", japan)]).write(to: menu.appendingPathComponent("box.dat"))

        let fallback = GdtexLoader.load(
            for: entry(folder: menu, serial: "T9504M"),
            menuFolder: menu,
            serials: ["T-9504M"]
        )
        #expect(fallback.image?.size == NSSize(width: 2, height: 2))

        let exact = GdtexLoader.load(
            for: entry(folder: menu, serial: "T9504J"),
            menuFolder: menu,
            serials: ["T9504J"]
        )
        #expect(exact.image?.size == NSSize(width: 3, height: 3))
    }

    @Test func missingCoverDoesNotSayFileNotFound() {
        let folder = URL(fileURLWithPath: "/tmp/katana-no-such-cover-\(UUID().uuidString)", isDirectory: true)
        let found = GdtexLoader.load(for: entry(folder: folder, serial: "T9705N"))
        #expect(found.image == nil)
        #expect(found.status == "No cover")
    }

    @Test func readsBoxDatOutOfMenuGdiWithoutLoadingTheWholeFile() throws {
        let fm = FileManager.default
        let menu = fm.temporaryDirectory.appendingPathComponent("katana-box-gdi-\(UUID().uuidString)", isDirectory: true)
        let game = fm.temporaryDirectory.appendingPathComponent("katana-box-game-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: menu, withIntermediateDirectories: true)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: menu)
            try? fm.removeItem(at: game)
        }

        let art = pvr(width: 2, height: 2)
        let box = boxDat(entries: [("MK51037", art)])
        let builder = Iso9660Builder()
        try builder.addFile("BOX.DAT", data: box)
        try builder.build(to: menu.appendingPathComponent("track.iso"))
        try "1\n1 0 4 2048 track.iso 0\n".write(
            to: menu.appendingPathComponent("disc.gdi"),
            atomically: true,
            encoding: .utf8
        )

        let found = GdtexLoader.load(
            for: entry(folder: game, serial: "MK-51037", format: .cdi, image: "disc.cdi"),
            menuFolder: menu,
            menuImageFileName: "disc.gdi",
            serials: ["MK-51037"]
        )
        #expect(found.image?.size == NSSize(width: 2, height: 2))
    }

    private func entry(
        folder: URL,
        serial: String,
        format: DiscFormat = .cdi,
        image: String = "disc.cdi"
    ) -> GameEntry {
        GameEntry(
            id: UUID(),
            number: 2,
            name: "Game",
            serial: serial,
            format: format,
            imageFileName: image,
            folderPath: folder.path,
            byteSize: 1,
            payloadByteSize: 1,
            contentSHA256: nil,
            isMenu: false
        )
    }

    /// Rectangle RGB565 texture. `size` is width and height.
    private func pvr(width: Int, height: Int) -> Data {
        var data = Data()
        data.append(contentsOf: [0x50, 0x56, 0x52, 0x54]) // PVRT
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(0x01) // RGB565
        data.append(0x09) // rectangle, linear
        data.append(contentsOf: [0, 0])
        data.append(contentsOf: [UInt8(width & 0xFF), UInt8((width >> 8) & 0xFF)])
        data.append(contentsOf: [UInt8(height & 0xFF), UInt8((height >> 8) & 0xFF)])
        let pixel: [UInt8] = [0xFF, 0xFF]
        for _ in 0..<(width * height) {
            data.append(contentsOf: pixel)
        }
        return data
    }

    /// One chunk per entry, placed after the header chunk.
    private func boxDat(entries: [(String, Data)], chunkSize: Int = 128) -> Data {
        var data = Data(count: chunkSize * (entries.count + 1))
        data[0] = UInt8(ascii: "D")
        data[1] = UInt8(ascii: "A")
        data[2] = UInt8(ascii: "T")
        data[3] = 1
        writeLE32(UInt32(chunkSize), into: &data, at: 4)
        writeLE32(UInt32(entries.count), into: &data, at: 8)
        for (index, entry) in entries.enumerated() {
            let base = 16 + index * 16
            let bytes = Array(entry.0.utf8.prefix(12))
            for (offset, byte) in bytes.enumerated() {
                data[base + offset] = byte
            }
            writeLE32(UInt32(index + 1), into: &data, at: base + 12)
            let at = chunkSize * (index + 1)
            data.replaceSubrange(at..<(at + entry.1.count), with: entry.1)
        }
        return data
    }

    private func writeLE32(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
