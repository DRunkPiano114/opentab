import Foundation

public enum ScriptBudget {
    /// One tab read. The query itself measures around 110ms against a real
    /// browser, so 300ms leaves no headroom.
    public static let read = Duration.milliseconds(500)
    /// Selecting or closing a tab, which also raises the window.
    public static let activate = Duration.milliseconds(500)
    /// Deadlines further out than this are treated as this. Nothing here asks
    /// for a longer budget, and the clamp keeps the nanosecond arithmetic away
    /// from overflow.
    public static let maximum = Duration.seconds(600)
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
            for job in worker.retire() { job.box.settle(.abandoned(.cancelled)) }
        }
    }

    public func run(_ source: String, lane: String, cacheable: Bool = true,
                    deadline: ContinuousClock.Instant) async throws -> ScriptValue {
        try Task.checkCancellation()

        let box = ScriptResultBox()
        let job = ScriptJob(source: source, cacheable: cacheable, box: box)
        enqueue(job, lane: lane)

        let timeout = DispatchWorkItem { box.settle(.abandoned(.timedOut)) }
        timers.asyncAfter(deadline: .now() + .nanoseconds(Self.nanoseconds(until: deadline)),
                          execute: timeout)

        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { box.attach($0) }
        } onCancel: {
            box.settle(.abandoned(.cancelled))
        }
        timeout.cancel()

        // Only an outcome we imposed leaves the job on its worker. A `-1712` the
        // target itself reported arrived through a worker that is still healthy.
        if outcome.abandoned { abandon(job, lane: lane) }

        switch outcome.result {
        case .success(let value):
            return value
        case .failure(.cancelled):
            throw CancellationError()
        case .failure(let error):
            throw error
        }
    }

    private func enqueue(_ job: ScriptJob, lane: String) {
        lock.lock()
        defer { lock.unlock() }
        let worker = workers[lane] ?? makeWorker(lane: lane)
        guard worker.submit(job) else {
            // Unreachable: a worker is retired and removed from the table in one
            // critical section, so one found here is live.
            job.box.settle(.delivered(.failure(.timedOut)))
            return
        }
        job.owner = worker
    }

    /// Gives up on a job we stopped waiting for. One that never started is
    /// simply recalled; one the worker is still inside costs that worker, along
    /// with its compile cache.
    private func abandon(_ job: ScriptJob, lane: String) {
        lock.lock()
        guard let owner = job.owner else {
            lock.unlock()
            return
        }
        job.owner = nil
        if owner.withdraw(job) {
            lock.unlock()
            return
        }
        // The owner may already have been written off by another job's timeout,
        // in which case a replacement is serving the lane and there is nothing
        // left to do.
        guard workers[lane] === owner else {
            lock.unlock()
            return
        }
        workers[lane] = nil
        // A job whose caller has already given up is not worth re-running.
        let leftovers = owner.retire().filter { !$0.box.isSettled }
        let replacement = makeWorker(lane: lane)
        for job in leftovers { job.owner = replacement }
        // Submitted before the lock is released: a leftover whose deadline
        // passes right now is abandoned as soon as the lock is free, and its
        // `withdraw` against a replacement that does not hold it yet reports
        // the job as finished. It would then be submitted anyway and run on a
        // worker nobody retires.
        for job in leftovers where !replacement.submit(job) {
            job.box.settle(.delivered(.failure(.timedOut)))
        }
        lock.unlock()
    }

    /// Callers hold `lock`.
    private func makeWorker(lane: String) -> ScriptWorker {
        let worker = ScriptWorker(label: "im.opentab.app.script.\(lane)",
                                  executorFactory: executorFactory)
        workers[lane] = worker
        return worker
    }

    private static func nanoseconds(until deadline: ContinuousClock.Instant) -> Int {
        let remaining = min(ContinuousClock.now.duration(to: deadline), ScriptBudget.maximum)
        guard remaining > .zero else { return 0 }
        let components = remaining.components
        return Int(components.seconds) * 1_000_000_000 + Int(components.attoseconds / 1_000_000_000)
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
