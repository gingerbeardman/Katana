import Foundation
import Testing
@testable import Katana

struct MenuListGeneratorTests {
    @Test func formatFolderNumberWidth() {
        #expect(MenuListGenerator.formatFolderNumber(1) == "01")
        #expect(MenuListGenerator.formatFolderNumber(99) == "99")
        #expect(MenuListGenerator.formatFolderNumber(100) == "100")
        #expect(MenuListGenerator.formatFolderNumber(274) == "274")
        #expect(MenuListGenerator.formatFolderNumber(1000) == "1000")
    }

    /// Keys stay 2-digit under 100 even on a 100+ game card; only 100+ grow (GCM).
    @Test func listKeysMatchGCMFolderLayout() {
        let items = [
            MenuListGenerator.Item(
                number: 1,
                name: "GDMENU",
                serial: "MK6969",
                ip: .menuDefaults
            ),
            MenuListGenerator.Item(
                number: 2,
                name: "Sonic",
                serial: "MK-5100",
                ip: .fallback(name: "Sonic", serial: "MK-5100")
            ),
            MenuListGenerator.Item(
                number: 100,
                name: "Jet Grind Radio",
                serial: "MK-5102",
                ip: .fallback(name: "Jet", serial: "MK-5102")
            ),
        ]
        let text = MenuListGenerator.makeGDMenuList(items: items)
        #expect(text.hasPrefix("[GDMENU]\n01.name=GDMENU") || text.contains("\n01.name=GDMENU"))
        #expect(text.contains("01.name=GDMENU"))
        #expect(text.contains("\n02.name=Sonic"))
        #expect(text.contains("100.name=Jet Grind Radio"))
        // No 3-digit zero-padded keys, ever — GDMENU won't match `002` folders.
        #expect(!text.contains("001.name="))
        #expect(!text.contains("002.name="))
    }

    @Test func gdMenuListShape() {
        let items = [
            MenuListGenerator.Item(
                number: 1,
                name: "GDMENU",
                serial: "MK-0000",
                ip: .menuDefaults
            ),
            MenuListGenerator.Item(
                number: 2,
                name: "18WHEELER",
                serial: "MK-51064",
                ip: IpBinInfo(
                    name: "18WHEELER",
                    productNumber: "MK-51064",
                    disc: "1/1",
                    region: "U",
                    vga: true,
                    version: "V1.500",
                    releaseDate: "20010423",
                    isCodeBreaker: false
                )
            ),
        ]
        let text = MenuListGenerator.makeGDMenuList(items: items)
        #expect(text.hasPrefix("[GDMENU]\n"))
        #expect(text.contains("01.name=GDMENU\n"))
        #expect(text.contains("01.disc=1/1\n"))
        #expect(text.contains("01.vga=1\n"))
        #expect(text.contains("02.name=18WHEELER\n"))
        #expect(text.contains("02.region=U\n"))
        #expect(text.contains("02.version=V1.500\n"))
        #expect(text.contains("02.date=20010423\n"))
        #expect(!text.contains(".product="))
    }

    @Test func openMenuListIncludesProduct() {
        let items = [
            MenuListGenerator.Item(
                number: 1,
                name: "openMenu",
                serial: "MK-1",
                ip: IpBinInfo(
                    name: "openMenu",
                    productNumber: "MK-1",
                    disc: "1/1",
                    region: "JUE",
                    vga: true,
                    version: "V1.000",
                    releaseDate: "20230101",
                    isCodeBreaker: false
                )
            ),
        ]
        let text = MenuListGenerator.makeOpenMenuList(items: items)
        #expect(text.hasPrefix("[OPENMENU]\n"))
        #expect(text.contains("num_items=1\n"))
        #expect(text.contains("[ITEMS]\n"))
        #expect(text.contains("01.product=MK1\n"))
    }

    @Test func codeBreakerClearsDiscField() {
        var ip = IpBinInfo.fallback(name: "CB", serial: "X")
        ip.isCodeBreaker = true
        let items = [MenuListGenerator.Item(number: 3, name: "CB", serial: "X", ip: ip)]
        let text = MenuListGenerator.makeGDMenuList(items: items)
        #expect(text.contains("03.disc=\n"))
    }

    @Test func itemsPreferCachedIpHeaderWithoutDiskRead() {
        // When `ipHeader` is set, LIST fields come from cache (no missing folder / no read).
        let cached = IpBinInfo(
            name: "CACHED",
            productNumber: "MK-9999",
            disc: "2/2",
            region: "J",
            vga: false,
            version: "V9.999",
            releaseDate: "19990101",
            isCodeBreaker: false
        )
        let game = GameEntry(
            id: UUID(),
            number: 2,
            name: "Display Name",
            serial: "MK-9999",
            format: .gdi,
            imageFileName: "disc.gdi",
            folderPath: "/tmp/katana-no-such-game-folder",
            byteSize: 1,
            payloadByteSize: 1,
            contentSHA256: nil,
            isMenu: false,
            detailsLoaded: true,
            ipHeader: cached
        )
        let menu = GameEntry(
            id: UUID(),
            number: 1,
            name: "GDMENU",
            serial: "MK-0000",
            format: .gdi,
            imageFileName: "disc.gdi",
            folderPath: "/tmp/katana-no-such-menu",
            byteSize: 1,
            payloadByteSize: 1,
            contentSHA256: nil,
            isMenu: true,
            detailsLoaded: true,
            ipHeader: .menuDefaults
        )
        let built = MenuListGenerator.itemsWithHeaderFills(
            for: [menu, game],
            menuKind: .gdMenu
        )
        #expect(built.filledHeaders.isEmpty) // both warm — no disk fills
        #expect(built.items.count == 2)
        #expect(built.items[1].ip.disc == "2/2")
        #expect(built.items[1].ip.vga == false)
        #expect(built.items[1].ip.version == "V9.999")
        let text = MenuListGenerator.makeGDMenuList(items: built.items)
        #expect(text.contains("02.disc=2/2\n"))
        #expect(text.contains("02.vga=0\n"))
        #expect(text.contains("02.date=19990101\n"))
    }

