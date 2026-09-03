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
                                   onRecord: { store.mainHotKey = $0 },
                                   onRecordingChanged: actions.setRecording)
                        .frame(width: 130, height: 24)
                }
                LabeledContent("Open it backwards") {
                    HotKeyRecorder(binding: store.reverseHotKey,
                                   onRecord: { store.reverseHotKey = $0 },
                                   onRecordingChanged: actions.setRecording)
                        .frame(width: 130, height: 24)
                }
                LabeledContent("Open straight into search") {
                    HotKeyRecorder(binding: store.searchHotKey, requiresHoldModifier: false,
                                   onRecord: { store.searchHotKey = $0 },
                                   onRecordingChanged: actions.setRecording)
                        .frame(width: 130, height: 24)
                }
                Text("""
                    Holding the modifier keeps the panel up; letting go switches to whatever is highlighted. \
                    The first two therefore need \u{2325}, \u{2303} or \u{2318} in them.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Reset to Defaults", action: store.resetHotKeys)
            }
            Section("Replace the system \u{2318}\u{21E5}") {
                Toggle("Use OpenTab for \u{2318}\u{21E5}", isOn: $store.cmdTabTakeover)
                    .disabled(!model.cmdTabTakeoverAvailable)
                Text("""
                    OpenTab switches off the system's own \u{2318}\u{21E5} in the window server for as long as it \
                    runs, and puts it back when it quits. If OpenTab is force quit or crashes instead, \
                    \u{2318}\u{21E5} stops working entirely until you log out and back in — the setting lives in \
                    the window server, not on disk, so a restart of OpenTab cannot always recover it. \
                    Off unless you turn it on.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
                if !model.cmdTabTakeoverAvailable {
                    Text("Not available on this system: the window server call OpenTab needs is missing.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if model.secureInputActive {
                    Text("Secure Input is active right now, so shortcuts may not reach OpenTab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
