import Foundation

/// A target that just timed out is skipped for a while instead of being asked
/// again on the next refresh. Without this, a wedged browser costs one
/// abandoned worker thread per refresh, and a process only has room for about
/// 64 threads.
public final class BrowserHealth: @unchecked Sendable {
    private struct Record {
        var failures: Int
        var openUntil: ContinuousClock.Instant
    }

    private let base: Duration
    private let cap: Duration
    private let lock = NSLock()
    private var records: [String: Record] = [:]

    public init(base: Duration = .seconds(2), cap: Duration = .seconds(30)) {
        self.base = base
        self.cap = cap
    }

    public func isCoolingDown(_ bundleID: String, now: ContinuousClock.Instant = .now) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[bundleID] else { return false }
        return now < record.openUntil
    }

    public func recordFailure(_ bundleID: String, now: ContinuousClock.Instant = .now) {
        lock.lock()
        defer { lock.unlock() }
        let failures = (records[bundleID]?.failures ?? 0) + 1
        var backoff = base
        for _ in 1..<failures {
            backoff = backoff * 2
            if backoff > cap { backoff = cap; break }
        }
        records[bundleID] = Record(failures: failures, openUntil: now.advanced(by: backoff))
    }

    public func recordSuccess(_ bundleID: String) {
        lock.lock()
        defer { lock.unlock() }
        records[bundleID] = nil
    }
}
