import Foundation

/// One entry that matched a query, with the offsets to emphasise.
public struct SearchHit: Sendable, Equatable {
    public let entry: Entry
    public let score: Int
    /// Offsets into `Array(entry.app.localizedName)`.
    public let appNameMatches: [Int]
    /// Offsets into `Array(entry.title)`.
    public let titleMatches: [Int]

    public init(entry: Entry, score: Int, appNameMatches: [Int] = [], titleMatches: [Int] = []) {
        self.entry = entry
        self.score = score
        self.appNameMatches = appNameMatches
        self.titleMatches = titleMatches
    }
}

/// Ranks entries against a typed query. Per-entry text indexes are built when
/// an entry is first seen and rebuilt only when its text changes, never per
/// keystroke.
public protocol SearchIndex: Sendable {
    /// Replaces the indexed set with `entries`.
    mutating func update(with entries: [Entry])
    /// Best first. An empty (or whitespace-only) query returns every entry in
    /// recency order.
    func search(_ query: String) -> [SearchHit]
}
