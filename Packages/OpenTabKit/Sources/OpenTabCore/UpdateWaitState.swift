import Foundation

/// What the menu bar holds of an update the updater has left waiting, as a
/// value. The updater's delegates turn its callbacks into these events and
/// ask it every question they answer, so the rules live where the pure-logic
/// suite reaches them.
public struct UpdateWaitState: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// A check found `version`. `shownByUpdater` is true when the updater
        /// presents it in its own window.
        case found(version: String, shownByUpdater: Bool, userInitiated: Bool)
        /// The found update's window has been in front of the user.
        case seen
        /// The session for the found update ended: installed, put off or
        /// skipped.
        case sessionFinished
        /// A downloaded update was held for the restart item.
        case held(version: String)
        /// The update cycle ended without installing the held update.
        case cycleEnded
    }

    /// A found update offered in the menu instead of in a window.
    public private(set) var waiting: StatusMenuSpec.WaitingUpdate?
    /// The version of a downloaded update held for the restart item.
    public private(set) var readyToInstall: String?

    public init() {}

    /// Whether the menu carries an update, found or downloaded, instead of
    /// the updater's own presentation. Without the status item there is no
    /// menu to carry it, and a critical update must not wait for the user to
    /// open one.
    public static func menuCarries(statusItemVisible: Bool, isCritical: Bool) -> Bool {
        statusItemVisible && !isCritical
    }

    /// Whether the updater shows an update a background check found in its
    /// own window, which is whenever the menu does not carry it.
    public static func updaterShowsFind(statusItemVisible: Bool, isCritical: Bool) -> Bool {
        !menuCarries(statusItemVisible: statusItemVisible, isCritical: isCritical)
    }

    /// Whether the waiting update has a window the updater can bring
    /// forward. A downloaded update held for install has none.
    public var canBringForward: Bool {
        waiting != nil && readyToInstall == nil
    }

    public mutating func apply(_ event: Event) {
        switch event {
        case let .found(version, shownByUpdater, userInitiated):
            // A check the user started opens its window at once.
            guard !shownByUpdater, !userInitiated else { return }
            waiting = StatusMenuSpec.WaitingUpdate(version: version)
        case .seen:
            waiting?.seen = true
        case let .held(version):
            readyToInstall = version
        case .sessionFinished, .cycleEnded:
            // The updater runs one session at a time, so a found update and
            // a held one never wait together, and whichever end arrives
            // closes both. One missed callback then cannot leave an item
            // offering an update the updater has already let go of.
            self = UpdateWaitState()
        }
    }
}
