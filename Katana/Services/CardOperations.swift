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
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> [UUID: FolderLocation] {
        let maxNumber = desiredNumbers.map(\.1).max() ?? 1

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

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Name cannot be empty."
        case .gameNotFound: return "Game not found."
        case .invalidOrder: return "Invalid reorder."
        case .destinationExists(let name): return "Destination folder already exists: \(name)"
        case .noVolume: return "No card open."
        case .busy: return "Another operation is in progress."
        }
    }
}
