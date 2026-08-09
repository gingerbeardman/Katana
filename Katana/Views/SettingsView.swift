import SwiftUI

/// Katana Settings — two panels (General / Card). Layout follows macOS layout-settings
/// (right-aligned section labels, 20pt margins, checkbox descriptions indented).
struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        TabView {
            GeneralSettingsPanel(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }

            CardSettingsPanel(state: state)
                .tabItem { Label("SD Card", systemImage: "sdcard") }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General (view options)

private struct GeneralSettingsPanel: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Duplicates:") {
                SettingsToggle(
                    "Enable duplicate tools",
                    isOn: $state.duplicatesEnabled
                )
                SettingsDescription(
                    "Sidebar, list chips, hashing, and Card menu actions for finding copies. Off by default — turn on when you want to clean the card."
                )

                if state.duplicatesEnabled {
                    SettingsToggle(
                        "Show markers in list",
                        isOn: $state.showDuplicateMarkers
                    )
                    SettingsDescription(
                        "Grade chips in the # column (Exact 1/2, …)."
                    )

                    SettingsToggle(
                        "Show duplicates only",
                        isOn: $state.showDuplicatesOnly
                    )
                    SettingsDescription(
                        "Highlight duplicates and dim the rest. All rows stay in place."
                    )
                }
            }

            SettingsSeparator()

            SettingsSection(title: "List:") {
                SettingsToggle(
                    "Scroll to new rows while scanning",
                    isOn: $state.scrollToNewRows
                )
                SettingsDescription(
                    "Follow each game as the table fills (and after Add).\nOff by default."
                )
            }

            SettingsSeparator()

            SettingsSection(title: "Units:") {
                SettingsToggle(
                    "Show sizes as whole megabytes",
                    isOn: $state.sizesAsIntegerMB
                )
                SettingsDescription(
                    "Size column and inspector use whole MB (e.g. 1,188 MB). Off uses adaptive KB/MB. Title bar and sidebar free/capacity use GB when large."
                )
            }
        }
        .settingsPanelChrome()
    }
}

// MARK: - Card

private struct CardSettingsPanel: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Menu type:") {
                Picker("", selection: Binding(
                    get: { state.menuKind },
                    set: { state.setMenuKind($0) }
                )) {
                    ForEach(MenuKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(state.volume == nil || state.isBusy)

                Text(state.menuKind.helpText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                SettingsDescription(
                    "After renames or reordering, use Card → Rebuild (⌘S) so the menu matches the SD card. On quit you will be prompted if the menu image is out of date."
                )
                .padding(.top, 2)
            }

            SettingsSeparator()

            SettingsSection(title: "Multipass:") {
                SettingsToggle(
                    "Manage multiple cards",
                    isOn: $state.manageMultipleCards
                )
                SettingsDescription(
                    "Show a Recent list in the sidebar to switch between SD cards. Off by default — one card at a time; the last card still reopens on launch."
                )
            }

            SettingsSeparator()

            SettingsSection(title: "Cache:") {
                Button("Clear Cache and Rescan…") {
                    Task { await state.clearCacheAndRescan() }
                }
                .disabled(state.volume == nil || state.isBusy)
                SettingsDescription(
                    "Deletes the local scan cache for the open card and re-reads every game folder from the SD card. Does not change games or hashes on the card."
                )
            }

            SettingsSeparator()

            SettingsSection(title: "Eject:") {
                SettingsToggle(
                    "Eject SD card on quit",
                    isOn: $state.ejectOnQuit
                )
                SettingsDescription(
                    "Unmount the open GDEMU card when quitting. Off by default — use Eject when you want to unplug."
                )
            }
        }
        .settingsPanelChrome()
    }
}

// MARK: - Layout primitives (layout-settings)

private extension View {
    func settingsPanelChrome() -> some View {
        self
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Right-aligned section label + left-aligned control stack.
/// Label width is shared so colons line up (center equalization).
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    private static var labelWidth: CGFloat { 100 }
    private static var labelToControlGap: CGFloat { 6 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.labelToControlGap) {
            Text(title)
                .frame(width: Self.labelWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.checkbox)
    }
}

/// Description under a checkbox: secondary caption, 14pt indent under title, 4pt above.
private struct SettingsDescription: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 18)
            .padding(.top, 4)
    }
}

private struct SettingsSeparator: View {
    var body: some View {
        Divider()
            .padding(.vertical, 12)
    }
}

#Preview {
    SettingsView(state: AppState())
}
