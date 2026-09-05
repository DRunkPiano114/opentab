import Foundation

/// Whether the app may replace the system's Cmd-Tab, decided from plain
/// values: the takeover is on only when a bound chord asks for it, the
/// Accessibility grant is present, the window-server write exists, and no
/// other copy of OpenTab is running.
///
/// Trust matters because the release of Cmd that commits the selection is
/// seen only by a global event monitor, which delivers nothing without the
/// grant: a takeover without it leaves the system switcher off and the
/// panel unable to commit. Another copy matters because enabling records
/// the live window-server state as the original to restore, and a window
/// server another copy has already changed would be recorded as "off".
public enum TakeoverPolicy: Equatable, Sendable {
    /// The takeover is on: the app binds Cmd-Tab and the system chords are off.
    case enabled
    /// Neither chord asks for the takeover.
    case notWanted
    /// The window-server write is missing on this Mac; permanent.
    case unavailable
    /// Another copy of OpenTab is running; it may already own the chords.
    case otherInstance
    /// The Accessibility grant is missing; the Cmd release would go unseen.
    case untrusted

    /// The first reason that applies wins: the permanent one, then the one
    /// another process owns, then the one the user fixes with a tick.
    public static func resolve(wanted: Bool, trusted: Bool, available: Bool,
                               otherInstanceRunning: Bool) -> TakeoverPolicy {
        guard wanted else { return .notWanted }
        guard available else { return .unavailable }
        guard !otherInstanceRunning else { return .otherInstance }
        guard trusted else { return .untrusted }
        return .enabled
    }

    public var isEnabled: Bool { self == .enabled }
}
