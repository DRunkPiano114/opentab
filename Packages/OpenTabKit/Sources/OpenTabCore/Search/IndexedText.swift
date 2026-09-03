import Foundation

/// A candidate string prepared once for repeated matching: folded characters,
/// boundary bonuses and, for Han characters, their pinyin readings.
///
/// Building one costs a few microseconds; matching against one is allocation
/// free apart from the DP tables. Cache it with the entry it describes and
/// rebuild only when the source string changes.
public struct IndexedText: Sendable, Equatable {
    /// The original characters; match offsets index into this.
    public let characters: [Character]
    /// Case- and diacritic-folded characters, Han left untouched.
    let folded: [Character]
    /// Per-offset bonus for the kind of boundary that begins there.
    let bonus: [Int]
    /// Pinyin readings per offset as ASCII bytes; empty for non-Han offsets and
    /// empty altogether when the string has no Han character, so ASCII text
    /// carries no pinyin cost at all.
    let pinyin: [[[UInt8]]]
    /// One bit per ASCII letter present in `folded` or in any reading. A query
    /// whose letters are not all in here cannot match.
    let letterMask: UInt32

    public var isEmpty: Bool { characters.isEmpty }
    public var count: Int { characters.count }
    public var hasPinyin: Bool { !pinyin.isEmpty }

    public init(_ string: String) {
        let characters = Array(string)
        var folded: [Character] = []
        folded.reserveCapacity(characters.count)
        var mask: UInt32 = 0
        var pinyin: [[[UInt8]]] = []
        var sawHan = false

        for (offset, ch) in characters.enumerated() {
            let f = TextFolding.fold(ch)
            folded.append(f)
            if let letter = TextFolding.letterBit(f) { mask |= letter }

            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1,
                  Pinyin.isHan(scalar) else {
                if sawHan { pinyin.append([]) }
                continue
            }
            let readings = Pinyin.readings(of: scalar)
            if !sawHan {
                sawHan = true
                pinyin = [[[UInt8]]](repeating: [], count: offset)
            }
            var encoded: [[UInt8]] = []
            encoded.reserveCapacity(readings.count)
            for reading in readings {
                let bytes = Array(reading.utf8)
                for b in bytes { mask |= 1 << UInt32(b &- 97) }
                encoded.append(bytes)
            }
            pinyin.append(encoded)
        }

        self.characters = characters
        self.folded = folded
        self.bonus = Self.boundaryBonuses(characters)
        self.pinyin = pinyin
        self.letterMask = mask
    }

    /// What kind of boundary begins at each offset. Every Han character is a
    /// morpheme and counts as a word start; so does a Latin letter that
    /// follows one.
    private static func boundaryBonuses(_ cand: [Character]) -> [Int] {
        var out = [Int](repeating: 0, count: cand.count)
        guard !cand.isEmpty else { return out }
        out[0] = FuzzyMatch.bonusWordStart + FuzzyMatch.bonusFirstChar
        var prevHan = TextFolding.isHan(cand[0])
        for j in 1..<cand.count {
            let ch = cand[j], prev = cand[j - 1]
            let han = TextFolding.isHan(ch)
            if han || prevHan {
                out[j] = FuzzyMatch.bonusWordStart
            } else if prev.isWhitespace {
                out[j] = FuzzyMatch.bonusWordStart
            } else if TextFolding.isSeparator(prev) {
                out[j] = FuzzyMatch.bonusAfterSeparator
            } else if prev.isLowercase && ch.isUppercase {
                out[j] = FuzzyMatch.bonusCamelBoundary
            } else if prev.isNumber != ch.isNumber {
                out[j] = FuzzyMatch.bonusCamelBoundary
            }
            prevHan = han
        }
        return out
    }
}

enum TextFolding {
    /// `String.folding` bridges to NSString at ~10us per call, far too slow
    /// per character per row. ASCII takes a pure-Swift path and Han is
    /// returned as is: folding does nothing to it and costs 27x an ASCII
    /// character. Only other non-ASCII text pays for full Unicode folding.
    static func fold(_ ch: Character) -> Character {
        if let ascii = ch.asciiValue {
            return (ascii >= 65 && ascii <= 90) ? Character(UnicodeScalar(ascii + 32)) : ch
        }
        if isHan(ch) { return ch }
        let folded = String(ch).folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: nil
        )
        if let only = folded.first, folded.count == 1 { return only }
        return ch.lowercased().first ?? ch
    }

    static func isHan(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return Pinyin.isHan(scalar)
    }

    /// The mask bit for a folded ASCII letter, nil for anything else.
    static func letterBit(_ ch: Character) -> UInt32? {
        guard let ascii = ch.asciiValue, ascii >= 97, ascii <= 122 else { return nil }
        return 1 << UInt32(ascii - 97)
    }

    static func isSeparator(_ ch: Character) -> Bool {
        "-_./\\:|()[]{}<>,;@#+*&\"'".contains(ch)
    }
}
