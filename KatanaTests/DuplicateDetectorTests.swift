import Foundation
import Testing
@testable import Katana

struct DuplicateDetectorTests {
    @Test func matchesSerialIgnoringPunctuation() {
        let a = entry(number: 2, name: "Sonic Adventure", serial: "T-9708N", size: 500_000_000)
        let b = entry(number: 5, name: "Sonic Adventure", serial: "T9708N", size: 500_000_000)
        let c = entry(number: 8, name: "Crazy Taxi", serial: "MK-51035", size: 400_000_000)

        let map = DuplicateDetector.analyze([a, b, c])
        #expect(map[a.id] != nil)
        #expect(map[b.id] != nil)
        #expect(map[c.id] == nil)
        #expect(map[a.id]?.isPrimary == true)
        #expect(map[b.id]?.isRedundant == true)
    }

    @Test func multiDiscSameSerialNotFlagged() {
        let d1 = entry(number: 10, name: "Shenmue (Disc 1)", serial: "MK-51059", size: 1_100_000_000)
        let d2 = entry(number: 11, name: "Shenmue (Disc 2)", serial: "MK-51059", size: 1_050_000_000)
        let d3 = entry(number: 12, name: "Shenmue (Disc 3)", serial: "MK-51059", size: 980_000_000)

        let map = DuplicateDetector.analyze([d1, d2, d3])
        #expect(map.isEmpty)
    }

    @Test func multiDiscMarkersCD() {
        let d1 = entry(number: 2, name: "Game CD1", serial: "T1111", size: 600_000_000)
        let d2 = entry(number: 3, name: "Game CD2", serial: "T1111", size: 550_000_000)
        #expect(DuplicateDetector.looksLikeMultiDiscPair(d1.name, d2.name))
        #expect(DuplicateDetector.analyze([d1, d2]).isEmpty)
    }

    @Test func sameSerialSameSizeStillDuplicate() {
        // Bad double-add of disc 1 — same serial and same size.
        let a = entry(number: 4, name: "Skies of Arcadia", serial: "MK-51052", size: 800_000_000)
        let b = entry(number: 20, name: "Skies of Arcadia (USA)", serial: "MK-51052", size: 800_000_000)
        let map = DuplicateDetector.analyze([a, b])
        #expect(map[a.id]?.grade == .strong || map[a.id]?.grade == .likely)
        #expect(map[b.id]?.isRedundant == true)
    }

    @Test func exactHashIsHighestGrade() {
        let a = entry(number: 2, name: "Foo", serial: "T0000", size: 100_000_000, hash: "abc")
        let b = entry(number: 9, name: "Bar", serial: "T9999", size: 100_000_000, hash: "abc")
        let map = DuplicateDetector.analyze([a, b])
        #expect(map[a.id]?.grade == .exact)
        #expect(map[b.id]?.grade == .exact)
    }

    @Test func fallsBackToNameWhenSerialEmpty() {
        let a = entry(number: 2, name: "Homebrew Tool", serial: "", size: 50_000_000)
        let b = entry(number: 3, name: "homebrew  tool", serial: "", size: 50_000_000)
        let c = entry(number: 4, name: "Other", serial: "", size: 60_000_000)

        let map = DuplicateDetector.analyze([a, b, c])
        #expect(map[a.id] != nil)
        #expect(map[b.id] != nil)
        #expect(map[c.id] == nil)
    }

    @Test func skipsMenu() {
        let menu = entry(number: 1, name: "GDMENU", serial: "MK6969", size: 1_000_000, isMenu: true)
        let a = entry(number: 2, name: "GDMENU", serial: "MK6969", size: 1_000_000)
        let map = DuplicateDetector.analyze([menu, a])
        #expect(map.isEmpty)
    }

    @Test func ignoredIdentityKeysExcludedFromGroups() {
        let a = entry(number: 2, name: "Sonic Adventure", serial: "T-9708N", size: 500_000_000)
        let b = entry(number: 5, name: "Sonic Adventure", serial: "T9708N", size: 500_000_000)
        let ignored = Set([DuplicateIdentity.key(for: b)])
        let map = DuplicateDetector.analyze([a, b], ignoredIdentityKeys: ignored)
        #expect(map.isEmpty)
    }

    @Test func redundantIDsKeepsLowestSlot() {
        let a = entry(number: 10, name: "Game", serial: "T0001", size: 200_000_000)
        let b = entry(number: 3, name: "Game", serial: "T0001", size: 200_000_000)
        let c = entry(number: 20, name: "Game", serial: "T0001", size: 200_000_000)
        let games = [a, b, c]
        let redundant = DuplicateDetector.redundantIDs(in: games)
        #expect(redundant == [a.id, c.id])
        #expect(!redundant.contains(b.id))
    }

    @Test func nameSimilarityDice() {
        #expect(DuplicateDetector.nameSimilarity("Sonic Adventure", "sonic adventure") == 1)
        #expect(DuplicateDetector.nameSimilarity("Sonic Adventure", "Sonic Adventure!") > 0.9)
        #expect(DuplicateDetector.nameSimilarity("Crazy Taxi", "Sonic") < 0.5)
    }

