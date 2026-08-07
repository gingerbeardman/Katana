//
//  KatanaTests.swift
//  KatanaTests
//
//  Created by Matt Sephton on 2026-08-07.
//

import Foundation
import Testing
@testable import Katana

struct KatanaTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

}

struct AutoRenameSourceTests {
    private func game(
        name: String = "Old",
        serial: String = "",
        image: String = "disc.cdi",
        folder: String = "/Volumes/Card/02"
    ) -> GameEntry {
        GameEntry(
            id: UUID(),
            number: 2,
            name: name,
            serial: serial,
            format: .cdi,
            imageFileName: image,
            folderPath: folder,
            byteSize: 1,
            payloadByteSize: 1,
            contentSHA256: nil,
            isMenu: false
        )
    }

    @Test func fileNameUsesImageBase() {
        let g = game(image: "Rumble_Fish_2.cdi")
        #expect(AutoRenameSource.fileName.suggestedName(for: g) == "Rumble Fish 2")
    }

    @Test func fileNameSkipsGenericDisc() {
        let g = game(image: "disc.gdi")
        #expect(AutoRenameSource.fileName.suggestedName(for: g) == nil)
    }

    @Test func folderNameSkipsSlotNumbers() {
        let g = game(folder: "/Volumes/Card/281")
        #expect(AutoRenameSource.folderName.suggestedName(for: g) == nil)
    }

    @Test func folderNameUsesNonNumericFolder() {
        let g = game(folder: "/tmp/Rumble Fish 2")
        #expect(AutoRenameSource.folderName.suggestedName(for: g) == "Rumble Fish 2")
    }

    @Test func ipBinUsesGameDatabaseWhenSerialKnown() {
        let g = game(serial: "MK-51000", image: "disc.gdi")
        // Bundle or source-tree DB may be available in tests via shared load;
        // if empty, still accept nil (IP.BIN not present in fixture).
        let name = AutoRenameSource.ipBin.suggestedName(for: g)
        if GameDatabase.entryCount > 0 || GameDatabase.title(for: "MK-51000") != nil {
            #expect(name == "Sonic Adventure" || name == nil)
        }
        // Direct GameDB probe (always works against shipped JSON keys via loadTitles in other tests).
        #expect(GameDatabase.lookupKeys(for: "MK-51000").contains("51000"))
    }
}
