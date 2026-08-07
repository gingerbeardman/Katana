import AppKit
import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class AppState {
    var volume: CardVolume?
    var games: [GameEntry] = []
    /// Multi-select (⌘/⇧ click). Empty when nothing selected.
    var selection: Set<GameEntry.ID> = []
    var searchText: String = ""
    /// When true, list only games that share a serial (or name) with another.
    var showDuplicatesOnly: Bool = false
    /// When true, show grade badges (Exact 1/2, …) on titles in the table. Default off.
    var showDuplicateMarkers: Bool = UserDefaults.standard.bool(forKey: AppState.showDuplicateMarkersKey) {
        didSet {
            UserDefaults.standard.set(showDuplicateMarkers, forKey: AppState.showDuplicateMarkersKey)
        }
    }
    /// When true, eject the open SD card on app quit. Default off.
    var ejectOnQuit: Bool = UserDefaults.standard.bool(forKey: AppState.ejectOnQuitKey) {
        didSet {
            UserDefaults.standard.set(ejectOnQuit, forKey: AppState.ejectOnQuitKey)
        }
    }
    var isScanning = false
    /// Trailing inspector visibility (standard macOS `.inspector`).
    var isInspectorPresented: Bool = true
    /// Bumped to focus the name field in the inspector (e.g. Rename…).
    var focusNameFieldToken: Int = 0
    /// Non-nil while a disk mutation runs (renumber, copy, delete).
    var busyMessage: String?
    /// Live scan progress for the status line / table chrome (`nil` when idle).
    var scanProgress: (completed: Int, total: Int)?
    var statusText: String = "Open a GDEMU SD card to begin."
    /// Transient status toast — auto-clears; never a modal.
    var flashMessage: String?
    var lastError: String?
    var lastScanStats: String?
    /// Recently opened cards (sidebar).
    var recentVolumes: [RememberedVolume] = []
    /// View-only table sort for the open card (persisted per volume UUID).
    var displaySort: DisplaySortPreference = .mostRecentFirst
    /// Which console menu image to bake (GDmenu or openMenu). Persisted per volume.
    var menuKind: MenuKind = .gdMenu
    /// True when disc names/order changed since the last menu GDI bake.
    /// Quit prompts to rebuild (then optionally ejects and exits).
    private(set) var menuNeedsRebuild: Bool = false

    let undoManager = UndoManager()

    private var bookmarkData: Data?
    private var accessURL: URL?
    private var flashTask: Task<Void, Never>?
    private var didAttemptRestore = false
    /// Set while a quit-time rebuild/eject is in progress (avoids re-entrancy).
    private var isHandlingQuit = false
    /// Background fill of folder sizes / stored hashes after a fast scan.
    private var detailEnrichmentTask: Task<Void, Never>?
    private var detailEnrichmentGeneration: UInt64 = 0

    private static let showDuplicateMarkersKey = "showDuplicateMarkers"
    private static let ejectOnQuitKey = "ejectOnQuit"

    var isBusy: Bool { isScanning || busyMessage != nil }

    /// List-row badge when markers are enabled and this id is in a group.
    func listDuplicateBadge(for id: GameEntry.ID) -> DuplicateInfo? {
        guard showDuplicateMarkers else { return nil }
        return duplicateInfoByID[id]
    }

    /// Cached duplicate map — recomputed off the main actor when `games` changes.
    private(set) var duplicateInfoByID: [GameEntry.ID: DuplicateInfo] = [:]
    private var duplicateRecomputeGeneration: UInt64 = 0

    var duplicateGameCount: Int {
        duplicateInfoByID.count
    }

    var duplicateGroupCount: Int {
        Set(duplicateInfoByID.values.map(\.groupKey)).count
    }

    var redundantDuplicateCount: Int {
        duplicateInfoByID.values.filter(\.isRedundant).count
    }

    var exactDuplicateCount: Int {
        duplicateInfoByID.values.filter { $0.grade == .exact }.count
    }

    var hashingPendingCount: Int {
        hashingProgress?.pendingCount ?? 0
    }

    /// Owned by AppState so SwiftUI observes start/stop (ContentHashService is not Observable).
    private(set) var isHashingActive: Bool = false

    var isHashing: Bool {
        isHashingActive || isStoppingHashing
    }

    /// True after Stop is pressed until the in-flight file finishes hashing.
    private(set) var isStoppingHashing: Bool = false

    var canStopHashing: Bool {
        isHashingActive && !isStoppingHashing
    }

    /// Folder path currently being hashed (for per-row spinner). `nil` when idle.
    private(set) var hashingFolderPath: String?
    /// Live remaining-bytes / rate / ETA for the active hash run.
    private(set) var hashingProgress: HashingProgress?

    /// Sidebar status while hashing (count, throughput, ETA once known).
    var hashingStatusText: String {
        if isStoppingHashing {
            return "Stopping… finishing current file"
        }
        guard let progress = hashingProgress else {
            return "Hashing…"
        }
        var parts: [String] = ["\(progress.pendingCount) left"]
        if progress.remainingBytes > 0 {
            parts.append(ByteCount.string(for: progress.remainingBytes))
        }
        if let bps = progress.bytesPerSecond {
            parts.append(ByteCount.throughput(bytesPerSecond: bps))
        }
        if let eta = progress.etaSeconds {
            parts.append(ByteCount.etaString(seconds: eta))
        } else if progress.completedCount == 0 {
            parts.append("estimating…")
        }
        return "Hashing… " + parts.joined(separator: " · ")
    }

    func isHashingGame(_ game: GameEntry) -> Bool {
        guard let hashingFolderPath else { return false }
        return game.folderPath == hashingFolderPath
    }

    var filteredGames: [GameEntry] {
        var list = games

        if showDuplicatesOnly {
            let dupIDs = Set(duplicateInfoByID.keys)
            list = list.filter { dupIDs.contains($0.id) }
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return list }
        let maxN = games.last?.number ?? 1
        return list.filter { game in
            game.name.localizedCaseInsensitiveContains(q)
                || game.serial.localizedCaseInsensitiveContains(q)
                || FolderNumbering.format(game.number, maxNumber: maxN).contains(q)
                || game.format.displayName.localizedCaseInsensitiveContains(q)
        }
    }

    func duplicateInfo(for id: GameEntry.ID) -> DuplicateInfo? {
        duplicateInfoByID[id]
    }

    /// Selected games in list order (by slot number).
    var selectedGames: [GameEntry] {
        games.filter { selection.contains($0.id) }
    }

    /// Single-selection convenience (nil if 0 or 2+ selected).
    var selectedGame: GameEntry? {
        let selected = selectedGames
        return selected.count == 1 ? selected[0] : nil
    }

    var selectedIndices: [Int] {
        games.indices.filter { selection.contains(games[$0].id) }
    }

    var totalBytes: Int64 {
        games.reduce(0) { $0 + $1.byteSize }
    }

    var selectedBytes: Int64 {
        selectedGames.reduce(0) { $0 + $1.byteSize }
    }

    var canEject: Bool { volume != nil && !isBusy }

    var canDeleteSelection: Bool { !selection.isEmpty && !isBusy }

    var canMoveSelectionUp: Bool {
        guard !isBusy, let first = selectedIndices.first else { return false }
        return first > 0
    }

    var canMoveSelectionDown: Bool {
        guard !isBusy, let last = selectedIndices.last else { return false }
        return last < games.count - 1
    }

    func focusRenameInInspector(for id: UUID? = nil) {
        if let id {
            selection = [id]
        }
        isInspectorPresented = true
        if selection.count == 1 {
            focusNameFieldToken &+= 1
        }
    }

    func selectOnly(_ id: GameEntry.ID) {
        selection = [id]
        isInspectorPresented = true
    }

    func selectAllDuplicates() {
        selection = DuplicateDetector.allDuplicateIDs(in: games)
        if !selection.isEmpty {
            isInspectorPresented = true
            showDuplicatesOnly = true
            flash("\(selection.count) games in \(duplicateGroupCount) duplicate groups")
        } else {
            flash("No duplicates found")
        }
    }

    /// Select every copy except the lowest slot number in each group (safe delete targets).
    func selectRedundantDuplicates(minimumGrade: DuplicateGrade = .weak) {
        selection = DuplicateDetector.redundantIDs(in: games, minimumGrade: minimumGrade)
        if !selection.isEmpty {
            isInspectorPresented = true
            showDuplicatesOnly = true
            let label = minimumGrade == .weak ? "redundant" : "\(minimumGrade.label.lowercased()) extras"
            flash("\(selection.count) \(label) selected (kept first of each)")
        } else {
            flash("No redundant copies")
        }
    }

    func selectExactRedundantDuplicates() {
        selectRedundantDuplicates(minimumGrade: .exact)
    }

    /// Games still without a content hash (for UI).
    var unhashedGameCount: Int {
        games.filter { !$0.isMenu && !$0.hasContentHash }.count
    }

    /// User-initiated: compute missing content hashes in the background (never automatic).
    func startContentHashing() {
        guard !isBusy, volume != nil, !isHashing else { return }
        let missing = unhashedGameCount
        guard missing > 0 else {
            flash("All games already have hashes")
            return
        }

        // Flip before any async work so the button disables / UI swaps on this click.
        isStoppingHashing = false
        isHashingActive = true
        hashingProgress = nil
        ContentHashService.shared.onCurrentFolderChanged = { [weak self] path in
            self?.hashingFolderPath = path
        }
        ContentHashService.shared.onHashed = { [weak self] path, sha, payloadSize in
            guard let self else { return }
            guard let idx = self.games.firstIndex(where: { $0.folderPath == path }) else { return }
            self.games[idx].contentSHA256 = sha
            self.games[idx].payloadByteSize = payloadSize
            self.scheduleDuplicateRecompute()
            self.invalidateCacheAsync()
        }
        ContentHashService.shared.onProgress = { [weak self] progress in
            self?.hashingProgress = progress
        }
        ContentHashService.shared.onFinished = { [weak self] in
            guard let self else { return }
            self.isStoppingHashing = false
            self.isHashingActive = false
            self.hashingFolderPath = nil
            self.hashingProgress = nil
        }
        ContentHashService.shared.startFilling(games: games)
        hashingFolderPath = ContentHashService.shared.currentFolderPath
        hashingProgress = ContentHashService.shared.progress
        let remaining = hashingProgress?.remainingBytes ?? 0
        if remaining > 0 {
            flash("Hashing \(missing) games · \(ByteCount.string(for: remaining))")
        } else {
            flash("Hashing \(missing) games…")
        }
    }

    func stopContentHashing() {
        guard canStopHashing else { return }
        isStoppingHashing = true
        ContentHashService.shared.cancel()
        // Keep row spinner on the current file until it finishes; button stays disabled.
        flash("Stopping hashing…")
    }

    // MARK: - Open / close

    /// Call once at launch: reload recents and reopen the last card if it is mounted.
    func restoreSessionIfNeeded() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        await reloadRecents()

        guard volume == nil else { return }
        guard let remembered = try? await VolumeStore.shared.lastRemembered() else {
            statusText = "Open a GDEMU SD card to begin."
            return
        }

        statusText = "Restoring \(remembered.volumeName)…"
        await openRemembered(remembered, showErrorIfMissing: false)
    }

    func reloadRecents() async {
        recentVolumes = (try? await VolumeStore.shared.recents()) ?? []
    }

    func openCard() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.message = "Select the root of your GDEMU SD card"
        panel.prompt = "Open Card"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url: url) }
    }

    func openRemembered(_ remembered: RememberedVolume, showErrorIfMissing: Bool = true) async {
        // Already showing this card — don't wipe the list and rescan.
        if volume?.volumeUUID == remembered.volumeUUID, !isScanning {
            return
        }

        do {
            let resolved = try VolumeStore.resolveURL(from: remembered)
            let url = resolved.url

            // Must start security scope before touching the card under sandbox.
            if resolved.isSecurityScoped {
                let ok = url.startAccessingSecurityScopedResource()
                if ok {
                    accessURL = url
                    bookmarkData = remembered.bookmarkData
                } else if !FileManager.default.fileExists(atPath: url.path) {
                    throw VolumeStoreError.notMounted(remembered.volumeName)
                }
            }

            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VolumeStoreError.notMounted(remembered.volumeName)
            }

            await open(url: url, preexistingBookmark: remembered.bookmarkData)
        } catch {
            if showErrorIfMissing {
                lastError = error.localizedDescription
            }
            statusText = "Open a GDEMU SD card to begin."
            await reloadRecents()
        }
    }

    func forgetRecent(_ remembered: RememberedVolume) async {
        try? await VolumeStore.shared.forget(uuid: remembered.volumeUUID)
        await reloadRecents()
    }

    func open(url: URL, preexistingBookmark: Data? = nil, forceRescan: Bool = false) async {
        // Same card already open (sidebar / Open panel / restore) — keep list, no rescan.
        // Explicit Rescan / Clear Cache still passes forceRescan: true.
        if !forceRescan, !isScanning, isSameOpenVolume(as: url) {
            // Refresh free-space chrome only.
            if let resolved = try? VolumeIdentity.resolve(rootURL: url) {
                volume = resolved
            }
            return
        }

        // If caller already started security scope, keep it; otherwise try now.
        if accessURL?.standardizedFileURL != url.standardizedFileURL {
            stopAccess()
            if url.startAccessingSecurityScopedResource() {
                accessURL = url
            }
        }

        lastError = nil
        undoManager.removeAllActions()
        cancelLazyDetailEnrichment()
        selection = []
        duplicateInfoByID = [:]
        games = []
        menuNeedsRebuild = false
        isScanning = true
        scanProgress = nil
        statusText = "Scanning \(url.lastPathComponent)…"

        // Show volume chrome immediately; table fills as folders are identified.
        if let resolved = try? VolumeIdentity.resolve(rootURL: url) {
            volume = resolved
            await loadDisplaySort(for: resolved.volumeUUID)
        }

        // Let SwiftUI paint the empty/disabled table before heavy work begins.
        await Task.yield()

        // Prefer a fresh bookmark while we hold access (sandbox re-open).
        let freshBookmark = VolumeStore.makeBookmark(for: url) ?? preexistingBookmark
        if let freshBookmark {
            bookmarkData = freshBookmark
        }

        do {
            // CardScanner.scan is nonisolated and runs in Task.detached internally.
            // Progress callbacks hop to MainActor so the table fills live.
            let result = try await CardScanner.scan(rootURL: url) { event in
                await MainActor.run {
                    self.insertScannedEntry(event.entry)
                    self.scanProgress = (event.completed, event.total)
                    self.statusText = "Scanning… \(event.completed)/\(event.total)"
                }
            }

            volume = result.volume
            // Final authoritative order (progress may have arrived out of slot order).
            games = result.entries
            if let first = result.entries.first {
                selection = [first.id]
            } else {
                selection = []
            }
            lastScanStats = "\(result.cacheHits) cached · \(result.cacheMisses) scanned · \(result.durationMilliseconds) ms"
            await resolveMenuKind(for: result.volume.volumeUUID, games: result.entries)
            if result.volume.isReadOnly {
                statusText = "\(result.entries.count) games · \(ByteCount.string(for: totalBytes)) · Read-only · \(menuKind.displayName)"
                flash("Card is read-only — check the SD lock switch")
            } else {
                statusText = "\(result.entries.count) games · \(ByteCount.string(for: totalBytes)) · \(menuKind.displayName)"
            }
            scanProgress = nil
            isScanning = false

            // Serial/name dups first; size/hash grades refine after lazy details.
            scheduleDuplicateRecompute()
            startLazyDetailEnrichment(volumeUUID: result.volume.volumeUUID)

            try? await VolumeStore.shared.remember(
                volume: result.volume,
                rootURL: url,
                existingBookmark: bookmarkData
            )
            await reloadRecents()
            // Content hashing is never automatic — user starts it from Duplicates / Card menu.
        } catch {
            cancelLazyDetailEnrichment()
            volume = nil
            games = []
            selection = []
            duplicateInfoByID = [:]
            menuKind = .gdMenu
            lastError = error.localizedDescription
            statusText = "Failed to open card"
            scanProgress = nil
            isScanning = false
            stopAccess()
        }
    }

    /// After a fast scan, fill folder/payload sizes and stored hash sidecars off the main actor.
    private func startLazyDetailEnrichment(volumeUUID: String) {
        cancelLazyDetailEnrichment()
        let pending = games.filter { !$0.detailsLoaded }
        guard !pending.isEmpty else { return }

        detailEnrichmentGeneration &+= 1
        let generation = detailEnrichmentGeneration
        let snapshot = pending.map { (id: $0.id, path: $0.folderPath) }

        detailEnrichmentTask = Task.detached(priority: .utility) {
            // Concurrent batches so the table fills sizes progressively without thrashing FAT USB.
            var i = 0
            while i < snapshot.count {
                if Task.isCancelled { return }
                let end = min(i + 8, snapshot.count)
                let batch = Array(snapshot[i..<end])
                var batchResults: [(UUID, CardScanner.FolderDetails)] = []
                await withTaskGroup(of: (UUID, CardScanner.FolderDetails)?.self) { group in
                    for item in batch {
                        group.addTask {
                            guard let details = try? CardScanner.loadFolderDetails(
                                folderURL: URL(fileURLWithPath: item.path, isDirectory: true)
                            ) else { return nil }
                            return (item.id, details)
                        }
                    }
                    for await result in group {
                        if let result { batchResults.append(result) }
                    }
                }
                await MainActor.run {
                    guard generation == self.detailEnrichmentGeneration else { return }
                    var any = false
                    for (id, details) in batchResults {
                        guard let idx = self.games.firstIndex(where: { $0.id == id }) else { continue }
                        self.games[idx].byteSize = details.byteSize
                        self.games[idx].payloadByteSize = details.payloadByteSize
                        if let sha = details.contentSHA256 {
                            self.games[idx].contentSHA256 = sha
                        }
                        self.games[idx].detailsLoaded = true
                        any = true
                    }
                    if any {
                        self.refreshStatus()
                        self.scheduleDuplicateRecompute()
                    }
                }
                i = end
            }

            await MainActor.run {
                guard generation == self.detailEnrichmentGeneration else { return }
                self.persistEnrichedCache(volumeUUID: volumeUUID)
            }
        }
    }

    private func cancelLazyDetailEnrichment() {
        detailEnrichmentGeneration &+= 1
        detailEnrichmentTask?.cancel()
        detailEnrichmentTask = nil
    }

    /// Write current entries back into the volume cache so the next open is fully warm.
    private func persistEnrichedCache(volumeUUID: String) {
        guard let volume, volume.volumeUUID == volumeUUID else { return }
        let entries = games
        Task.detached(priority: .utility) {
            // Rebuild fingerprints cheaply from current entry fields (name listing again is fine here).
            var cached: [CachedEntry] = []
            cached.reserveCapacity(entries.count)
            for game in entries {
                let folderURL = game.folderURL
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)
                    .filter { !$0.hasPrefix(".") }) ?? []
                let imageURL = folderURL.appendingPathComponent(game.imageFileName)
                let imageValues = try? imageURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let fp = FolderFingerprint(
                    folderName: folderURL.lastPathComponent,
                    imageFileName: game.imageFileName,
                    imageSize: Int64(imageValues?.fileSize ?? Int(game.byteSize)),
                    imageModTimeSeconds: FolderFingerprint.modTimeSeconds(
                        imageValues?.contentModificationDate ?? .distantPast
                    ),
                    nameTxt: game.name,
                    serialTxt: game.serial.isEmpty ? nil : game.serial,
                    fileCount: names.count
                )
                var entry = game
                entry.detailsLoaded = true
                cached.append(CachedEntry(fingerprint: fp, entry: entry))
            }
            let cache = CardCache(
                volumeUUID: volumeUUID,
                volumeName: volume.volumeName,
                rootPath: volume.rootPath,
                scannedAt: Date(),
                entries: cached.sorted { $0.entry.number < $1.entry.number }
            )
            try? await CardCacheStore.shared.save(cache)
        }
    }

    /// Insert one scanned game by slot number (progressive table fill).
    private func insertScannedEntry(_ entry: GameEntry) {
        if let existing = games.firstIndex(where: { $0.number == entry.number }) {
            games[existing] = entry
            return
        }
        if let idx = games.firstIndex(where: { $0.number > entry.number }) {
            games.insert(entry, at: idx)
        } else {
            games.append(entry)
        }
    }

    /// O(n²) duplicate analysis off the main actor; results land asynchronously.
    private func scheduleDuplicateRecompute() {
        duplicateRecomputeGeneration &+= 1
        let generation = duplicateRecomputeGeneration
        let snapshot = games
        Task.detached(priority: .utility) {
            let info = DuplicateDetector.analyze(snapshot)
            await MainActor.run {
                guard generation == self.duplicateRecomputeGeneration else { return }
                self.duplicateInfoByID = info
            }
        }
    }

    /// Load persisted visual sort for this card (default: newest slots first).
    func loadDisplaySort(for volumeUUID: String) async {
        displaySort = (try? await VolumeStore.shared.displaySort(for: volumeUUID))
            ?? .mostRecentFirst
    }

    /// Persist table column sort for the open card.
    func saveDisplaySort(_ sort: DisplaySortPreference) {
        displaySort = sort
        guard let uuid = volume?.volumeUUID else { return }
        Task {
            try? await VolumeStore.shared.setDisplaySort(sort, for: uuid)
        }
    }

    /// Prefer saved choice, else detect from slot 01 name / IP.BIN, else GDmenu.
    private func resolveMenuKind(for volumeUUID: String, games: [GameEntry]) async {
        if let saved = try? await VolumeStore.shared.menuKind(for: volumeUUID) {
            menuKind = saved
            return
        }
        menuKind = MenuRebuildService.detectMenuKind(games: games) ?? .gdMenu
        // Remember detection so rebuild stays consistent even if name.txt is edited later.
        try? await VolumeStore.shared.setMenuKind(menuKind, for: volumeUUID)
    }

    /// User chose GDmenu vs openMenu (rebuild will bake that image).
    func setMenuKind(_ kind: MenuKind) {
        guard menuKind != kind else { return }
        menuKind = kind
        if let uuid = volume?.volumeUUID {
            Task {
                try? await VolumeStore.shared.setMenuKind(kind, for: uuid)
            }
        }
        if volume != nil, !games.isEmpty {
            markMenuNeedsRebuild()
            flash("Menu set to \(kind.displayName) — rebuild to apply (⇧⌘R)")
        }
    }

    func rescan() async {
        guard let volume else { return }
        await open(url: volume.rootURL, preexistingBookmark: bookmarkData, forceRescan: true)
    }

    func clearCacheAndRescan() async {
        guard let volume else { return }
        try? await CardCacheStore.shared.clear(volumeUUID: volume.volumeUUID)
        await open(url: volume.rootURL, preexistingBookmark: bookmarkData, forceRescan: true)
    }

    /// True when `url` is the card currently loaded (by volume UUID or standardized path).
    private func isSameOpenVolume(as url: URL) -> Bool {
        guard let volume else { return false }
        if volume.rootURL.standardizedFileURL == url.standardizedFileURL {
            return true
        }
        if let resolved = try? VolumeIdentity.resolve(rootURL: url),
           resolved.volumeUUID == volume.volumeUUID
        {
            return true
        }
        return false
    }

    func eject() async {
        guard let volume, !isBusy else { return }
        busyMessage = "Ejecting \(volume.volumeName)…"
        defer { busyMessage = nil }

        let root = volume.rootURL
        let name = volume.volumeName
        do {
            // Keep last volume + recents so remount/relaunch can restore access.
            stopAccess()
            self.volume = nil
            games = []
            selection = []
            menuNeedsRebuild = false
            menuKind = .gdMenu
            undoManager.removeAllActions()
            try await VolumeEject.eject(rootURL: root)
            statusText = "Ejected \(name)"
            flash("Ejected")
            await reloadRecents()
        } catch {
            // Re-open if eject failed (still mounted).
            lastError = error.localizedDescription
            statusText = "Eject failed"
            await open(url: root, preexistingBookmark: bookmarkData)
        }
    }

    // MARK: - Immediate operations

    func renameSelected(to newName: String) {
        guard let game = selectedGame else { return }
        rename(id: game.id, to: newName)
    }

    func rename(id: UUID, to newName: String) {
        guard !isBusy, let index = games.firstIndex(where: { $0.id == id }) else { return }
        let game = games[index]
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != game.name, !trimmed.isEmpty else { return }

        do {
            let previous = try CardOperations.rename(game: game, to: trimmed)
            games[index].name = trimmed
            games[index].isMenu = GameEntry.isMenuName(trimmed) || games[index].number == 1
            markMenuNeedsRebuild()
            refreshStatus()
            invalidateCacheAsync()

            undoManager.registerUndo(withTarget: self) { target in
                target.rename(id: id, to: previous)
            }
            undoManager.setActionName("Rename")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Apply sentence case to every selected game (immediate writes).
    func sentenceCaseSelection() {
        let targets = selectedGames
        guard !targets.isEmpty, !isBusy else { return }

        var undos: [(UUID, String)] = []
        for game in targets {
            let converted = game.name.sentenceCasedTitle
            guard converted != game.name else { continue }
            guard let index = games.firstIndex(where: { $0.id == game.id }) else { continue }
            do {
                let previous = try CardOperations.rename(game: games[index], to: converted)
                games[index].name = converted
                undos.append((game.id, previous))
            } catch {
                lastError = error.localizedDescription
                break
            }
        }

        guard !undos.isEmpty else { return }
        markMenuNeedsRebuild()
        refreshStatus()
        invalidateCacheAsync()
        flash(undos.count == 1 ? "Renamed" : "Renamed \(undos.count) games")

        undoManager.registerUndo(withTarget: self) { target in
            for (id, previous) in undos.reversed() {
                target.rename(id: id, to: previous)
            }
        }
        undoManager.setActionName(undos.count == 1 ? "Sentence Case" : "Sentence Case \(undos.count) Games")
    }

    func deleteSelected() {
        delete(ids: selection)
    }

    func delete(id: UUID) {
        delete(ids: [id])
    }

    func delete(ids: Set<UUID>) {
        guard !isBusy, let volume, !ids.isEmpty else { return }
        let snapshot = games
        let victims = snapshot.filter { ids.contains($0.id) }
        guard !victims.isEmpty else { return }
        let root = volume.rootURL
        let label = victims.count == 1 ? victims[0].name : "\(victims.count) games"
        let progress = makeProgressHandler()

        Task {
            busyMessage = "Removing \(label)…"
            defer { busyMessage = nil }
            do {
                let result = try await Task.detached {
                    try CardOperations.delete(
                        gameIDs: ids,
                        games: snapshot,
                        rootURL: root,
                        progress: progress
                    )
                }.value

                // In-memory update only — no full card rescan.
                games = result.updatedGames
                selection = []
                markMenuNeedsRebuild()
                refreshStatus()
                scheduleDuplicateRecompute()
                invalidateCacheAsync()
                flash("Removed \(label)")

                undoManager.registerUndo(withTarget: self) { target in
                    target.undelete(trashed: result.trashed)
                }
                undoManager.setActionName(victims.count == 1 ? "Delete \(victims[0].name)" : "Delete \(victims.count) Games")
            } catch {
                lastError = error.localizedDescription
                // Recover from partial renumber if needed.
                await rescan()
            }
        }
    }

    private func undelete(trashed: [TrashedGame]) {
        guard !isBusy, let volume, !trashed.isEmpty else { return }
        let snapshot = games
        let root = volume.rootURL
        let label = trashed.count == 1 ? trashed[0].game.name : "\(trashed.count) games"
        let progress = makeProgressHandler()

        Task {
            busyMessage = "Restoring \(label)…"
            defer { busyMessage = nil }
            do {
                let updated = try await Task.detached {
                    try CardOperations.undelete(
                        trashed: trashed,
                        currentGames: snapshot,
                        rootURL: root,
                        progress: progress
                    )
                }.value

                games = updated
                selection = Set(trashed.map(\.game.id))
                markMenuNeedsRebuild()
                refreshStatus()
                scheduleDuplicateRecompute()
                invalidateCacheAsync()
                flash("Restored \(label)")
            } catch {
                lastError = error.localizedDescription
                await rescan()
            }
        }
    }

    /// Move the selection as a block up or down one slot (packs non-contiguous picks together).
    func moveSelection(up: Bool) {
        guard !isBusy, !selection.isEmpty else { return }
        if up, !canMoveSelectionUp { return }
        if !up, !canMoveSelectionDown { return }

        let selectedIDs = games.filter { selection.contains($0.id) }.map(\.id)
        let otherIDs = games.filter { !selection.contains($0.id) }.map(\.id)
        guard let firstSelectedIndex = games.firstIndex(where: { selection.contains($0.id) }) else { return }

        let othersBefore = games[0..<firstSelectedIndex].filter { !selection.contains($0.id) }.count
        let insertAt: Int
        if up {
            insertAt = max(0, othersBefore - 1)
        } else {
            insertAt = min(otherIDs.count, othersBefore + 1)
        }

        var newOrder = otherIDs
        newOrder.insert(contentsOf: selectedIDs, at: insertAt)
        applyOrder(newOrder, actionName: up ? "Move Up" : "Move Down", preserveSelection: selection)
    }

    func moveSelection(to offsets: IndexSet, destination: Int) {
        guard !isBusy else { return }
        // Map from filtered list is risky; only allow reorder when not filtering.
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flash("Clear search to reorder")
            return
        }
        var order = games.map(\.id)
        order.move(fromOffsets: offsets, toOffset: destination)
        let moved = Set(offsets.map { games[$0].id })
        applyOrder(order, actionName: "Reorder", preserveSelection: moved)
    }

    func sortAlphabetically() {
        guard !isBusy, games.count > 1 else { return }
        var items = games
        // Pin menu (first isMenu or number 1 named menu) at top if present.
        let menu = items.first(where: \.isMenu)
        let rest: [GameEntry]
        if let menu {
            rest = items.filter { $0.id != menu.id }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            items = [menu] + rest
        } else {
            items = items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        applyOrder(items.map(\.id), actionName: "Sort")
    }

    private func applyOrder(
        _ orderedIDs: [UUID],
        actionName: String,
        preserveSelection: Set<GameEntry.ID>? = nil
    ) {
        guard let volume else { return }
        let previous = games.map(\.id)
        guard orderedIDs != previous else { return }
        let snapshot = games
        let root = volume.rootURL
        let keepSelection = preserveSelection ?? selection
        let progress = makeProgressHandler()

        Task {
            busyMessage = "Updating folder numbers…"
            defer { busyMessage = nil }
            do {
                let updated = try await Task.detached {
                    try CardOperations.applyOrder(
                        orderedIDs: orderedIDs,
                        games: snapshot,
                        rootURL: root,
                        progress: progress
                    )
                }.value

                games = updated
                selection = keepSelection.intersection(Set(orderedIDs))
                markMenuNeedsRebuild()
                refreshStatus()
                scheduleDuplicateRecompute()
                invalidateCacheAsync()

                undoManager.registerUndo(withTarget: self) { target in
                    target.applyOrder(previous, actionName: actionName, preserveSelection: keepSelection)
                }
                undoManager.setActionName(actionName)
            } catch {
                lastError = error.localizedDescription
                await rescan()
            }
        }
    }

    // MARK: - GDmenu list rebuild

    var canRebuildMenu: Bool {
        volume != nil && !games.isEmpty && !isBusy
    }

    func markMenuNeedsRebuild() {
        menuNeedsRebuild = true
    }

    func clearMenuNeedsRebuild() {
        menuNeedsRebuild = false
    }

    /// Rebuild the on-console GDmenu / openMenu image so the list matches current slots/names.
    func rebuildMenuList() {
        Task {
            _ = await rebuildMenuListAsync()
        }
    }

    /// Rebuild menu; returns `true` on success. Used by toolbar and quit flow.
    @discardableResult
    func rebuildMenuListAsync() async -> Bool {
        guard volume != nil, !games.isEmpty else { return false }
        // Allow quit-time rebuild even if `isBusy` was set by the quit handler.
        guard !isScanning else { return false }
        if busyMessage != nil, !isHandlingQuit { return false }

        let snapshot = games
        guard let root = volume?.rootURL else { return false }
        let kind = menuKind
        let progress = makeProgressHandler()

        busyMessage = "Rebuilding \(kind.displayName)…"
        defer {
            if !isHandlingQuit {
                busyMessage = nil
            }
        }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try MenuRebuildService.rebuild(
                    games: snapshot,
                    rootURL: root,
                    menuKind: kind,
                    progress: progress
                )
            }.value

            // Light refresh of the menu row size / name; full rescan is unnecessary.
            if let idx = games.firstIndex(where: { $0.number == 1 }) {
                games[idx].name = result.menuKind.menuFolderName
                games[idx].isMenu = true
                games[idx].format = .gdi
                games[idx].imageFileName = "disc.gdi"
                games[idx].folderPath = result.menuFolderPath
                if let size = directorySize(at: result.menuFolderPath) {
                    games[idx].byteSize = size
                    games[idx].payloadByteSize = size
                }
                games[idx].contentSHA256 = nil
            }
            menuKind = result.menuKind
            if let uuid = volume?.volumeUUID {
                try? await VolumeStore.shared.setMenuKind(result.menuKind, for: uuid)
            }

            clearMenuNeedsRebuild()
            refreshStatus()
            invalidateCacheAsync()
            flash("Rebuilt \(result.menuKind.displayName) · \(result.itemCount) items")
            statusText = "\(result.menuKind.displayName) rebuilt · \(result.itemCount) items · \(ByteCount.string(for: Int64(result.listByteCount))) list"
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Quit (rebuild → eject → exit)

    /// Called from `AppDelegate.applicationShouldTerminate`.
    func handleApplicationShouldTerminate() -> NSApplication.TerminateReply {
        if isHandlingQuit {
            return .terminateNow
        }

        // Don't interrupt in-flight card work unless we're only "busy" with nothing critical.
        if isBusy {
            let alert = NSAlert()
            alert.messageText = "Still working"
            alert.informativeText = busyMessage ?? "Wait for the current operation to finish, then quit again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .terminateCancel
        }

        if menuNeedsRebuild, volume != nil, !games.isEmpty {
            let ejectNote = ejectOnQuit
                ? "Rebuild writes the current names and order into slot 01, ejects the card, then quits."
                : "Rebuild writes the current names and order into slot 01, then quits."
            let alert = NSAlert()
            alert.messageText = "Rebuild menu before quitting?"
            alert.informativeText = """
            The game list on the SD card changed, but the \(menuKind.displayName) image in slot 01 has not been rebuilt yet.

            \(ejectNote)
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Rebuild & Quit")
            alert.addButton(withTitle: "Quit Without Rebuilding")
            alert.addButton(withTitle: "Cancel")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                isHandlingQuit = true
                Task { await self.finishQuit(rebuild: true) }
                return .terminateLater
            case .alertSecondButtonReturn:
                isHandlingQuit = true
                Task { await self.finishQuit(rebuild: false) }
                return .terminateLater
            default:
                return .terminateCancel
            }
        }

        // Optional: eject open card on quit (Settings; default off).
        if ejectOnQuit, volume != nil {
            isHandlingQuit = true
            Task { await self.finishQuit(rebuild: false) }
            return .terminateLater
        }

        return .terminateNow
    }

    /// Rebuild (optional) → optional eject → allow app termination.
    private func finishQuit(rebuild: Bool) async {
        let shouldEject = ejectOnQuit && volume != nil
        if rebuild {
            busyMessage = "Rebuilding menu list…"
        } else if shouldEject {
            busyMessage = "Ejecting…"
        }
        defer {
            busyMessage = nil
            isHandlingQuit = false
        }

        if rebuild {
            let ok = await rebuildMenuListAsync()
            if !ok {
                // Stay open so the user can fix the error.
                let alert = NSAlert()
                alert.messageText = "Menu rebuild failed"
                alert.informativeText = lastError ?? "Unknown error. The app will stay open."
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
        }

        if shouldEject {
            await ejectForQuit()
        }
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Eject without reopening on failure (used only when leaving the app).
    private func ejectForQuit() async {
        guard let volume else {
            stopAccess()
            return
        }
        busyMessage = "Ejecting \(volume.volumeName)…"
        let root = volume.rootURL
        do {
            stopAccess()
            self.volume = nil
            games = []
            selection = []
            menuNeedsRebuild = false
            undoManager.removeAllActions()
            try await VolumeEject.eject(rootURL: root)
        } catch {
            // Still quit — card may already be gone or busy; don't block exit.
            lastError = nil
            statusText = "Eject skipped: \(error.localizedDescription)"
        }
    }

    private nonisolated static func directoryByteSize(path: String) -> Int64? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }

    private func directorySize(at path: String) -> Int64? {
        Self.directoryByteSize(path: path)
    }

    /// Progress updates from background file ops → UI busy text.
    private func makeProgressHandler() -> @Sendable (String) -> Void {
        { [weak self] message in
            Task { @MainActor in
                self?.busyMessage = message
            }
        }
    }

    private func refreshStatus() {
        if let volume {
            var parts = [
                "\(games.count) games",
                ByteCount.string(for: totalBytes),
                volume.volumeName,
                menuKind.displayName,
            ]
            if volume.isReadOnly {
                parts.append("Read-only")
            }
            statusText = parts.joined(separator: " · ")
        }
    }

    private func invalidateCacheAsync() {
        guard let volume else { return }
        Task {
            try? await CardCacheStore.shared.clear(volumeUUID: volume.volumeUUID)
        }
    }

    private func flash(_ message: String) {
        flashMessage = message
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { flashMessage = nil }
        }
    }

    private func stopAccess() {
        cancelLazyDetailEnrichment()
        ContentHashService.shared.cancel()
        isStoppingHashing = false
        isHashingActive = false
        hashingFolderPath = nil
        hashingProgress = nil
        accessURL?.stopAccessingSecurityScopedResource()
        accessURL = nil
    }
}
