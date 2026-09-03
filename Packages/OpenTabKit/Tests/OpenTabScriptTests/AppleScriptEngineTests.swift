import XCTest
@testable import OpenTabScript

final class AppleScriptEngineTests: XCTestCase {
    func testReturnsExecutorResult() async throws {
        let recorder = ScriptRecorder { _ in .success(.text("42")) }
        let engine = makeEngine(recorder)
        let value = try await engine.run("noop", lane: "a", deadline: deadline(1000))
        XCTAssertEqual(value, .text("42"))
        XCTAssertEqual(recorder.sources, ["noop"])
    }

    func testMapsExecutorFailure() async {
        let recorder = ScriptRecorder { _ in .failure(.notPermitted) }
        let engine = makeEngine(recorder)
        do {
            _ = try await engine.run("noop", lane: "a", deadline: deadline(1000))
            XCTFail("expected a failure")
        } catch let error as ScriptError {
            XCTAssertEqual(error, .notPermitted)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// The SIGSTOP case: a target that never answers must not outlive the
    /// budget, and the worker holding it is written off.
    func testWedgedTargetTimesOutWithinBudgetAndReplacesWorker() async throws {
        let gate = DispatchSemaphore(value: 0)
        let recorder = ScriptRecorder { source in
            if source == "hang" { gate.wait() }
            return .success(.text(source))
        }
        let engine = makeEngine(recorder)
        _ = try await engine.run("warm up", lane: "wedged", deadline: deadline(1000))
        let before = engine.workerIdentity(lane: "wedged")

        let started = ContinuousClock.now
        do {
            _ = try await engine.run("hang", lane: "wedged", deadline: deadline(150))
            XCTFail("expected a timeout")
        } catch let error as ScriptError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .milliseconds(600), "budget overrun: \(elapsed)")
        XCTAssertNotNil(before)
        XCTAssertNotEqual(engine.workerIdentity(lane: "wedged"), before,
                          "a budget overrun must write the worker off")
        gate.signal()
    }

    /// A job queued behind a wedged one is re-homed, so its own timeout has to
    /// act on the worker that ended up with it rather than the one it was
    /// submitted to.
    func testRehomedJobTimesOutAgainstItsNewWorker() async {
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let recorder = ScriptRecorder { source in
            if source.hasPrefix("hang") {
                entered.signal()
                gate.wait()
            }
            return .success(.text(source))
        }
        let engine = makeEngine(recorder)

        async let first: Void = {
            _ = try? await engine.run("hang first", lane: "chrome", deadline: deadline(200))
        }()
        blockUntilSignalled(entered)
        async let second: Void = {
            _ = try? await engine.run("hang second", lane: "chrome", deadline: deadline(700))
        }()

        await first
        blockUntilSignalled(entered)
        await second

        let third = engine.workerIdentity(lane: "chrome")
        XCTAssertEqual(recorder.executorsCreated, 3,
                       "the re-homed job's timeout must retire its new worker too")
        XCTAssertNotNil(third)
        gate.signal()
        gate.signal()
    }

    /// A wedged target must not stall a different one: they are separate lanes,
    /// therefore separate threads.
    func testWedgedLaneDoesNotBlockAnotherLane() async throws {
        let gate = DispatchSemaphore(value: 0)
        let recorder = ScriptRecorder { source in
            if source == "hang" { gate.wait() }
            return .success(.text(source))
        }
        let engine = makeEngine(recorder)

        async let wedged: Void = {
            _ = try? await engine.run("hang", lane: "chrome", deadline: deadline(200))
        }()

        let started = ContinuousClock.now
        let value = try await engine.run("quick", lane: "safari", deadline: deadline(1000))
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(value, .text("quick"))
        XCTAssertLessThan(elapsed, .milliseconds(200), "cross-lane interference: \(elapsed)")

        await wedged
        gate.signal()
    }

    func testLaneRecoversAfterATimeout() async throws {
        let gate = DispatchSemaphore(value: 0)
        let recorder = ScriptRecorder { source in
            if source == "hang" { gate.wait() }
            return .success(.text(source))
        }
        let engine = makeEngine(recorder)

        _ = try? await engine.run("hang", lane: "chrome", deadline: deadline(120))
        let replacement = try await engine.run("next", lane: "chrome", deadline: deadline(1000))
        XCTAssertEqual(replacement, .text("next"))
        XCTAssertEqual(recorder.executorsCreated, 2, "the wedged worker should have been replaced")
        gate.signal()
    }

    /// A job still queued behind a wedged one is re-homed onto the replacement
    /// worker rather than being lost with it.
    func testQueuedJobSurvivesWorkerReplacement() async throws {
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let recorder = ScriptRecorder { source in
            if source == "hang" {
                entered.signal()
                gate.wait()
            }
            return .success(.text(source))
        }
        let engine = makeEngine(recorder)

        async let wedged: Void = {
            _ = try? await engine.run("hang", lane: "chrome", deadline: deadline(400))
        }()
        blockUntilSignalled(entered)
        async let queued = engine.run("queued", lane: "chrome", deadline: deadline(3000))

        await wedged
        let value = try await queued
        XCTAssertEqual(value, .text("queued"))
        gate.signal()
    }

    func testCancellationThrowsAndKeepsTheLaneUsable() async throws {
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let recorder = ScriptRecorder { source in
            if source == "hang" {
                entered.signal()
                gate.wait()
            }
            return .success(.text(source))
        }
        let engine = makeEngine(recorder)

        let task = Task { try await engine.run("hang", lane: "chrome", deadline: deadline(5000)) }
        blockUntilSignalled(entered)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }

        let value = try await engine.run("next", lane: "chrome", deadline: deadline(1000))
        XCTAssertEqual(value, .text("next"))
        gate.signal()
    }

    func testCancelledTaskNeverReachesTheExecutor() async {
        let recorder = ScriptRecorder()
        let engine = makeEngine(recorder)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            blockUntilSignalled(release)
            return try await engine.run("noop", lane: "a", deadline: deadline(1000))
        }
        task.cancel()
        release.signal()
        _ = try? await task.value
        XCTAssertTrue(recorder.sources.isEmpty)
    }

    func testActivationScriptsAreNotCompileCached() async throws {
        let recorder = ScriptRecorder { _ in .success(.text("true")) }
        let engine = makeEngine(recorder)
        _ = try await engine.run("activate", lane: "a", cacheable: false, deadline: deadline(1000))
        XCTAssertEqual(recorder.recordedCalls, [.init(source: "activate", cacheable: false)])
    }

    /// A `-1712` reported by the target came back through a worker that is
    /// still healthy; only giving up on a job the worker still owns writes it
    /// off.
    func testTargetReportedTimeoutKeepsTheWorker() async {
        let recorder = ScriptRecorder { _ in .failure(.timedOut) }
        let engine = makeEngine(recorder)
        _ = try? await engine.run("a", lane: "chrome", deadline: deadline(5000))
        _ = try? await engine.run("b", lane: "chrome", deadline: deadline(5000))
        XCTAssertEqual(recorder.executorsCreated, 1)
        XCTAssertEqual(recorder.sources, ["a", "b"])
    }
}
