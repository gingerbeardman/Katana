import Testing
@testable import Katana

struct FolderNumberingTests {
    @Test func twoDigitMinimum() {
        #expect(FolderNumbering.format(1) == "01")
        #expect(FolderNumbering.format(2) == "02")
        #expect(FolderNumbering.format(99) == "99")
    }

    @Test func naturalWidthAbove99() {
        // GCM keeps `02`…`99` even on a 100+ game card; only 100+ grow.
        #expect(FolderNumbering.format(100) == "100")
        #expect(FolderNumbering.format(294) == "294")
        #expect(FolderNumbering.format(1000) == "1000")
    }

    @Test func parseValid() {
        #expect(FolderNumbering.parse("01") == 1)
        #expect(FolderNumbering.parse("294") == 294)
        #expect(FolderNumbering.parse("001") == 1)
    }

    @Test func parseInvalid() {
        #expect(FolderNumbering.parse("") == nil)
        #expect(FolderNumbering.parse("0") == nil)
        #expect(FolderNumbering.parse("01a") == nil)
        #expect(FolderNumbering.parse("GDEMU.ini") == nil)
    }
}
