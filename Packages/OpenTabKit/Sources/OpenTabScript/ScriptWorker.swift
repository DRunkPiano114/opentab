import Foundation

final class ScriptJob {
    let source: String
    let cacheable: Bool
    let box: ScriptResultBox

    init(source: String, cacheable: Bool, box: ScriptResultBox) {
        self.source = source
        self.cacheable = cacheable
        self.box = box
    }
}

typealias ScriptResultBox = OneShot<Result<ScriptValue, ScriptError>>

/// One dedicated thread that owns one AppleScript executor.
///
/// L12, all measured: jobs are pulled from a condition variable at the top level
/// of the thread body. Delivering them through the thread's run loop instead
/// (`perform(_:on:)`, `CFRunLoopPerformBlock`) wedges the first send for 12-21
/// seconds, because AppleScript spins a nested run loop while it waits for a
/// reply. A Swift `actor` is equally wrong: it would run the blocking call on
/// the cooperative pool and starve every other async task in the app (L13).
final class ScriptWorker: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [ScriptJob] = []
    private var stopped = false

    init(label: String, executorFactory: @escaping @Sendable () -> any ScriptExecuting) {
        let thread = Thread { [self] in
            let executor = executorFactory()
            while true {
                condition.lock()
                while pending.isEmpty && !stopped { condition.wait() }
                if stopped {
                    condition.unlock()
                    return
                }
                let job = pending.removeFirst()
                condition.unlock()

                job.box.settle(executor.execute(job.source, cacheable: job.cacheable))

                condition.lock()
                let done = stopped
                condition.unlock()
                if done { return }
            }
        }
        thread.name = label
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// False when the worker has already been retired; the caller then routes
    /// the job to a fresh one.
    func submit(_ job: ScriptJob) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped else { return false }
        pending.append(job)
        condition.signal()
        return true
    }

    /// Removes a job that has not started yet. False means it is already running
    /// on the thread and can no longer be recalled.
    func withdraw(_ job: ScriptJob) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard let index = pending.firstIndex(where: { $0 === job }) else { return false }
        pending.remove(at: index)
        return true
    }

    /// Stops the worker and hands back the jobs that never started. A thread
    /// blocked inside a wedged script exits once that script finally drains.
    func retire() -> [ScriptJob] {
        condition.lock()
        stopped = true
        let leftovers = pending
        pending = []
        condition.broadcast()
        condition.unlock()
        return leftovers
    }
}
