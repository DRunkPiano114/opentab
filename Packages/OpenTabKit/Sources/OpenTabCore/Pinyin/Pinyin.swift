import Foundation

/// Han character to pinyin lookup over the built-in table.
///
/// Readings are lowercase ASCII with no tone marks. A character with several
/// readings returns all of them, most common first. Syllables with "ü" are
/// listed twice, spelled with "v" (the IME convention) and with "u".
public enum Pinyin {
    /// Empty for anything the table does not cover, including non-Han scalars.
    public static func readings(of scalar: Unicode.Scalar) -> [String] {
        PinyinTable.readings(of: scalar)
    }

    /// CJK Unified Ideographs, all blocks. Case and diacritic folding are
    /// meaningless for these and cost 27x per character, so callers skip them.
    public static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x323AF:
            return true
        default:
            return false
        }
    }
}
