import Foundation

/// The seam between the threading engine and AppleScript itself. Implementations
/// are used from exactly one thread and are therefore not `Sendable`; tests
/// substitute a blocking fake for a wedged application.
protocol ScriptExecuting: AnyObject {
    /// `cacheable` marks a fixed script source worth keeping compiled. Sources
    /// with a window or tab id interpolated into them are never cached, or the
    /// cache would grow without bound.
    func execute(_ source: String, cacheable: Bool) -> Result<ScriptValue, ScriptError>
}

/// In-process execution. Roughly 14x faster than an `osascript` subprocess
/// (appendix K §2.1), at the cost of having no way to interrupt a running
/// script: the engine's soft timeout abandons the worker instead.
final class NSAppleScriptExecutor: ScriptExecuting {
    private var compiled: [String: NSAppleScript] = [:]

    func execute(_ source: String, cacheable: Bool) -> Result<ScriptValue, ScriptError> {
        let script: NSAppleScript
        if cacheable, let cached = compiled[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else {
                return .failure(.compileFailed(code: 0, message: "NSAppleScript(source:) returned nil"))
            }
            var compileError: NSDictionary?
            guard fresh.compileAndReturnError(&compileError) else {
                let code = (compileError?[NSAppleScript.errorNumber] as? Int) ?? 0
                let message = (compileError?[NSAppleScript.errorMessage] as? String) ?? ""
                return .failure(.compileFailed(code: code, message: message))
            }
            if cacheable { compiled[source] = fresh }
            script = fresh
        }

        var executionError: NSDictionary?
        let result = script.executeAndReturnError(&executionError)
        if let executionError { return .failure(.mapExecution(executionError)) }
        return .success(ScriptValue(descriptor: result))
    }
}
