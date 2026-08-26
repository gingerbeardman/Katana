import SwiftUI

@main
struct KatanaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()

    init() {
        LaunchTrace.mark("KatanaApp.init")
        // Wire Delete → Delete Immediately… as ⌥-alternates on native NSMenus
        // (SwiftUI has no isAlternate API; pattern from 2UP).
        MenuOptionAlternates.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                // Narrow enough for sidebar + #/Title (optional columns can be hidden).
                .frame(minWidth: 720, minHeight: 480)
                .task {
                    LaunchTrace.mark("ContentView.task begin")
                    appDelegate.appState = state
                    // Warm GameDB off the main actor so first card scan doesn’t hitch.
                    Task.detached(priority: .utility) {
                        LaunchTrace.mark("GameDB warm start")
                        _ = GameDatabase.entryCount
                        LaunchTrace.mark("GameDB warm done (\(GameDatabase.entryCount) titles)")
                    }
                    // Let the first frame (window chrome, empty split view) paint before
                    // restoreSession touches the SD card / security-scope bookmarks.
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(50))
                    // Welcome after the main window exists so it centres and orders correctly.
                    WelcomeWindowController.shared.showIfFirstLaunch()
                    LaunchTrace.mark("ContentView.task → restoreSessionIfNeeded")
                    await state.restoreSessionIfNeeded()
                    state.checkForUpdatesInBackground()
                    LaunchTrace.mark("ContentView.task end")
                }
                .onAppear {
                    LaunchTrace.mark("ContentView.onAppear")
                    appDelegate.appState = state
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Card…") {
                    state.openCard()
                }
                .keyboardShortcutUnlessTextEditing("o", textEditing: state.isTextInputFocused)
            }

            CommandGroup(after: .pasteboard) {
                Button("Undo") {
                    state.undoManager.undo()
                }
                .keyboardShortcutUnlessTextEditing("z", textEditing: state.isTextInputFocused)
                // While typing, leave ⌘Z to the field editor / system Edit menu.
                .disabled(!state.undoManager.canUndo || state.isTextInputFocused)

                Button("Redo") {
                    state.undoManager.redo()
                }
                .keyboardShortcutUnlessTextEditing(
                    "z",
                    modifiers: [.command, .shift],
                    textEditing: state.isTextInputFocused
                )
                .disabled(!state.undoManager.canRedo || state.isTextInputFocused)
            }

            // Card-wide: volume, menu bake, trash, scan cache — not selection.
            CommandMenu("Card") {
                Button("Add Games…") {
                    state.addGames()
                }
                .keyboardShortcutUnlessTextEditing("i", textEditing: state.isTextInputFocused)
                .disabled(!state.canAddGames)
                .help("Add disc images or game folders. Hold ⌥ to keep source names (skip auto-rename).")

                Button("Apply A–Z Order to Card") {
                    state.sortAlphabetically()
                }
                .disabled(state.volume == nil || state.isBusy || state.isArranging)
                .help("Renumber game folders A–Z on the SD card (not table display sort)")

                Button(state.isArranging ? "Cancel Arrange" : "Arrange List…") {
                    if state.isArranging {
                        state.cancelArrange()
                    } else {
                        state.beginArrange()
                    }
                }
                .disabled((!state.canArrange && !state.isArranging) || state.isTextInputFocused)
                .help("Drag rows to reorder. Apply once to rename folders.")

                Divider()

                Button("Rebuild Menu List…") {
                    state.rebuildMenuList()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!state.canRebuildMenu)
                .help("Bake LIST.INI / OPENMENU.INI into slot 01")

                Picker("Menu Type", selection: Binding(
                    get: { state.menuKind },
                    set: { state.setMenuKind($0) }
                )) {
                    ForEach(MenuKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .disabled(state.volume == nil || state.isBusy)

                if state.duplicatesEnabled {
                    Divider()

                    Button("Compute Missing Hashes…") {
                        state.startContentHashing()
                    }
                    .disabled(!state.canStartHashing)
                    .help(
                        state.isBusy
                            ? "Wait for the current operation (e.g. menu rebuild) to finish before hashing."
                            : "Background SHA-256 of game payload; writes sidecars. Not available during menu rebuild."
                    )

                    Button(state.isStoppingHashing ? "Stopping…" : "Stop Hashing") {
                        state.stopContentHashing()
                    }
                    .disabled(!state.canStopHashing)
                }

                Divider()

                Button("Empty Card Trash…") {
                    state.emptyCardTrash()
                }
                .disabled(!state.canEmptyCardTrash)
                .help("Permanently delete soft-deleted games in .katana-trash on the card")

                Button("Eject Card") {
                    Task { await state.eject() }
                }
                .keyboardShortcutUnlessTextEditing(
                    "e",
                    modifiers: [.command, .shift],
                    textEditing: state.isTextInputFocused
                )
                .disabled(!state.canEject)

                Divider()

                Button("Rescan") {
                    Task { await state.rescan() }
                }
                .disabled(state.volume == nil || state.isBusy)
                .help("Re-read the open card from disk (uses cache when folders are unchanged)")

                Button("Clear Cache and Rescan") {
                    Task { await state.clearCacheAndRescan() }
                }
                .keyboardShortcutUnlessTextEditing("r", textEditing: state.isTextInputFocused)
                .disabled(state.volume == nil || state.isBusy)
                .help("Delete this card’s scan cache, then re-read every game folder from disk")
            }

            // Selection / row actions for the open card’s game list.
            CommandMenu("Game") {
                Menu("Manually Rename") {
                    Button("Sentence Case") {
                        state.sentenceCaseSelection()
                    }
                    Button("Title Case") {
                        state.titleCaseSelection()
                    }
                    Button("Uppercase") {
                        state.uppercaseSelection()
                    }
                    Button("Lowercase") {
                        state.lowercaseSelection()
                    }
                }
                .disabled(state.selection.isEmpty || state.isBusy)

                Menu("Automatically Rename") {
                    ForEach(AutoRenameSource.allCases) { source in
                        Button(source.menuTitle) {
                            state.autoRenameSelection(from: source)
                        }
                        .help(source.helpText)
                    }
                }
                .disabled(state.selection.isEmpty || state.isBusy)

                // Pair: soft Delete + ⌥-alternate Delete Immediately… (wired on the
                // native NSMenu by MenuOptionAlternates — only one row shows at a time).
                Button(state.selection.count > 1
                       ? "Delete \(state.selection.count) Games"
                       : "Delete Selected") {
                    state.deleteSelected()
                }
                .keyboardShortcutUnlessTextEditing(
                    .delete,
                    modifiers: [],
                    textEditing: state.isTextInputFocused
                )
                // ⌫ must delete characters in a text field, not games.
                .disabled(!state.canDeleteSelection || state.isTextInputFocused)
                .help("Soft-delete to card trash (fast, undoable). Hold ⌥ for Delete Immediately.")

                Button(state.selection.count > 1
                       ? "Delete \(state.selection.count) Games Immediately…"
                       : "Delete Immediately…") {
                    state.deleteSelectedImmediately()
                }
                .keyboardShortcutUnlessTextEditing(
                    .delete,
                    modifiers: [.option],
                    textEditing: state.isTextInputFocused
                )
                .disabled(!state.canDeleteSelection || state.isTextInputFocused)
                .help("Erase from the card now — not moved to trash; cannot be undone")

                Divider()

                Button(state.moveUpTitle) {
                    state.moveSelectionTowardTop()
                }
                .keyboardShortcutUnlessTextEditing(
                    .upArrow,
                    modifiers: .command,
                    textEditing: state.isTextInputFocused
                )
                .disabled(!state.canMoveSelectionUp || state.isBusy)
                .help(state.moveUpHelp)

                Button(state.moveDownTitle) {
                    state.moveSelectionTowardBottom()
                }
                .keyboardShortcutUnlessTextEditing(
                    .downArrow,
                    modifiers: .command,
                    textEditing: state.isTextInputFocused
                )
                .disabled(!state.canMoveSelectionDown || state.isBusy)
                .help(state.moveDownHelp)

                Button("Move to Top") {
                    state.moveSelectionToTop()
                }
                .keyboardShortcutUnlessTextEditing(
                    .upArrow,
                    modifiers: [.command, .option],
                    textEditing: state.isTextInputFocused
                )
                .disabled(!state.canMoveSelectionToTop || state.isBusy)
                .help(state.moveToTopHelp)

                Button("Move to Bottom") {
                    state.moveSelectionToBottom()
                }
                .keyboardShortcutUnlessTextEditing(
                    .downArrow,
                    modifiers: [.command, .option],
                    textEditing: state.isTextInputFocused
                )
                .disabled(!state.canMoveSelectionToBottom || state.isBusy)
                .help(state.moveToBottomHelp)

                Divider()

                Button("Select All") {
                    state.selection = Set(state.filteredGames.map(\.id))
                }
                .keyboardShortcutUnlessTextEditing("a", textEditing: state.isTextInputFocused)
                // ⌘A must select field text, not every game row — and a *disabled*
                // item that still has the equivalent beeps instead of reaching the field.
                .disabled(state.games.isEmpty || state.isBusy || state.isTextInputFocused)

                Button("Deselect All") {
                    state.selection = []
                }
                .disabled(state.selection.isEmpty)

                if state.duplicatesEnabled {
                    Divider()

                    Button("Select All Duplicates") {
                        state.selectAllDuplicates()
                    }
                    .disabled(state.games.isEmpty || state.isBusy)

                    Button("Select Exact Extras") {
                        state.selectExactRedundantDuplicates()
                    }
                    .disabled(state.exactDuplicateCount == 0 || state.isBusy)

                    Button("Select All Extras") {
                        state.selectRedundantDuplicates()
                    }
                    .disabled(state.redundantDuplicateCount == 0 || state.isBusy)

                    Button("Select Not-Duplicate Marks") {
                        state.selectMarkedNotDuplicates()
                    }
                    .disabled(state.gamesMarkedNotDuplicate.isEmpty || state.isBusy)
                    .help("Select games marked “not a duplicate” on this card")

                    Button("Clear Not-Duplicate Marks") {
                        state.clearAllNotDuplicateMarks()
                    }
                    .disabled(state.notDuplicateMarkCount == 0 || state.isBusy)
                    .help("Remove all not-a-duplicate marks for this card")
                }
            }

            // Inject into the system View menu (do not use CommandMenu("View") — that creates a second View).
            CommandGroup(after: .sidebar) {
                Toggle("Enable Duplicate Tools", isOn: Binding(
                    get: { state.duplicatesEnabled },
                    set: { state.duplicatesEnabled = $0 }
                ))
                .keyboardShortcutUnlessTextEditing("d", textEditing: state.isTextInputFocused)

                if state.duplicatesEnabled {
                    Toggle("Show Duplicate Markers", isOn: Binding(
                        get: { state.showDuplicateMarkers },
                        set: { state.showDuplicateMarkers = $0 }
                    ))
                    .keyboardShortcutUnlessTextEditing(
                        "d",
                        modifiers: [.command, .option],
                        textEditing: state.isTextInputFocused
                    )

                    Toggle("Show Duplicates Only", isOn: Binding(
                        get: { state.showDuplicatesOnly },
                        set: { state.showDuplicatesOnly = $0 }
                    ))
                    .disabled(state.games.isEmpty)
                }

                Divider()

                Button(state.isInspectorPresented ? "Hide Inspector" : "Show Inspector") {
                    state.isInspectorPresented.toggle()
                }
                .keyboardShortcutUnlessTextEditing(
                    "i",
                    modifiers: [.command, .option],
                    textEditing: state.isTextInputFocused
                )
            }

            CommandGroup(after: .help) {
                Button("Welcome to Katana") {
                    WelcomeWindowController.shared.show()
                }

                Button("Check for Updates…") {
                    state.checkForUpdates(userInitiated: true)
                }
            }
        }

        Settings {
            SettingsView(state: state)
        }
    }
}
