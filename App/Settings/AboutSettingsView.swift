import SwiftUI

/// Version, updates and the long-run health read-out, which is where a user
/// looks when something is wrong and where a bug report is copied from.
struct AboutSettingsView: View {
    @Bindable var store: SettingsStore
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Self.version)
                Link("OpenTab on GitHub", destination: URL(string: "https://github.com/DRunkPiano114/opentab")!)
            }
            if model.updatesAvailable {
                Section("Updates") {
                    Button("Check for Updates\u{2026}", action: actions.checkForUpdates)
                    Toggle("Check for updates automatically", isOn: $store.automaticUpdateChecks)
                    Text("""
                        Once a day OpenTab asks GitHub whether a newer version exists; an update \
                        installs only after you click Install.
                        """)
                    .settingsHelp()
                }
            }
            Section {
                Text(model.health.text)
                    .settingsHelp()
            }
        }
        .formStyle(.grouped)
        .frame(width: ChromeTheme.windowWidth)
        .onAppear(perform: actions.refreshHealth)
    }

    /// A build made outside the release workflow carries the placeholder
    /// version, and showing it is the point: the git tag is the only place a
    /// real version comes from.
    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
