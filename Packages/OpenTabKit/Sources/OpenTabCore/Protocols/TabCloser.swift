import Foundation

/// Closing is not part of `TabProvider`: only some providers can do it. Both
/// scripted browsers close through their dictionaries, and the Accessibility
/// provider presses the tab's own close button.
public protocol TabCloser: Sendable {
    /// Closes the tab without selecting it first.
    func close(_ tab: TabSnapshot, deadline: ContinuousClock.Instant) async throws
}
