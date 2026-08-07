import Foundation

/// Immediate, on-disk mutations. No deferred "save" — the SD card is the source of truth.
enum CardOperations: Sendable {
    nonisolated static let trashFolderName = ".dcgdsd-trash"
    nonisolated static let tmpFolderName = ".dcgdsd-tmp"
    nonisolated static let nameFile = "name.txt"
    nonisolated static let serialFile = "serial.txt"

    // MARK: - Rename

    /// Write `name.txt` immediately. Returns previous name for undo.
    @discardableResult
    nonisolated static func rename(game: GameEntry, to newName: String) throws -> String {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OperationError.emptyName
        }
        let previous = game.name
        let url = game.folderURL.appendingPathComponent(nameFile)
        try trimmed.write(to: url, atomically: true, encoding: .utf8)
        return previous
    }

    // MARK: - Delete (soft → same-volume trash, pack gaps)

    /// Soft-delete one or more games into `.dcgdsd-trash/`, then pack remaining numbers.
    /// Uses single-pass renames when packing down (half the I/O of two-phase renumber).
    /// Returns updated remaining games — callers should **not** full-rescan.
    nonisolated static func delete(
        gameIDs: Set<UUID>,
        games: [GameEntry],
        rootURL: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> BatchDeleteResult {
        guard !gameIDs.isEmpty else {
            throw OperationError.gameNotFound
        }

        let toDelete = games.filter { gameIDs.contains($0.id) }
        guard !toDelete.isEmpty else {
            throw OperationError.gameNotFound
        }

        let previousOrder = games.map(\.id)
        let trashRoot = try ensureDir(rootURL.appendingPathComponent(trashFolderName, isDirectory: true))
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")

        var trashed: [TrashedGame] = []
        trashed.reserveCapacity(toDelete.count)

        for game in toDelete {
            progress?("Trashing \(game.name)…")
            let trashName = "\(stamp)_\(FolderNumbering.format(game.number))_\(sanitize(game.name))"
            let trashURL = uniqueURL(trashRoot.appendingPathComponent(trashName, isDirectory: true))
            try FileManager.default.moveItem(at: game.folderURL, to: trashURL)
            trashed.append(
                TrashedGame(
                    game: game,
                    trashURL: trashURL,
                    originalIndex: games.firstIndex(where: { $0.id == game.id }) ?? 0
                )
            )
        }

        // Remaining keep list order; pack into 01…n with as few renames as possible.
        let remaining = games.filter { !gameIDs.contains($0.id) }
        var pathByID = Dictionary(uniqueKeysWithValues: remaining.map { ($0.id, $0.folderPath) })
        let desired = remaining.enumerated().map { ($0.element.id, $0.offset + 1) }

        let locations = try renumber(
            pathByID: &pathByID,
            desiredNumbers: desired,
            rootURL: rootURL,
            preferCompactPack: true,
            progress: progress
        )

        let updatedGames: [GameEntry] = remaining.enumerated().map { index, game in
            var copy = game
            let number = index + 1
            copy.number = number
            if let loc = locations[game.id] {
                copy.folderPath = loc.path
                copy.number = loc.number
            } else {
                copy.folderPath = rootURL
                    .appendingPathComponent(
                        FolderNumbering.format(number, maxNumber: remaining.count),
                        isDirectory: true
                    )
                    .path
            }
            copy.isMenu = number == 1 || GameEntry.isMenuName(copy.name)
            return copy
        }

        return BatchDeleteResult(
            trashed: trashed,
            previousOrder: previousOrder,
            updatedGames: updatedGames
        )
    }

    /// Convenience single delete.
    nonisolated static func delete(
        gameID: UUID,
        games: [GameEntry],
        rootURL: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> BatchDeleteResult {
        try delete(gameIDs: [gameID], games: games, rootURL: rootURL, progress: progress)
    }

    /// Restore soft-deleted games into `currentGames` order at their recorded indices.
    nonisolated static func undelete(
        trashed: [TrashedGame],
        currentGames: [GameEntry],
        rootURL: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> [GameEntry] {
        guard !trashed.isEmpty else { return currentGames }

        progress?("Restoring \(trashed.count) game\(trashed.count == 1 ? "" : "s")…")

        let tmp = try ensureDir(rootURL.appendingPathComponent(tmpFolderName, isDirectory: true))
        var pathByID = Dictionary(uniqueKeysWithValues: currentGames.map { ($0.id, $0.folderPath) })
        var order = currentGames.map(\.id)
        var restoredByID: [UUID: GameEntry] = Dictionary(
            uniqueKeysWithValues: currentGames.map { ($0.id, $0) }
        )

        let sorted = trashed.sorted { $0.originalIndex > $1.originalIndex }
        for item in sorted {
            let staged = tmp.appendingPathComponent(item.game.id.uuidString, isDirectory: true)
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            try FileManager.default.moveItem(at: item.trashURL, to: staged)
            pathByID[item.game.id] = staged.path
            restoredByID[item.game.id] = item.game
            let insertIndex = min(max(0, item.originalIndex), order.count)
            order.insert(item.game.id, at: insertIndex)
        }

        let desired = order.enumerated().map { ($0.element, $0.offset + 1) }
        let locations = try renumber(
            pathByID: &pathByID,
            desiredNumbers: desired,
            rootURL: rootURL,
            preferCompactPack: false,
            progress: progress
        )

        return order.enumerated().map { index, id in
            var game = restoredByID[id]!
            let number = index + 1
            game.number = number
            if let loc = locations[id] {
                game.folderPath = loc.path
                game.number = loc.number
            } else {
                game.folderPath = rootURL
                    .appendingPathComponent(
                        FolderNumbering.format(number, maxNumber: order.count),
                        isDirectory: true
                    )
                    .path
            }
            game.isMenu = number == 1 || GameEntry.isMenuName(game.name)
            return game
        }
    }

    // MARK: - Import (add discs)

    /// A resolved disc package ready to copy onto the card.
    struct DiscImportSource: Sendable, Hashable {
        /// Directory whose contents form the GDEMU game folder (or parent of a lone image).
        var packageURL: URL
        /// When set, only these file names (relative to `packageURL`) are copied — e.g. a single CDI.
        var fileNames: [String]?
        var imageFileName: String
        var hintName: String
    }

    struct ImportResult: Sendable {
        /// Full game list after import (existing renumbered if width grew + new slots).
        var games: [GameEntry]
        var added: [GameEntry]
        var skipped: [(url: URL, reason: String)]
    }

    /// Copy disc packages/images into the next free slots. Existing folders are renumbered
    /// first when digit width must grow (e.g. 99 → 100).
    nonisolated static func importDiscs(
        sources: [URL],
        games: [GameEntry],
        rootURL: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> ImportResult {
        guard !sources.isEmpty else {
            return ImportResult(games: games, added: [], skipped: [])
        }

        var resolved: [DiscImportSource] = []
        var skipped: [(URL, String)] = []
        var seenPackages = Set<String>()

        for url in sources {
            do {
                let source = try resolveImportSource(url)
                let key = source.packageURL.standardizedFileURL.path
                    + "|" + (source.fileNames?.sorted().joined(separator: ",") ?? "*")
                if seenPackages.contains(key) {
                    skipped.append((url, "Duplicate selection"))
                    continue
                }
                // Refuse importing from the open card itself.
                let rootPath = rootURL.standardizedFileURL.path
                let pkgPath = source.packageURL.standardizedFileURL.path
                if pkgPath == rootPath || pkgPath.hasPrefix(rootPath + "/") {
                    skipped.append((url, "Source is already on this card"))
                    continue
                }
                seenPackages.insert(key)
                resolved.append(source)
            } catch {
                skipped.append((url, error.localizedDescription))
            }
        }

        guard !resolved.isEmpty else {
            return ImportResult(games: games, added: [], skipped: skipped)
        }

        let fm = FileManager.default
        let existing = games.sorted { $0.number < $1.number }

        // Next slot must respect **on-disk** numbered folders, not only the in-memory list.
        // A stale/empty `games` array (or snapshot desync) used to pick "001" while the menu
        // already occupied that slot → "Destination folder already exists: 001".
        let occupiedBefore = try occupiedSlotNumbers(on: rootURL)
        let memoryMax = existing.map(\.number).max() ?? 0
        let diskMax = occupiedBefore.max() ?? 0
        let startNumber = max(memoryMax, diskMax, existing.count) + 1
        let endNumber = startNumber + resolved.count - 1
        let newTotal = max(endNumber, memoryMax, diskMax, existing.count + resolved.count)

        // Widen folder names if we cross 99 / 999 boundaries.
        var pathByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0.folderPath) })
        let desiredExisting = existing.enumerated().map { ($0.element.id, $0.offset + 1) }
        // Use final card size for digit width (e.g. 99 → 100 forces 01→001 renames).
        let locations = try renumber(
            pathByID: &pathByID,
            desiredNumbers: desiredExisting,
            rootURL: rootURL,
            preferCompactPack: false,
            maxNumber: newTotal,
            progress: progress
        )

        var updatedExisting: [GameEntry] = existing.enumerated().map { index, game in
            var copy = game
            let number = index + 1
            copy.number = number
            if let loc = locations[game.id] {
                copy.folderPath = loc.path
                copy.number = loc.number
            } else {
                copy.folderPath = rootURL
                    .appendingPathComponent(
                        FolderNumbering.format(number, maxNumber: newTotal),
                        isDirectory: true
                    )
                    .path
            }
            copy.isMenu = number == 1 || GameEntry.isMenuName(copy.name)
            return copy
        }

        var added: [GameEntry] = []
        added.reserveCapacity(resolved.count)
        var nextNumber = startNumber
        // Re-read after renumber so free-slot search sees final names.
        var occupied = try occupiedSlotNumbers(on: rootURL)

        for (offset, source) in resolved.enumerated() {
            // Skip any slot still occupied (gaps, stale memory, concurrent mounts).
            while occupied.contains(nextNumber) {
                nextNumber += 1
            }
            let number = nextNumber
            nextNumber += 1
            let widthMax = max(newTotal, number, occupied.max() ?? 0)
            let folderName = FolderNumbering.format(number, maxNumber: widthMax)
            progress?("Copying \(offset + 1)/\(resolved.count)… \(source.hintName)")

            let dest = rootURL.appendingPathComponent(folderName, isDirectory: true)
            if fm.fileExists(atPath: dest.path) {
                // Extremely unlikely after occupied check; keep a clear error.
                throw OperationError.destinationExists(folderName)
            }
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            occupied.insert(number)

            do {
                try copyPackage(source: source, to: dest)
            } catch {
                try? fm.removeItem(at: dest)
                throw error
            }

            // Prefer disc.* names when we copied a single image file.
            // Resolve display name from the *source* filename first (GCM-style), before rename.
            var imageName = source.imageFileName
            let preferred = preferredImageName(for: source.imageFileName)
            if source.fileNames?.count == 1,
               preferred != source.imageFileName
            {
                let from = dest.appendingPathComponent(source.imageFileName)
                let to = dest.appendingPathComponent(preferred)
                if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
                    try? fm.moveItem(at: from, to: to)
                    imageName = preferred
                }
            }

            let format = discFormat(for: imageName)
            let ip = IpBinReader.read(
                folderURL: dest,
                imageFileName: imageName,
                format: format
            )
            // Like GDMENU Card Manager: default title from source file/folder name so
            // homebrew variants (same IP.BIN) stay distinct. GameDB/IP are fallbacks only.
            let resolvedName = importDisplayName(source: source, ip: ip)

            try resolvedName.name.write(
                to: dest.appendingPathComponent(nameFile),
                atomically: true,
                encoding: .utf8
            )
            if !resolvedName.serial.isEmpty {
                try resolvedName.serial.write(
                    to: dest.appendingPathComponent(serialFile),
                    atomically: true,
                    encoding: .utf8
                )
            }

            let details = try? CardScanner.loadFolderDetails(folderURL: dest)
            let entry = GameEntry(
                id: UUID(),
                number: number,
                name: resolvedName.name,
                serial: resolvedName.serial,
                format: format,
                imageFileName: imageName,
                folderPath: dest.path,
                byteSize: details?.byteSize ?? 0,
                payloadByteSize: details?.payloadByteSize ?? 0,
                contentSHA256: details?.contentSHA256,
                isMenu: false,
                detailsLoaded: details != nil
            )
            added.append(entry)
        }

        return ImportResult(
            games: updatedExisting + added,
            added: added,
            skipped: skipped
        )
    }

    /// Turn a user-selected file or folder into a copyable disc package.
    nonisolated static func resolveImportSource(_ url: URL) throws -> DiscImportSource {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw OperationError.importUnreadable(url.lastPathComponent)
        }

        if isDir.boolValue {
            let names = try fm.contentsOfDirectory(atPath: url.path)
                .filter { !$0.hasPrefix(".") }
            guard let image = detectImageName(in: names) else {
                throw OperationError.importNoDiscImage(url.lastPathComponent)
            }
            return DiscImportSource(
                packageURL: url.standardizedFileURL,
                fileNames: nil,
                imageFileName: image,
                hintName: url.lastPathComponent
            )
        }

        let ext = url.pathExtension.lowercased()
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent

        switch ext {
        case "gdi":
            // Whole GDI set lives next to the cue file.
            let names = try fm.contentsOfDirectory(atPath: parent.path)
                .filter { !$0.hasPrefix(".") }
            return DiscImportSource(
                packageURL: parent.standardizedFileURL,
                fileNames: nil,
                imageFileName: name,
                hintName: (name as NSString).deletingPathExtension
            )
        case "cdi":
            return DiscImportSource(
                packageURL: parent.standardizedFileURL,
                fileNames: [name],
                imageFileName: name,
                hintName: (name as NSString).deletingPathExtension
            )
        case "ccd":
            // CloneCCD-style: .ccd + .img + optional .sub
            let base = (name as NSString).deletingPathExtension
            var files = [name]
            for companion in ["\(base).img", "\(base).sub", "\(base).cue"] {
                if fm.fileExists(atPath: parent.appendingPathComponent(companion).path) {
                    files.append(companion)
                }
            }
            return DiscImportSource(
                packageURL: parent.standardizedFileURL,
                fileNames: files,
                imageFileName: name,
                hintName: base
            )
        default:
            throw OperationError.importUnsupported(url.lastPathComponent)
        }
    }

    nonisolated private static func copyPackage(source: DiscImportSource, to dest: URL) throws {
        let fm = FileManager.default
        if let fileNames = source.fileNames {
            for name in fileNames {
                let from = source.packageURL.appendingPathComponent(name)
                let to = dest.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else {
                    throw OperationError.importUnreadable(name)
                }
                try fm.copyItem(at: from, to: to)
            }
            return
        }

        let names = try fm.contentsOfDirectory(atPath: source.packageURL.path)
            .filter { !$0.hasPrefix(".") }
        for name in names {
            // Skip nested manager trash/tmp if someone selected a card root by mistake
            // (already blocked) or odd packages.
            if name == trashFolderName || name == tmpFolderName { continue }
            let from = source.packageURL.appendingPathComponent(name)
            let to = dest.appendingPathComponent(name)
            try fm.copyItem(at: from, to: to)
        }
    }

    nonisolated private static func detectImageName(in names: [String]) -> String? {
        let byLower = Dictionary(uniqueKeysWithValues: names.map { ($0.lowercased(), $0) })
        for preferred in ["disc.gdi", "disc.cdi", "disc.ccd"] {
            if let name = byLower[preferred] { return name }
        }
        let priority: [String: Int] = ["gdi": 0, "cdi": 1, "ccd": 2]
        let ranked = names.compactMap { name -> (String, Int)? in
            let ext = (name as NSString).pathExtension.lowercased()
            guard let rank = priority[ext] else { return nil }
            return (name, rank)
        }
        return ranked.sorted { $0.1 < $1.1 }.first?.0
    }

    nonisolated private static func preferredImageName(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "gdi": return "disc.gdi"
        case "cdi": return "disc.cdi"
        case "ccd": return "disc.ccd"
        default: return fileName
        }
    }

    nonisolated private static func discFormat(for fileName: String) -> DiscFormat {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "gdi": return .gdi
        case "cdi": return .cdi
        case "ccd": return .ccd
        default: return .unknown
        }
    }

    /// Import naming: source file / folder first (distinguishes variants), then GameDB / IP.BIN.
    nonisolated static func importDisplayName(
        source: DiscImportSource,
        ip: IpBinInfo?
    ) -> (name: String, serial: String) {
        let serial = ip?.productNumber.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Original image base name (before any rename to disc.*).
        let fileBase = (source.imageFileName as NSString)
            .deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !fileBase.isEmpty, fileBase.lowercased() != "disc" {
            return (fileBase, serial)
        }

        // Package / selection folder name (e.g. BELTRUNNER-SHIPPLAY-DC).
        let hint = source.hintName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty, FolderNumbering.parse(hint) == nil {
            return (hint, serial)
        }

        // Fallback: GameDB → IP.BIN → leftovers.
        return GameDatabase.resolveDisplayName(
            nameTxt: nil,
            serialTxt: nil,
            ip: ip,
            imageFileName: source.imageFileName,
            folderName: source.hintName
        )
    }

    // MARK: - Reorder

    /// Apply a new full order. Returns updated game list (no disk rescan needed).
    nonisolated static func applyOrder(
        orderedIDs: [UUID],
        games: [GameEntry],
        rootURL: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> [GameEntry] {
        let byID = Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })
        guard orderedIDs.count == games.count,
              Set(orderedIDs) == Set(games.map(\.id))
        else {
            throw OperationError.invalidOrder
        }

        var pathByID = Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0.folderPath) })
        let desired = orderedIDs.enumerated().map { ($0.element, $0.offset + 1) }
        let locations = try renumber(
            pathByID: &pathByID,
            desiredNumbers: desired,
            rootURL: rootURL,
            preferCompactPack: false,
            progress: progress
        )

        return orderedIDs.enumerated().map { index, id in
            var game = byID[id]!
            let number = index + 1
            game.number = number
            if let loc = locations[id] {
                game.folderPath = loc.path
                game.number = loc.number
            } else {
                game.folderPath = rootURL
                    .appendingPathComponent(
                        FolderNumbering.format(number, maxNumber: orderedIDs.count),
                        isDirectory: true
                    )
                    .path
            }
            game.isMenu = number == 1 || GameEntry.isMenuName(game.name)
            return game
        }
    }

    // MARK: - Renumber engine

    struct FolderLocation: Sendable {
        var number: Int
        var path: String
    }

    /// Slot numbers that already have a folder on the card root (e.g. `001`, `02`).
    nonisolated static func occupiedSlotNumbers(on rootURL: URL) throws -> Set<Int> {
        let children = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var slots = Set<Int>()
        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            if let n = FolderNumbering.parse(child.lastPathComponent) {
                slots.insert(n)
            }
        }
        return slots
    }

    /// Renumber folders. Returns final number+path for every id in `desiredNumbers`.
    ///
    /// - `preferCompactPack`: after deletes, remaining games only move *down* into freed slots.
    ///   Process low→high with **one rename each** (no park-in-tmp). Falls back to two-phase
    ///   if a destination is still occupied (width change / unexpected layout).
    @discardableResult
    nonisolated static func renumber(
        pathByID: inout [UUID: String],
        desiredNumbers: [(UUID, Int)],
        rootURL: URL,
        preferCompactPack: Bool,
        maxNumber maxNumberOverride: Int? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> [UUID: FolderLocation] {
        let maxNumber = maxNumberOverride ?? desiredNumbers.map(\.1).max() ?? 1

        struct Planned {
            var id: UUID
            var from: URL
            var number: Int
            var finalName: String
        }

        var planned: [Planned] = []
        planned.reserveCapacity(desiredNumbers.count)

        for (id, number) in desiredNumbers {
            guard let path = pathByID[id] else { continue }
            let from = URL(fileURLWithPath: path, isDirectory: true)
            let finalName = FolderNumbering.format(number, maxNumber: maxNumber)
            planned.append(Planned(id: id, from: from, number: number, finalName: finalName))
        }

        let needsMove = planned.filter {
            $0.from.lastPathComponent != $0.finalName
                || $0.from.deletingLastPathComponent().standardizedFileURL != rootURL.standardizedFileURL
        }

        if needsMove.isEmpty {
            return Dictionary(uniqueKeysWithValues: planned.map {
                ($0.id, FolderLocation(number: $0.number, path: $0.from.path))
            })
        }

        progress?("Renumbering \(needsMove.count) folders…")

        let fm = FileManager.default
        var usedCompact = false

        if preferCompactPack {
            // Single-pass: ascending by current folder number, rename into free lower slots.
            usedCompact = true
            let ordered = needsMove.sorted {
                (FolderNumbering.parse($0.from.lastPathComponent) ?? Int.max)
                    < (FolderNumbering.parse($1.from.lastPathComponent) ?? Int.max)
            }

            for (index, move) in ordered.enumerated() {
                let dest = rootURL.appendingPathComponent(move.finalName, isDirectory: true)
                if move.from.standardizedFileURL == dest.standardizedFileURL {
                    continue
                }
                if fm.fileExists(atPath: dest.path) {
                    usedCompact = false
                    break
                }
                try fm.moveItem(at: move.from, to: dest)
                pathByID[move.id] = dest.path
                if index % 10 == 0 || index == ordered.count - 1 {
                    progress?("Renumbering \(index + 1)/\(ordered.count)…")
                }
            }
        }

        if !usedCompact {
            // Two-phase for arbitrary reorder / width shrink / collisions.
            // Reset pathByID from planned `from` for any we may have partially moved — if compact
            // failed mid-way, recover by two-phase from current on-disk state.
            if preferCompactPack {
                // Rebuild from disk: whatever still exists under old or new names.
                for item in planned {
                    let finalURL = rootURL.appendingPathComponent(item.finalName, isDirectory: true)
                    if fm.fileExists(atPath: finalURL.path) {
                        pathByID[item.id] = finalURL.path
                    } else if fm.fileExists(atPath: item.from.path) {
                        pathByID[item.id] = item.from.path
                    }
                }
            }

            let tmpRoot = try ensureDir(rootURL.appendingPathComponent(tmpFolderName, isDirectory: true))

            var phaseMoves: [(id: UUID, from: URL, phaseA: URL, finalName: String, number: Int)] = []
            for item in planned {
                guard let path = pathByID[item.id] else { continue }
                let from = URL(fileURLWithPath: path, isDirectory: true)
                let finalName = FolderNumbering.format(item.number, maxNumber: maxNumber)
                if from.lastPathComponent == finalName,
                   from.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL {
                    continue
                }
                let phaseA = tmpRoot.appendingPathComponent(item.id.uuidString, isDirectory: true)
                phaseMoves.append((item.id, from, phaseA, finalName, item.number))
            }

            progress?("Renumbering \(phaseMoves.count) folders…")

            for (index, m) in phaseMoves.enumerated() {
                if fm.fileExists(atPath: m.phaseA.path) {
                    try fm.removeItem(at: m.phaseA)
                }
                try fm.moveItem(at: m.from, to: m.phaseA)
                if index % 10 == 0 {
                    progress?("Parking \(index + 1)/\(phaseMoves.count)…")
                }
            }

            for (index, m) in phaseMoves.enumerated() {
                let dest = rootURL.appendingPathComponent(m.finalName, isDirectory: true)
                if fm.fileExists(atPath: dest.path) {
                    throw OperationError.destinationExists(dest.lastPathComponent)
                }
                try fm.moveItem(at: m.phaseA, to: dest)
                pathByID[m.id] = dest.path
                if index % 10 == 0 || index == phaseMoves.count - 1 {
                    progress?("Placing \(index + 1)/\(phaseMoves.count)…")
                }
            }

            if let contents = try? fm.contentsOfDirectory(atPath: tmpRoot.path), contents.isEmpty {
                try? fm.removeItem(at: tmpRoot)
            }
        }

        // Build final map for all desired ids.
        var result: [UUID: FolderLocation] = [:]
        for (id, number) in desiredNumbers {
            let finalName = FolderNumbering.format(number, maxNumber: maxNumber)
            let path = pathByID[id]
                ?? rootURL.appendingPathComponent(finalName, isDirectory: true).path
            // Prefer canonical path under root with final name.
            let canonical = rootURL.appendingPathComponent(finalName, isDirectory: true).path
            result[id] = FolderLocation(
                number: number,
                path: FileManager.default.fileExists(atPath: canonical) ? canonical : path
            )
        }
        return result
    }

    // MARK: - Helpers

    private nonisolated static func ensureDir(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var i = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + "-\(i)", isDirectory: true)
            i += 1
        }
        return candidate
    }

    private nonisolated static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return String(cleaned.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TrashedGame: Sendable {
    var game: GameEntry
    var trashURL: URL
    var originalIndex: Int
}

struct BatchDeleteResult: Sendable {
    var trashed: [TrashedGame]
    var previousOrder: [UUID]
    /// Remaining games with final numbers/paths — apply directly, skip full rescan.
    var updatedGames: [GameEntry]
}

enum OperationError: LocalizedError {
    case emptyName
    case gameNotFound
    case invalidOrder
    case destinationExists(String)
    case noVolume
    case busy
    case importNoDiscImage(String)
    case importUnsupported(String)
    case importUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Name cannot be empty."
        case .gameNotFound: return "Game not found."
        case .invalidOrder: return "Invalid reorder."
        case .destinationExists(let name):
            return "Could not create slot \(name) — that folder already exists on the card. Try Rescan, then add again."
        case .noVolume: return "No card open."
        case .busy: return "Another operation is in progress."
        case .importNoDiscImage(let name):
            return "No disc image (.gdi / .cdi / .ccd) found in “\(name)”."
        case .importUnsupported(let name):
            return "Unsupported file “\(name)”. Choose a .gdi, .cdi, .ccd, or a game folder."
        case .importUnreadable(let name):
            return "Cannot read “\(name)”."
        }
    }
}