    /// Sequels share a soft name score but are different products — must not group.
    @Test func sequelsNotFlaggedAsNameOnlyDuplicates() {
        let vt1 = entry(
            number: 38,
            name: "VIRTUA TENNIS",
            serial: "MK-5105450",
            size: 297_000_000
        )
        let vt2 = entry(
            number: 39,
            name: "VIRTUA TENNIS 2",
            serial: "MK-5118650",
            size: 1_008_000_000
        )
        #expect(DuplicateDetector.nameSimilarity(vt1.name, vt2.name) >= 0.82)
        #expect(DuplicateDetector.looksLikeSequelPair(vt1.name, vt2.name))
        let map = DuplicateDetector.analyze([vt1, vt2])
        #expect(map.isEmpty)
    }

    @Test func sequelWithEmptySerialsAndDifferentSizesIgnored() {
        let a = entry(number: 2, name: "Resident Evil 2", serial: "", size: 800_000_000)
        let b = entry(number: 3, name: "Resident Evil 3", serial: "", size: 900_000_000)
        #expect(DuplicateDetector.looksLikeSequelPair(a.name, b.name))
        #expect(DuplicateDetector.analyze([a, b]).isEmpty)
    }

    @Test func trueNameDupWithoutSerialStillGroupsWhenSameSize() {
        let a = entry(number: 2, name: "Homebrew Tool", serial: "", size: 50_000_000)
        let b = entry(number: 3, name: "homebrew  tool", serial: "", size: 50_000_000)
        let map = DuplicateDetector.analyze([a, b])
        #expect(map[a.id] != nil)
        #expect(map[b.id] != nil)
    }

    @Test func differentSerialSameNameSimilarSizeStillWeak() {
        // Same display title, different product code, similar dump size (region renames).
        let a = entry(number: 2, name: "Crazy Taxi", serial: "MK-51035", size: 400_000_000)
        let b = entry(number: 5, name: "Crazy Taxi", serial: "T-9709N", size: 405_000_000)
        let map = DuplicateDetector.analyze([a, b])
        #expect(map[a.id]?.grade == .weak)
        #expect(map[b.id]?.isRedundant == true)
    }

    @Test func analysisSignatureStableForSameList() {
        let a = entry(number: 2, name: "Foo", serial: "T1", size: 10)
        let b = entry(number: 3, name: "Bar", serial: "T2", size: 20)
        let s1 = DuplicateDetector.analysisSignature(games: [a, b])
        let s2 = DuplicateDetector.analysisSignature(games: [b, a]) // order by number
        #expect(s1 == s2)
        #expect(s1.count == 64)
    }

    @Test func cacheRoundTripRemapsIDs() {
        let a = entry(number: 2, name: "Sonic Adventure", serial: "T-9708N", size: 500_000_000)
        let b = entry(number: 5, name: "Sonic Adventure", serial: "T9708N", size: 500_000_000)
        let info = DuplicateDetector.analyze([a, b])
        let sig = DuplicateDetector.analysisSignature(games: [a, b])
        let record = DuplicateDetector.cacheRecord(
            volumeUUID: "vol",
            signature: sig,
            games: [a, b],
            info: info
        )
        // New UUIDs, same folders/content (folder path uses number).
        let a2 = entry(number: 2, name: "Sonic Adventure", serial: "T-9708N", size: 500_000_000)
        let b2 = entry(number: 5, name: "Sonic Adventure", serial: "T9708N", size: 500_000_000)
        let mapped = DuplicateDetector.mapFromCache(record, onto: [a2, b2])
        #expect(mapped?[a2.id]?.isPrimary == true)
        #expect(mapped?[b2.id]?.isRedundant == true)
        #expect(mapped?[a2.id]?.grade == info[a.id]?.grade)
    }

    private func entry(
        number: Int,
        name: String,
        serial: String,
        size: Int64,
        hash: String? = nil,
        isMenu: Bool = false
    ) -> GameEntry {
        GameEntry(
            id: UUID(),
            number: number,
            name: name,
            serial: serial,
            format: .cdi,
            imageFileName: "disc.cdi",
            folderPath: "/tmp/\(number)",
            byteSize: size,
            payloadByteSize: size,
            contentSHA256: hash,
            isMenu: isMenu || GameEntry.isMenuName(name)
        )
    }
}

struct ContentHashSidecarTests {
    @Test func parseBareHex() {
        #expect(ContentHashSidecar.parseHashFileContents("d41d8cd98f00b204e9800998ecf8427e\n")?.count == 32)
    }

    @Test func parseGNUSumLine() {
        let line = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  disc.cdi\n"
        #expect(ContentHashSidecar.parseHashFileContents(line)?.count == 64)
    }

    @Test func parseBSDStyle() {
        let line = "SHA256 (disc.cdi) = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        #expect(ContentHashSidecar.parseHashFileContents(line)?.count == 64)
    }
}
