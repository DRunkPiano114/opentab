import Foundation
@testable import OpenTabScript

/// Stands in for AppleScript. Blocking here is the test analogue of a
/// SIGSTOPped browser: the call cannot be interrupted, exactly like
/// `executeAndReturnError`.
final class FakeExecutor: ScriptExecuting {
    let recorder: ScriptRecorder

    init(recorder: ScriptRecorder) {
        self.recorder = recorder
    }

    func execute(_ source: String, cacheable: Bool) -> Result<ScriptValue, ScriptError> {
        recorder.record(source: source, cacheable: cacheable)
        return recorder.respond(to: source)
    }
}

final class ScriptRecorder: @unchecked Sendable {
    struct Call: Equatable {
        let source: String
        let cacheable: Bool
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var executorCount = 0
    private let responder: @Sendable (String) -> Result<ScriptValue, ScriptError>

    init(responder: @escaping @Sendable (String) -> Result<ScriptValue, ScriptError> = { _ in .success(.list([])) }) {
        self.responder = responder
    }

    var factory: @Sendable () -> any ScriptExecuting {
        { [self] in
            lock.lock()
            executorCount += 1
            lock.unlock()
            return FakeExecutor(recorder: self)
        }
    }

    func record(source: String, cacheable: Bool) {
        lock.lock()
        calls.append(Call(source: source, cacheable: cacheable))
        lock.unlock()
    }

    func respond(to source: String) -> Result<ScriptValue, ScriptError> {
        responder(source)
    }

    var recordedCalls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var sources: [String] {
        recordedCalls.map(\.source)
    }

    /// How many worker threads have been created, i.e. how many times a worker
    /// was written off and replaced.
    var executorsCreated: Int {
        lock.lock()
        defer { lock.unlock() }
        return executorCount
    }
}

struct StubLiveness: BrowserLiveness {
    let running: Set<String>

    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
}

func makeEngine(_ recorder: ScriptRecorder) -> AppleScriptEngine {
    AppleScriptEngine(executorFactory: recorder.factory)
}

/// `DispatchSemaphore.wait()` is unavailable from async contexts, but these
/// tests need to block until a worker thread reaches a known point. Every use
/// is released by the same test.
func blockUntilSignalled(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}

func deadline(_ milliseconds: Int) -> ContinuousClock.Instant {
    .now.advanced(by: .milliseconds(milliseconds))
}
