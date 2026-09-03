import Foundation

/// Shared plumbing for the scripted providers: liveness gate, circuit breaker,
/// and one engine lane per target bundle id.
struct BrowserSession: Sendable {
    let engine: AppleScriptEngine
    let liveness: any BrowserLiveness
    let health: BrowserHealth

    /// `nil` means the target is not running, which is a skip rather than a
    /// failure. A target still cooling down after a timeout throws `.timedOut`
    /// so the caller keeps showing its cached rows.
    func run(_ source: String, bundleID: String, cacheable: Bool,
             deadline: ContinuousClock.Instant) async throws -> ScriptValue? {
        guard liveness.isRunning(bundleID: bundleID) else { return nil }
        guard !health.isCoolingDown(bundleID) else { throw ScriptError.timedOut }
        do {
            let value = try await engine.run(source, lane: bundleID, cacheable: cacheable,
                                             deadline: deadline)
            health.recordSuccess(bundleID)
            return value
        } catch let error as ScriptError {
            // Only a timeout is worth backing off from: it is the one failure
            // that costs an abandoned thread. A refusal returns instantly, and
            // backing off from it would outlast the user granting permission.
            if error == .timedOut { health.recordFailure(bundleID) }
            throw error
        }
    }
}
