import SwiftUI

/// The settings window's pages. Every control writes straight through to
/// `SettingsStore`, which applies the change to the running app. The pages are
/// hosted one per tab by `SettingsTabController`.
struct GeneralSettingsView: View {
    @Bindable var store: SettingsStore
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $store.launchesAtLogin)
                Toggle("Show menu bar icon", isOn: $store.showMenuBarIcon)
                if !store.showMenuBarIcon {
                    Text("With the icon hidden, launch OpenTab again to reopen this window.")
                        .settingsHelp()
                }
            }
            Section("Panel") {
                Picker("Position", selection: $store.panelPosition) {
                    ForEach(PanelPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Text size", selection: $store.textSize) {
                    ForEach(PanelTextSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Wider panel", isOn: $store.widePanel)
                Picker("Order", selection: $store.isAlphabetical) {
                    Text("Most recent first").tag(false)
                    Text("Alphabetical").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
            Section("Index") {
                LabeledContent("Windows and tabs") {
                    HStack {
                        Text("\(model.health.entryCount)")
                        Button("Rebuild Index", action: actions.rebuildIndex)
                    }
                }
                Text("""
                    Rebuilding drops the whole list and reads every window again, which clears rows left \
                    behind by a window that closed while its app was not answering.
                    """)
                .settingsHelp()
            }
        }
        .formStyle(.grouped)
        .frame(width: ChromeTheme.windowWidth)
    }
}

struct HotKeySettingsView: View {
    @Bindable var store: SettingsStore
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Form {
            Section {
                LabeledContent("Open the switcher") {
                    HotKeyRecorder(binding: store.mainHotKey, defaultBinding: .mainDefault,
                                   takeoverAvailable: model.cmdTabTakeoverAvailable,
                                   reservedChords: [store.reverseHotKey, store.searchHotKey],
                                   onRecord: { store.mainHotKey = $0 },
                                   onRecordingChanged: actions.setRecording)
                        .frame(width: ChromeTheme.recorderSize.width, height: ChromeTheme.recorderSize.height)
                }
                LabeledContent("Open the switcher backwards") {
                    HotKeyRecorder(binding: store.reverseHotKey, defaultBinding: .reverseDefault,
                                   takeoverAvailable: model.cmdTabTakeoverAvailable,
                                   reservedChords: [store.mainHotKey, store.searchHotKey],
                                   onRecord: { store.reverseHotKey = $0 },
                                   onRecordingChanged: actions.setRecording)
                        .frame(width: ChromeTheme.recorderSize.width, height: ChromeTheme.recorderSize.height)
                }
                LabeledContent("Open search") {
                    HotKeyRecorder(binding: store.searchHotKey, defaultBinding: .searchDefault,
                                   requiresHoldModifier: false, acceptsCmdTab: false,
                                   takeoverAvailable: model.cmdTabTakeoverAvailable,
                                   reservedChords: [store.mainHotKey, store.reverseHotKey],
                                   onRecord: { store.searchHotKey = $0 },
                                   onRecordingChanged: actions.setRecording)
                        .frame(width: ChromeTheme.recorderSize.width, height: ChromeTheme.recorderSize.height)
                }
                Text("""
                    Holding the modifier keeps the panel up and letting go switches, so the first two shortcuts \
                    need \u{2325}, \u{2303} or \u{2318}.
                    """)
                .settingsHelp()
                Text("\u{2318}\u{2009}Tab replaces the system app switcher while OpenTab runs and comes back when it quits.")
                    .settingsHelp()
                if model.takeoverPolicy == .unavailable {
                    Text("\u{2318}\u{2009}Tab is not available on this Mac, so OpenTab is using \u{2325}\u{2009}Tab.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if model.takeoverPolicy == .untrusted {
                    Text("""
                        \u{2318}\u{2009}Tab works once Accessibility is granted; until then OpenTab is using \
                        \u{2325}\u{2009}Tab.
                        """)
                    .settingsHelp()
                }
                if let otherInstance = model.otherInstance {
                    Text(otherInstance)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if model.secureInputActive {
                    Text("Secure Input is active, so shortcuts may not reach OpenTab.")
                        .settingsHelp()
                }
                // The store cannot see availability, and a reset to a chord
                // the recorder refuses would show Cmd-Tab over the red caption.
                Button("Reset to Defaults") {
                    if model.cmdTabTakeoverAvailable {
                        store.resetHotKeys()
                    } else {
                        store.mainHotKey = .optionTab
                        store.reverseHotKey = .optionShiftTab
                        store.searchHotKey = .searchDefault
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: ChromeTheme.windowWidth)
    }
}

struct PrivacySettingsView: View {
    @Bindable var store: SettingsStore
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Form {
            Section("What is listed") {
                Toggle("Include private and incognito windows", isOn: $store.includesPrivateTabs)
                Text("""
                    Private tab titles are readable, so leaving this off is what keeps them out of the list, \
                    out of search and off disk.
                    """)
                .settingsHelp()
            }
            Section("Icons") {
                Toggle("Look up missing icons on Google", isOn: $store.remoteFavicons)
                Text(FaviconStore.remoteDisclosureText)
                    .settingsHelp()
                LabeledContent("Safari icon cache") {
                    if model.safariCacheGranted {
                        Text("Readable").foregroundStyle(.secondary)
                    } else {
                        Button("Choose Folder\u{2026}", action: actions.grantSafariCacheAccess)
                    }
                }
                Text("""
                    OpenTab can read Safari's icon cache only after you choose the ~/Library/Safari folder \
                    once.
                    """)
                    .settingsHelp()
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if model.accessibilityGranted {
                        Text("Granted").foregroundStyle(.secondary)
                    } else {
                        Button("Open System Settings\u{2026}", action: actions.openAccessibilitySettings)
                    }
                }
                Text("Required: without it OpenTab lists no windows at all.")
                    .settingsHelp()
                automation
                if !model.windowIDBridgeAvailable {
                    Text("""
                        This Mac does not expose the window-id call, so some windows are matched less \
                        precisely.
                        """)
                        .settingsHelp()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: ChromeTheme.windowWidth)
    }

    @ViewBuilder
    private var automation: some View {
        LabeledContent("Automation") {
            if actions.automationPaneExists() {
                Button("Open System Settings\u{2026}", action: actions.openAutomationSettings)
            } else {
                Text("Not requested yet").foregroundStyle(.secondary)
            }
        }
        Text("""
            Browsers need this to list their tabs; macOS only shows an Automation pane once an app has asked \
            at least once.
            """)
        .settingsHelp()
        ForEach(model.tabsUnavailable, id: \.self) { name in
            Text("\(name) tabs need Automation access.")
                .settingsHelp()
        }
        ForEach(model.tabsAwaitingRequest, id: \.bundleID) { browser in
            Button("Enable Tabs for \(browser.name)\u{2026}") { actions.requestAutomation(browser.bundleID) }
        }
    }
}
