import Foundation

/// The highlighted row while the panel is open.
///
/// Opens on the second entry: the first is the window the user is already in,
/// so a bare hold-Tab-release must land on the previous one. Selecting the
/// first entry would turn the most common gesture into a no-op.
public struct Selection: Sendable, Equatable {
    public private(set) var index: Int
    public private(set) var count: Int

    public init(count: Int) {
        self.count = count
        self.index = count > 1 ? 1 : 0
    }

    public var isEmpty: Bool { count == 0 }

    public mutating func advance(by delta: Int) {
        guard count > 0 else { return }
        index = ((index + delta) % count + count) % count
    }

    public mutating func select(_ newIndex: Int) {
        guard count > 0 else { return }
        index = min(max(newIndex, 0), count - 1)
    }

    /// Keeps the highlight on the same row when the list changes underneath it.
    /// `newIndex` is where the previously selected row moved to, or `nil` if it
    /// disappeared, in which case the highlight stays at the same position.
    public mutating func listChanged(count newCount: Int, previousRowNowAt newIndex: Int?) {
        count = newCount
        guard newCount > 0 else { index = 0; return }
        index = min(newIndex ?? index, newCount - 1)
    }
}
