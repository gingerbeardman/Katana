import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class AppState {
    var volume: CardVolume? {
        didSet {
            // Blank window only: Open / Reopen live in the sidebar. Force it open when
            // nothing is mounted — not when a volume successfully restores on launch.
            if volume == nil {
                splitColumnVisibility = .all
            }
        }
    }
    var games: [GameEntry] = [] {
        didSet {
            maxGameNumber = games.map(\.number).max() ?? 1
        }
    }
    /// Highest slot number on the open card (avoids `games.map` in every table/inspector body).
    private(set) var maxGameNumber: Int = 1
    /// Inspector-only snapshot — updated when selection or *selected* row data changes,
    /// not on every background size-enrichment write to unrelated rows.
    private(set) var inspectorSnapshot: InspectorSnapshot = .empty
    /// Leading sidebar column visibility (`NavigationSplitView`).
    /// Starts `.automatic` so a successful restore does not force the sidebar open;
    /// forced to `.all` only for blank windows (no card open / remount failed).
    var splitColumnVisibility: NavigationSplitViewVisibility = .automatic
    /// Multi-select (⌘/⇧ click). Empty when nothing selected.
    var selection: Set<GameEntry.ID> = [] {
        didSet {
            guard oldValue != selection else { return }
            rebuildInspectorSnapshot()
        }
    }
    /// Bumped while the table is filling so the list can scroll to the newest row.
    var scrollTargetGameID: GameEntry.ID?
    var searchText: String = ""
    /// Master switch for the duplicates suite (sidebar, markers, commands). Default **on** (opt-out).
    var duplicatesEnabled: Bool = AppState.loadDuplicatesEnabled() {
        didSet {
            UserDefaults.standard.set(duplicatesEnabled, forKey: AppState.duplicatesEnabledKey)
            if oldValue != duplicatesEnabled {
                if duplicatesEnabled {
                    scheduleDuplicateRecompute()
                } else {
                    showDuplicatesOnly = false
                    // Leave markers preference alone; UI ignores them while feature is off.
                }
            }
        }
    }
    /// When true, list dimming / focus mode for non-duplicates (requires `duplicatesEnabled`).
    var showDuplicatesOnly: Bool = false
    /// When true, show grade badges in the # column. Default on with the feature.
    var showDuplicateMarkers: Bool = AppState.loadShowDuplicateMarkers() {
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
    /// When true, show the Recent list for switching between SD cards. Default **off**
    /// (single-card UX). Restore-on-launch still uses the last remembered volume either way.
    var manageMultipleCards: Bool = UserDefaults.standard.bool(forKey: AppState.manageMultipleCardsKey) {
        didSet {
            UserDefaults.standard.set(manageMultipleCards, forKey: AppState.manageMultipleCardsKey)
        }
    }
    /// When true, follow newly scanned/imported rows in the table. Default off.
    var scrollToNewRows: Bool = UserDefaults.standard.bool(forKey: AppState.scrollToNewRowsKey) {
        didSet {
            UserDefaults.standard.set(scrollToNewRows, forKey: AppState.scrollToNewRowsKey)
        }
    }
    /// When true, game/list sizes are whole MB (`1,188 MB`). When false, adaptive KB/MB.
    /// Title bar + sidebar capacity still use GB when large. Default on.
    var sizesAsIntegerMB: Bool = AppState.loadSizesAsIntegerMB() {
        didSet {
            UserDefaults.standard.set(sizesAsIntegerMB, forKey: AppState.sizesAsIntegerMBKey)
            if oldValue != sizesAsIntegerMB {
                refreshStatus()
            }
        }
    }
    var isScanning = false
    /// True while baking/installing the console menu image (slot 01).
    var isRebuildingMenu = false
    /// 0…1 progress for the rebuild edge bar (`nil` when idle).
    var rebuildProgress: Double?
    /// Trailing inspector visibility (standard macOS `.inspector`). Persisted across launches.
    var isInspectorPresented: Bool = AppState.loadInspectorPresented() {
        didSet {
            UserDefaults.standard.set(isInspectorPresented, forKey: AppState.isInspectorPresentedKey)
        }
    }
    /// Bumped to focus the name field in the inspector (e.g. Rename…).
    var focusNameFieldToken: Int = 0
    /// True while a text field / field editor is first responder (search, rename, …).
    /// Menu key equivalents that would steal ⌘A / ⌫ / ⌘Z are disabled while set.
    var isTextInputFocused: Bool = false
    /// Finder-style inline rename target in the game table (`nil` when idle).
    /// Observed inside `RenameAwareTitleCell` so SwiftUI Table cell caching still updates.
    var renamingGameID: GameEntry.ID?
    /// Non-nil while a disk mutation runs (renumber, copy, delete).
    var busyMessage: String?
    /// Live scan progress for the status line / table chrome (`nil` when idle).
    var scanProgress: (completed: Int, total: Int)?
    var statusText: String = "Open a GDEMU SD card to begin"
    /// Soft-delete trash on the open card (`.katana-trash`).
    var trashSummary: CardOperations.TrashSummary = .empty
    /// Transient status toast — auto-clears; never a modal.
    var flashMessage: String?
    var lastError: String?
    var lastScanStats: String?
    /// Recently opened cards (sidebar).
    var recentVolumes: [RememberedVolume] = []
    /// View-only table sort for the open card (persisted per volume UUID).
    var displaySort: DisplaySortPreference = .mostRecentFirst
    /// Volume UUID that `displaySort` was loaded for — avoids writing the previous card’s
    /// sort onto a newly opened UUID during the open race.
    private var displaySortLoadedForUUID: String?
    /// Which console menu image to bake (GDmenu or openMenu). Persisted per volume.
    var menuKind: MenuKind = .gdMenu
    /// Kind currently installed in slot 01 (last successful bake, or detected on open).
    /// Switching preference away and back without list changes does not dirty the menu.
    private(set) var bakedMenuKind: MenuKind = .gdMenu
    /// Names / order / slots changed since the last bake (independent of menu-type picker).
    private(set) var menuContentDirty: Bool = false
    /// Rebuild needed when the list changed **or** the chosen type ≠ what’s on the card.
    var menuNeedsRebuild: Bool {
        guard volume != nil, !games.isEmpty else { return false }
        return menuContentDirty || menuKind != bakedMenuKind
    }
    /// Per-card “not a duplicate” identity keys for the open volume (`DuplicateIdentity`).
    private(set) var notDuplicateKeys: Set<String> = []
    /// Inspector section expand/collapse (global UserDefaults, survives launches).
    var inspectorSectionExpanded: [String: Bool] = AppState.loadInspectorSections() {
        didSet {
            AppState.saveInspectorSections(inspectorSectionExpanded)
        }
    }

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
    /// Coalesce size writes so SwiftUI is not notified every 8-folder FAT batch.
    private var enrichmentPendingDetails: [(UUID, CardScanner.FolderDetails)] = []
    private var enrichmentFlushTask: Task<Void, Never>?
    private var enrichmentLastFlushAt: CFAbsoluteTime = 0
    /// NSWorkspace volume rename / app-activate observers (Finder label changes).
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var didInstallWorkspaceObservers = false

    private static let duplicatesEnabledKey = "duplicatesEnabled"
    private static let showDuplicateMarkersKey = "showDuplicateMarkers"
    private static let ejectOnQuitKey = "ejectOnQuit"
    private static let manageMultipleCardsKey = "manageMultipleCards"
    private static let scrollToNewRowsKey = "scrollToNewRows"
    private static let sizesAsIntegerMBKey = "sizesAsIntegerMB"
    private static let isInspectorPresentedKey = "isInspectorPresented"
    private static let inspectorSectionsKey = "inspectorSectionExpanded"

    /// Default on when the key has never been written (first launch).
    private static func loadInspectorPresented() -> Bool {
        if UserDefaults.standard.object(forKey: isInspectorPresentedKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: isInspectorPresentedKey)
    }

    /// Default on — feature is opt-out.
    private static func loadDuplicatesEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: duplicatesEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: duplicatesEnabledKey)
    }

    /// Default on when unset (matches feature-on default); respect explicit false.
    private static func loadShowDuplicateMarkers() -> Bool {
        if UserDefaults.standard.object(forKey: showDuplicateMarkersKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: showDuplicateMarkersKey)
    }

    /// Default on (whole MB) when the key has never been written.
    private static func loadSizesAsIntegerMB() -> Bool {
        if UserDefaults.standard.object(forKey: sizesAsIntegerMBKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: sizesAsIntegerMBKey)
    }

    /// Game sizes: Size column, inspector, selection totals — **MB only** (never GB).
    func formatSize(_ bytes: Int64) -> String {
        ByteCount.gameSizeString(for: bytes, integerMegabytes: sizesAsIntegerMB)
    }

    /// Size column / inspector: “—” while folder walk is still pending (avoids “0 MB” for GDI).
    func formatGameSize(_ game: GameEntry) -> String {
        if game.needsDetailEnrichment, game.byteSize < 1_000_000 {
            return "—"
        }
        return formatSize(game.byteSize)
    }

    /// Volume chrome: sidebar free/capacity/trash and title-bar totals — **GB** when large.
    func formatSize(_ bytes: Int64, capacityHint: Int64?) -> String {
        ByteCount.volumeSizeString(for: bytes, integerMegabytes: sizesAsIntegerMB, capacityHint: capacityHint)
    }

    private static func loadInspectorSections() -> [String: Bool] {
        (UserDefaults.standard.dictionary(forKey: inspectorSectionsKey) as? [String: Bool]) ?? [:]
    }

    private static func saveInspectorSections(_ map: [String: Bool]) {
        UserDefaults.standard.set(map, forKey: inspectorSectionsKey)
    }

    func isInspectorSectionExpanded(_ section: InspectorSection) -> Bool {
        inspectorSectionExpanded[section.rawValue] ?? section.defaultExpanded
    }

    func toggleInspectorSection(_ section: InspectorSection) {
        var next = inspectorSectionExpanded
        let current = next[section.rawValue] ?? section.defaultExpanded
        next[section.rawValue] = !current
        inspectorSectionExpanded = next
    }

    func setInspectorSection(_ section: InspectorSection, expanded: Bool) {
        var next = inspectorSectionExpanded
        next[section.rawValue] = expanded
        inspectorSectionExpanded = next
    }

    var isBusy: Bool { isScanning || isRebuildingMenu || busyMessage != nil }

    /// List-row badge for the `#` column. Only real duplicate chips — never a blank “—”.
    func listDuplicateBadge(for id: GameEntry.ID) -> DuplicateListBadge? {
        guard duplicatesEnabled else { return nil }
        let markersWanted = showDuplicateMarkers || showDuplicatesOnly
        guard markersWanted else { return nil }

        // Menu row has its own MENU chip.
        if games.first(where: { $0.id == id })?.isMenu == true {
            return nil
        }

        guard let info = duplicateInfoByID[id] else { return nil }
        return .ready(info)
    }

    /// Soft-dim non-duplicates when filtering is on (rows stay in place — no list reflow).
    func isDeemphasizedInList(_ game: GameEntry) -> Bool {
        guard duplicatesEnabled, showDuplicatesOnly, hasDuplicateAnalysis else { return false }
        if game.isMenu { return true }
        return duplicateInfoByID[game.id] == nil
    }

    /// Cached duplicate map — recomputed off the main actor when `games` changes.
    private(set) var duplicateInfoByID: [GameEntry.ID: DuplicateInfo] = [:]
    /// True only while the **first** analysis runs (empty map → pending “—” badges).
    /// Incremental recomputes keep the previous map so the table does not blank out.
    private(set) var isDuplicateInfoComputing: Bool = false
    /// False until the first analyze for this open card finishes (even if zero dups).
    /// Used so “Show duplicates only” can keep showing all rows while calculating.
    private(set) var hasDuplicateAnalysis: Bool = false
    private var duplicateRecomputeGeneration: UInt64 = 0
    private var duplicateRecomputeDebounceTask: Task<Void, Never>?

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
    /// Last measured hashing throughput for the open card (bytes/sec). Seeds ETA on the next run.
    private(set) var cachedHashBytesPerSecond: Double?

    /// Effective rate: live sample, else last-known card seed.
    private var hashingEffectiveRate: Double? {
        if let bps = hashingProgress?.bytesPerSecond, bps.isFinite, bps > 0 { return bps }
        if let s = cachedHashBytesPerSecond, s.isFinite, s > 0 { return s }
        return nil
    }

    /// 0…1 for the linear progress bar (Spindle-style).
    var hashingFraction: Double {
        hashingProgress?.fractionComplete ?? 0
    }

    /// Compact label above the bar, e.g. `Hashing — 18m remaining`.
    var hashingProgressLabel: String {
        if isStoppingHashing {
            return "Stopping…"
        }
        let eta: Double? = {
            guard let progress = hashingProgress else { return nil }
            if let e = progress.etaSeconds { return e }
            guard let rate = hashingEffectiveRate, rate > 0, progress.remainingBytes > 0 else {
                return nil
            }
            return Double(progress.remainingBytes) / rate
        }()
        if let eta {
            let duration = ByteCount.etaString(seconds: eta)
                .trimmingCharacters(in: CharacterSet(charactersIn: "~"))
            return "Hashing — \(duration) remaining"
        }
        return "Hashing…"
    }

    /// Trailing percent, e.g. `17%`.
    var hashingPercentLabel: String {
        if isStoppingHashing { return "" }
        let pct = hashingFraction * 100
        if pct > 0, pct < 10 {
            return String(format: "%.0f%%", pct)
        }
        return "\(Int(pct.rounded(.down)))%"
    }

    /// Full detail for tooltips (rate, counts).
    var hashingHelpText: String {
        guard let progress = hashingProgress else {
            return "Hashing disc content"
        }
        var lines = ["\(progress.completedCount) of \(progress.totalCount) games"]
        if progress.hashedBytes > 0 {
            lines.append("\(formatSize(progress.hashedBytes)) hashed")
        }
        if progress.remainingBytes > 0 {
            lines.append("\(formatSize(progress.remainingBytes)) remaining")
        }
        if let bps = hashingEffectiveRate {
            lines.append(ByteCount.throughput(bytesPerSecond: bps, integerMegabytes: sizesAsIntegerMB))
        }
        if let eta = progress.etaSeconds {
            lines.append("ETA \(ByteCount.etaString(seconds: eta))")
        }
        return lines.joined(separator: "\n")
    }

    func isHashingGame(_ game: GameEntry) -> Bool {
        guard let hashingFolderPath else { return false }
        return game.folderPath == hashingFolderPath
    }

    var filteredGames: [GameEntry] {
        // Never remove rows for “Show duplicates only” — that reflows the table.
        // Non-dups are dimmed via `isDeemphasizedInList` once analysis finishes.
        var list = games

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
        guard !selection.isEmpty else { return [] }
        return games.filter { selection.contains($0.id) }
    }

    /// Single-selection convenience (nil if 0 or 2+ selected).
    var selectedGame: GameEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return games.first { $0.id == id }
    }

    var selectedIndices: [Int] {
        guard !selection.isEmpty else { return [] }
        return games.indices.filter { selection.contains(games[$0].id) }
    }

    /// Lookup without re-filtering the whole list for common single-id paths.
    func game(id: GameEntry.ID) -> GameEntry? {
        games.first { $0.id == id }
    }

    /// Replace the game list and optionally refresh the inspector snapshot.
    func replaceGames(_ newGames: [GameEntry], refreshInspector: Bool = true) {
        games = newGames
        if refreshInspector {
            rebuildInspectorSnapshot()
        }
    }

    /// Rebuild inspector inputs without requiring `InspectorView` to observe `games`.
    func rebuildInspectorSnapshot() {
        let maxN = maxGameNumber
        var snap = InspectorSnapshot(
            content: .empty,
            maxNumber: maxN,
            menuDisplayName: menuKind.displayName,
            duplicatesEnabled: duplicatesEnabled,
            isBusy: isBusy,
            focusNameFieldToken: focusNameFieldToken
        )
        if selection.isEmpty {
            snap.content = .empty
        } else if selection.count == 1, let id = selection.first, let game = games.first(where: { $0.id == id }) {
            let dup = duplicatesEnabled ? duplicateInfoByID[id] : nil
            let marked = duplicatesEnabled && isMarkedNotDuplicate(game)
            snap.content = .single(game: game, duplicate: dup, markedNotDuplicate: marked)
        } else {
            let selected = games.filter { selection.contains($0.id) }
            let bytes = selected.reduce(Int64(0)) { $0 + $1.byteSize }
            let anyDup = duplicatesEnabled && selected.contains { duplicateInfoByID[$0.id] != nil }
            let anyMarked = duplicatesEnabled && selected.contains { isMarkedNotDuplicate($0) }
            snap.content = .multi(games: selected, totalBytes: bytes, anyDup: anyDup, anyMarked: anyMarked)
        }
        inspectorSnapshot = snap
    }

    var totalBytes: Int64 {
        games.reduce(0) { $0 + $1.byteSize }
    }

    var selectedBytes: Int64 {
        selectedGames.reduce(0) { $0 + $1.byteSize }
    }

    var canEject: Bool { volume != nil && !isBusy }

    /// Soft-delete trash (`.katana-trash`) can be emptied when a writable card is open.
    var canEmptyCardTrash: Bool {
        guard volume != nil, !isBusy, volume?.isReadOnly != true else { return false }
        return !trashSummary.isEmpty
    }

    /// Whether the sidebar should show the Recent list.
    /// Multi-card mode only; hide when the list is empty or is just the open card alone.
    var showsRecentCardsSection: Bool {
        guard manageMultipleCards, !recentVolumes.isEmpty else { return false }
        if recentVolumes.count == 1,
           let only = recentVolumes.first,
           volume?.volumeUUID == only.volumeUUID
        {
            return false
        }
        return true
    }

    /// Last remembered card for single-card “Reopen …” (may be nil).
    var lastRememberedVolume: RememberedVolume? {
        recentVolumes.first
    }

    /// Reopen button when no card is open and we have a remembered volume.
    var canReopenLastCard: Bool {
        volume == nil && !isBusy && !isScanning && lastRememberedVolume != nil
    }

    var canAddGames: Bool {
        volume != nil && !isBusy && volume?.isReadOnly != true
    }

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
        cancelInlineRename()
        if let id {
            selection = [id]
        }
        isInspectorPresented = true
        if selection.count == 1 {
            focusNameFieldToken &+= 1
        }
    }

    /// Start Finder-style inline rename on a single game (table title cell).
    /// Defers setting `renamingGameID` so context-menu teardown does not immediately
    /// cancel the brand-new field editor (2UP activation pattern).
    func beginInlineRename(_ id: GameEntry.ID) {
        guard !isBusy, !isScanning, games.contains(where: { $0.id == id }) else { return }
        selection = [id]
        // If already renaming this row, leave the field alone.
        if renamingGameID == id { return }
        renamingGameID = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.isBusy, !self.isScanning,
                  self.selection == [id],
                  self.games.contains(where: { $0.id == id })
            else { return }
            self.renamingGameID = id
        }
    }

    func cancelInlineRename() {
        renamingGameID = nil
    }

    func commitInlineRename(id: GameEntry.ID, to newName: String) {
        renamingGameID = nil
        rename(id: id, to: newName)
    }

    func selectOnly(_ id: GameEntry.ID) {
        selection = [id]
        isInspectorPresented = true
    }

    func selectAllDuplicates() {
        selection = DuplicateDetector.allDuplicateIDs(in: games, ignoredIdentityKeys: notDuplicateKeys)
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
        selection = DuplicateDetector.redundantIDs(
            in: games,
            minimumGrade: minimumGrade,
            ignoredIdentityKeys: notDuplicateKeys
        )
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

    /// Mark game(s) as not duplicates on **this card** (persisted by volume UUID).
    func markNotDuplicate(ids: Set<GameEntry.ID>? = nil) {
        let targetIDs = ids ?? selection
        guard let uuid = volume?.volumeUUID else { return }
        let targets = games.filter { targetIDs.contains($0.id) && !$0.isMenu }
        guard !targets.isEmpty else {
            flash("Nothing to mark")
            return
        }
        var keys = notDuplicateKeys
        for game in targets {
            keys.insert(DuplicateIdentity.key(for: game))
        }
        notDuplicateKeys = keys
        Task {
            try? await VolumeStore.shared.setNotDuplicateKeys(keys, for: uuid)
        }
        // Keep the table stable: strip badges for marked rows now, re-analyze in the
        // background without blanking every row to “—” or wiping sizes.
        let removedIDs = Set(targets.map(\.id))
        if !duplicateInfoByID.isEmpty {
            duplicateInfoByID = Self.duplicateMapRemoving(removedIDs, from: duplicateInfoByID)
        }
        rebuildInspectorSnapshot()
        scheduleDuplicateRecompute(showPendingMarkers: false)
        let n = targets.count
        flash(n == 1 ? "Marked not a duplicate" : "Marked \(n) games not duplicates")
    }

    /// Undo a “not a duplicate” mark for the selection (or given ids).
    func clearNotDuplicateMark(ids: Set<GameEntry.ID>? = nil) {
        let targetIDs = ids ?? selection
        guard let uuid = volume?.volumeUUID else { return }
        let targets = games.filter { targetIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        var keys = notDuplicateKeys
        var removed = 0
        for game in targets {
            if keys.remove(DuplicateIdentity.key(for: game)) != nil {
                removed += 1
            }
        }
        guard removed > 0 else {
            flash("Not marked as not-a-duplicate")
            return
        }
        notDuplicateKeys = keys
        Task {
            try? await VolumeStore.shared.setNotDuplicateKeys(keys, for: uuid)
        }
        // Full re-analyze without pending “—” flash (restore can reintroduce groups).
        rebuildInspectorSnapshot()
        scheduleDuplicateRecompute(showPendingMarkers: false)
        flash(removed == 1 ? "Duplicate detection restored" : "Restored \(removed) games")
    }

    func isMarkedNotDuplicate(_ game: GameEntry) -> Bool {
        notDuplicateKeys.contains(DuplicateIdentity.key(for: game))
    }

    /// Games on the open card that currently match a stored “not a duplicate” key.
    var gamesMarkedNotDuplicate: [GameEntry] {
        games.filter { isMarkedNotDuplicate($0) }
    }

    var notDuplicateMarkCount: Int {
        // Prefer live matches; fall back to raw key count (orphans after rename/delete).
        let matched = gamesMarkedNotDuplicate.count
        return matched > 0 ? matched : notDuplicateKeys.count
    }

    /// Select every game on this card that is marked not-a-duplicate.
    func selectMarkedNotDuplicates() {
        let ids = Set(gamesMarkedNotDuplicate.map(\.id))
        guard !ids.isEmpty else {
            flash("No not-a-duplicate marks on this card")
            return
        }
        selection = ids
        isInspectorPresented = true
        showDuplicatesOnly = false
        flash("\(ids.count) marked not-duplicate selected")
    }

    /// Clear every “not a duplicate” mark for the open card (including orphan keys).
    func clearAllNotDuplicateMarks() {
        guard let uuid = volume?.volumeUUID else { return }
        guard !notDuplicateKeys.isEmpty else {
            flash("No not-a-duplicate marks on this card")
            return
        }
        let n = notDuplicateMarkCount
        notDuplicateKeys = []
        Task {
            try? await VolumeStore.shared.setNotDuplicateKeys([], for: uuid)
        }
        scheduleDuplicateRecompute(showPendingMarkers: false)
        flash(n == 1 ? "Cleared 1 not-a-duplicate mark" : "Cleared \(n) not-a-duplicate marks")
    }

    /// Games still without a content hash (for UI).
    var unhashedGameCount: Int {
        games.filter { !$0.isMenu && !$0.hasContentHash }.count
    }

    /// Hashing and menu rebuild both thrash the card — never run them together.
    var canStartHashing: Bool {
        volume != nil
            && !isBusy
            && !isHashing
            && unhashedGameCount > 0
    }

    /// User-initiated: compute missing content hashes in the background.
    func startContentHashing() {
        guard canStartHashing else {
            if isHashing { return }
            if isBusy {
                flash("Wait for the current operation to finish before hashing")
            }
            return
        }
        let targets = games.filter { !$0.isMenu && !$0.hasContentHash }
        guard !targets.isEmpty else {
            flash("All games already have hashes")
            return
        }
        beginContentHashing(targets, flashLabel: "Hashing \(targets.count) game\(targets.count == 1 ? "" : "s")")
    }

    /// Hash newly imported games (or merge them into a run already in progress).
    private func startHashingImportedGames(_ added: [GameEntry]) {
        guard volume != nil, volume?.isReadOnly != true else { return }
        // Don't start while scanning / rebuild / etc. (import has already cleared busy).
        if isBusy, !isHashing { return }

        let needHash = added.filter { !$0.isMenu && !$0.hasContentHash }
        guard !needHash.isEmpty else { return }

        if isHashing {
            // Restart queue with every still-unhashed title so new slots join the run.
            let allMissing = games.filter { !$0.isMenu && !$0.hasContentHash }
            guard !allMissing.isEmpty else { return }
            beginContentHashing(
                allMissing,
                flashLabel: "Hashing \(allMissing.count) game\(allMissing.count == 1 ? "" : "s") (including new)"
            )
            return
        }

        let n = needHash.count
        beginContentHashing(
            needHash,
            flashLabel: n == 1 ? "Hashing new game" : "Hashing \(n) new games"
        )
    }

    /// Shared start path for manual “Compute Missing Hashes” and post-import auto-hash.
    private func beginContentHashing(_ targets: [GameEntry], flashLabel: String) {
        guard volume != nil, !targets.isEmpty else { return }

        // Flip before any async work so the button disables / UI swaps on this click.
        isStoppingHashing = false
        isHashingActive = true
        hashingProgress = nil

        let volumeUUID = volume?.volumeUUID
        let gamesSnapshot = targets

        ContentHashService.shared.onCurrentFolderChanged = { [weak self] path in
            self?.hashingFolderPath = path
        }
        ContentHashService.shared.onHashed = { [weak self] path, sha, payloadSize in
            guard let self else { return }
            guard let idx = self.games.firstIndex(where: { $0.folderPath == path }) else { return }
            self.games[idx].contentSHA256 = sha
            self.games[idx].payloadByteSize = payloadSize
            // Debounce: hashing fires per-file; avoid blanking markers / thrashing the table.
            self.scheduleDuplicateRecompute(showPendingMarkers: false, debounce: .milliseconds(400))
            self.invalidateCacheAsync()
        }
        ContentHashService.shared.onProgress = { [weak self] progress in
            self?.hashingProgress = progress
        }
        ContentHashService.shared.onMeasuredRate = { [weak self] rate in
            guard let self else { return }
            self.cachedHashBytesPerSecond = rate
            guard let volumeUUID else { return }
            Task {
                try? await VolumeStore.shared.setHashBytesPerSecond(rate, for: volumeUUID)
            }
        }
        ContentHashService.shared.onFinished = { [weak self] in
            guard let self else { return }
            let measured = ContentHashService.shared.lastMeasuredBytesPerSecond
            let uuid = self.volume?.volumeUUID
            self.isStoppingHashing = false
            self.isHashingActive = false
            self.hashingFolderPath = nil
            self.hashingProgress = nil
            if let measured {
                self.cachedHashBytesPerSecond = measured
                if let uuid {
                    Task {
                        try? await VolumeStore.shared.setHashBytesPerSecond(measured, for: uuid)
                    }
                }
            }
        }

        // Always resolve seed before startFilling — memory can be stale after snapshot open /
        // same-card early return that skipped loadCachedHashRate.
        Task {
            var seed: Double? = {
                guard let s = self.cachedHashBytesPerSecond, s.isFinite, s > 0 else { return nil }
                return s
            }()
            if seed == nil, let volumeUUID {
                if let stored = try? await VolumeStore.shared.hashBytesPerSecond(for: volumeUUID),
                   stored.isFinite, stored > 0
                {
                    seed = stored
                    self.cachedHashBytesPerSecond = stored
                }
            }
            guard self.isHashingActive else { return }

            ContentHashService.shared.startFilling(
                games: gamesSnapshot,
                seedBytesPerSecond: seed
            )
            self.hashingFolderPath = ContentHashService.shared.currentFolderPath
            self.hashingProgress = ContentHashService.shared.progress

            let remaining = self.hashingProgress?.remainingBytes ?? 0
            var flashParts = [flashLabel]
            if remaining > 0 {
                flashParts.append(self.formatSize(remaining))
            }
            if let seed, seed > 0 {
                flashParts.append(ByteCount.throughput(bytesPerSecond: seed, integerMegabytes: self.sizesAsIntegerMB))
            }
            self.flash(flashParts.joined(separator: " · "))
        }
    }

    func stopContentHashing() {
        guard canStopHashing else { return }
        isStoppingHashing = true
        ContentHashService.shared.cancel()
        // Keep row spinner on the current file until it finishes; onFinished clears stopping.
        flash("Stopping… finishing current file")
    }

    // MARK: - Open / close

    /// Call once at launch: reload recents and reopen the last card if it is mounted.
    func restoreSessionIfNeeded() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        installWorkspaceVolumeObserversIfNeeded()
        LaunchTrace.mark("restoreSessionIfNeeded begin")
        await LaunchTrace.measureAsync("reloadRecents") {
            await reloadRecents()
        }

        guard volume == nil else {
            LaunchTrace.mark("restoreSessionIfNeeded: volume already open")
            return
        }
        guard let remembered = try? await VolumeStore.shared.lastRemembered() else {
            statusText = "Open a GDEMU SD card to begin"
            // Blank window — no volume to restore; open sidebar for Open / Reopen.
            splitColumnVisibility = .all
            LaunchTrace.mark("restoreSessionIfNeeded: no remembered volume")
            return
        }

        statusText = "Restoring \(remembered.volumeName)…"
        LaunchTrace.mark("restoreSessionIfNeeded → openRemembered(\(remembered.volumeName))")
        await openRemembered(remembered, showErrorIfMissing: false)
        if volume == nil {
            // Remount failed (card not present) — blank window needs the sidebar.
            splitColumnVisibility = .all
        }
        // Successful restore: leave splitColumnVisibility alone (user / system preference).
        LaunchTrace.mark("restoreSessionIfNeeded end")
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
        // Already showing this card — don't wipe the list and rescan, but refresh
        // name/path/free space in case Finder renamed the volume while we were open.
        if volume?.volumeUUID == remembered.volumeUUID, !isScanning {
            await refreshOpenVolumeIdentity(preferredUUID: remembered.volumeUUID)
            return
        }

        // Paint restore chrome before any SD / bookmark I/O (bookmark resolve can stall).
        if volume == nil {
            statusText = "Restoring \(remembered.volumeName)…"
        }

        do {
            // Bookmark resolve, security scope, and existence check can hit a slow SD reader —
            // never block the main actor while waiting.
            struct PreparedOpen: Sendable {
                var url: URL
                var accessStarted: Bool
                var bookmarkData: Data?
            }
            let prepared: PreparedOpen = try await LaunchTrace.measureAsync("openRemembered prepare (detached)") {
                try await Task.detached(priority: .userInitiated) {
                    let resolved = try LaunchTrace.measure("resolveURL bookmark") {
                        try VolumeStore.resolveURL(from: remembered)
                    }
                    let url = resolved.url
                    LaunchTrace.mark("resolved URL: \(url.path)")

                    var accessStarted = false
                    if resolved.isSecurityScoped {
                        let ok = LaunchTrace.measure("startAccessingSecurityScopedResource") {
                            url.startAccessingSecurityScopedResource()
                        }
                        if ok {
                            accessStarted = true
                        } else if !FileManager.default.fileExists(atPath: url.path) {
                            throw VolumeStoreError.notMounted(remembered.volumeName)
                        }
                    }

                    let exists = LaunchTrace.measure("fileExists card root") {
                        FileManager.default.fileExists(atPath: url.path)
                    }
                    guard exists else {
                        throw VolumeStoreError.notMounted(remembered.volumeName)
                    }
                    return PreparedOpen(
                        url: url,
                        accessStarted: accessStarted,
                        bookmarkData: remembered.bookmarkData
                    )
                }.value
            }

            if prepared.accessStarted {
                accessURL = prepared.url
                bookmarkData = prepared.bookmarkData
            }

            // Pass remembered identity so path-only roots keep the same cache key after renames.
            await open(
                url: prepared.url,
                preexistingBookmark: remembered.bookmarkData,
                preferredVolumeUUID: remembered.volumeUUID
            )
        } catch {
            LaunchTrace.mark("openRemembered failed: \(error.localizedDescription)")
            if showErrorIfMissing {
                lastError = error.localizedDescription
            }
            statusText = "Open a GDEMU SD card to begin"
            await reloadRecents()
        }
    }

    func forgetRecent(_ remembered: RememberedVolume) async {
        try? await VolumeStore.shared.forget(uuid: remembered.volumeUUID)
        await reloadRecents()
    }

    /// Single-card empty state: reopen the most recent remembered volume.
    func reopenLastCard() {
        guard let remembered = lastRememberedVolume else { return }
        Task { await openRemembered(remembered, showErrorIfMissing: true) }
    }

    func open(
        url: URL,
        preexistingBookmark: Data? = nil,
        forceRescan: Bool = false,
        preferredVolumeUUID: String? = nil
    ) async {
        LaunchTrace.mark(
            "open begin forceRescan=\(forceRescan) preferred=\(preferredVolumeUUID ?? "nil") path=\(url.path)"
        )
        // Same card already open (sidebar / Open panel / restore) — keep list, no rescan.
        // Explicit Rescan / Clear Cache still passes forceRescan: true.
        if !forceRescan, !isScanning, isSameOpenVolume(as: url) {
            await refreshOpenVolumeChrome(for: url, persistRecents: true)
            LaunchTrace.mark("open early-return same volume")
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
        resetDuplicateAnalysisState()
        notDuplicateKeys = []
        games = []
        menuContentDirty = false
        // Drop previous card’s sort immediately so the Table does not keep stale header
        // chevrons / order while the new volume resolves (cold open was the worst case).
        displaySort = .mostRecentFirst
        displaySortLoadedForUUID = nil
        isScanning = true
        scanProgress = nil
        statusText = "Scanning \(url.lastPathComponent)…"

        // Lock identity for this open: remembered/preferred first (stable across Finder renames
        // and flaky FAT volume UUIDs), else disk UUID, else mint once.
        // Open Card (no preferred) still reuses a recent with the same path / volume name.
        var lockedVolumeUUID = preferredVolumeUUID
        if lockedVolumeUUID == nil {
            lockedVolumeUUID = try? await VolumeStore.shared.matchingRecentUUID(for: url)
            if let lockedVolumeUUID {
                LaunchTrace.mark("open matched recent UUID \(lockedVolumeUUID)")
            }
        }
        let preferredForEarly = lockedVolumeUUID

        // Show volume chrome immediately; table fills as folders are identified.
        // Resolve off main — capacity/read-only queries can stall on slow SD readers.
        let earlyVolume = await LaunchTrace.measureAsync("VolumeIdentity.resolve (detached)") {
            await Task.detached(priority: .userInitiated) {
                try? VolumeIdentity.resolve(rootURL: url, preferredUUID: preferredForEarly)
            }.value
        }
        if let resolved = earlyVolume {
            lockedVolumeUUID = resolved.volumeUUID
            // Load sort *before* publishing `volume` so GameListView’s onChange(volumeUUID)
            // applies the correct comparators (and remounts the Table) on first paint.
            await LaunchTrace.measureAsync("loadDisplaySort") {
                await loadDisplaySort(for: resolved.volumeUUID)
            }
            await LaunchTrace.measureAsync("loadNotDuplicateKeys") {
                await loadNotDuplicateKeys(for: resolved.volumeUUID)
            }
            volume = resolved
        }

        // Let SwiftUI paint chrome before scan work.
        await Task.yield()

        // Keep any preexisting security-scope bookmark for this open; refresh off the
        // critical path (bookmark creation can stall seconds on some SD readers).
        if bookmarkData == nil {
            bookmarkData = preexistingBookmark
        }

        do {
            // Recent / reopen: paint from Application Support cache without waiting on SD readdir.
            let preferSnapshot = !forceRescan
            if preferSnapshot {
                statusText = "Opening \(url.lastPathComponent)…"
            }

            let preferredForScan = lockedVolumeUUID
            var firstProgressAt: CFAbsoluteTime?
            let result = try await LaunchTrace.measureAsync("CardScanner.scan preferSnapshot=\(preferSnapshot)") {
                try await CardScanner.scan(
                    rootURL: url,
                    preferSnapshotCache: preferSnapshot,
                    preferredVolumeUUID: preferredForScan
                ) { event in
                    if firstProgressAt == nil {
                        firstProgressAt = CFAbsoluteTimeGetCurrent()
                        LaunchTrace.mark(
                            "scan first progress: \(event.entries.count) entries completed=\(event.completed)/\(event.total)"
                        )
                    }
                    let uiStart = CFAbsoluteTimeGetCurrent()
                    await MainActor.run {
                        self.insertScannedEntries(event.entries)
                        // Full-list first paint (cache trust) — don't show "Scanning… n/n".
                        if event.completed < event.total {
                            self.scanProgress = (event.completed, event.total)
                            self.statusText = "Scanning… \(event.completed)/\(event.total)"
                        }
                    }
                    let uiMs = Int((CFAbsoluteTimeGetCurrent() - uiStart) * 1000)
                    if uiMs >= 16 || event.entries.count >= 50 {
                        LaunchTrace.mark(
                            "scan UI apply \(event.entries.count) rows completed=\(event.completed)/\(event.total) (\(uiMs)ms main)"
                        )
                    }
                }
            }

            LaunchTrace.mark(
                "scan result: \(result.entries.count) games hits=\(result.cacheHits) misses=\(result.cacheMisses) scannerMs=\(result.durationMilliseconds)"
            )

            volume = result.volume
            // Final authoritative order (progress may have arrived out of slot order).
            let applyStart = CFAbsoluteTimeGetCurrent()
            replaceGames(result.entries, refreshInspector: false)
            if let first = result.entries.first {
                selection = [first.id] // didSet rebuilds inspector
            } else {
                selection = []
            }
            rebuildInspectorSnapshot()
            LaunchTrace.mark(
                "assign games+selection (\(result.entries.count)) (\(Int((CFAbsoluteTimeGetCurrent() - applyStart) * 1000))ms)"
            )
            if result.cacheMisses == 0, result.cacheHits > 0, preferSnapshot {
                lastScanStats = "\(result.cacheHits) from cache · \(result.durationMilliseconds) ms"
            } else {
                lastScanStats = "\(result.cacheHits) cached · \(result.cacheMisses) scanned · \(result.durationMilliseconds) ms"
            }

            // List is interactive as soon as rows are assigned — do not block on menu
            // detection (IP.BIN), trash summary, or bookmark refresh.
            scanProgress = nil
            isScanning = false
            refreshStatus()
            LaunchTrace.mark("open list interactive")

            // Serial/name dups first; size/hash grades refine after lazy details.
            scheduleDuplicateRecompute()
            startLazyDetailEnrichment(volumeUUID: result.volume.volumeUUID)

            let rememberVolume = result.volume
            let rememberRoot = url
            let rememberBookmark = bookmarkData
            let needsNotDup = notDuplicateKeys.isEmpty
            Task {
                // Bookmark refresh can stall; never gate first paint on it.
                let freshBookmark = await LaunchTrace.measureAsync("makeBookmark (deferred)") {
                    await Task.detached(priority: .utility) {
                        VolumeStore.makeBookmark(for: rememberRoot) ?? rememberBookmark
                    }.value
                }
                if let freshBookmark {
                    await MainActor.run { self.bookmarkData = freshBookmark }
                }
                await LaunchTrace.measureAsync("resolveMenuKind (deferred)") {
                    await self.resolveMenuKind(for: rememberVolume.volumeUUID, games: result.entries)
                }
                await self.loadCachedHashRate(for: rememberVolume.volumeUUID)
                if needsNotDup {
                    await self.loadNotDuplicateKeys(for: rememberVolume.volumeUUID)
                }
                await MainActor.run {
                    self.refreshTrashSummary()
                    if rememberVolume.isReadOnly {
                        self.flash("Card is read-only — check the SD lock switch")
                    }
                }
                await LaunchTrace.measureAsync("VolumeStore.remember (deferred)") {
                    try? await VolumeStore.shared.remember(
                        volume: rememberVolume,
                        rootURL: rememberRoot,
                        existingBookmark: freshBookmark ?? rememberBookmark
                    )
                }
                await self.reloadRecents()
            }
            LaunchTrace.mark("open end OK (list ready)")
            // Content hashing is never automatic — user starts it from Duplicates / Card menu.
        } catch {
            cancelLazyDetailEnrichment()
            volume = nil // also forces sidebar open via didSet
            games = []
            selection = []
            trashSummary = .empty
            resetDuplicateAnalysisState()
            notDuplicateKeys = []
            displaySort = .mostRecentFirst
            displaySortLoadedForUUID = nil
            menuKind = .gdMenu
            lastError = error.localizedDescription
            statusText = "Failed to open card"
            scanProgress = nil
            isScanning = false
            stopAccess()
        }
    }

    /// After a fast scan, fill folder/payload sizes and stored hash sidecars off the main actor.
    /// UI publishes are **coalesced** (~200 ms): per-batch `games[i]=…` was thrashing SwiftUI
    /// (Inspector + Table) for seconds on a 276-game card (Instruments ~30s mark).
    private func startLazyDetailEnrichment(volumeUUID: String) {
        cancelLazyDetailEnrichment()
        let pending = games.filter(\.needsDetailEnrichment)
        guard !pending.isEmpty else { return }

        detailEnrichmentGeneration &+= 1
        let generation = detailEnrichmentGeneration
        let work = pending.map { (id: $0.id, path: $0.folderPath) }
        // Larger FAT batches — fewer MainActor hops; flush still time-coalesced.
        let batchSize = 24

        detailEnrichmentTask = Task.detached(priority: .utility) {
            var i = 0
            while i < work.count {
                if Task.isCancelled { return }
                let end = min(i + batchSize, work.count)
                let batch = Array(work[i..<end])
                var batchResults: [(UUID, CardScanner.FolderDetails)] = []
                batchResults.reserveCapacity(batch.count)
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
                if !batchResults.isEmpty {
                    await MainActor.run {
                        guard generation == self.detailEnrichmentGeneration else { return }
                        self.enqueueEnrichmentDetails(batchResults)
                    }
                }
                i = end
            }

            await MainActor.run {
                guard generation == self.detailEnrichmentGeneration else { return }
                self.flushEnrichmentDetails(force: true)
                self.refreshStatus()
                // Final accurate grades once all sizes/hashes are known.
                self.scheduleDuplicateRecompute(showPendingMarkers: false)
                self.persistEnrichedCache(volumeUUID: volumeUUID)
            }
        }
    }

    private func enqueueEnrichmentDetails(_ batch: [(UUID, CardScanner.FolderDetails)]) {
        enrichmentPendingDetails.append(contentsOf: batch)
        let minInterval: CFAbsoluteTime = 0.22
        let elapsed = CFAbsoluteTimeGetCurrent() - enrichmentLastFlushAt
        if elapsed >= minInterval, enrichmentPendingDetails.count >= 24 {
            flushEnrichmentDetails(force: true)
            return
        }
        enrichmentFlushTask?.cancel()
        let wait = max(0, minInterval - elapsed)
        let generation = detailEnrichmentGeneration
        enrichmentFlushTask = Task { @MainActor in
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            guard !Task.isCancelled, generation == self.detailEnrichmentGeneration else { return }
            self.flushEnrichmentDetails(force: true)
        }
    }

    /// Apply pending size/hash fields in one `games` write (single Observation pulse).
    private func flushEnrichmentDetails(force: Bool) {
        guard force, !enrichmentPendingDetails.isEmpty else { return }
        let pending = enrichmentPendingDetails
        enrichmentPendingDetails = []
        enrichmentLastFlushAt = CFAbsoluteTimeGetCurrent()
        enrichmentFlushTask = nil

        var indexByID: [GameEntry.ID: Int] = [:]
        indexByID.reserveCapacity(games.count)
        for (i, g) in games.enumerated() {
            indexByID[g.id] = i
        }

        var next = games
        var selectedTouched = false
        var any = false
        for (id, details) in pending {
            guard let idx = indexByID[id] else { continue }
            next[idx].byteSize = details.byteSize
            next[idx].payloadByteSize = details.payloadByteSize
            if let sha = details.contentSHA256 {
                next[idx].contentSHA256 = sha
            }
            next[idx].detailsLoaded = true
            any = true
            if selection.contains(id) {
                selectedTouched = true
            }
        }
        guard any else { return }
        games = next
        // Only rebuild inspector when the *selected* row’s sizes/hashes changed.
        if selectedTouched {
            rebuildInspectorSnapshot()
        }
    }

    private func cancelLazyDetailEnrichment() {
        detailEnrichmentGeneration &+= 1
        detailEnrichmentTask?.cancel()
        detailEnrichmentTask = nil
        enrichmentFlushTask?.cancel()
        enrichmentFlushTask = nil
        enrichmentPendingDetails = []
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

    /// Batch insert for scan progress — one array mutation pass, optional single scroll target.
    /// First event often contains a full-slot skeleton (stubs / cache) so the table height
    /// is stable; later events replace rows by slot number without inserting/deleting.
    private func insertScannedEntries(_ entries: [GameEntry]) {
        guard !entries.isEmpty else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        // Merge sorted by slot into `games` (also kept sorted by number).
        let incoming = entries.sorted { $0.number < $1.number }
        if games.isEmpty {
            games = incoming
        } else if incoming.count > 1,
                  games.count == incoming.count,
                  zip(games, incoming).allSatisfy({ $0.number == $1.number })
        {
            // Full-list replace in slot order (snapshot / first-paint skeleton).
            games = incoming
        } else {
            for entry in incoming {
                insertScannedEntry(entry)
            }
        }
        if isScanning, scrollToNewRows, let last = incoming.last {
            selection = [last.id]
            scrollTargetGameID = last.id
        }
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        if ms >= 8 || incoming.count >= 50 {
            LaunchTrace.mark("insertScannedEntries n=\(incoming.count) gamesNow=\(games.count) (\(ms)ms)")
        }
    }

    /// O(n²) duplicate analysis off the main actor; results land asynchronously.
    ///
    /// - Parameters:
    ///   - showPendingMarkers: When true, every row shows “—” until this run finishes.
    ///     Defaults to **only** when there is no map yet (first paint). Incremental
    ///     updates (not-a-dupe, size enrichment, hashing) keep existing badges so the
    ///     table does not blank out or thrash.
    ///   - debounce: Coalesce rapid callers (enrichment batches / per-file hashes).
    private func scheduleDuplicateRecompute(
        showPendingMarkers: Bool? = nil,
        debounce: Duration? = nil
    ) {
        guard duplicatesEnabled else { return }
        let showPending = showPendingMarkers ?? duplicateInfoByID.isEmpty
        if let debounce {
            duplicateRecomputeDebounceTask?.cancel()
            duplicateRecomputeDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
                self.runDuplicateRecompute(showPendingMarkers: showPending)
            }
            return
        }
        duplicateRecomputeDebounceTask?.cancel()
        duplicateRecomputeDebounceTask = nil
        runDuplicateRecompute(showPendingMarkers: showPending)
    }

    private func resetDuplicateAnalysisState() {
        duplicateRecomputeDebounceTask?.cancel()
        duplicateRecomputeDebounceTask = nil
        duplicateRecomputeGeneration &+= 1
        duplicateInfoByID = [:]
        isDuplicateInfoComputing = false
        hasDuplicateAnalysis = false
    }

    private func runDuplicateRecompute(showPendingMarkers: Bool) {
        duplicateRecomputeGeneration &+= 1
        let generation = duplicateRecomputeGeneration
        let snapshot = games
        let ignored = notDuplicateKeys
        if snapshot.isEmpty {
            duplicateInfoByID = [:]
            isDuplicateInfoComputing = false
            hasDuplicateAnalysis = true
            return
        }
        // First analysis for this card: pending badges + unfiltered “duplicates only” list.
        // Always set computing on first pass so sidebar metrics show “—” (not zeros / empty).
        let firstPass = !hasDuplicateAnalysis
        if showPendingMarkers || firstPass {
            isDuplicateInfoComputing = true
        }
        let volumeUUID = volume?.volumeUUID
        LaunchTrace.mark("DuplicateDetector.analyze schedule n=\(snapshot.count)")
        Task.detached(priority: .utility) {
            let signature = DuplicateDetector.analysisSignature(
                games: snapshot,
                ignoredIdentityKeys: ignored
            )

            // Disk cache hit: same names/sizes/hashes as last run for this volume.
            if let uuid = volumeUUID,
               let cached = try? await CardCacheStore.shared.loadDuplicates(volumeUUID: uuid),
               cached.signature == signature,
               let mapped = DuplicateDetector.mapFromCache(cached, onto: snapshot)
            {
                LaunchTrace.mark("DuplicateDetector cache HIT rows=\(mapped.count)")
                await MainActor.run {
                    guard generation == self.duplicateRecomputeGeneration else { return }
                    self.duplicateInfoByID = mapped
                    self.isDuplicateInfoComputing = false
                    self.hasDuplicateAnalysis = true
                    if !self.selection.isEmpty {
                        self.rebuildInspectorSnapshot()
                    }
                }
                return
            }

            let info = LaunchTrace.measure("DuplicateDetector.analyze n=\(snapshot.count)") {
                DuplicateDetector.analyze(snapshot, ignoredIdentityKeys: ignored)
            }

            if let uuid = volumeUUID {
                let record = DuplicateDetector.cacheRecord(
                    volumeUUID: uuid,
                    signature: signature,
                    games: snapshot,
                    info: info
                )
                try? await CardCacheStore.shared.saveDuplicates(record)
                LaunchTrace.mark("DuplicateDetector cache SAVE rows=\(record.rows.count)")
            }

            await MainActor.run {
                guard generation == self.duplicateRecomputeGeneration else { return }
                let applyStart = CFAbsoluteTimeGetCurrent()
                self.duplicateInfoByID = info
                self.isDuplicateInfoComputing = false
                self.hasDuplicateAnalysis = true
                if !self.selection.isEmpty {
                    self.rebuildInspectorSnapshot()
                }
                LaunchTrace.mark(
                    "DuplicateDetector apply map size=\(info.count) (\(Int((CFAbsoluteTimeGetCurrent() - applyStart) * 1000))ms main)"
                )
            }
        }
    }

    /// Drop `ids` from the badge map and renumber remaining groups (optimistic UI).
    private static func duplicateMapRemoving(
        _ ids: Set<GameEntry.ID>,
        from map: [GameEntry.ID: DuplicateInfo]
    ) -> [GameEntry.ID: DuplicateInfo] {
        var byGroup: [String: [(GameEntry.ID, DuplicateInfo)]] = [:]
        for (id, info) in map where !ids.contains(id) {
            byGroup[info.groupKey, default: []].append((id, info))
        }
        var result: [GameEntry.ID: DuplicateInfo] = [:]
        for (_, members) in byGroup {
            guard members.count > 1 else { continue }
            let sorted = members.sorted { $0.1.indexInGroup < $1.1.indexInGroup }
            let size = sorted.count
            for (offset, pair) in sorted.enumerated() {
                var info = pair.1
                info.indexInGroup = offset + 1
                info.groupSize = size
                result[pair.0] = info
            }
        }
        return result
    }

    private func loadNotDuplicateKeys(for volumeUUID: String) async {
        notDuplicateKeys = (try? await VolumeStore.shared.notDuplicateKeys(for: volumeUUID)) ?? []
    }

    /// Load persisted visual sort for this card (default: newest slots first).
    func loadDisplaySort(for volumeUUID: String) async {
        let loaded = (try? await VolumeStore.shared.displaySort(for: volumeUUID))
            ?? .mostRecentFirst
        displaySort = loaded
        displaySortLoadedForUUID = volumeUUID
    }

    /// Load last hashing throughput for instant ETA on “Compute Missing Hashes”.
    private func loadCachedHashRate(for volumeUUID: String) async {
        if let rate = try? await VolumeStore.shared.hashBytesPerSecond(for: volumeUUID),
           rate.isFinite, rate > 0
        {
            cachedHashBytesPerSecond = rate
        } else {
            cachedHashBytesPerSecond = nil
        }
    }

    /// Persist table column sort for the open card.
    func saveDisplaySort(_ sort: DisplaySortPreference) {
        displaySort = sort
        // Only write once sort has been loaded for *this* open volume (prevents the
        // previous card’s header state from being saved onto a newly opened UUID).
        guard let uuid = volume?.volumeUUID, uuid == displaySortLoadedForUUID else { return }
        Task {
            try? await VolumeStore.shared.setDisplaySort(sort, for: uuid)
        }
    }

    /// Prefer saved choice for picker; always set `bakedMenuKind` from what’s on the card.
    /// Detection may open the menu disc image (IP.BIN) — always off the main actor.
    private func resolveMenuKind(for volumeUUID: String, games: [GameEntry]) async {
        let snapshot = games
        let detected = await LaunchTrace.measureAsync("detectMenuKind (detached)") {
            await Task.detached(priority: .utility) {
                MenuRebuildService.detectMenuKind(games: snapshot) ?? .gdMenu
            }.value
        }
        bakedMenuKind = detected
        if let saved = try? await VolumeStore.shared.menuKind(for: volumeUUID) {
            menuKind = saved
        } else {
            menuKind = detected
            // Remember detection so rebuild stays consistent even if name.txt is edited later.
            try? await VolumeStore.shared.setMenuKind(menuKind, for: volumeUUID)
        }
    }

    /// User chose GDmenu vs openMenu. Rebuild only if type ≠ baked image or list is dirty.
    func setMenuKind(_ kind: MenuKind) {
        guard menuKind != kind else { return }
        menuKind = kind
        if let uuid = volume?.volumeUUID {
            Task {
                try? await VolumeStore.shared.setMenuKind(kind, for: uuid)
            }
        }
        guard volume != nil, !games.isEmpty else { return }
        if menuKind == bakedMenuKind {
            // Restored the type already on the card — no type-mismatch rebuild.
            if menuContentDirty {
                flash("Menu set to \(kind.displayName) — list still needs rebuild (⌘S)")
            } else {
                flash("Menu set to \(kind.displayName)")
            }
        } else {
            flash("Menu set to \(kind.displayName) — rebuild to apply (⌘S)")
        }
    }

    func rescan() async {
        guard let volume else { return }
        await open(
            url: volume.rootURL,
            preexistingBookmark: bookmarkData,
            forceRescan: true,
            preferredVolumeUUID: volume.volumeUUID
        )
    }

    /// Drop the Application Support scan cache for the open volume and re-read the card.
    func clearCacheAndRescan() async {
        guard let volume, !isBusy else { return }
        let name = volume.volumeName
        let uuid = volume.volumeUUID
        try? await CardCacheStore.shared.clear(volumeUUID: uuid)
        flash("Cleared cache for \(name)")
        await open(
            url: volume.rootURL,
            preexistingBookmark: bookmarkData,
            forceRescan: true,
            preferredVolumeUUID: uuid
        )
    }

    /// True when `url` is the card currently loaded (by volume UUID or standardized path).
    private func isSameOpenVolume(as url: URL) -> Bool {
        guard let volume else { return false }
        if volume.rootURL.standardizedFileURL == url.standardizedFileURL {
            return true
        }
        // Prefer current identity so path-only roots don't mint a new id on compare.
        if let resolved = try? VolumeIdentity.resolve(
            rootURL: url,
            preferredUUID: volume.volumeUUID
        ),
           resolved.volumeUUID == volume.volumeUUID
        {
            return true
        }
        return false
    }

    /// Refresh free-space chrome, display name, and root path from the live volume.
    /// - Parameter persistRecents: When true, update `volumes.json` so Reopen / Recent show the new label.
    private func refreshOpenVolumeChrome(for url: URL, persistRecents: Bool = false) async {
        let preferred = volume?.volumeUUID
        // Resolve off main — capacity / name queries can stall on slow SD.
        let resolved = await Task.detached(priority: .utility) {
            try? VolumeIdentity.resolve(rootURL: url, preferredUUID: preferred)
        }.value
        guard let resolved else { return }

        let nameChanged = volume?.volumeName != resolved.volumeName
        let pathChanged = volume?.rootURL.standardizedFileURL != resolved.rootURL.standardizedFileURL
        volume = resolved
        // Keep security-scope URL aligned when Finder renames /Volumes/Old → /Volumes/New.
        if pathChanged {
            accessURL = resolved.rootURL
        }
        await loadCachedHashRate(for: resolved.volumeUUID)

        if persistRecents || nameChanged || pathChanged {
            let rememberVolume = resolved
            let rememberRoot = resolved.rootURL
            let rememberBookmark = bookmarkData
            Task {
                try? await VolumeStore.shared.remember(
                    volume: rememberVolume,
                    rootURL: rememberRoot,
                    existingBookmark: rememberBookmark
                )
                await reloadRecents()
            }
            if nameChanged {
                LaunchTrace.mark("volume name refreshed → \(resolved.volumeName)")
            }
        }
    }

    /// Re-resolve the open card’s path/name (bookmark or current root) after external renames.
    private func refreshOpenVolumeIdentity(preferredUUID: String? = nil) async {
        guard let volume, !isScanning else { return }
        let uuid = preferredUUID ?? volume.volumeUUID

        // Prefer live root if it still exists (same mount point path).
        if FileManager.default.fileExists(atPath: volume.rootURL.path) {
            await refreshOpenVolumeChrome(for: volume.rootURL, persistRecents: true)
            return
        }

        // Path gone after rename — recover via remembered bookmark / /Volumes/<name>.
        if let remembered = try? await VolumeStore.shared.remembered(uuid: uuid)
            ?? recentVolumes.first(where: { $0.volumeUUID == uuid })
        {
            do {
                let resolved = try await Task.detached(priority: .userInitiated) {
                    try VolumeStore.resolveURL(from: remembered)
                }.value
                if resolved.isSecurityScoped {
                    _ = resolved.url.startAccessingSecurityScopedResource()
                    accessURL = resolved.url
                    bookmarkData = remembered.bookmarkData
                }
                await refreshOpenVolumeChrome(for: resolved.url, persistRecents: true)
                return
            } catch {
                LaunchTrace.mark("refreshOpenVolumeIdentity resolve failed: \(error.localizedDescription)")
            }
        }

        await loadCachedHashRate(for: uuid)
    }

    /// Finder volume renames + return-to-app: keep title/sidebar name in sync without rescan.
    private func installWorkspaceVolumeObserversIfNeeded() {
        guard !didInstallWorkspaceObservers else { return }
        didInstallWorkspaceObservers = true
        let nc = NSWorkspace.shared.notificationCenter

        let rename = nc.addObserver(
            forName: NSWorkspace.didRenameVolumeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let newURL = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            let oldURL = note.userInfo?[NSWorkspace.oldVolumeURLUserInfoKey] as? URL
            Task { @MainActor in
                await self.handleWorkspaceVolumeRename(oldURL: oldURL, newURL: newURL)
            }
        }
        let activate = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Cheap when name/path unchanged; fixes renames that happened while we were in the background.
                await self.refreshOpenVolumeIdentity()
            }
        }
        workspaceObserverTokens = [rename, activate]
    }

    private func handleWorkspaceVolumeRename(oldURL: URL?, newURL: URL?) async {
        guard let volume, let newURL, !isScanning, !isBusy else { return }
        let our = volume.rootURL.standardizedFileURL
        let old = oldURL?.standardizedFileURL
        let matchesOld = old == our
        let matchesNew = newURL.standardizedFileURL == our
        // Same card under a new /Volumes/name (bookmark identity).
        let matchesUUID: Bool = {
            guard let resolved = try? VolumeIdentity.resolve(
                rootURL: newURL,
                preferredUUID: volume.volumeUUID
            ) else { return false }
            return resolved.volumeUUID == volume.volumeUUID
        }()

        guard matchesOld || matchesNew || matchesUUID else { return }
        LaunchTrace.mark(
            "workspace volume rename \(old?.path ?? "?") → \(newURL.path)"
        )
        await refreshOpenVolumeChrome(for: newURL, persistRecents: true)
    }

    /// Permanently remove soft-deleted games from `.katana-trash` (with confirmation).
    func emptyCardTrash() {
        guard let volume, !isBusy, !volume.isReadOnly else { return }

        let root = volume.rootURL
        let volumeName = volume.volumeName
        let capacity = volume.totalBytes
        let progress = makeProgressHandler()

        Task {
            // Size the trash off the main actor so the click never freezes the UI.
            let summary = await Task.detached(priority: .userInitiated) {
                CardOperations.trashSummary(on: root)
            }.value
            trashSummary = summary
            guard !summary.isEmpty else {
                flash("Trash is empty")
                return
            }

            let countWord = summary.itemCount == 1 ? "item" : "items"
            let sizeLabel = formatSize(summary.totalBytes, capacityHint: capacity)

            let alert = NSAlert()
            alert.messageText = "Empty card Trash?"
            alert.informativeText = """
            Permanently delete \(summary.itemCount) \(countWord) (\(sizeLabel)) from \(CardOperations.trashFolderName) on “\(volumeName)”.

            This cannot be undone. Numbered game slots are not affected.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Empty Trash")
            alert.addButton(withTitle: "Cancel")
            // Filled red danger control (white label on systemRed), not red-on-grey text.
            // `hasDestructiveAction` only tints the title — we want a solid bezel instead.
            let emptyButton = alert.buttons[0]
            emptyButton.hasDestructiveAction = false
            if #available(macOS 11.0, *) {
                emptyButton.bezelColor = .systemRed
            }
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            busyMessage = "Emptying trash…"
            defer { busyMessage = nil }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CardOperations.emptyTrash(rootURL: root, progress: progress)
                }.value
                let preferred = self.volume?.volumeUUID
                if let resolved = try? VolumeIdentity.resolve(rootURL: root, preferredUUID: preferred) {
                    self.volume = resolved
                }
                refreshTrashSummary()
                if result.itemCount == 0 {
                    flash("Trash was empty")
                } else {
                    let sizeNote = result.bytesFreed > 0
                        ? " · \(formatSize(result.bytesFreed, capacityHint: capacity)) freed"
                        : ""
                    flash("Emptied trash · \(result.itemCount) item\(result.itemCount == 1 ? "" : "s")\(sizeNote)")
                }
            } catch {
                lastError = error.localizedDescription
                refreshTrashSummary()
            }
        }
    }

    func eject() async {
        guard let volume, !isBusy else { return }
        busyMessage = "Ejecting \(volume.volumeName)…"
        defer { busyMessage = nil }

        let root = volume.rootURL
        let name = volume.volumeName
        let uuid = volume.volumeUUID
        do {
            // Keep last volume + recents so remount/relaunch can restore access.
            stopAccess()
            self.volume = nil // also forces sidebar open via didSet
            games = []
            selection = []
            trashSummary = .empty
            lastScanStats = nil
            menuContentDirty = false
            bakedMenuKind = .gdMenu
            menuKind = .gdMenu
            displaySort = .mostRecentFirst
            displaySortLoadedForUUID = nil
            undoManager.removeAllActions()
            resetDuplicateAnalysisState()
            try await VolumeEject.eject(rootURL: root)
            statusText = "Ejected \(name)"
            flash("Ejected")
            await reloadRecents()
        } catch {
            // Re-open if eject failed (still mounted).
            lastError = error.localizedDescription
            statusText = "Eject failed"
            await open(
                url: root,
                preexistingBookmark: bookmarkData,
                preferredVolumeUUID: uuid
            )
        }
    }

    // MARK: - Import (add discs)

    /// Pick disc images / game folders and copy them into the next free slots.
    func addGames() {
        guard canAddGames else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Select Dreamcast disc images or game folders (.gdi / .cdi / .ccd)"
        panel.prompt = "Add to Card"
        var types: [UTType] = [.folder]
        for ext in ["gdi", "cdi", "ccd"] {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        Task { await importDiscURLs(panel.urls) }
    }

    func importDiscURLs(_ urls: [URL]) async {
        guard canAddGames, let volume else { return }
        let root = volume.rootURL
        let snapshot = games
        let progress = makeProgressHandler()

        busyMessage = "Adding \(urls.count) disc\(urls.count == 1 ? "" : "s")…"
        defer { busyMessage = nil }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try CardOperations.importDiscs(
                    sources: urls,
                    games: snapshot,
                    rootURL: root,
                    progress: progress
                )
            }.value

            games = result.games
            if let last = result.added.last {
                selection = [last.id]
                if scrollToNewRows {
                    scrollTargetGameID = last.id
                }
            }
            scheduleDuplicateRecompute()
            markMenuNeedsRebuild()
            refreshStatus()
            invalidateCacheAsync()
            // Free space may have changed after large copies.
            let preferred = self.volume?.volumeUUID
            if let resolved = try? VolumeIdentity.resolve(rootURL: root, preferredUUID: preferred) {
                self.volume = resolved
            }

            if result.added.isEmpty {
                let reason = result.skipped.first?.reason ?? "Nothing to add"
                lastError = reason
                flash("No discs added")
            } else {
                let skipNote = result.skipped.isEmpty
                    ? ""
                    : " · \(result.skipped.count) skipped"
                flash("Added \(result.added.count) game\(result.added.count == 1 ? "" : "s")\(skipNote)")
                // New slots get content hashes in the background for duplicate detection.
                startHashingImportedGames(result.added)
                if !result.skipped.isEmpty {
                    let detail = result.skipped
                        .prefix(5)
                        .map { "\($0.url.lastPathComponent): \($0.reason)" }
                        .joined(separator: "\n")
                    lastError = "Some items were skipped:\n\(detail)"
                }
            }
        } catch {
            lastError = error.localizedDescription
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
            // Disable animations around the row/title update — SwiftUI Table + subtitle
            // reflow was shifting the entire split view under the titlebar.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                games[index].name = trimmed
                games[index].isMenu = GameEntry.isMenuName(trimmed) || games[index].number == 1
                markMenuNeedsRebuild()
            }
            // Name-only change: patch cache in place so the next launch can still snapshot.
            persistNameCacheUpdates(for: [games[index]])
            if selection.contains(id) {
                rebuildInspectorSnapshot()
            }

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
        applyBulkRename(to: selectedGames, actionName: "Sentence Case") { $0.name.sentenceCasedTitle }
    }

    /// Apply title case to every selected game (immediate writes).
    func titleCaseSelection() {
        applyBulkRename(to: selectedGames, actionName: "Title Case") { $0.name.titleCasedName }
    }

    /// Apply uppercase to every selected game (immediate writes).
    func uppercaseSelection() {
        applyBulkRename(to: selectedGames, actionName: "Uppercase") { $0.name.uppercasedName }
    }

    /// Apply lowercase to every selected game (immediate writes).
    func lowercaseSelection() {
        applyBulkRename(to: selectedGames, actionName: "Lowercase") { $0.name.lowercasedName }
    }

    /// Auto-rename selection from IP.BIN / folder name / disc file name (GCM-style).
    func autoRenameSelection(from source: AutoRenameSource) {
        autoRename(ids: selection, from: source)
    }

    func autoRename(ids: Set<UUID>, from source: AutoRenameSource) {
        let targets = games.filter { ids.contains($0.id) }
        guard !targets.isEmpty, !isBusy else { return }

        applyBulkRename(to: targets, actionName: source.menuTitle) { game in
            source.suggestedName(for: game)
        }
    }

    /// Shared path for sentence-case / auto-rename batches (undoable).
    private func applyBulkRename(
        to targets: [GameEntry],
        actionName: String,
        newName: (GameEntry) -> String?
    ) {
        guard !targets.isEmpty, !isBusy else { return }

        var undos: [(UUID, String)] = []
        var skipped = 0
        for game in targets {
            guard let converted = newName(game)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !converted.isEmpty
            else {
                skipped += 1
                continue
            }
            guard converted != game.name else { continue }
            guard let index = games.firstIndex(where: { $0.id == game.id }) else { continue }
            do {
                let previous = try CardOperations.rename(game: games[index], to: converted)
                games[index].name = converted
                games[index].isMenu = GameEntry.isMenuName(converted) || games[index].number == 1
                undos.append((game.id, previous))
            } catch {
                lastError = error.localizedDescription
                break
            }
        }

        guard !undos.isEmpty else {
            if skipped == targets.count {
                flash("No names available from that source")
            } else {
                flash("Names already match")
            }
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            markMenuNeedsRebuild()
        }
        let renamed = undos.compactMap { id, _ in games.first(where: { $0.id == id }) }
        persistNameCacheUpdates(for: renamed)
        if !selection.isEmpty {
            rebuildInspectorSnapshot()
        }
        flash(undos.count == 1 ? "Renamed" : "Renamed \(undos.count) games")

        undoManager.registerUndo(withTarget: self) { target in
            for (id, previous) in undos.reversed() {
                target.rename(id: id, to: previous)
            }
        }
        let label = undos.count == 1 ? actionName : "\(actionName) (\(undos.count))"
        undoManager.setActionName(label)
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
                refreshTrashSummary()
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
                refreshTrashSummary()
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
        volume != nil && !games.isEmpty && !isBusy && !isHashing
    }

    func markMenuNeedsRebuild() {
        // Avoid implicit layout animation when the rebuild strip appears — that was
        // sliding the whole window contents up under the titlebar after rename.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            menuContentDirty = true
        }
    }

    /// After a successful bake: list matches disc and baked kind matches the picker.
    func clearMenuNeedsRebuild() {
        menuContentDirty = false
        bakedMenuKind = menuKind
    }

    /// Rebuild the on-console GDmenu / openMenu image so the list matches current slots/names.
    func rebuildMenuList() {
        guard canRebuildMenu || (isHandlingQuit && !isHashing && volume != nil && !games.isEmpty) else {
            if isHashing {
                flash("Stop hashing before rebuilding the menu")
            }
            return
        }
        Task {
            _ = await rebuildMenuListAsync()
        }
    }

    /// Rebuild menu; returns `true` on success. Used by toolbar and quit flow.
    @discardableResult
    func rebuildMenuListAsync() async -> Bool {
        guard volume != nil, !games.isEmpty else { return false }
        // Never contend with hashing for SD card I/O.
        guard !isHashing else {
            lastError = "Can’t rebuild the menu while content hashing is running."
            flash("Stop hashing before rebuilding the menu")
            return false
        }
        // Allow quit-time rebuild even if `isBusy` was set by the quit handler.
        guard !isScanning, !isRebuildingMenu else { return false }
        if busyMessage != nil, !isHandlingQuit { return false }

        let snapshot = games
        guard let root = volume?.rootURL else { return false }
        let kind = menuKind

        isRebuildingMenu = true
        rebuildProgress = 0
        statusText = "Rebuilding \(kind.displayName)…"
        defer {
            isRebuildingMenu = false
            rebuildProgress = nil
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
                    progress: { [weak self] message, fraction in
                        Task { @MainActor in
                            guard let self, self.isRebuildingMenu else { return }
                            self.rebuildProgress = min(1, max(0, fraction))
                            self.statusText = message
                        }
                    }
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
            bakedMenuKind = result.menuKind
            menuContentDirty = false
            if let uuid = volume?.volumeUUID {
                try? await VolumeStore.shared.setMenuKind(result.menuKind, for: uuid)
            }

            refreshStatus()
            invalidateCacheAsync()
            flash("Rebuilt \(result.menuKind.displayName) · \(result.itemCount) items")
            statusText = "\(result.menuKind.displayName) rebuilt · \(result.itemCount) items · \(formatSize(Int64(result.listByteCount))) list"
            return true
        } catch {
            lastError = error.localizedDescription
            refreshStatus()
            return false
        }
    }

    // MARK: - Quit (rebuild → eject → exit)

    /// Called from `AppDelegate.applicationShouldTerminate`.
    func handleApplicationShouldTerminate() -> NSApplication.TerminateReply {
        if isHandlingQuit {
            return .terminateNow
        }

        // Don't interrupt in-flight card work (rebuild, imports, …).
        if isBusy {
            let alert = NSAlert()
            alert.messageText = "Still working"
            alert.informativeText = busyMessage ?? "Wait for the current operation to finish, then quit again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .terminateCancel
        }

        // Hashing is not `isBusy` (UI stays usable) but still owns the card.
        if isHashing {
            let alert = NSAlert()
            alert.messageText = "Hashing in progress"
            alert.informativeText = isStoppingHashing
                ? "Wait for the current file to finish, then quit again."
                : "Stop hashing (or wait for it to finish) before quitting. Rebuilding the menu and hashing both use the SD card heavily."
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
        // Rebuild uses the edge progress bar (isRebuildingMenu), not the center overlay.
        if !rebuild, shouldEject {
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
            trashSummary = .empty
            menuContentDirty = false
            bakedMenuKind = .gdMenu
            menuKind = .gdMenu
            displaySort = .mostRecentFirst
            displaySortLoadedForUUID = nil
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
        guard let volume else { return }
        // Subtitle under the volume name (nav title) — not the name again.
        // games · used (game folders) · free (volume) · menu · [Read-only]
        let capacity = volume.totalBytes
        var parts: [String] = [
            "\(games.count) games",
            formatSize(totalBytes, capacityHint: capacity),
        ]
        if let free = volume.freeBytes {
            parts.append("\(formatSize(free, capacityHint: capacity)) free")
        }
        parts.append(menuKind.displayName)
        if volume.isReadOnly {
            parts.append("Read-only")
        }
        statusText = parts.joined(separator: " · ")
    }

    /// Re-read `.katana-trash` item count and size for the open card (off main actor).
    func refreshTrashSummary() {
        guard let volume else {
            trashSummary = .empty
            return
        }
        let root = volume.rootURL
        let uuid = volume.volumeUUID
        Task.detached(priority: .utility) {
            let summary = CardOperations.trashSummary(on: root)
            await MainActor.run {
                // Drop the result if the user switched/ejected cards mid-walk.
                guard self.volume?.volumeUUID == uuid else { return }
                self.trashSummary = summary
            }
        }
    }

    private func invalidateCacheAsync() {
        guard let volume else { return }
        Task {
            try? await CardCacheStore.shared.clear(volumeUUID: volume.volumeUUID)
        }
    }

    /// After name-only renames, update the on-disk scan cache instead of deleting it.
    /// Folder set is unchanged — next open can still take the snapshot path.
    private func persistNameCacheUpdates(for games: [GameEntry]) {
        guard let volume, !games.isEmpty else { return }
        let uuid = volume.volumeUUID
        var namesByFolder: [String: (name: String, isMenu: Bool)] = [:]
        namesByFolder.reserveCapacity(games.count)
        for game in games {
            let folder = game.folderURL.lastPathComponent
            namesByFolder[folder] = (name: game.name, isMenu: game.isMenu)
        }
        Task {
            try? await CardCacheStore.shared.applyNameUpdates(
                volumeUUID: uuid,
                namesByFolder: namesByFolder
            )
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
        cachedHashBytesPerSecond = nil
        accessURL?.stopAccessingSecurityScopedResource()
        accessURL = nil
    }
}
