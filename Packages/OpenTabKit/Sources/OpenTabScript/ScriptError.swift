import Foundation

/// AppleScript failures, already classified. The raw `errorNumber` is kept only
/// in `failed` so that callers branch on meaning, never on a message string.
public enum ScriptError: Error, Sendable, Hashable {
    case compileFailed(code: Int, message: String)
    /// Our own budget expired, or the target reported `errAETimeout`.
    case timedOut
    /// `-1743` / `-10004`. Ambiguous by itself; see `AutomationSelfCheck`.
    case notPermitted
    /// `-1744`: no authorisation record. Cannot distinguish "never asked" from
    /// "asked and denied", so the caller keeps its own log.
    case permissionUndetermined
    /// `-600` / `-609`. A skip, not a failure: the target is simply gone.
    case targetNotRunning
    /// `-1719` / `-1728`: a tab or window disappeared mid-read. Benign race.
    case indexRace
    /// The addressed window or tab no longer exists.
    case notFound
    case failed(code: Int, message: String)
    case cancelled

    /// True when the right response is to drop the affected rows and keep the
    /// rest, rather than surfacing anything to the user.
    public var isBenign: Bool {
        switch self {
        case .targetNotRunning, .indexRace: true
        default: false
        }
    }
}

public extension ScriptError {
    static func mapExecution(code: Int, message: String) -> ScriptError {
        switch code {
        case -1712: .timedOut
        case -1743, -10004: .notPermitted
        case -1744: .permissionUndetermined
        case -600, -609: .targetNotRunning
        case -1719, -1728: .indexRace
        default: .failed(code: code, message: message)
        }
    }

    static func mapExecution(_ info: NSDictionary) -> ScriptError {
        let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (info[NSAppleScript.errorMessage] as? String) ?? ""
        return mapExecution(code: code, message: message)
    }
}
