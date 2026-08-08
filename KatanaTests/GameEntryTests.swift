import Foundation
import Testing
@testable import Katana

struct GameEntryTests {
    private func entry(
        format: DiscFormat = .gdi,
        byteSize: Int64,
        detailsLoaded: Bool
    ) -> GameEntry {
        GameEntry(
            id: UUID(),
            number: 2,
            name: "Test",
            serial: "MK-1",
            format: format,
            imageFileName: format == .gdi ? "disc.gdi" : "disc.cdi",
            folderPath: "/tmp/02",
            byteSize: byteSize,
            payloadByteSize: byteSize,
            contentSHA256: nil,
            isMenu: false,
            detailsLoaded: detailsLoaded
        )
    }

    @Test func needsEnrichmentWhenDetailsNotLoaded() {
        #expect(entry(byteSize: 50, detailsLoaded: false).needsDetailEnrichment)
    }

    @Test func needsEnrichmentForTinyGDIEvenIfMarkedLoaded() {
        // disc.gdi cue file size mistaken for full size in older caches.
        #expect(entry(format: .gdi, byteSize: 512, detailsLoaded: true).needsDetailEnrichment)
        #expect(entry(format: .gdi, byteSize: 999_999, detailsLoaded: true).needsDetailEnrichment)
    }

    @Test func fullyLoadedGDIDoesNotNeedEnrichment() {
        #expect(!entry(format: .gdi, byteSize: 1_188_000_000, detailsLoaded: true).needsDetailEnrichment)
    }

    @Test func largeProvisionalCDIStillEnrichesUntilFlagSet() {
        let g = entry(format: .cdi, byteSize: 800_000_000, detailsLoaded: false)
        #expect(g.needsDetailEnrichment)
    }

    @Test func loadedCDIDoesNotNeedEnrichment() {
        #expect(!entry(format: .cdi, byteSize: 800_000_000, detailsLoaded: true).needsDetailEnrichment)
    }
}
