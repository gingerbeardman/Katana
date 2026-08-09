import Darwin
import Foundation

/// Immediate, on-disk mutations. No deferred "save" — the SD card is the source of truth.
enum CardOperations: Sendable {
    nonisolated static let trashFolderName = ".katana-trash"
    nonisolated static let tmpFolderName = ".katana-tmp"
    nonisolated static let nameFile = "name.txt"
    nonisolated static let serialFile = "serial.txt"

    // MARK: - Rename

    /// Write `name.txt` immediately. Returns previous name for undo.
    /// - Parameter cardRoot: Security-scoped card root when available. Child URLs built from
    ///   this keep sandbox write access; path-only `game.folderURL` does not.
    @discardableResult
    nonisolated static func rename(game: GameEntry, to newName: String, cardRoot: URL? = nil) throws -> String {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OperationError.emptyName
        }
        let previous = game.name
        let folder = scopedFolderURL(for: game, under: cardRoot)
        let url = folder.appendingPathComponent(nameFile)
        // Non-atomic on purpose: FAT32/exFAT atomic replace (temp + rename) is flaky under
        // the App Sandbox and often surfaces as “don’t have permission to save name.txt”.
        try trimmed.write(to: url, atomically: false, encoding: .utf8)
        return previous
    }

    // MARK: - Delete (soft → trash, or permanent wipe, then pack gaps)

    /// Remove one or more games, then pack remaining numbers.
    ///
    /// - Parameter permanent: When `false` (default), **soft-delete** into `.katana-trash/`
    ///   (fast move; undoable). When `true`, **immediately erase** the folders from the card
    ///   (slow for large GDI sets; not undoable).
    /// - Returns updated remaining games — callers should **not** full-rescan.
    ///   `trashed` is empty when `permanent` is true.
    nonisolated static func delete(
        gameIDs: Set<UUID>,
        games: [GameEntry],
        rootURL: URL,
        permanent: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil,
        fractionProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> BatchDeleteResult {
        guard !gameIDs.isEmpty else {
            throw OperationError.gameNotFound
        }

        let toDelete = games.filter { gameIDs.contains($0.id) }
        guard !toDelete.isEmpty else {
            throw OperationError.gameNotFound
        }

        let previousOrder = games.map(\.id)
        var trashed: [TrashedGame] = []
        trashed.reserveCapacity(permanent ? 0 : toDelete.count)

        if permanent {
            // Pre-size all victims so the edge bar reflects large tracks.
            var plans: [(game: GameEntry, folder: URL, bytes: Int64)] = []
            plans.reserveCapacity(toDelete.count)
            var totalBytes: Int64 = 0
            for game in toDelete {
                let folder = scopedFolderURL(for: game, under: rootURL)
                let bytes = max(1, directoryByteSize(at: folder) ?? game.byteSize)
                plans.append((game, folder, bytes))
                totalBytes += bytes
            }
            totalBytes = max(1, totalBytes)
            let counter = ProgressByteCounter(total: totalBytes, report: fractionProgress)
            fractionProgress?(0)

            for (index, plan) in plans.enumerated() {
                progress?(
                    "Deleting \(plan.game.name)… (\(index + 1)/\(plans.count))"
                )
                let base = counter.completed
                try removeTree(at: plan.folder) { wipedInFolder in
                    counter.report(base + wipedInFolder)
                }
                counter.add(plan.bytes)
            }
        } else {
            let trashRoot = try ensureDir(rootURL.appendingPathComponent(trashFolderName, isDirectory: true))
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")

            for (index, game) in toDelete.enumerated() {
                progress?("Trashing \(game.name)… (\(index + 1)/\(toDelete.count))")
                fractionProgress?(Double(index) / Double(max(toDelete.count, 1)))
                let trashName = "\(stamp)_\(FolderNumbering.format(game.number))_\(sanitize(game.name))"
                let trashURL = uniqueURL(trashRoot.appendingPathComponent(trashName, isDirectory: true))
                // Must move via scoped root — `URL(fileURLWithPath:)` drops security scope.
                let source = scopedFolderURL(for: game, under: rootURL)
                try FileManager.default.moveItem(at: source, to: trashURL)
                trashed.append(
                    TrashedGame(
                        game: game,
                        trashURL: trashURL,
                        originalIndex: games.firstIndex(where: { $0.id == game.id }) ?? 0
                    )
                )
            }
            fractionProgress?(1)
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

    /// Convenience single delete (soft by default).
    nonisolated static func delete(
        gameID: UUID,
        games: [GameEntry],
        rootURL: URL,
        permanent: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil,
        fractionProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> BatchDeleteResult {
        try delete(
            gameIDs: [gameID],
            games: games,
            rootURL: rootURL,
            permanent: permanent,
            progress: progress,
            fractionProgress: fractionProgress
        )
    }

    /// Restore soft-deleted games into `currentGames` order at their recorded indices.
    nonisolated static func undelete(
        trashed: [TrashedGame],
        currentGames: [GameEntry],
        rootURL: URL,
        progress: (@Sendable (String) -> Void)? = nil,
        fractionProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> [GameEntry] {
        guard !trashed.isEmpty else { return currentGames }

        progress?("Restoring \(trashed.count) game\(trashed.count == 1 ? "" : "s")…")
        fractionProgress?(0)

        let tmp = try ensureDir(rootURL.appendingPathComponent(tmpFolderName, isDirectory: true))
        var pathByID = Dictionary(uniqueKeysWithValues: currentGames.map { ($0.id, $0.folderPath) })
        var order = currentGames.map(\.id)
        var restoredByID: [UUID: GameEntry] = Dictionary(
            uniqueKeysWithValues: currentGames.map { ($0.id, $0) }
        )

        let trashRoot = rootURL.appendingPathComponent(trashFolderName, isDirectory: true)
        let sorted = trashed.sorted { $0.originalIndex > $1.originalIndex }
        for (index, item) in sorted.enumerated() {
            let staged = tmp.appendingPathComponent(item.game.id.uuidString, isDirectory: true)
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            // Trash URL may be path-only (scope lost) — re-home under scoped root.
            let trashSource = trashRoot.appendingPathComponent(
                item.trashURL.lastPathComponent,
                isDirectory: true
            )
            try FileManager.default.moveItem(at: trashSource, to: staged)
            pathByID[item.game.id] = staged.path
            restoredByID[item.game.id] = item.game
            let insertIndex = min(max(0, item.originalIndex), order.count)
            order.insert(item.game.id, at: insertIndex)
            // Un-trash staging is ~10% of the bar; renumbering the card is the long part.
            fractionProgress?(0.1 * Double(index + 1) / Double(sorted.count))
        }

        let desired = order.enumerated().map { ($0.element, $0.offset + 1) }
        let locations = try renumber(
            pathByID: &pathByID,
            desiredNumbers: desired,
            rootURL: rootURL,
            preferCompactPack: false,
            progress: progress,
            fractionProgress: fractionProgress.map { report in
                { f in report(0.1 + 0.9 * f) }
            }
        )
        fractionProgress?(1)

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

    // MARK: - Trash

    /// Soft-deleted packages under `.katana-trash/` (top-level items + total bytes).
    nonisolated struct TrashSummary: Sendable, Equatable {
        var itemCount: Int
        var totalBytes: Int64

        var isEmpty: Bool { itemCount == 0 }

        static let empty = TrashSummary(itemCount: 0, totalBytes: 0)
    }

    struct EmptyTrashResult: Sendable {
        /// Top-level items removed from trash.
        var itemCount: Int
        /// Approximate bytes reclaimed (folder contents).
        var bytesFreed: Int64
    }

    /// Inspect `.katana-trash/` without deleting. Safe if missing.
    nonisolated static func trashSummary(on rootURL: URL) -> TrashSummary {
        LaunchTrace.measure("CardOperations.trashSummary") {
            let trashRoot = rootURL.appendingPathComponent(trashFolderName, isDirectory: true)
            let fm = FileManager.default
            guard fm.fileExists(atPath: trashRoot.path) else { return .empty }

            guard let contents = try? fm.contentsOfDirectory(
                at: trashRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ), !contents.isEmpty else {
                return .empty
            }

            var bytes: Int64 = 0
            for url in contents {
                bytes += directoryByteSize(at: url) ?? 0
            }
            return TrashSummary(itemCount: contents.count, totalBytes: bytes)
        }
    }

    /// Permanently delete everything under `.katana-trash/`.
    /// Safe if missing (returns zeros). Does not affect numbered game slots.
    ///
    /// - Important: `rootURL` must be the live security-scoped card root. Child URLs are
    ///   rebuilt with `appendingPathComponent` — never use path-only URLs from enumeration
    ///   (those drop App Sandbox write access on FAT volumes).
    nonisolated static func emptyTrash(
        rootURL: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> EmptyTrashResult {
        // Start scope if the URL carries it. Do **not** stop here — Katana holds card
        // access for the whole session (2UP pattern). A balancing stop in a worker would
        // drop the session grant mid-use when this is the same URL AppState is holding.
        _ = rootURL.startAccessingSecurityScopedResource()
        return try emptyTrashFolder(
            rootURL.appendingPathComponent(trashFolderName, isDirectory: true),
            progress: progress
        )
    }

    nonisolated private static func emptyTrashFolder(
        _ trashRoot: URL,
        progress: (@Sendable (String) -> Void)?
    ) throws -> EmptyTrashResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashRoot.path) else {
            return EmptyTrashResult(itemCount: 0, bytesFreed: 0)
        }

        // Path names only, then rebuild under `trashRoot` so every delete target inherits
        // the security-scoped parent. Include AppleDouble `._*` (no skipsHiddenFiles).
        let names = (try? fm.contentsOfDirectory(atPath: trashRoot.path)) ?? []
        guard !names.isEmpty else {
            try? fm.removeItem(at: trashRoot)
            return EmptyTrashResult(itemCount: 0, bytesFreed: 0)
        }

        progress?("Emptying trash…")
        var bytes: Int64 = 0
        var removed = 0
        var firstError: Error?

        for (index, name) in names.enumerated() {
            let target = trashRoot.appendingPathComponent(name, isDirectory: true)
            bytes += directoryByteSize(at: target) ?? 0
            do {
                try removeTree(at: target)
                removed += 1
            } catch {
                if firstError == nil { firstError = error }
            }
            if index % 5 == 0 || index == names.count - 1 {
                progress?("Emptying trash… \(index + 1)/\(names.count)")
            }
        }

        if let left = try? fm.contentsOfDirectory(atPath: trashRoot.path), left.isEmpty {
            try? fm.removeItem(at: trashRoot)
        }

        // If nothing was removed and something failed, surface the first error.
        if removed == 0, let firstError {
            throw firstError
        }
        // Partial success is OK — remaining items stay for a later Empty Trash.
        return EmptyTrashResult(itemCount: removed, bytesFreed: bytes)
    }

    /// Bottom-up delete for FAT: clear xattrs, remove files, then directories.
    /// Prefer path-based APIs; rebuild every child under `root` (scope-safe).
    /// - Parameter onBytesRemoved: Approximate bytes freed so far under this root (for progress).
    nonisolated private static func removeTree(
        at root: URL,
        onBytesRemoved: (@Sendable (Int64) -> Void)? = nil
    ) throws {
        try removeTree(at: root, bytesSoFar: 0, onBytesRemoved: onBytesRemoved)
    }

    @discardableResult
    nonisolated private static func removeTree(
        at root: URL,
        bytesSoFar: Int64,
        onBytesRemoved: (@Sendable (Int64) -> Void)?
    ) throws -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { return bytesSoFar }

        clearExtendedAttributes(at: root.path)
        var done = bytesSoFar

        if isDir.boolValue {
            let children = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            for name in children {
                // Skip AppleDouble noise names handled as regular files below.
                done = try removeTree(
                    at: root.appendingPathComponent(name, isDirectory: false),
                    bytesSoFar: done,
                    onBytesRemoved: onBytesRemoved
                )
            }
        } else {
            let size = fileByteSize(at: root)
            done += max(0, size)
            onBytesRemoved?(done)
        }

        do {
            try fm.removeItem(atPath: root.path)
        } catch {
            // Last resort: URL form (some sandboxed stacks prefer one or the other).
            try fm.removeItem(at: root)
        }
        return done
    }

    nonisolated private static func clearExtendedAttributes(at path: String) {
        path.withCString { pathPtr in
            _ = removexattr(pathPtr, "com.apple.quarantine", 0)
            _ = removexattr(pathPtr, "com.apple.provenance", 0)
            // Drop Finder info / resource-fork companions on FAT.
            _ = removexattr(pathPtr, "com.apple.FinderInfo", 0)
            _ = removexattr(pathPtr, "com.apple.ResourceFork", 0)
        }
    }

    /// Whether `.katana-trash` exists and has content.
    nonisolated static func trashIsEmpty(on rootURL: URL) -> Bool {
        trashSummary(on: rootURL).isEmpty
    }

    nonisolated private static func directoryByteSize(at url: URL) -> Int64? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
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
        /// Measured transfer samples for rate learning (0 when nothing was copied/hashed).
        var copiedBytes: Int64 = 0
        var copySeconds: Double = 0
        var hashedBytes: Int64 = 0
        var hashSeconds: Double = 0
    }

    /// Remembered transfer rates used to time-weight the import progress bar.
    struct TransferRateEstimates: Sendable {
        /// Bytes/sec writing game files to the card.
        var writeBytesPerSecond: Double
        /// Bytes/sec reading payload while hashing (source volume).
        var hashBytesPerSecond: Double

        /// Conservative fallbacks before any operation has been measured.
        static let defaults = TransferRateEstimates(
            writeBytesPerSecond: 15_000_000,
            hashBytesPerSecond: 120_000_000
        )
    }

    /// Live import UI events — placeholders appear before the heavy copy finishes.
    enum ImportEvent: Sendable {
        /// Existing slots renumbered (digit-width growth); replace the in-memory list prefix.
        case existingUpdated([GameEntry])
        /// Slot folder + provisional `name.txt` created; show the row immediately.
        case slotPrepared(GameEntry)
        /// Hashing or copying this slot (row spinner).
        case slotActive(UUID)
        /// Slot fully written (name/serial/hash/size).
        case slotFinished(GameEntry)
        /// Slot failed after prepare — remove the provisional row (folder cleaned up).
        case slotFailed(UUID)
        /// Overall 0…1 for the edge progress bar (legacy; prefer `copyProgress`).
        case fraction(Double)
        /// Copy progress: one equal chunk per file; fill steps to a notch when its file lands.
        case copyProgress(fraction: Double, segmentEnds: [Double])
        /// Status line / busy caption.
        case message(String)
    }

    /// Copy disc packages/images into the next free slots. Existing folders are renumbered
    /// first when digit width must grow (e.g. 99 → 100).
    ///
    /// Accepts folders, disc images, multi-select GDI/CCD track sets, and `.zip` archives.
    /// When `onEvent` is set, each new slot is prepared (folder + name) before hashing/copy
    /// so the table can show rows immediately with a per-file spinner.
    nonisolated static func importDiscs(
        sources: [URL],
        games: [GameEntry],
        rootURL: URL,
        preferDatabaseNames: Bool = false,
        rates: TransferRateEstimates = .defaults,
        progress: (@Sendable (String) -> Void)? = nil,
        onEvent: (@Sendable (ImportEvent) -> Void)? = nil
    ) throws -> ImportResult {
        func emit(_ event: ImportEvent) {
            onEvent?(event)
            if case .message(let text) = event {
                LaunchTrace.mark("import msg: \(text)")
                progress?(text)
            }
        }

        guard !sources.isEmpty else {
            return ImportResult(games: games, added: [], skipped: [])
        }

        emit(.message("Resolving packages…"))
        let discovery = resolveImportSources(sources)
        defer {
            for temp in discovery.temporaryRoots {
                try? FileManager.default.removeItem(at: temp)
            }
        }

        var resolved: [DiscImportSource] = []
        var skipped = discovery.skipped
        var seenPackages = Set<String>()
        let rootPath = rootURL.standardizedFileURL.path

        for source in discovery.sources {
            let key = source.packageURL.standardizedFileURL.path
                + "|" + (source.fileNames?.sorted().joined(separator: ",") ?? "*")
            if seenPackages.contains(key) {
                skipped.append((source.packageURL, "Duplicate selection"))
                continue
            }
            // Refuse importing from the open card itself.
            let pkgPath = source.packageURL.standardizedFileURL.path
            if pkgPath == rootPath || pkgPath.hasPrefix(rootPath + "/") {
                skipped.append((source.packageURL, "Source is already on this card"))
                continue
            }
            seenPackages.insert(key)
            resolved.append(source)
        }

        guard !resolved.isEmpty else {
            return ImportResult(games: games, added: [], skipped: skipped)
        }

        let fm = FileManager.default
        let existing = games.sorted { $0.number < $1.number }
        let totalSlots = resolved.count

        // Next slot must respect **on-disk** numbered folders, not only the in-memory list.
        // A stale/empty `games` array (or snapshot desync) used to pick "001" while the menu
        // already occupied that slot → "Destination folder already exists: 001".
        let occupiedBefore = try occupiedSlotNumbers(on: rootURL)
        let memoryMax = existing.map(\.number).max() ?? 0
        let diskMax = occupiedBefore.max() ?? 0
        let startNumber = max(memoryMax, diskMax, existing.count) + 1
        let endNumber = startNumber + resolved.count - 1
        let newTotal = max(endNumber, memoryMax, diskMax, existing.count + resolved.count)

        emit(.message("Preparing \(totalSlots) slot\(totalSlots == 1 ? "" : "s")…"))
        emit(.fraction(0))

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
            progress: { progress?($0); onEvent?(.message($0)) }
        )

        let updatedExisting: [GameEntry] = existing.enumerated().map { index, game in
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
        emit(.existingUpdated(updatedExisting))

        var added: [GameEntry] = []
        added.reserveCapacity(resolved.count)
        var nextNumber = startNumber
        // Re-read after renumber so free-slot search sees final names.
        var occupied = try occupiedSlotNumbers(on: rootURL)

        /// One on-card slot ready for hash + byte-weighted copy.
        struct PreparedSlot {
            var source: DiscImportSource
            var dest: URL
            var entryID: UUID
            var number: Int
            var imageName: String
            var preferred: String
            var willRenameSingle: Bool
            var format: DiscFormat
            var provisionalName: String
            var files: [(from: URL, to: URL, name: String, size: Int64)]
        }

        // Prepare every slot first so we can size-weight the whole import (not equal per file/slot).
        var prepared: [PreparedSlot] = []
        prepared.reserveCapacity(resolved.count)
        for source in resolved {
            while occupied.contains(nextNumber) {
                nextNumber += 1
            }
            let number = nextNumber
            nextNumber += 1
            let widthMax = max(newTotal, number, occupied.max() ?? 0)
            let folderName = FolderNumbering.format(number, maxNumber: widthMax)
            var imageName = source.imageFileName
            let preferred = preferredImageName(for: source.imageFileName)
            let willRenameSingle = source.fileNames?.count == 1 && preferred != source.imageFileName
            if willRenameSingle {
                imageName = preferred
            }
            let format = discFormat(for: imageName)
            let provisionalName = importDisplayName(source: source, ip: nil).name
            let entryID = UUID()
            let dest = rootURL.appendingPathComponent(folderName, isDirectory: true)
            if fm.fileExists(atPath: dest.path) {
                throw OperationError.destinationExists(folderName)
            }
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            occupied.insert(number)
            try provisionalName.write(
                to: dest.appendingPathComponent(nameFile),
                atomically: true,
                encoding: .utf8
            )
            let files = try packageCopyPlan(source: source, dest: dest)
            prepared.append(
                PreparedSlot(
                    source: source,
                    dest: dest,
                    entryID: entryID,
                    number: number,
                    imageName: imageName,
                    preferred: preferred,
                    willRenameSingle: willRenameSingle,
                    format: format,
                    provisionalName: provisionalName,
                    files: files
                )
            )

            let provisional = GameEntry(
                id: entryID,
                number: number,
                name: provisionalName,
                serial: "",
                format: format,
                imageFileName: imageName,
                folderPath: dest.path,
                byteSize: 0,
                payloadByteSize: 0,
                contentSHA256: nil,
                isMenu: false,
                detailsLoaded: false
            )
            emit(.slotPrepared(provisional))
        }

        // Time-weighted progress from remembered transfer rates: each file is one chunk
        // weighted by its estimated copy time (size ÷ card write rate), and each slot gets
        // a trailing hash unit (payload ÷ hash rate) so finalize crawls instead of stalling
        // at 99%. Markers sit at file completions only; every file keeps a ~2% floor so a
        // GDI's cue and small tracks stay visible next to a multi-GB track. The fill
        // advances in the same weighted space and reaches a notch exactly when its file
        // has fully landed — never before. Held ≤0.99 until the final full-width emit.
        struct ProgressUnit {
            var weight: Double
            /// File units end at a visible marker; hash units fill toward the next one.
            var isFile: Bool
        }
        let writeRate = max(rates.writeBytesPerSecond, 1)
        let hashRate = max(rates.hashBytesPerSecond, 1)
        var rawUnits: [ProgressUnit] = []
        for slot in prepared {
            for file in slot.files {
                rawUnits.append(.init(weight: Double(max(file.size, 1)) / writeRate, isFile: true))
            }
            let slotBytes = slot.files.reduce(Int64(0)) { $0 + max($1.size, 1) }
            rawUnits.append(.init(weight: Double(slotBytes) / hashRate, isFile: false))
        }
        let rawTotal = max(rawUnits.reduce(0) { $0 + $1.weight }, .ulpOfOne)
        let minMarkerWeight = rawTotal * 0.02
        let units = rawUnits.map {
            ProgressUnit(weight: $0.isFile ? max($0.weight, minMarkerWeight) : $0.weight, isFile: $0.isFile)
        }
        let totalWeight = max(units.reduce(0) { $0 + $1.weight }, .ulpOfOne)
        var cumulativeWeight = 0.0
        var segmentEnds: [Double] = []
        for unit in units {
            cumulativeWeight += unit.weight
            if unit.isFile {
                segmentEnds.append(min(1, cumulativeWeight / totalWeight))
            }
        }
        emit(.copyProgress(fraction: 0, segmentEnds: segmentEnds))

        var weightCompleted = 0.0
        var unitIndex = 0
        var lastEmittedFraction = -1.0

        /// Whole units done plus capped partial progress inside the active unit — the fill
        /// never crosses the active file’s notch before it completes.
        func emitCopyProgress(partialRatio: Double = 0, force: Bool = false) {
            let weight = unitIndex < units.count ? units[unitIndex].weight : 0
            let partial = min(max(partialRatio, 0), 1) * weight
            let fraction = min(0.99, (weightCompleted + partial) / totalWeight)
            if force || fraction - lastEmittedFraction >= 0.004 {
                lastEmittedFraction = fraction
                LaunchTrace.mark(String(
                    format: "import progress %.1f%% unit=%d partial=%.3f",
                    fraction * 100, unitIndex, partialRatio
                ))
                emit(.copyProgress(fraction: fraction, segmentEnds: segmentEnds))
            }
        }

        /// Advance the fill past the active unit (a finished file or a finished hash).
        func finishCurrentUnit() {
            if unitIndex < units.count {
                weightCompleted += units[unitIndex].weight
                LaunchTrace.mark(String(
                    format: "import marker %@ unit=%d reached at %.1f%%",
                    units[unitIndex].isFile ? "file" : "hash",
                    unitIndex,
                    min(1, weightCompleted / totalWeight) * 100
                ))
            }
            unitIndex += 1
            emitCopyProgress(force: true)
        }

        // Transfer samples for rate learning (returned in ImportResult).
        var copiedBytes: Int64 = 0
        var copySeconds = 0.0
        var hashedBytes: Int64 = 0
        var hashSeconds = 0.0

        // Names already on the card (case-insensitive). Auto-rename will not reuse them —
        // keeps beltrunner/shipplay/combat variants distinct when they share one IP product.
        var claimedDisplayNames = Set(
            updatedExisting.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )

        // Batch-aware: if several packages in this import would auto-rename to the *same*
        // GameDB / IP title (typical for test builds of one product), force source names
        // for every member of that collision set — not only the 2nd+ after sequential claim.
        var forceSourceNameIDs = Set<UUID>()
        if preferDatabaseNames, prepared.count > 1 {
            var preferredByID: [UUID: String] = [:]
            preferredByID.reserveCapacity(prepared.count)
            for slot in prepared {
                let ip = IpBinReader.read(
                    folderURL: slot.source.packageURL,
                    imageFileName: slot.source.imageFileName,
                    format: slot.format
                )
                let preferred = importDisplayName(
                    source: slot.source,
                    ip: ip,
                    preferDatabaseNames: true,
                    reservedNames: []
                ).name
                preferredByID[slot.entryID] = preferred
            }
            var counts: [String: Int] = [:]
            for name in preferredByID.values {
                counts[name.lowercased(), default: 0] += 1
            }
            for (id, name) in preferredByID {
                let key = name.lowercased()
                if counts[key, default: 0] > 1 || claimedDisplayNames.contains(key) {
                    forceSourceNameIDs.insert(id)
                }
            }
        }

        // Copy first (markers + mid-file fill). Hash on source after each package’s files land
        // so we never re-walk multi‑GB tracks on the card (`loadFolderDetails`).
        for (offset, slot) in prepared.enumerated() {
            emit(.slotActive(slot.entryID))
            var imageName = slot.imageName

            do {
                let fileCount = slot.files.count
                for (fileIndex, file) in slot.files.enumerated() {
                    let label = fileCount > 1
                        ? "Copying \(offset + 1)/\(totalSlots)… \(file.name) (\(fileIndex + 1)/\(fileCount))"
                        : "Copying \(offset + 1)/\(totalSlots)… \(slot.source.hintName)"
                    emit(.message(label))

                    let size = max(file.size, 1)
                    let copyStart = Date()
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: file.from.path, isDirectory: &isDir), isDir.boolValue {
                        try fm.copyItem(at: file.from, to: file.to)
                        copySeconds += Date().timeIntervalSince(copyStart)
                        copiedBytes += size
                        finishCurrentUnit()
                        continue
                    }

                    // Stream large tracks so the fill crawls inside this file's chunk.
                    try copyFile(from: file.from, to: file.to) { writtenInFile in
                        emitCopyProgress(partialRatio: Double(writtenInFile) / Double(size))
                    }
                    let copyElapsed = Date().timeIntervalSince(copyStart)
                    LaunchTrace.mark(String(
                        format: "import copy done %@ %lldB in %.2fs (%.1f MB/s)",
                        file.name, size, copyElapsed,
                        Double(size) / max(copyElapsed, 0.001) / 1_000_000
                    ))
                    copySeconds += copyElapsed
                    copiedBytes += size
                    finishCurrentUnit()
                }

                if slot.willRenameSingle {
                    let from = slot.dest.appendingPathComponent(slot.source.imageFileName)
                    let to = slot.dest.appendingPathComponent(slot.preferred)
                    if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
                        try? fm.moveItem(at: from, to: to)
                        imageName = slot.preferred
                    }
                }

                // Hold at ≤0.99 (after last track) while hash / name / serial run.
                emit(.message("Finalizing \(offset + 1)/\(totalSlots)… \(slot.source.hintName)"))

                var contentHash: String?
                var payloadSize: Int64 = slot.files.reduce(Int64(0)) { $0 + $1.size }
                if let sources = try? payloadSourcesForImport(
                    source: slot.source,
                    destImageName: imageName
                ), !sources.isEmpty {
                    // Still hash on the *source* volume (usually faster than the SD card).
                    let expectedHashBytes = max(payloadSize, 1)
                    let hashStart = Date()
                    if let computed = try? ContentHashSidecar.compute(sources: sources, onBytes: { hashed in
                        emitCopyProgress(partialRatio: Double(hashed) / Double(expectedHashBytes))
                    }) {
                        hashSeconds += Date().timeIntervalSince(hashStart)
                        hashedBytes += computed.payloadSize
                        try? ContentHashSidecar.write(computed, to: slot.dest)
                        contentHash = computed.sha256
                        payloadSize = computed.payloadSize
                    }
                }
                // The slot's hash unit is done (or skipped) — step to the next unit either way.
                finishCurrentUnit()

                let ip = IpBinReader.read(
                    folderURL: slot.dest,
                    imageFileName: imageName,
                    format: slot.format
                )
                let useDatabaseName = preferDatabaseNames && !forceSourceNameIDs.contains(slot.entryID)
                let resolvedName = importDisplayName(
                    source: slot.source,
                    ip: ip,
                    preferDatabaseNames: useDatabaseName,
                    reservedNames: claimedDisplayNames
                )
                claimedDisplayNames.insert(resolvedName.name.lowercased())

                try resolvedName.name.write(
                    to: slot.dest.appendingPathComponent(nameFile),
                    atomically: true,
                    encoding: .utf8
                )
                if !resolvedName.serial.isEmpty {
                    try resolvedName.serial.write(
                        to: slot.dest.appendingPathComponent(serialFile),
                        atomically: true,
                        encoding: .utf8
                    )
                }

                // Prefer sizes we already measured — skip loadFolderDetails (slow FAT walk).
                // Cache IP.BIN now so the next menu rebuild skips a per-track GDI read.
                let entry = GameEntry(
                    id: slot.entryID,
                    number: slot.number,
                    name: resolvedName.name,
                    serial: resolvedName.serial,
                    format: slot.format,
                    imageFileName: imageName,
                    folderPath: slot.dest.path,
                    byteSize: payloadSize,
                    payloadByteSize: payloadSize,
                    contentSHA256: contentHash,
                    isMenu: false,
                    detailsLoaded: contentHash != nil,
                    ipHeader: ip
                )
                added.append(entry)
                emit(.slotFinished(entry))
            } catch {
                try? fm.removeItem(at: slot.dest)
                occupied.remove(slot.number)
                emit(.slotFailed(slot.entryID))
                throw error
            }
        }

        emit(.copyProgress(fraction: 1, segmentEnds: segmentEnds))
        emit(.message("Added \(added.count) game\(added.count == 1 ? "" : "s")"))
        return ImportResult(
            games: updatedExisting + added,
            added: added,
            skipped: skipped,
            copiedBytes: copiedBytes,
            copySeconds: copySeconds,
            hashedBytes: hashedBytes,
            hashSeconds: hashSeconds
        )
    }

    // MARK: - Import resolve (grouping + GDI + zip)

    /// Result of turning dropped/picked URLs into copyable packages.
    struct ImportDiscovery: Sendable {
        var sources: [DiscImportSource]
        var skipped: [(url: URL, reason: String)]
        /// Temp extract roots (zip) — caller must delete after import.
        var temporaryRoots: [URL]
    }

    /// Resolve one or many selection URLs: multi-select GDI/CCD sets, folders, images, `.zip`.
    nonisolated static func resolveImportSources(_ urls: [URL]) -> ImportDiscovery {
        var sources: [DiscImportSource] = []
        var skipped: [(URL, String)] = []
        var temporaryRoots: [URL] = []
        var looseFiles: [URL] = []

        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "zip" {
                do {
                    let extracted = try extractZipForImport(url)
                    temporaryRoots.append(extracted)
                    let found = discoverPackages(under: extracted, depth: 0)
                    if found.isEmpty {
                        skipped.append((url, "No disc image found inside archive"))
                    } else {
                        sources.append(contentsOf: found)
                    }
                } catch {
                    skipped.append((url, error.localizedDescription))
                }
                continue
            }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                skipped.append((url, OperationError.importUnreadable(url.lastPathComponent).localizedDescription))
                continue
            }
            if isDir.boolValue {
                do {
                    sources.append(try resolveImportSource(url))
                } catch {
                    // Nested packages (e.g. folder of game folders).
                    let nested = discoverPackages(under: url, depth: 0)
                    if nested.isEmpty {
                        skipped.append((url, error.localizedDescription))
                    } else {
                        sources.append(contentsOf: nested)
                    }
                }
            } else {
                looseFiles.append(url)
            }
        }

        let grouped = groupLooseImportFiles(looseFiles)
        sources.append(contentsOf: grouped.sources)
        skipped.append(contentsOf: grouped.skipped)

        return ImportDiscovery(sources: sources, skipped: skipped, temporaryRoots: temporaryRoots)
    }

    /// Turn a user-selected file or folder into a copyable disc package.
    nonisolated static func resolveImportSource(_ url: URL) throws -> DiscImportSource {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw OperationError.importUnreadable(url.lastPathComponent)
        }

        if isDir.boolValue {
            return try resolveFolderPackage(url)
        }

        let ext = url.pathExtension.lowercased()
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent

        switch ext {
        case "gdi":
            return try resolveGDIPackage(gdiURL: url)
        case "cdi":
            return DiscImportSource(
                packageURL: parent.standardizedFileURL,
                fileNames: [name],
                imageFileName: name,
                hintName: (name as NSString).deletingPathExtension
            )
        case "ccd":
            return resolveCCDPackage(ccdURL: url)
        case "zip":
            // Use `resolveImportSources` so the extract temp is cleaned up after import.
            throw OperationError.importUnsupported(url.lastPathComponent)
        default:
            throw OperationError.importUnsupported(url.lastPathComponent)
        }
    }

    /// Folder that already looks like a GDEMU game package.
    nonisolated private static func resolveFolderPackage(_ url: URL) throws -> DiscImportSource {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: url.path)
            .filter { !$0.hasPrefix(".") }
        guard let image = detectImageName(in: names) else {
            throw OperationError.importNoDiscImage(url.lastPathComponent)
        }
        let ext = (image as NSString).pathExtension.lowercased()
        switch ext {
        case "gdi":
            let gdiURL = url.appendingPathComponent(image)
            var source = try resolveGDIPackage(gdiURL: gdiURL)
            // Prefer folder name for display when the package is a game folder.
            source.hintName = url.lastPathComponent
            return source
        case "ccd":
            var source = resolveCCDPackage(ccdURL: url.appendingPathComponent(image))
            source.hintName = url.lastPathComponent
            return source
        case "cdi":
            return DiscImportSource(
                packageURL: url.standardizedFileURL,
                fileNames: [image],
                imageFileName: image,
                hintName: url.lastPathComponent
            )
        default:
            return DiscImportSource(
                packageURL: url.standardizedFileURL,
                fileNames: nil,
                imageFileName: image,
                hintName: url.lastPathComponent
            )
        }
    }

    /// GDI cue + only the track files it names (not the whole parent directory).
    nonisolated static func resolveGDIPackage(gdiURL: URL) throws -> DiscImportSource {
        let fm = FileManager.default
        guard fm.fileExists(atPath: gdiURL.path) else {
            throw OperationError.importUnreadable(gdiURL.lastPathComponent)
        }
        let parent = gdiURL.deletingLastPathComponent()
        let gdiName = gdiURL.lastPathComponent
        let text = (try? String(contentsOf: gdiURL, encoding: .utf8))
            ?? (try? String(contentsOf: gdiURL, encoding: .isoLatin1))
            ?? ""
        let tracks = gdiReferencedFileNames(in: text)
        var files: [String] = [gdiName]
        var missing: [String] = []
        for track in tracks {
            let path = parent.appendingPathComponent(track).path
            if fm.fileExists(atPath: path) {
                if !files.contains(track) { files.append(track) }
            } else {
                missing.append(track)
            }
        }
        // Fall back: if the cue listed nothing parseable, copy siblings that look like tracks
        // only when the cue was empty of names — never dump the whole parent.
        if tracks.isEmpty {
            let siblings = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
            for name in siblings where !name.hasPrefix(".") {
                let ext = (name as NSString).pathExtension.lowercased()
                if ["bin", "raw", "iso", "img"].contains(ext), !files.contains(name) {
                    files.append(name)
                }
            }
        } else if files.count == 1, !missing.isEmpty {
            throw OperationError.importMissingTracks(gdiName, missing)
        }

        return DiscImportSource(
            packageURL: parent.standardizedFileURL,
            fileNames: files,
            imageFileName: gdiName,
            hintName: (gdiName as NSString).deletingPathExtension
        )
    }

    /// CloneCCD-style: `.ccd` + matching `.img` / `.sub` / `.cue` when present.
    nonisolated static func resolveCCDPackage(ccdURL: URL) -> DiscImportSource {
        let fm = FileManager.default
        let parent = ccdURL.deletingLastPathComponent()
        let name = ccdURL.lastPathComponent
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
    }

    /// Parse track file names from a `.gdi` cue (shared Redump-aware parser).
    nonisolated static func gdiReferencedFileNames(in text: String) -> [String] {
        GdiCue.referencedFileNames(in: text)
    }

    /// Multi-select Finder drop: group files that form one or more disc packages.
    nonisolated private static func groupLooseImportFiles(
        _ urls: [URL]
    ) -> (sources: [DiscImportSource], skipped: [(URL, String)]) {
        guard !urls.isEmpty else { return ([], []) }

        var sources: [DiscImportSource] = []
        var skipped: [(URL, String)] = []
        var claimed = Set<String>() // standardized paths claimed by a package

        // Group by parent directory so multi-select from one folder becomes one+ packages.
        var byParent: [String: [URL]] = [:]
        for url in urls {
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            byParent[parent, default: []].append(url)
        }

        for (_, files) in byParent {
            // GDI packages first (each cue owns its tracks).
            let gdis = files.filter { $0.pathExtension.lowercased() == "gdi" }
            for gdi in gdis {
                do {
                    let source = try resolveGDIPackage(gdiURL: gdi)
                    sources.append(source)
                    claimed.insert(gdi.standardizedFileURL.path)
                    for name in source.fileNames ?? [] {
                        let path = gdi.deletingLastPathComponent()
                            .appendingPathComponent(name)
                            .standardizedFileURL.path
                        claimed.insert(path)
                    }
                } catch {
                    skipped.append((gdi, error.localizedDescription))
                    claimed.insert(gdi.standardizedFileURL.path)
                }
            }

            // CCD packages.
            let ccds = files.filter { $0.pathExtension.lowercased() == "ccd" }
            for ccd in ccds {
                let path = ccd.standardizedFileURL.path
                if claimed.contains(path) { continue }
                let source = resolveCCDPackage(ccdURL: ccd)
                sources.append(source)
                claimed.insert(path)
                for name in source.fileNames ?? [] {
                    let p = ccd.deletingLastPathComponent()
                        .appendingPathComponent(name)
                        .standardizedFileURL.path
                    claimed.insert(p)
                }
            }

            // Lone CDIs.
            for cdi in files where cdi.pathExtension.lowercased() == "cdi" {
                let path = cdi.standardizedFileURL.path
                if claimed.contains(path) { continue }
                do {
                    sources.append(try resolveImportSource(cdi))
                    claimed.insert(path)
                } catch {
                    skipped.append((cdi, error.localizedDescription))
                    claimed.insert(path)
                }
            }

            // Leftover files (tracks without a cue, random docs, etc.).
            for url in files {
                let path = url.standardizedFileURL.path
                if claimed.contains(path) { continue }
                let ext = url.pathExtension.lowercased()
                if ["bin", "raw", "iso", "img", "sub", "cue"].contains(ext) {
                    skipped.append((
                        url,
                        "Track/companion file needs its .gdi or .ccd (select the cue with the tracks)"
                    ))
                } else {
                    skipped.append((
                        url,
                        OperationError.importUnsupported(url.lastPathComponent).localizedDescription
                    ))
                }
                claimed.insert(path)
            }
        }

        return (sources, skipped)
    }

    /// Walk a directory tree (bounded depth) for importable packages — used after zip extract.
    nonisolated private static func discoverPackages(under root: URL, depth: Int) -> [DiscImportSource] {
        guard depth < 4 else { return [] }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var sources: [DiscImportSource] = []
        var looseFiles: [URL] = []

        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                if let pkg = try? resolveFolderPackage(child) {
                    sources.append(pkg)
                } else {
                    sources.append(contentsOf: discoverPackages(under: child, depth: depth + 1))
                }
            } else if child.pathExtension.lowercased() == "zip" {
                // Nested zip: extract under this root so outer import cleanup removes it.
                let nested = root.appendingPathComponent(
                    ".katana-nested-\(UUID().uuidString)",
                    isDirectory: true
                )
                if (try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)) != nil,
                   (try? ZipExtractor.extract(zipURL: child, to: nested)) != nil
                {
                    sources.append(contentsOf: discoverPackages(under: nested, depth: depth + 1))
                }
            } else {
                looseFiles.append(child)
            }
        }

        let grouped = groupLooseImportFiles(looseFiles)
        sources.append(contentsOf: grouped.sources)
        return sources
    }

    nonisolated private static func extractZipForImport(_ zipURL: URL) throws -> URL {
        let fm = FileManager.default
        let dest = fm.temporaryDirectory
            .appendingPathComponent("katana-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            try ZipExtractor.extract(zipURL: zipURL, to: dest)
        } catch {
            try? fm.removeItem(at: dest)
            throw OperationError.importArchiveFailed(zipURL.lastPathComponent, error.localizedDescription)
        }
        return dest
    }

    /// Payload files to hash for import, using **destination** names and **source** content paths.
    nonisolated private static func payloadSourcesForImport(
        source: DiscImportSource,
        destImageName: String
    ) throws -> [ContentHashSidecar.PayloadSource] {
        let fm = FileManager.default
        let names: [String]
        if let fileNames = source.fileNames {
            names = fileNames
        } else {
            names = try fm.contentsOfDirectory(atPath: source.packageURL.path)
                .filter { !$0.hasPrefix(".") }
                .filter { $0 != trashFolderName && $0 != tmpFolderName }
        }

        var sources: [ContentHashSidecar.PayloadSource] = []
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            guard ContentHashSidecar.payloadExtensions.contains(ext) else { continue }
            let content = source.packageURL.appendingPathComponent(name)
            guard fm.fileExists(atPath: content.path) else { continue }
            // Single-image imports may land as disc.gdi / disc.cdi / disc.ccd.
            let canonical = (name == source.imageFileName) ? destImageName : name
            sources.append(.init(name: canonical, contentURL: content))
        }
        return sources
    }

    /// Files to copy for a package, with on-disk sizes for byte-weighted progress.
    /// Always expands to **leaf files** so folder drops get per-file segment markers.
    nonisolated private static func packageCopyPlan(
        source: DiscImportSource,
        dest: URL
    ) throws -> [(from: URL, to: URL, name: String, size: Int64)] {
        let fm = FileManager.default
        var pairs: [(from: URL, to: URL, name: String)] = []

        if let fileNames = source.fileNames {
            for name in fileNames {
                let from = source.packageURL.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else {
                    throw OperationError.importUnreadable(name)
                }
                pairs.append((from, dest.appendingPathComponent(name), name))
            }
        } else {
            // Flatten package folder → regular files only (skip nested trash/tmp).
            let names = try fm.contentsOfDirectory(atPath: source.packageURL.path)
                .filter { !$0.hasPrefix(".") }
                .filter { $0 != trashFolderName && $0 != tmpFolderName }
                .sorted()
            for name in names {
                let from = source.packageURL.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: from.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    // One-level expand (unusual for GDEMU packages).
                    let kids = (try? fm.contentsOfDirectory(atPath: from.path)) ?? []
                    for kid in kids where !kid.hasPrefix(".") {
                        let childFrom = from.appendingPathComponent(kid)
                        var childDir: ObjCBool = false
                        guard fm.fileExists(atPath: childFrom.path, isDirectory: &childDir),
                              !childDir.boolValue
                        else { continue }
                        let rel = "\(name)/\(kid)"
                        pairs.append((
                            childFrom,
                            dest.appendingPathComponent(name).appendingPathComponent(kid),
                            rel
                        ))
                    }
                } else {
                    pairs.append((from, dest.appendingPathComponent(name), name))
                }
            }
        }

        return pairs.map { pair in
            let size = fileByteSize(at: pair.from)
            return (pair.from, pair.to, pair.name, max(size, 1))
        }
    }

    nonisolated private static func fileByteSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // Directory packages: sum regular files one level deep (good enough for progress).
            let kids = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            return kids.reduce(Int64(0)) { sum, name in
                let child = url.appendingPathComponent(name)
                let s = (try? fm.attributesOfItem(atPath: child.path)[.size] as? Int64) ?? 0
                return sum + max(0, s)
            }
        }
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize
        {
            return Int64(size)
        }
        return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    /// Stream a file copy in chunks, reporting written bytes (`FileManager.copyItem` is opaque).
    /// Stream one file onto the card with uncached writes (honest progress, no close-drain).
    /// Shared with menu install — any bulk write to the card should come through here.
    nonisolated static func copyFile(
        from source: URL,
        to dest: URL,
        onProgress: (_ bytesWrittenInFile: Int64) -> Void = { _ in }
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        fm.createFile(atPath: dest.path, contents: nil)
        let reader = try FileHandle(forReadingFrom: source)
        let writer = try FileHandle(forWritingTo: dest)
        // Bypass the page cache on the card side: without this, macOS absorbs ~500 MB of a
        // large track at RAM speed (progress races ahead), then close() blocks for the whole
        // drain (bar pinned at the file's marker). Uncached, write() runs at true card speed
        // so byte counts — and the learned write rate — track physical progress.
        // (Reader stays cached: the hash pass re-reads the same source bytes right after.)
        _ = fcntl(writer.fileDescriptor, F_NOCACHE, 1)
        defer {
            try? reader.close()
            try? writer.close()
        }

        let chunkSize = 512 * 1024
        var written: Int64 = 0
        while true {
            let data: Data
            do {
                guard let chunk = try reader.read(upToCount: chunkSize) else { break }
                if chunk.isEmpty { break }
                data = chunk
            } catch {
                throw OperationError.importUnreadable(source.lastPathComponent)
            }
            do {
                try writer.write(contentsOf: data)
            } catch {
                throw OperationError.importUnreadable(dest.lastPathComponent)
            }
            written += Int64(data.count)
            onProgress(written)
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
    /// With `preferDatabaseNames`, that order flips: GameDB title (looked up by the IP.BIN
    /// serial) → IP.BIN product name → source file / folder — **unless** the source label is a
    /// distinctive build/variant name (`beltrunner-shipplay-f64-dc`), in which case the source
    /// wins so test images with unique serials but the same product title stay distinct.
    ///
    /// - Parameter reservedNames: case-insensitive names already on the card or claimed
    ///   earlier in this import. When auto-rename would reuse one of these, falls back to
    ///   the source name.
    nonisolated static func importDisplayName(
        source: DiscImportSource,
        ip: IpBinInfo?,
        preferDatabaseNames: Bool = false,
        reservedNames: Set<String> = []
    ) -> (name: String, serial: String) {
        let serial = ip?.productNumber.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reserved = Set(reservedNames.map { $0.lowercased() })
        let sourceLabel = sourceDisplayLabel(for: source)

        if preferDatabaseNames {
            var dbName: String?
            if let title = GameDatabase.title(for: serial) {
                dbName = title
            } else if let raw = ip?.name.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                dbName = raw.localizedCapitalized
            }
            if let dbName, !dbName.isEmpty {
                // Variant filenames (hyphen/underscore builds) beat a short shared product title.
                if let sourceLabel, prefersSourceLabel(sourceLabel, overDatabaseName: dbName) {
                    return (sourceLabel, serial)
                }
                if !reserved.contains(dbName.lowercased()) {
                    return (dbName, serial)
                }
                // Collision — keep going for source-based name.
            }
        }

        if let sourceLabel {
            return (sourceLabel, serial)
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

    /// File base name, or package folder name when the image is a generic `disc.*`.
    nonisolated static func sourceDisplayLabel(for source: DiscImportSource) -> String? {
        let fileBase = (source.imageFileName as NSString)
            .deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !fileBase.isEmpty, fileBase.lowercased() != "disc" {
            return fileBase
        }
        let hint = source.hintName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty, FolderNumbering.parse(hint) == nil {
            return hint
        }
        return nil
    }

    /// True when the source looks like a build/variant id rather than a plain retail title.
    /// e.g. `beltrunner-shipplay-f64-dc` over generic `Beltrunner`.
    nonisolated static func prefersSourceLabel(_ source: String, overDatabaseName database: String) -> Bool {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = database.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !d.isEmpty else { return false }
        if s.compare(d, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return false
        }
        // Hyphen / underscore tokens are almost always build tags (f32/f64, shipplay, busy4…).
        if s.contains("-") || s.contains("_") {
            return true
        }
        // Substantially longer than the catalog title → extra detail worth keeping.
        if s.count >= d.count + 4 {
            return true
        }
        return false
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
        progress: (@Sendable (String) -> Void)? = nil,
        fractionProgress: (@Sendable (Double) -> Void)? = nil
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
            // Stay under `rootURL` so sandbox security scope is preserved.
            let from = scopedFolderURL(path: path, under: rootURL)
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
                fractionProgress?(Double(index + 1) / Double(ordered.count))
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
                let from = scopedFolderURL(path: path, under: rootURL)
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
                fractionProgress?(0.5 * Double(index + 1) / Double(max(phaseMoves.count, 1)))
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
                fractionProgress?(0.5 + 0.5 * Double(index + 1) / Double(max(phaseMoves.count, 1)))
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

    /// Folder URL under a security-scoped card root (App Sandbox).
    ///
    /// `URL(fileURLWithPath: game.folderPath)` drops security scope even when the path
    /// is the same as a scoped volume — all card mutations must go through `rootURL`
    /// + last path component instead.
    nonisolated static func scopedFolderURL(for game: GameEntry, under rootURL: URL?) -> URL {
        scopedFolderURL(path: game.folderPath, under: rootURL)
    }

    nonisolated static func scopedFolderURL(path: String, under rootURL: URL?) -> URL {
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        if let rootURL {
            return rootURL.appendingPathComponent(name, isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
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

/// Thread-safe byte progress for permanent delete (avoids mutating captured `var` in Sendable closures).
/// `nonisolated` opts out of default MainActor isolation (delete runs off the main actor).
private nonisolated final class ProgressByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    private let total: Int64
    private let report: (@Sendable (Double) -> Void)?

    init(total: Int64, report: (@Sendable (Double) -> Void)?) {
        self.total = max(1, total)
        self.report = report
    }

    var completed: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func add(_ bytes: Int64) {
        lock.lock()
        value += max(0, bytes)
        let frac = min(1, Double(value) / Double(total))
        lock.unlock()
        report?(frac)
    }

    func report(_ absoluteCompleted: Int64) {
        lock.lock()
        value = max(value, absoluteCompleted)
        let frac = min(1, Double(value) / Double(total))
        lock.unlock()
        report?(frac)
    }
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
    case importMissingTracks(String, [String])
    case importArchiveFailed(String, String)

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
            return "Unsupported file “\(name)”. Choose a disc image (.gdi / .cdi / .ccd), .zip, or a game folder."
        case .importUnreadable(let name):
            return "Cannot read “\(name)”."
        case .importMissingTracks(let gdi, let tracks):
            let list = tracks.prefix(4).joined(separator: ", ")
            let more = tracks.count > 4 ? "…" : ""
            let plural = tracks.count == 1 ? "" : "s"
            return "“\(gdi)” is missing track file\(plural): \(list)\(more)."
        case .importArchiveFailed(let name, let reason):
            return "Could not open archive “\(name)”: \(reason)"
        }
    }
}
