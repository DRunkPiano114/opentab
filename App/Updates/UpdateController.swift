import AppKit
import OpenTabCore
import Sparkle

/// The one updater of the process, present only when the bundle carries both
/// a feed and a public key. The development build carries neither on purpose:
/// it must never replace itself with the release build. Sparkle starts
/// happily with an empty feed and then fails every check, so the guard is
/// ours to enforce.
///
/// Every mention of Sparkle in the app is inside this type.
@MainActor
final class UpdateController {
    /// Sparkle strips quotes from the feed before using it, so a feed that is
    /// only quotes is empty to it as well.
    private static let padding = CharacterSet(charactersIn: "\"'").union(.whitespacesAndNewlines)
    private static let log = Log.make("updates")

    static func isConfigured(feedURL: String?, publicKey: String?) -> Bool {
        !trimmed(feedURL).isEmpty && !trimmed(publicKey).isEmpty
    }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: padding) ?? ""
    }

    private let updaterController: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    /// Called on the main actor with the current value the moment it is set,
    /// and again on every change: a menu built after the updater already
    /// reported `false` would otherwise stay disabled until the next one.
    var onCanCheckForUpdatesChanged: ((Bool) -> Void)? {
        didSet { onCanCheckForUpdatesChanged?(updaterController.updater.canCheckForUpdates) }
    }

    /// Nil when the bundle carries no feed or no public key; nothing of
    /// Sparkle is touched in that case.
    init?(bundle: Bundle = .main) {
        let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard Self.isConfigured(feedURL: feedURL, publicKey: publicKey) else {
            Self.log.notice("no update feed in this bundle: updater not started")
            return nil
        }
        updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                        updaterDelegate: nil,
                                                        userDriverDelegate: nil)
        let host = URL(string: Self.trimmed(feedURL))?.host() ?? "unknown"
        Self.log.notice("updater started feed host=\(host, privacy: .public)")
        // Sparkle's own menu validation never runs while the status menu
        // disables auto-enabling, so whoever draws the item needs this.
        observation = updaterController.updater.observe(\.canCheckForUpdates,
                                                        options: [.initial, .new]) { [weak self] _, change in
            guard let can = change.newValue else { return }
            // Sparkle changes this on the main thread.
            MainActor.assumeIsolated { self?.onCanCheckForUpdatesChanged?(can) }
        }
    }

    /// Sparkle owns this preference and writes it to the app's own defaults
    /// domain, where it outlives the update that replaces the bundle.
    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Sparkle activates the app itself before its windows appear, because it
    /// recognises the accessory activation policy.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
