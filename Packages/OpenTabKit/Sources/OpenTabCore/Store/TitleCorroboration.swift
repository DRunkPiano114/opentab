import Foundation

/// Decides whether a script tab's title and an AX window's title describe the
/// same window (reconciliation D). Never string equality: Chrome titles its
/// windows `<page> - Google Chrome` while the tab is just `<page>`, so equality
/// would never claim a Chrome window and every Chrome window would be listed
/// twice.
public enum TitleCorroboration {
    /// A normalized tab title shorter than this is too generic to be trusted as
    /// a substring or a mid-word prefix; short titles need an exact match or a
    /// prefix that ends at a word boundary.
    public static let minimumTrustedLength = 8

    private static let separators = [" - ", " — ", " – "]

    /// Trims, strips a trailing `" - <appName>"` (any of the three dash forms),
    /// strips a trailing `(N)` unread count, applies Unicode NFC and collapses
    /// runs of whitespace.
    public static func normalize(_ title: String, appName: String? = nil) -> String {
        var text = title.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let appName {
            let name = appName.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                for separator in separators where text.hasSuffix(separator + name) {
                    text = String(text.dropLast(separator.count + name.count))
                    break
                }
            }
        }
        text = stripTrailingCount(text)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func corroborates(windowTitle: String, tabTitle: String, appName: String? = nil) -> Bool {
        let window = normalize(windowTitle, appName: appName)
        let tab = normalize(tabTitle, appName: appName)
        guard !window.isEmpty, !tab.isEmpty else { return false }
        if window == tab { return true }
        if isPrefix(tab, of: window) || isPrefix(window, of: tab) { return true }
        return tab.count >= minimumTrustedLength && window.contains(tab)
    }

    /// A long prefix matches anywhere (truncated titles); a short one must end
    /// at a word boundary so "Git" cannot claim "GitHub".
    private static func isPrefix(_ prefix: String, of text: String) -> Bool {
        guard text.hasPrefix(prefix), text.count > prefix.count else { return false }
        if prefix.count >= minimumTrustedLength { return true }
        let next = text[text.index(text.startIndex, offsetBy: prefix.count)]
        return !(next.isLetter || next.isNumber)
    }

    private static func stripTrailingCount(_ text: String) -> String {
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return text }
        let digits = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return text }
        return String(text[..<open]).trimmingCharacters(in: .whitespaces)
    }
}
