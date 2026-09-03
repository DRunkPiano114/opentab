import Foundation

/// `SearchIndex` over `Entry` values.
///
/// Each entry is matched on its app name, its title and its URL, plus the app
/// name and title joined so a query can span both ("chrome github"). The
/// best field wins after a per-field weight that ranks an app-name hit above
/// a tab title above a window title above a URL. The weight multiplies rather
/// than adds, so the precedence grows with match quality: a whole-word hit on
/// the app name beats the same hit on a title, while a scattered app-name hit
/// still loses to a clean title prefix. Whitespace in the query is dropped:
/// the user's spaces need not line up with the candidate's.
public struct EntrySearchIndex: SearchIndex {
    /// Per-field multipliers in percent, applied before fields are compared.
    public struct FieldWeight: Sendable, Equatable {
        public var appName = 130
        public var tabTitle = 110
        public var windowTitle = 100
        public var url = 80
        public init() {}
    }

    private struct Item {
        var entry: Entry
        let appName: IndexedText
        let title: IndexedText
        let combined: IndexedText
        let url: IndexedText?
        /// Offsets in `combined` at or past this belong to the title.
        let titleStart: Int

        init(_ entry: Entry) {
            self.entry = entry
            appName = IndexedText(entry.app.localizedName)
            title = IndexedText(entry.title)
            combined = IndexedText(entry.app.localizedName + " " + entry.title)
            titleStart = appName.count + 1
            url = entry.url.map { IndexedText(Self.searchableURL($0)) }
        }

        func sameText(as other: Entry) -> Bool {
            entry.app.localizedName == other.app.localizedName
                && entry.title == other.title
                && entry.url == other.url
        }

        private static func searchableURL(_ url: URL) -> String {
            let text = url.absoluteString
            if let range = text.range(of: "://") { return String(text[range.upperBound...]) }
            return text
        }
    }

    public var fieldWeight = FieldWeight()
    private var items: [EntryID: Item] = [:]

    public init() {}

    public var count: Int { items.count }

    public mutating func update(with entries: [Entry]) {
        var next: [EntryID: Item] = [:]
        next.reserveCapacity(entries.count)
        for entry in entries {
            if var cached = items[entry.id], cached.sameText(as: entry) {
                cached.entry = entry
                next[entry.id] = cached
            } else {
                next[entry.id] = Item(entry)
            }
        }
        items = next
    }

    public func search(_ query: String) -> [SearchHit] {
        let stripped = String(query.filter { !$0.isWhitespace })
        if stripped.isEmpty {
            return EntrySort.sorted(items.values.map(\.entry), mode: .recency)
                .map { SearchHit(entry: $0, score: 0) }
        }
        let q = FuzzyMatch.Query(stripped)
        var scratch = FuzzyMatch.Scratch()
        var hits: [SearchHit] = []
        for item in items.values {
            if let hit = score(item, against: q, scratch: &scratch) { hits.append(hit) }
        }
        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.entry.focusTick != b.entry.focusTick { return a.entry.focusTick > b.entry.focusTick }
            return a.entry.discoveryRank < b.entry.discoveryRank
        }
        return hits
    }

    private func score(_ item: Item, against q: FuzzyMatch.Query, scratch: inout FuzzyMatch.Scratch) -> SearchHit? {
        var best: SearchHit?
        func consider(_ score: Int, weight: Int, appName: [Int] = [], title: [Int] = []) {
            let weighted = score * weight / 100
            if let current = best, current.score >= weighted { return }
            best = SearchHit(entry: item.entry, score: weighted, appNameMatches: appName, titleMatches: title)
        }

        if let m = FuzzyMatch.match(q, in: item.appName, scratch: &scratch) {
            consider(m.score, weight: fieldWeight.appName, appName: m.matchedIndices)
        }
        if let m = FuzzyMatch.match(q, in: item.title, scratch: &scratch) {
            let weight = item.entry.kind == .tab ? fieldWeight.tabTitle : fieldWeight.windowTitle
            consider(m.score, weight: weight, title: m.matchedIndices)
        }
        // An alignment inside one field scores no higher in the joined text
        // than in the field itself, so the joined text is consulted only when
        // neither field matches alone. A query that matches a field alone and
        // would also align across both fields with a better score is not
        // considered; the joined DP is the longest and would otherwise run for
        // every row a broad query hits.
        if best == nil, let m = FuzzyMatch.match(q, in: item.combined, scratch: &scratch) {
            let appName = m.matchedIndices.filter { $0 < item.titleStart - 1 }
            let title = m.matchedIndices.filter { $0 >= item.titleStart }.map { $0 - item.titleStart }
            consider(m.score, weight: fieldWeight.windowTitle, appName: appName, title: title)
        }
        if let url = item.url, let m = FuzzyMatch.match(q, in: url, scratch: &scratch) {
            consider(m.score, weight: fieldWeight.url)
        }
        return best
    }
}
