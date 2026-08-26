import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: $state.splitColumnVisibility) {
            SidebarView(state: state)
        } detail: {
            GameListView(state: state)
                .navigationTitle(state.volume?.volumeName ?? "Katana")
                .navigationSubtitle(state.statusText)
                .inspector(isPresented: $state.isInspectorPresented) {
                    InspectorView(state: state)
                        .inspectorColumnWidth(min: 260, ideal: 280, max: 360)
                }
                // Toolbar order (layout-toolbar): leading = highest-frequency task flow;
                // trailing = stable global/UI (search via .searchable, then inspector).
                // Default: Open · Add · Delete · Rebuild · A–Z · Eject | search | Inspector
                // Palette only: Up / Down / Duplicates (+ native Space / Flexible Space).
                .toolbar(id: "katana.main") {
                    // --- Leading: open / create ---
                    ToolbarItem(id: "open", placement: .primaryAction) {
                        Button {
                            state.openCard()
                        } label: {
                            Label("Open", systemImage: "folder")
                        }
                        .help("Open GDEMU SD card")
                    }

                    ToolbarItem(id: "add", placement: .primaryAction) {
                        Button {
                            state.addGames()
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .disabled(!state.canAddGames)
                        .help("Add disc images or game folders. Hold ⌥ to keep source names (skip auto-rename).")
                    }

                    // --- Edit selection ---
                    ToolbarItem(id: "delete", placement: .primaryAction) {
                        Button {
                            state.deleteSelected()
                        } label: {
                            Label("Delete", systemImage: "minus")
                        }
                        .disabled(!state.canDeleteSelection)
                        .help(state.selection.count > 1
                              ? "Soft-delete \(state.selection.count) games (⌫). Option-click / ⌥⌫ erases immediately."
                              : "Soft-delete selected game (⌫). Option-click / ⌥⌫ erases immediately.")
                    }

                    ToolbarItem(id: "move", placement: .primaryAction) {
                        ControlGroup {
                            Button {
                                state.moveSelectionToTop()
                            } label: {
                                Label("Top", systemImage: "arrow.up.to.line")
                            }
                            .disabled(!state.canMoveSelectionToTop)
                            .help(state.moveToTopHelp)
                            Button {
                                state.moveSelectionTowardTop()
                            } label: {
                                Label("Up", systemImage: "arrow.up")
                            }
                            .disabled(!state.canMoveSelectionUp)
                            .help(state.moveUpHelp)
                            Button {
                                state.moveSelectionTowardBottom()
                            } label: {
                                Label("Down", systemImage: "arrow.down")
                            }
                            .disabled(!state.canMoveSelectionDown)
                            .help(state.moveDownHelp)
                            Button {
                                state.moveSelectionToBottom()
                            } label: {
                                Label("Bottom", systemImage: "arrow.down.to.line")
                            }
                            .disabled(!state.canMoveSelectionToBottom)
                            .help(state.moveToBottomHelp)
                        }
                    }
                    .defaultCustomization(.hidden)

                    // --- Commit / organize (after edit) ---
                    ToolbarItem(id: "rebuildMenu", placement: .primaryAction) {
                        Button {
                            state.rebuildMenuList()
                        } label: {
                            Label(
                                state.menuNeedsRebuild ? "Rebuild Menu*" : "Rebuild Menu",
                                systemImage: "oven"
                            )
                        }
                        .disabled(!state.canRebuildMenu)
                        .help(
                            state.isHashing
                                ? "Stop hashing before rebuilding — both operations need exclusive access to the card."
                                : state.menuNeedsRebuild
                                    ? "\(state.menuKind.displayName) is out of date — bake names/order into slot 01. You will also be prompted on quit."
                                    : "Bake the current game list into the \(state.menuKind.displayName) image (slot 01)."
                        )
                        .symbolVariant(state.menuNeedsRebuild ? .fill : .none)
                    }

                    ToolbarItem(id: "arrange", placement: .primaryAction) {
                        Button {
                            if state.isArranging {
                                state.cancelArrange()
                            } else {
                                state.beginArrange()
                            }
                        } label: {
                            Label(
                                state.isArranging ? "Cancel Arrange" : "Arrange",
                                systemImage: "line.3.horizontal"
                            )
                        }
                        .disabled(!state.canArrange && !state.isArranging)
                        .help(state.isArranging
                              ? "Leave arrange mode without applying (or Apply in the bar above the list)"
                              : "Drag selected rows to reorder, or click here. Folders change only when you Apply.")
                        .symbolVariant(state.isArranging ? .fill : .none)
                    }

                    ToolbarItem(id: "sortAZ", placement: .primaryAction) {
                        Button {
                            state.sortAlphabetically()
                        } label: {
                            Label("Apply A–Z to Card", systemImage: "arrow.up.arrow.down.square")
                        }
                        .disabled(state.volume == nil || state.games.count < 2 || state.isBusy || state.isArranging)
                        .help("Renumber folders A–Z on the SD card. Click table headers to sort the view only.")
                    }

                    ToolbarItem(id: "duplicates", placement: .primaryAction) {
                        Button {
                            state.showDuplicatesOnly.toggle()
                        } label: {
                            Label(
                                state.showDuplicatesOnly ? "All Games" : "Duplicates",
                                systemImage: state.showDuplicatesOnly
                                    ? "square.stack.3d.up"
                                    : "square.stack.3d.up.badge.a"
                            )
                        }
                        .disabled(state.games.isEmpty || !state.duplicatesEnabled)
                        .help(
                            !state.duplicatesEnabled
                                ? "Duplicate tools are off (Settings → General)"
                                : (!state.hasDuplicateAnalysis || state.isDuplicateInfoComputing)
                                    ? "Detecting duplicates…"
                                    : state.duplicateGameCount == 0
                                        ? "No duplicates detected"
                                        : "\(state.duplicateGroupCount) groups · \(state.redundantDuplicateCount) extras"
                        )
                        .symbolVariant(state.showDuplicatesOnly ? .fill : .none)
                    }
                    .defaultCustomization(.hidden)

                    // --- Session end (later in flow) ---
                    ToolbarItem(id: "eject", placement: .primaryAction) {
                        Button {
                            Task { await state.eject() }
                        } label: {
                            Label("Eject", systemImage: "eject")
                        }
                        .disabled(!state.canEject)
                        .help("Eject SD card")
                    }

                    // Trailing-most global UI control (after searchable).
                    ToolbarItem(id: "inspector", placement: .confirmationAction) {
                        Button {
                            state.isInspectorPresented.toggle()
                        } label: {
                            Label("Inspector", systemImage: "sidebar.trailing")
                        }
                        .help(state.isInspectorPresented ? "Hide Inspector" : "Show Inspector")
                        .symbolVariant(state.isInspectorPresented ? .fill : .none)
                    }
                }
                .installNativeToolbarSpacers()
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if let flash = state.flashMessage {
                    Text(flash)
                        .font(.callout.weight(.medium).monospacedDigit())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Scoped to this overlay only — must not sit on NavigationSplitView
            // (that reflowed the whole window content up under the titlebar).
            .animation(.snappy, value: state.flashMessage)
        }
    }

}

#Preview {
    ContentView(state: AppState())
        .frame(width: 1000, height: 640)
}

#Preview("Update available") {
    let state = AppState()
    state.availableUpdate = UpdateChecker.AvailableUpdate(
        version: "4.0",
        htmlURL: URL(string: "https://github.com/gingerbeardman/Katana/releases")!,
        publishedAt: nil
    )
    return ContentView(state: state)
        .frame(width: 1000, height: 640)
}
