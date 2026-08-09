import Foundation
import Testing
@testable import Katana

struct UpdateCheckerTests {
    @Test func normalizeVersionStripsLeadingV() {
        #expect(UpdateChecker.normalizeVersion("v1.2.3") == "1.2.3")
        #expect(UpdateChecker.normalizeVersion("V2.0") == "2.0")
        #expect(UpdateChecker.normalizeVersion("1.0") == "1.0")
    }

    @Test func compareVersionsOrdersComponents() {
        #expect(UpdateChecker.compareVersions("1.10", "1.9") == .orderedDescending)
        #expect(UpdateChecker.compareVersions("1.0", "1.0.0") == .orderedSame)
        #expect(UpdateChecker.compareVersions("1.0.1", "1.0") == .orderedDescending)
        #expect(UpdateChecker.compareVersions("0.9", "1.0") == .orderedAscending)
    }
}
