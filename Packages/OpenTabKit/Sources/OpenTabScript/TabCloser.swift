import Foundation
import OpenTabCore

/// Closing is not part of `TabProvider`, but both scripted browsers support it
/// through their dictionaries.
public protocol TabCloser: Sendable {
    /// Closes the tab without selecting it first.
    func close(_ tab: TabSnapshot, deadline: ContinuousClock.Instant) async throws
}
