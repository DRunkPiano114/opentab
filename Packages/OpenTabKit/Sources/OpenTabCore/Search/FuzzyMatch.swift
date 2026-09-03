import Foundation

/// Scoring fuzzy subsequence matcher for interactive switcher filtering.
///
/// Every query character must be accounted for by the candidate, in order,
/// though not necessarily adjacently. A query character is accounted for
/// either by an equal candidate character or, for ASCII letters, by a prefix
/// of a pinyin reading of a Han candidate character; one Han character can
/// absorb a whole syllable. Among all alignments the highest-scoring one wins,
/// found by dynamic programming in O(query x candidate) time.
///
/// The score rewards the alignments a human reads as "obviously what I meant":
/// a match at a word start, a match that continues an unbroken run, a match at
/// the very beginning of the string. It penalises characters skipped between
/// matches and before the first match. A direct character match always
/// outscores a pinyin match of the same shape: typing the character itself is
/// stronger evidence than typing its sound.
public enum FuzzyMatch {
    public struct Match: Equatable, Sendable {
        public let score: Int
        /// Offsets into `IndexedText.characters` that were matched, ascending
        /// and unique. A Han character matched through pinyin appears once
        /// however many query letters it absorbed.
        public let matchedIndices: [Int]
    }

    /// The query, folded once. Whitespace is not special here; strip it
    /// before building one if the user's spaces should not have to line up
    /// with the candidate's.
    public struct Query: Sendable, Equatable {
        let raw: [Character]
        let folded: [Character]
        /// The ASCII letter at each offset, 0 where the character is not one.
        let letters: [UInt8]
        let letterMask: UInt32

        public var isEmpty: Bool { raw.isEmpty }

        public init(_ string: String) {
            let raw = Array(string)
            var folded: [Character] = []
            var letters: [UInt8] = []
            var mask: UInt32 = 0
            folded.reserveCapacity(raw.count)
            letters.reserveCapacity(raw.count)
            for ch in raw {
                let f = TextFolding.fold(ch)
                folded.append(f)
                if let bit = TextFolding.letterBit(f) {
                    mask |= bit
                    letters.append(f.asciiValue!)
                } else {
                    letters.append(0)
                }
            }
            self.raw = raw
            self.folded = folded
            self.letters = letters
            self.letterMask = mask
        }
    }

    // Tuned so a word-start hit beats a mid-word hit, and an unbroken run beats
    // the same characters scattered. Keep the gaps between tiers wide enough
    // that no pile of small bonuses crosses one.
    static let scoreMatch = 16
    static let bonusWordStart = 30
    static let bonusCamelBoundary = 24
    static let bonusAfterSeparator = 26
    static let bonusFirstChar = 20      // on top of word-start, at index 0 only
    static let bonusConsecutive = 22
    static let bonusExactCase = 2
    static let penaltyGapStart = -6     // the first skipped character in a gap
    static let penaltyGapExtend = -2    // each further skipped character
    static let penaltyLeading = -3      // per character skipped before the first match
    static let maxLeadingPenalty = -24  // floor, so a long prefix isn't fatal

    // A Han character absorbed through pinyin scores per query letter it
    // absorbs, so a whole syllable outweighs an initial, plus a bonus for the
    // complete syllable. The per-character penalty keeps a run of initials
    // ("ss" for 硕士) below a Latin acronym of the same shape ("ss" for
    // System Settings): an initial is the weakest evidence the matcher accepts.
    static let scorePinyinLetter = 8
    static let bonusFullSyllable = 12
    static let penaltyPinyinCharacter = -12

    private static let negInf = Int.min / 4

    /// DP tables reused across matches. One search over thousands of rows
    /// would otherwise allocate two arrays per row.
    public struct Scratch: Sendable {
        var best: [Int] = []
        var parent: [Int32] = []

        public init() {}

        mutating func reset(cells: Int) {
            if best.count < cells {
                best = [Int](repeating: negInf, count: cells)
                parent = [Int32](repeating: -1, count: cells)
            } else {
                for i in 0..<cells { best[i] = negInf; parent[i] = -1 }
            }
        }
    }

    /// Convenience for one-off matching; builds the indexes on every call.
    public static func match(query: String, candidate: String) -> Match? {
        var scratch = Scratch()
        return match(Query(query), in: IndexedText(candidate), scratch: &scratch)
    }

    /// Returns nil when `query` cannot be aligned with `text`. An empty query
    /// matches everything with score 0.
    public static func match(_ query: Query, in text: IndexedText) -> Match? {
        var scratch = Scratch()
        return match(query, in: text, scratch: &scratch)
    }

