import Testing
@testable import Katana

struct FolderNumberingTests {
    @Test func twoDigitWidth() {
        #expect(FolderNumbering.format(1, maxNumber: 50) == "01")
        #expect(FolderNumbering.format(99, maxNumber: 99) == "99")
    }

    @Test func threeDigitWidth() {
        // Menu (slot 1) stays `01` even when games use 3 digits (GCM / live GDEMU cards).
        #expect(FolderNumbering.format(1, maxNumber: 100) == "01")
        #expect(FolderNumbering.format(2, maxNumber: 100) == "002")
        #expect(FolderNumbering.format(99, maxNumber: 294) == "099")
        #expect(FolderNumbering.format(294, maxNumber: 294) == "294")
    }

    @Test func fourDigitWidth() {
        #expect(FolderNumbering.format(1, maxNumber: 1000) == "01")
        #expect(FolderNumbering.format(2, maxNumber: 1000) == "0002")
        #expect(FolderNumbering.format(1000, maxNumber: 1000) == "1000")
    }

    @Test func menuSlotAlwaysTwoDigits() {
        #expect(FolderNumbering.format(1) == "01")
        #expect(FolderNumbering.format(1, maxNumber: 9) == "01")
        #expect(FolderNumbering.format(1, maxNumber: 9999) == "01")
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
