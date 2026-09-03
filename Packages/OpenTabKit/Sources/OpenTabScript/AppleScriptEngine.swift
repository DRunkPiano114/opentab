import Foundation
import os

public enum ScriptBudget {
    /// One tab read. The query itself measures around 110ms against a real
    /// browser, so 300ms leaves no headroom.
    public static let read = Duration.milliseconds(500)
    /// Selecting or closing a tab, which also raises the window.
    public static let activate = Duration.milliseconds(500)
}

/// Runs AppleScript off the main thread with a budget the target cannot exceed.
///
/// One worker thread per lane (a lane is one target bundle id), so a wedged
/// browser stalls only its own reads. `executeAndReturnError` cannot be
/// interrupted, so the budget is enforced on our side: the call returns
/// `.timedOut` and the worker is abandoned, left to drain on its own, and
/// replaced for subsequent requests.
public final class AppleScriptEngine: @unchecked Sendable {
    private let executorFactory: @Sendable () -> any ScriptExecuting
    private let timers = DispatchQueue(label: "im.opentab.app.script.timeout")
    private let lock = NSLock()
    private var workers: [String: ScriptWorker] = [:]

    public convenience init() {
        self.init(executorFactory: { NSAppleScriptExecutor() })
    }

    init(executorFactory: @escaping @Sendable () -> any ScriptExecuting) {
        self.executorFactory = executorFactory
    }

    deinit {
        // A worker thread parks on its condition variable and is kept alive by
        // its own closure, so dropping the engine without retiring them would
        // strand one thread per lane. Any job still queued belongs to a call
        // that is no longer awaiting a result.
        for worker in workers.values {
            for job in worker.retire() { job.box.settle(.failure(.cancelled)) }
        }
    }

    public func run(_ source: String, lane: String, cacheable: Bool = true,
                    deadline: ContinuousClock.Instant) async throws -> ScriptValue {
        try Task.checkCancellation()

        let box = ScriptResultBox()
        let job = ScriptJob(source: source, cacheable: cacheable, box: box)
        let worker = enqueue(job, lane: lane)

        // Set only when we stop waiting on a job the worker still owns, which
        // is what makes the worker unusable. A `-1712` the target itself
        // reported comes back through the worker, which stays healthy.
        let abandoned = OSAllocatedUnfairLock(initialState: false)
        let timeout = DispatchWorkItem {
            if box.settle(.failure(.timedOut)) { abandoned.withLock { $0 = true } }
        }
        timers.asyncAfter(deadline: .now() + .nanoseconds(Self.nanoseconds(until: deadline)),
                          execute: timeout)

        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { box.attach($0) }
        } onCancel: {
            if box.settle(.failure(.cancelled)) { abandoned.withLock { $0 = true } }
        }
        timeout.cancel()

        switch outcome {
        case .success(let value):
            return value
        case .failure(let error):
            // A job that never started can simply be recalled. One that is
            // already inside `executeAndReturnError` cannot, so its worker is
            // written off along with its compile cache.
            if abandoned.withLock({ $0 }), !worker.withdraw(job) {
                recycle(lane: lane, retiring: worker)
            }
            if error == .cancelled { throw CancellationError() }
            throw error
        }
    }

    private func enqueue(_ job: ScriptJob, lane: String) -> ScriptWorker {
        lock.lock()
        defer { lock.unlock() }
        while true {
            let worker = workers[lane] ?? makeWorker(lane: lane)
            if worker.submit(job) { return worker }
            workers[lane] = nil
        }
    }

    private func recycle(lane: String, retiring worker: ScriptWorker) {
        lock.lock()
        guard workers[lane] === worker else {
            lock.unlock()
            return
        }
        workers[lane] = nil
        let leftovers = worker.retire()
        let replacement = makeWorker(lane: lane)
        lock.unlock()
        for job in leftovers where !replacement.submit(job) {
            job.box.settle(.failure(.timedOut))
        }
    }

    /// Callers hold `lock`.
    private func makeWorker(lane: String) -> ScriptWorker {
        let worker = ScriptWorker(label: "im.opentab.app.script.\(lane)",
                                  executorFactory: executorFactory)
        workers[lane] = worker
        return worker
    }

    private static func nanoseconds(until deadline: ContinuousClock.Instant) -> Int {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return 0 }
        let components = remaining.components
        let capped = min(components.seconds, 60)
        return Int(capped) * 1_000_000_000 + Int(components.attoseconds / 1_000_000_000)
    }
}

extension AppleScriptEngine {
    /// Test hook: identifies the worker currently serving a lane, so a test can
    /// assert that a timeout actually replaced it.
    func workerIdentity(lane: String) -> ObjectIdentifier? {
        lock.lock()
        defer { lock.unlock() }
        return workers[lane].map(ObjectIdentifier.init)
    }
}