    public static func match(_ query: Query, in text: IndexedText, scratch: inout Scratch) -> Match? {
        let m = query.folded.count
        let n = text.folded.count
        if m == 0 { return Match(score: 0, matchedIndices: []) }
        if n == 0 { return nil }
        if query.letterMask & ~text.letterMask != 0 { return nil }
        if !text.hasPinyin {
            if m > n { return nil }
            guard isSubsequence(query.folded, text.folded) else { return nil }
        }

        // best[i * n + j]: best score with query[0..<i] consumed and query's
        // last consumed character sitting on candidate offset j. Row 0 is
        // never read; the first match is seeded from the leading penalty.
        // parent holds the flat index of the predecessor cell, -1 at a start.
        let cells = (m + 1) * n
        scratch.reset(cells: cells)
        return scratch.best.withUnsafeMutableBufferPointer { best in
            scratch.parent.withUnsafeMutableBufferPointer { parent in
                align(query, text, m: m, n: n, best: best, parent: parent)
            }
        }
    }

    private static func align(_ query: Query, _ text: IndexedText, m: Int, n: Int,
                              best: UnsafeMutableBufferPointer<Int>,
                              parent: UnsafeMutableBufferPointer<Int32>) -> Match? {

        for i in 0..<m {
            let rowBase = i * n
            // Running best of best[k] + (cost of a gap ending just before j),
            // so the inner scan over k collapses to O(1).
            var bestGapped = negInf
            var bestGappedIdx = -1
            let qc = query.folded[i]
            let letter = query.letters[i]

            for j in 0..<n {
                var pred: Int
                var predParent: Int32
                if i == 0 {
                    pred = max(maxLeadingPenalty, penaltyLeading * j)
                    predParent = -1
                } else {
                    if j > 0 {
                        if bestGapped != negInf { bestGapped += penaltyGapExtend }
                        let k = j - 2
                        if k >= 0 {
                            let v = best[rowBase + k]
                            if v != negInf, v + penaltyGapStart > bestGapped {
                                bestGapped = v + penaltyGapStart
                                bestGappedIdx = k
                            }
                        }
                    }
                    pred = bestGapped
                    var predIdx = bestGappedIdx
                    // The adjacent predecessor is the consecutive-run case.
                    if j >= 1 {
                        let v = best[rowBase + j - 1]
                        if v != negInf, v + bonusConsecutive > pred {
                            pred = v + bonusConsecutive
                            predIdx = j - 1
                        }
                    }
                    guard pred != negInf else { continue }
                    predParent = Int32(rowBase + predIdx)
                }

                if text.folded[j] == qc {
                    var s = pred + scoreMatch + text.bonus[j]
                    // Only an UPPERCASE query character earns the case bonus.
                    // Rewarding any exact-case hit would systematically favour
                    // lowercase candidates, since users type lowercase: "ss"
                    // would rank "sublime scratch" over "System Settings".
                    if query.raw[i].isUppercase && text.characters[j] == query.raw[i] { s += bonusExactCase }
                    let idx = (i + 1) * n + j
                    if s > best[idx] { best[idx] = s; parent[idx] = predParent }
                }

                guard letter != 0, text.hasPinyin else { continue }
                for reading in text.pinyin[j] {
                    var k = 0
                    while k < reading.count, i + k < m, query.letters[i + k] == reading[k] { k += 1 }
                    guard k > 0 else { continue }
                    let base = pred + text.bonus[j] + penaltyPinyinCharacter
                    for len in 1...k {
                        var s = base + len * scorePinyinLetter
                        if len == reading.count { s += bonusFullSyllable }
                        let idx = (i + len) * n + j
                        if s > best[idx] { best[idx] = s; parent[idx] = predParent }
                    }
                }
            }
        }

        var endIdx = -1
        var endScore = negInf
        let lastRow = m * n
        for j in 0..<n where best[lastRow + j] > endScore {
            endScore = best[lastRow + j]
            endIdx = lastRow + j
        }
        guard endIdx >= 0 else { return nil }

        var indices: [Int] = []
        indices.reserveCapacity(m)
        var idx = endIdx
        while idx >= 0 {
            indices.append(idx % n)
            idx = Int(parent[idx])
        }
        return Match(score: endScore, matchedIndices: indices.reversed())
    }

    /// Ranks `candidates` best-first, dropping non-matches. Ties keep input order.
    public static func rank(query: String, candidates: [String]) -> [(candidate: String, score: Int)] {
        let q = Query(query)
        var scratch = Scratch()
        var hits: [(order: Int, candidate: String, score: Int)] = []
        hits.reserveCapacity(candidates.count)
        for (idx, s) in candidates.enumerated() {
            if let m = match(q, in: IndexedText(s), scratch: &scratch) {
                hits.append((idx, s, m.score))
            }
        }
        hits.sort { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
        return hits.map { ($0.candidate, $0.score) }
    }

    private static func isSubsequence(_ q: [Character], _ c: [Character]) -> Bool {
        var qi = 0
        for ch in c where qi < q.count && ch == q[qi] {
            qi += 1
        }
        return qi == q.count
    }
}
