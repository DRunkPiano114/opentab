import Foundation

/// The result of one job, plus who produced it. `abandoned` marks the outcomes
/// we imposed from outside - a budget overrun or task cancellation - which are
/// the only ones that leave a job stranded on its worker.
struct ScriptOutcome: Sendable {
    let result: Result<ScriptValue, ScriptError>
    let abandoned: Bool

    static func delivered(_ result: Result<ScriptValue, ScriptError>) -> ScriptOutcome {
        ScriptOutcome(result: result, abandoned: false)
    }

    static func abandoned(_ error: ScriptError) -> ScriptOutcome {
        ScriptOutcome(result: .failure(error), abandoned: true)
    }
}

typealias ScriptResultBox = OneShot<ScriptOutcome>

final class ScriptJob {
    let source: String
    let cacheable: Bool
    let box: ScriptResultBox
    /// The worker currently responsible for the job. Guarded by the engine's
    /// lock, and reassigned when a job outlives the worker it was queued on.
    var owner: ScriptWorker?

    init(source: String, cacheable: Bool, box: ScriptResultBox) {
        self.source = source
        self.cacheable = cacheable
        self.box = box
    }
}

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
    private var running: ScriptJob?
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
                running = job
                condition.unlock()

                job.box.settle(.delivered(executor.execute(job.source, cacheable: job.cacheable)))

                condition.lock()
                running = nil
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

    /// True when the worker is no longer going to execute the job, either
    /// because it was still queued and has now been removed, or because it has
    /// already finished. False means the thread is inside the job right now and
    /// cannot be recalled.
    func withdraw(_ job: ScriptJob) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if let index = pending.firstIndex(where: { $0 === job }) {
            pending.remove(at: index)
            return true
        }
        return running !== job
    }

    /// Stops the worker and hands back the jobs that never started. A thread
    /// blocked inside a wedged script exits once that script finally drains,
    /// which the script's own `with timeout` bounds for anything sent to an
    /// application.
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
