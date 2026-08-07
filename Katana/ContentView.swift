import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
        } detail: {
            GameListView(state: state)
                .navigationTitle(state.volume?.volumeName ?? "Katana")
                .navigationSubtitle(state.statusText)
                .inspector(isPresented: $state.isInspectorPresented) {
                    InspectorView(state: state)
                        .inspectorColumnWidth(min: 260, ideal: 280, max: 360)
                }
                // Toolbar lives on the detail column so trailing items sit with
                // search + inspector (search → inspector, trailing-most).
                .toolbar {
                    // Task actions sit inward of search (not primaryAction).
                    ToolbarItemGroup(placement: .automatic) {
                        Button {
                            state.openCard()
                        } label: {
                            Label("Open", systemImage: "folder")
                        }
                        .help("Open GDEMU SD card")

                        Button {
                            state.deleteSelected()
                        } label: {
                            Label("Delete", systemImage: "minus")
                        }
                        .disabled(!state.canDeleteSelection)
                        .help(state.selection.count > 1
                              ? "Remove \(state.selection.count) games and renumber"
                              : "Remove selected game and renumber")

                        Button {
                            state.moveSelection(up: true)
                        } label: {
                            Label("Up", systemImage: "arrow.up")
                        }
                        .disabled(!state.canMoveSelectionUp)

                        Button {
                            state.moveSelection(up: false)
                        } label: {
                            Label("Down", systemImage: "arrow.down")
                        }
                        .disabled(!state.canMoveSelectionDown)

                        Button {
                            state.sortAlphabetically()
                        } label: {
                            Label("Apply A–Z to Disc", systemImage: "arrow.up.arrow.down.square")
                        }
                        .disabled(state.volume == nil || state.games.count < 2 || state.isBusy)
                        .help("Renumber folders A–Z on the SD card. Click table headers to sort the view only.")

                        Button {
                            state.rebuildMenuList()
                        } label: {
                            Label(
                                state.menuNeedsRebuild ? "Rebuild Menu*" : "Rebuild Menu",
                                systemImage: "opticaldisc"
                            )
                        }
                        .disabled(!state.canRebuildMenu)
                        .help(
                            state.menuNeedsRebuild
                                ? "\(state.menuKind.displayName) is out of date — bake names/order into slot 01. You will also be prompted on quit."
                                : "Bake the current game list into the \(state.menuKind.displayName) image (slot 01)."
                        )
                        .symbolVariant(state.menuNeedsRebuild ? .fill : .none)

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
                        .disabled(state.games.isEmpty)
                        .help(
                            state.duplicateGameCount == 0
                                ? "No duplicates detected"
                                : "\(state.duplicateGroupCount) groups · \(state.redundantDuplicateCount) extras"
                        )
                        .symbolVariant(state.showDuplicatesOnly ? .fill : .none)

                        Button {
                            Task { await state.eject() }
                        } label: {
                            Label("Eject", systemImage: "eject")
                        }
                        .disabled(!state.canEject)
                        .help("Eject SD card")
                    }

                    // Trailing-most: only the inspector toggle as primaryAction,
                    // so it anchors to the right of the searchable field.
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            state.isInspectorPresented.toggle()
                        } label: {
                            Label("Inspector", systemImage: "sidebar.trailing")
                        }
                        .help(state.isInspectorPresented ? "Hide Inspector" : "Show Inspector")
                    }
                }
        }
        .overlay(alignment: .bottom) {
            if let flash = state.flashMessage {
                Text(flash)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: state.flashMessage)
        .overlay(alignment: .top) {
            if let err = state.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") { state.lastError = nil }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(10)
                .background(.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding()
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: state.lastError)
    }

}

#Preview {
    ContentView(state: AppState())
        .frame(width: 1000, height: 640)
}