    @Test func menuKindDetect() {
        #expect(MenuKind.detect(fromName: "GDMENU") == .gdMenu)
        #expect(MenuKind.detect(fromName: "gdmenu") == .gdMenu)
        #expect(MenuKind.detect(fromName: "openMenu") == .openMenu)
        #expect(MenuKind.detect(fromName: "OPEN MENU") == .openMenu)
        #expect(MenuKind.detect(fromName: "Sonic") == nil)

        let gdIP = IpBinInfo.menuDefaults
        #expect(MenuKind.detect(fromIP: gdIP) == .gdMenu)

        let openIP = IpBinInfo(
            name: "openMenu",
            productNumber: "NEODC_1",
            disc: "1/1",
            region: "JUE",
            vga: true,
            version: "V0.1.0",
            releaseDate: "20230101",
            isCodeBreaker: false
        )
        #expect(MenuKind.detect(fromIP: openIP) == .openMenu)
        #expect(MenuKind.detect(fromIP: IpBinInfo.fallback(name: "Game", serial: "T-123")) == nil)
    }
}

struct IpBinReaderTests {
    @Test func parseEighteenWheelerHeader() throws {
        // Minimal synthetic header matching Aaru Dreamcast IP.BIN layout.
        var data = Data(count: 256)
        data.replaceSubrange(0..<16, with: Array("SEGA SEGAKATANA ".utf8))
        data.replaceSubrange(0x10..<0x20, with: Array("SEGA ENTERPRISES".utf8))
        data.replaceSubrange(0x20..<0x24, with: Array("6F92".utf8))
        data[0x24] = 0x20 // spare
        data.replaceSubrange(0x25..<0x2B, with: Array("GD-ROM".utf8))
        data[0x2B] = 0x31 // disc_no '1'
        data[0x2C] = 0x2F // '/'
        data[0x2D] = 0x31 // disc_total '1'
        data.replaceSubrange(0x30..<0x38, with: Array("U       ".utf8))
        data.replaceSubrange(0x38..<0x3F, with: Array("0799A10".utf8))
        data.replaceSubrange(0x40..<0x4A, with: Array("MK-51064  ".utf8))
        data.replaceSubrange(0x4A..<0x50, with: Array("V1.500".utf8))
        data.replaceSubrange(0x50..<0x58, with: Array("20010423".utf8))
        data.replaceSubrange(0x60..<0x6C, with: Array("1ST_READ.BIN".utf8))
        data.replaceSubrange(0x80..<(0x80 + 9), with: Array("18WHEELER".utf8))

        let info = try #require(IpBinReader.parse(ipData: data))
        #expect(info.name == "18WHEELER")
        #expect(info.productNumber == "MK-51064")
        #expect(info.disc == "1/1")
        #expect(info.region == "U")
        #expect(info.vga == true)
        #expect(info.version == "V1.500")
        #expect(info.releaseDate == "20010423")
    }

    @Test func parseRealTrack03FromCard() throws {
        let url = URL(fileURLWithPath: "/Volumes/200GB/004/track03.iso")
        guard FileManager.default.fileExists(atPath: url.path) else { return } // skip if card unmounted
        let data = try Data(contentsOf: url)
        let header = data.prefix(512)
        let info = try #require(IpBinReader.parse(ipData: Data(header)))
        #expect(info.name == "18WHEELER")
        #expect(info.productNumber == "MK-51064")
        #expect(info.disc == "1/1")
        #expect(info.vga == true)
    }

    @Test func parseRejectsNonKatana() {
        let data = Data(repeating: 0, count: 256)
        #expect(IpBinReader.parse(ipData: data) == nil)
    }

    /// Homebrew CDIs put big CDDA sessions before the data track, so IP.BIN can sit
    /// far into the image. The old 8 MB scan cap made those games fall back to
    /// placeholder headers (date 19990909) in LIST.INI.
    @Test func readsHeaderDeepInsideCDI() throws {
        var header = Data(count: 256)
        header.replaceSubrange(0..<16, with: Array("SEGA SEGAKATANA ".utf8))
        header.replaceSubrange(0x25..<0x2B, with: Array("GD-ROM".utf8))
        header[0x2B] = 0x31
        header[0x2D] = 0x31
        header.replaceSubrange(0x30..<0x38, with: Array("JUE     ".utf8))
        header.replaceSubrange(0x38..<0x3F, with: Array("0799A10".utf8))
        header.replaceSubrange(0x40..<0x4A, with: Array("NGDT-0083 ".utf8))
        header.replaceSubrange(0x4A..<0x50, with: Array("V1.000".utf8))
        header.replaceSubrange(0x50..<0x58, with: Array("20061202".utf8))
        header.replaceSubrange(0x80..<(0x80 + 12), with: Array("FAST STRIKER".utf8))

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("katana-ipbin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // 9 MB of "audio" before the header — beyond the old cap, spanning chunk edges.
        let url = folder.appendingPathComponent("disc.cdi")
        var image = Data(repeating: 0x55, count: 9 * 1024 * 1024 + 123)
        image.append(header)
        image.append(Data(repeating: 0, count: 2048))
        try image.write(to: url)

        let info = try #require(
            IpBinReader.read(folderURL: folder, imageFileName: "disc.cdi", format: .cdi)
        )
        #expect(info.name == "FAST STRIKER")
        #expect(info.releaseDate == "20061202")
    }
}
