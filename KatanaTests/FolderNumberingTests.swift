import Testing
@testable import Katana

struct FolderNumberingTests {
    @Test func twoDigitWidth() {
        #expect(FolderNumbering.format(1, maxNumber: 50) == "01")
        #expect(FolderNumbering.format(99, maxNumber: 99) == "99")
    }

    @Test func threeDigitWidth() {
        #expect(FolderNumbering.format(1, maxNumber: 100) == "001")
        #expect(FolderNumbering.format(99, maxNumber: 294) == "099")
        #expect(FolderNumbering.format(294, maxNumber: 294) == "294")
    }

    @Test func fourDigitWidth() {
        #expect(FolderNumbering.format(1, maxNumber: 1000) == "0001")
        #expect(FolderNumbering.format(1000, maxNumber: 1000) == "1000")
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
