import SwiftUI

/// The settings window's content: three pages, every control writing straight
/// through to `SettingsStore`, which applies the change to the running app.
struct SettingsView: View {
    @Bindable var store: SettingsStore
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        TabView {
            GeneralSettingsView(store: store, model: model, actions: actions)
                .tabItem { Label("General", systemImage: "gearshape") }
            HotKeySettingsView(store: store, model: model, actions: actions)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            PrivacySettingsView(store: store, model: model, actions: actions)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettingsView: View {
    @Bindable var store: SettingsStore
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Form {
            Section {
                Toggle("Open OpenTab at login", isOn: $store.launchesAtLogin)
                Toggle("Show the menu bar icon", isOn: $store.showMenuBarIcon)
                if !store.showMenuBarIcon {
                    Text("With the icon hidden, open this window again by launching OpenTab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.updatesAvailable {
                    Toggle("Check for updates automatically", isOn: $store.automaticUpdateChecks)
                    Text("""
                        Once a day OpenTab asks GitHub whether a newer version exists; an update \
                        installs only after you click Install.
                        """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Section("Hide windows") {
                IgnorePatternsEditor(store: store)
            }
            Section("Index") {
                LabeledContent("Windows and tabs listed") {
                    HStack {
                        Text("\(model.health.entryCount)")
                        Button("Rebuild Index", action: actions.rebuildIndex)
                    }
                }
                Text("""
                    A window that closes at the exact moment its app answers nothing leaves a row behind: \
                    OpenTab never deletes a row on an empty read, because doing so makes the list flicker. \
                    Rebuilding drops the whole list and reads every window again.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
                LabeledContent("Memory", value: model.health.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: actions.refreshHealth)
    }
}

private struct HotKeySettingsView: View {
    @Bindable var store: SettingsStore
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Form {
            Section {
                LabeledContent("Open the switcher") {
                    HotKeyRecorder(binding: store.mainHotKey,
                                   takeoverAvailable: model.cmdTabTakeoverAvailable,
                                   reservedChords: [store.reverseHotKey, store.searchHotKey],
                                   onRecord: { store.mainHotKey = $0 },
                                   onRecordingChanged: actions.setRecording)
                        .frame(width: 130, height: 24)
                }
                LabeledContent("Open the switcher backwards") {
                    HotKeyRecorder(binding: store.reverseHotKey,
                                   takeoverAvailable: model.cmdTabTakeoverAvailable,
                                   reservedChords: [store.mainHotKey, store.searchHotKey],
                                   onRecord: { store.reverseHotKey = $0 },
                                   onRecordingChanged: actions.setRecording)
                        .frame(width: 130, height: 24)
                }
                LabeledContent("Open search") {
                    HotKeyRecorder(binding: store.searchHotKey, requiresHoldModifier: false, acceptsCmdTab: false,
                                   takeoverAvailable: model.cmdTabTakeoverAvailable,
                                   reservedChords: [store.mainHotKey, store.reverseHotKey],
                                   onRecord: { store.searchHotKey = $0 },
                                   onRecordingChanged: actions.setRecording)
                        .frame(width: 130, height: 24)
                }
                Text("""
                    Holding the modifier keeps the panel up and letting go switches, so the first two shortcuts \
                    need \u{2325}, \u{2303} or \u{2318}.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("\u{2318}\u{2009}Tab replaces the system app switcher while OpenTab runs and comes back when it quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let otherInstance = model.otherInstance {
                    Text(otherInstance)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if model.secureInputActive {
                    Text("Secure Input is active, so shortcuts may not reach OpenTab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
    }
}

private struct PrivacySettingsView: View {
    @Bindable var store: SettingsStore
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Form {
            Section("What OpenTab lists") {
                Toggle("Include private and incognito windows", isOn: $store.includesPrivateTabs)
                Text("""
                    Off by default. Private tab titles are readable, so leaving this off is what keeps them \
                    out of the list, out of search and off disk. Safari cannot tell OpenTab which of its \
                    windows are private, so with this off Safari is listed by window and never by tab.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Icons") {
                Toggle("Look up missing icons on Google", isOn: $store.remoteFavicons)
                Text(FaviconStore.remoteDisclosureText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Safari's icon cache") {
                    if model.safariCacheGranted {
                        Text("Readable").foregroundStyle(.secondary)
                    } else {
                        Button("Choose Folder\u{2026}", action: actions.grantSafariCacheAccess)
                    }
                }
                Text("OpenTab reads Safari's icon cache only if you hand it the ~/Library/Safari folder once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if model.accessibilityGranted {
                        Text("Granted").foregroundStyle(.secondary)
                    } else {
                        Button("Open System Settings\u{2026}", action: actions.openAccessibilitySettings)
                    }
                }
                Text("Required. Without it OpenTab can list no windows at all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                automation
                if !model.windowIDBridgeAvailable {
                    Text("""
                        Running with reduced features: this system does not expose the window-id call, so \
                        some windows are matched less precisely.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
            Browsers need this to list their tabs; without it they are listed by window. macOS only shows an \
            Automation pane once an app has asked at least once.
            """)
        .font(.caption)
        .foregroundStyle(.secondary)
        ForEach(model.tabsUnavailable, id: \.self) { name in
            Text("\(name): tabs unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(model.tabsAwaitingRequest, id: \.bundleID) { browser in
            Button("Enable tabs for \(browser.name)\u{2026}") { actions.requestAutomation(browser.bundleID) }
        }
    }
}


/// The user's own title regexes. One per line, applied as they are typed and
/// reported when one does not compile: `IgnoreRules` drops an uncompilable
/// pattern silently, which would otherwise look like a rule that does nothing.
private struct IgnorePatternsEditor: View {
    @Bindable var store: SettingsStore
    @State private var text = ""
    @State private var pending: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 56)
                .onChange(of: text) { _, new in
                    // Applying a change rebuilds the whole index, so a line
                    // being typed is not applied one character at a time.
                    pending?.cancel()
                    pending = Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        store.ignoreTitlePatterns = new.split(separator: "\n", omittingEmptySubsequences: true)
                            .map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    }
                }
            let invalid = SettingsStore.invalidPatterns(in: store.ignoreTitlePatterns)
            Text(invalid.isEmpty
                 ? "One regular expression per line, matched against window titles."
                 : "Not a valid expression: \(invalid.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(invalid.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        }
        .onAppear { text = store.ignoreTitlePatterns.joined(separator: "\n") }
    }
}
