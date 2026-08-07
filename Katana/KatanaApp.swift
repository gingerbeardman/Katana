import SwiftUI

@main
struct KatanaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .frame(minWidth: 900, minHeight: 520)
                .task {
                    appDelegate.appState = state
                    await state.restoreSessionIfNeeded()
                }
                .onAppear {
                    appDelegate.appState = state
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Card…") {
                    state.openCard()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .pasteboard) {
                Button("Undo") {
                    state.undoManager.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                // While typing, leave ⌘Z to the field editor / system Edit menu.
                .disabled(!state.undoManager.canUndo || state.isTextInputFocused)

                Button("Redo") {
                    state.undoManager.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!state.undoManager.canRedo || state.isTextInputFocused)
            }

            CommandMenu("Card") {
                Button("Add Games…") {
                    state.addGames()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!state.canAddGames)

                Button("Apply A–Z Order to Disc") {
                    state.sortAlphabetically()
                }
                .disabled(state.volume == nil || state.isBusy)
                // Display sort is free via table column headers (does not touch disc).

                Button("Rebuild Menu List…") {
                    state.rebuildMenuList()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!state.canRebuildMenu || state.isTextInputFocused)
                // Bakes LIST.INI (GDmenu) or OPENMENU.INI (openMenu) into slot 01.
                // Disabled while hashing so rebuild and hash never contend for the card.

                Menu("Menu Type") {
                    ForEach(MenuKind.allCases) { kind in
                        Button {
                            state.setMenuKind(kind)
                        } label: {
                            HStack {
                                Text(kind.displayName)
                                if state.menuKind == kind {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                .disabled(state.volume == nil || state.isBusy)

                Menu("Automatically Rename") {
                    ForEach(AutoRenameSource.allCases) { source in
                        Button(source.menuTitle) {
                            state.autoRenameSelection(from: source)
                        }
                    }
                }
                .disabled(state.selection.isEmpty || state.isBusy)

                Button(state.selection.count > 1
                       ? "Delete \(state.selection.count) Games"
                       : "Delete Selected") {
                    state.deleteSelected()
                }
                .keyboardShortcut(.delete, modifiers: [])
                // ⌫ must delete characters in a text field, not games.
                .disabled(!state.canDeleteSelection || state.isTextInputFocused)

                Button("Select All") {
                    state.selection = Set(state.filteredGames.map(\.id))
                }
                .keyboardShortcut("a", modifiers: .command)
                // ⌘A must select field text, not every game row.
                .disabled(state.games.isEmpty || state.isBusy || state.isTextInputFocused)

                Button("Deselect All") {
                    state.selection = []
                }
                .disabled(state.selection.isEmpty)

                Divider()

                Button("Show Duplicates Only") {
                    state.showDuplicatesOnly.toggle()
                }
                .disabled(state.games.isEmpty)

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

                Divider()

                Button("Compute Missing Hashes…") {
                    state.startContentHashing()
                }
                .disabled(!state.canStartHashing)
                .help(
                    state.isBusy
                        ? "Wait for the current operation (e.g. menu rebuild) to finish before hashing."
                        : "Background SHA-256 of disc payload; writes sidecars. Not available during menu rebuild."
                )

                Button(state.isStoppingHashing ? "Stopping…" : "Stop Hashing") {
                    state.stopContentHashing()
                }
                .disabled(!state.canStopHashing)

                Divider()

                Button("Eject Card") {
                    Task { await state.eject() }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!state.canEject)

                Divider()

                Button("Rescan") {
                    Task { await state.rescan() }
                }
                .disabled(state.volume == nil || state.isBusy)
            }

            CommandGroup(after: .sidebar) {
                Button(state.isInspectorPresented ? "Hide Inspector" : "Show Inspector") {
                    state.isInspectorPresented.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }

            CommandMenu("View") {
                Toggle("Show Duplicate Markers", isOn: Binding(
                    get: { state.showDuplicateMarkers },
                    set: { state.showDuplicateMarkers = $0 }
                ))
                .keyboardShortcut("d", modifiers: [.command, .option])

                Toggle("Scroll to New Rows While Scanning", isOn: Binding(
                    get: { state.scrollToNewRows },
                    set: { state.scrollToNewRows = $0 }
                ))

                Toggle("Show Duplicates Only", isOn: Binding(
                    get: { state.showDuplicatesOnly },
                    set: { state.showDuplicatesOnly = $0 }
                ))
                .disabled(state.games.isEmpty)

                Divider()

                Button(state.isInspectorPresented ? "Hide Inspector" : "Show Inspector") {
                    state.isInspectorPresented.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        Settings {
            Form {
                Section("Philosophy") {
                    Text("Operations write immediately to the SD card. No Save button. No Done alerts.")
                    Text("Long work (renumber, copy) shows a spinner. Undo with ⌘Z when possible.")
                        .foregroundStyle(.secondary)
                }
                Section("View") {
                    Toggle("Show duplicate markers", isOn: Binding(
                        get: { state.showDuplicateMarkers },
                        set: { state.showDuplicateMarkers = $0 }
                    ))
                    Text("Grade badges (Exact 1/2, …) on titles in the game list. Off by default.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Toggle("Scroll to new rows while scanning", isOn: Binding(
                        get: { state.scrollToNewRows },
                        set: { state.scrollToNewRows = $0 }
                    ))
                    Text("Follow each game as the table fills (and after Add). Off by default.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Card") {
                    Toggle("Eject SD card on quit", isOn: Binding(
                        get: { state.ejectOnQuit },
                        set: { state.ejectOnQuit = $0 }
                    ))
                    Text("When on, quitting unmounts the open GDEMU card. Off by default — use the Eject button when you want to unplug.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Menu image") {
                    Picker("Menu type", selection: Binding(
                        get: { state.menuKind },
                        set: { state.setMenuKind($0) }
                    )) {
                        ForEach(MenuKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(state.volume == nil || state.isBusy)

                    Text(state.menuKind.helpText)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Text("After renames or reordering, use Card → Rebuild Menu List (⌘S) so the console menu matches the SD card. GDmenu and openMenu are both supported — pick the type above, then rebuild. Folder names and name.txt update immediately; the list is baked into slot 01.")
                        .foregroundStyle(.secondary)
                    Text("On quit, if the menu is out of date you will be prompted to rebuild. Eject-on-quit is optional (Settings → Card).")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 440)
            .padding()
        }
    }
}
