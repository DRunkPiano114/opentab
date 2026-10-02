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
                    // A held update keeps the updater busy, so the check
                    // button would stay disabled until the next quit.
                    if let ready = model.readyToInstall {
                        Button("Restart to Update to \(ready)", action: actions.installUpdate)
                    } else {
                        Button("Check for Updates\u{2026}", action: actions.checkForUpdates)
                            .disabled(!model.canCheckForUpdates)
                    }
                    Toggle("Check for updates automatically", isOn: $store.automaticUpdateChecks)
                    Toggle("Download and install updates automatically", isOn: $store.automaticUpdateInstalls)
                        .disabled(!store.automaticUpdateChecks)
                    Text("""
                        With automatic checks on, OpenTab asks GitHub for a newer version every six hours, \
                        and stops asking while an update it found is waiting to be installed. Without \
                        automatic installs, a new update installs only after you click Install in its \
                        window. When a background check finds one, the menu bar offers it first, unless the \
                        icon is hidden or the update is critical. With automatic installs, an update \
                        downloads in the background and installs when OpenTab quits, or at once from Restart \
                        to Update when that appears. An update that has already downloaded still installs \
                        when OpenTab quits, even if you turn these settings off.
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
