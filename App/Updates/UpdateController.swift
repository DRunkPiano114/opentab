import AppKit
import OpenTabCore
import Sparkle

/// The one updater of the process, present only when the bundle carries both
/// a feed and a public key. The development build carries neither on purpose:
/// it must never replace itself with the release build. Sparkle starts
/// happily with an empty feed and then fails every check, so the guard is
/// ours to enforce.
///
/// Every mention of Sparkle in the app is inside this file.
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
    /// Sparkle holds its user driver delegate weakly, so this is what keeps
    /// it alive.
    private let reminder: ScheduledUpdateReminder
    /// Held for the same reason: Sparkle holds its updater delegate weakly.
    private let pendingInstall: PendingInstall
    private var observation: NSKeyValueObservation?
    private var downloadsObservation: NSKeyValueObservation?

    /// Called on the main actor with the current value the moment it is set,
    /// and again on every change: a menu built after the updater already
    /// reported `false` would otherwise stay disabled until the next one.
    var onCanCheckForUpdatesChanged: ((Bool) -> Void)? {
        didSet { onCanCheckForUpdatesChanged?(updaterController.updater.canCheckForUpdates) }
    }

    /// Called with the current value the moment it is set, and again on every
    /// change, including one made with the checkbox in Sparkle's own update
    /// window, which writes the same preference.
    var onAutomaticallyDownloadsUpdatesChanged: ((Bool) -> Void)? {
        didSet { onAutomaticallyDownloadsUpdatesChanged?(updaterController.updater.automaticallyDownloadsUpdates) }
    }

    /// The update a background check found, replayed the moment this is set
    /// and called again on every change; nil once the update is installed or
    /// put off.
    var onWaitingUpdateChanged: ((StatusMenuSpec.WaitingUpdate?) -> Void)? {
        didSet { onWaitingUpdateChanged?(reminder.waiting) }
    }

    /// The version of an update downloaded in the background and waiting to
    /// install on quit, replayed the moment this is set and called again on
    /// every change.
    var onReadyToInstallChanged: ((String?) -> Void)? {
        didSet { onReadyToInstallChanged?(pendingInstall.version) }
    }

    /// Whether the status item is on screen to carry the reminder and the
    /// restart item. Without it Sparkle presents a background find, and a
    /// downloaded update, the way it would with no menu at all.
    var isStatusItemVisible: () -> Bool = { true } {
        didSet {
            reminder.isStatusItemVisible = isStatusItemVisible
            pendingInstall.isStatusItemVisible = isStatusItemVisible
        }
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
        // Sparkle reads both delegates once, while the controller is built.
        reminder = ScheduledUpdateReminder()
        pendingInstall = PendingInstall()
        updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                        updaterDelegate: pendingInstall,
                                                        userDriverDelegate: reminder)
        reminder.onChange = { [weak self] waiting in self?.onWaitingUpdateChanged?(waiting) }
        pendingInstall.onChange = { [weak self] version in self?.onReadyToInstallChanged?(version) }
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
        downloadsObservation = updaterController.updater.observe(\.automaticallyDownloadsUpdates,
                                                                 options: [.new]) { [weak self] _, change in
            guard let downloads = change.newValue else { return }
            // Sparkle relays this from its observer of the user defaults,
            // which is not bound to the main thread.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.onAutomaticallyDownloadsUpdatesChanged?(downloads) }
            } else {
                Task { @MainActor in self?.onAutomaticallyDownloadsUpdatesChanged?(downloads) }
            }
        }
    }

    /// Sparkle owns this preference and writes it to the app's own defaults
    /// domain, where it outlives the update that replaces the bundle.
    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Download updates in the background and install them on quit. Sparkle
    /// reads this as false, and ignores a write, while automatic checks are
    /// off.
    var automaticallyDownloadsUpdates: Bool {
        get { updaterController.updater.automaticallyDownloadsUpdates }
        set { updaterController.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// Sparkle activates the app itself before its windows appear, because it
    /// recognises the accessory activation policy.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Brings a found update's window forward once the status item that
    /// offered it has gone. A downloaded update held for install has no window
    /// to bring forward and stays offered in About.
    func showWaitingUpdate() {
        guard reminder.waiting != nil, pendingInstall.version == nil else { return }
        checkForUpdates()
    }

    /// Installs the downloaded update and relaunches, with no window of
    /// Sparkle's own. Does nothing when no update is waiting to install.
    func installNow() {
        pendingInstall.installNow()
    }
}

/// Keeps hold of an update that was downloaded in the background, so the
/// user can install it now instead of at the next quit, which for an app that
/// runs for weeks may be a long way off.
///
/// Sparkle calls every method here on the main thread.
@MainActor
private final class PendingInstall: NSObject, SPUUpdaterDelegate {
    private static let log = Log.make("updates")

    var onChange: ((String?) -> Void)?

    private(set) var version: String? {
        didSet {
            guard version != oldValue else { return }
            onChange?(version)
        }
    }

    /// True holds a downloaded update for the restart item.
    var isStatusItemVisible: () -> Bool = { true }

    private var install: (() -> Void)?

    // The update installs on quit whatever this returns. True keeps
    // `immediateInstallHandler` for the restart item but holds the update
    // cycle open, which costs Sparkle's own fallbacks: no further check runs
    // until the handler is called or the app quits, an update left
    // uninstalled is never shown again, and a critical one is never shown at
    // once. False keeps them, which a hidden status item (no restart item to
    // offer it) and a critical update both need.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard isStatusItemVisible(), !item.isCriticalUpdate else {
            Self.log.notice("update left to install on quit version=\(item.displayVersionString, privacy: .public)")
            return false
        }
        Self.log.notice("update ready to install version=\(item.displayVersionString, privacy: .public)")
        install = immediateInstallHandler
        version = item.displayVersionString
        return true
    }

    // A held cycle ends only when the install fails or is put off. The
    // handler does nothing once its cycle has ended.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        drop()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        drop()
    }

    func installNow() {
        guard let install else { return }
        Self.log.notice("installing the downloaded update now")
        install()
    }

    private func drop() {
        install = nil
        version = nil
    }
}

/// Keeps an update found by a scheduled check out of a window of its own.
/// Sparkle opens that window without activating an accessory app, so it lands
/// behind whatever is in front and no further scheduled check runs while it
/// waits; the status item carries the reminder instead.
///
/// Sparkle calls every method here on the main thread.
@MainActor
private final class ScheduledUpdateReminder: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    private static let log = Log.make("updates")

    /// True keeps a background find in the menu bar, including the one at
    /// launch that Sparkle would otherwise bring to the front. A critical
    /// update is shown at once whatever this says.
    var isStatusItemVisible: () -> Bool = { true }
    var onChange: ((StatusMenuSpec.WaitingUpdate?) -> Void)?

    private(set) var waiting: StatusMenuSpec.WaitingUpdate? {
        didSet {
            guard waiting != oldValue else { return }
            onChange?(waiting)
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle requires this to have no side effects; the reminder is
    /// recorded in the call that follows it.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                             andInImmediateFocus immediateFocus: Bool) -> Bool {
        !isStatusItemVisible() || update.isCriticalUpdate
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        Self.log.notice("update waiting in the menu bar version=\(update.displayVersionString, privacy: .public)")
        waiting = StatusMenuSpec.WaitingUpdate(version: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        waiting?.seen = true
    }

    func standardUserDriverWillFinishUpdateSession() {
        waiting = nil
    }
}
