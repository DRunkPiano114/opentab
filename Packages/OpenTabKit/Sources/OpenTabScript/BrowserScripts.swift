import Foundation

/// AppleScript sources, written against the dictionaries dumped with `sdef`.
///
/// Safari: window `id` (integer, read-only), `current tab`, element `tab`; tab
/// `name`, `index`, `URL`, and a `close` command. It has no tab id and no
/// private-window flag anywhere in its dictionary.
/// Chromium: window `id` (text), `mode` ("normal" / "incognito"),
/// `active tab index` (settable), element `tab`; tab `id`, `title`, `URL`.
///
/// Every script addresses its target with `tell application id`, never by name:
/// names resolve ambiguously and a plain `tell application "Safari"` launches
/// Safari. Callers still check that the target is running first.
enum BrowserScripts {
    /// Bounds a wedged target. It only constrains commands sent to the
    /// application object, not local computation, and its ability to cut through
    /// a consent prompt is unverified - the engine's own budget is what we rely
    /// on.
    static let targetTimeout = 2

    static func timed(_ body: String) -> String {
        "with timeout of \(targetTimeout) seconds\n\(body)\nend timeout"
    }

    /// One row per window: {window id, active tab index, {tab indices},
    /// {tab names}, {tab URLs}}. The plural form reads every tab in one Apple
    /// Event; a per-tab loop is 6.5x slower.
    static func safariReadTabs(bundleID: String) -> String {
        timed("""
        tell application id "\(bundleID)"
        \tset collected to {}
        \trepeat with browserWindow in windows
        \t\ttry
        \t\t\tset activeIndex to 0
        \t\t\ttry
        \t\t\t\tset activeIndex to index of current tab of browserWindow
        \t\t\tend try
        \t\t\tset end of collected to {id of browserWindow, activeIndex, (index of every tab of browserWindow), (name of every tab of browserWindow), (URL of every tab of browserWindow)}
        \t\tend try
        \tend repeat
        \treturn collected
        end tell
        """)
    }

    /// One row per window: {window id, mode, active tab index, {tab ids},
    /// {tab titles}, {tab URLs}}.
    static func chromiumReadTabs(bundleID: String) -> String {
        timed("""
        tell application id "\(bundleID)"
        \tset collected to {}
        \trepeat with browserWindow in windows
        \t\ttry
        \t\t\tset end of collected to {id of browserWindow, mode of browserWindow, active tab index of browserWindow, (id of every tab of browserWindow), (title of every tab of browserWindow), (URL of every tab of browserWindow)}
        \t\tend try
        \tend repeat
        \treturn collected
        end tell
        """)
    }

    /// Safari addresses tabs positionally, so an index that moved between the
    /// read and this call selects the wrong tab. There is no tab id to
    /// re-resolve against.
    static func safariActivateTab(bundleID: String, windowID: String, tabIndex: Int) -> String {
        timed("""
        tell application id "\(bundleID)"
        \tset target to first window whose id is \(windowID)
        \tset visible of target to true
        \tset current tab of target to tab \(tabIndex) of target
        \tset index of target to 1
        \tactivate
        end tell
        """)
    }

    static func safariCloseTab(bundleID: String, windowID: String, tabIndex: Int) -> String {
        timed("""
        tell application id "\(bundleID)"
        \tset target to first window whose id is \(windowID)
        \tclose tab \(tabIndex) of target
        end tell
        """)
    }

    /// Chromium tabs carry stable ids but expose no index, so the index the
    /// window needs is recovered by walking the tab list.
    static func chromiumActivateTab(bundleID: String, windowID: String, tabID: String) -> String {
        chromiumTabLoop(bundleID: bundleID, windowID: windowID, tabID: tabID, action: """
        \t\t\t\t\tset visible of browserWindow to true
        \t\t\t\t\tset active tab index of browserWindow to position
        \t\t\t\t\tset index of browserWindow to 1
        \t\t\t\t\tactivate
        """)
    }

    static func chromiumCloseTab(bundleID: String, windowID: String, tabID: String) -> String {
        chromiumTabLoop(bundleID: bundleID, windowID: windowID, tabID: tabID, action: """
        \t\t\t\t\tclose tab position of browserWindow
        """)
    }

    private static func chromiumTabLoop(bundleID: String, windowID: String, tabID: String,
                                        action: String) -> String {
        timed("""
        tell application id "\(bundleID)"
        \trepeat with browserWindow in windows
        \t\tif (id of browserWindow as text) is \(AppleScriptLiteral.quoted(windowID)) then
        \t\t\trepeat with position from 1 to count of tabs of browserWindow
        \t\t\t\tif (id of tab position of browserWindow as text) is \(AppleScriptLiteral.quoted(tabID)) then
        \(action)
        \t\t\t\t\treturn true
        \t\t\t\tend if
        \t\t\tend repeat
        \t\tend if
        \tend repeat
        \treturn false
        end tell
        """)
    }
}

enum AppleScriptLiteral {
    /// Ids come from the browser, so they are quoted rather than trusted.
    static func quoted(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}
