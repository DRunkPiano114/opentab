import XCTest
@testable import OpenTabScript

/// End-to-end checks of the real `NSAppleScript` executor using scripts that
/// compute locally and address no application. They need no automation grant.
///
/// Timings gathered here are not browser timings: the host has no
/// `NSApplication` event loop, which is exactly the condition under which
/// Apple Event benchmarks are invalid (L12). Only the engine's own behaviour is
/// under test.
final class LocalExecutionTests: XCTestCase {
    private func requireOptIn() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENTAB_SCRIPT_LOCAL_EXEC"] == "1",
                          "set OPENTAB_SCRIPT_LOCAL_EXEC=1 to run real AppleScript")
    }

    func testRunsARealScriptOnTheWorkerThread() async throws {
        try requireOptIn()
        let engine = AppleScriptEngine()
        let value = try await engine.run("return (1 + 1) as text", lane: "local",
                                         deadline: .now.advanced(by: .seconds(5)))
        XCTAssertEqual(value, .text("2"))
    }

    func testReturnsAListAsAList() async throws {
        try requireOptIn()
        let engine = AppleScriptEngine()
        let value = try await engine.run("return {\"a\", \"b\"}", lane: "local",
                                         deadline: .now.advanced(by: .seconds(5)))
        XCTAssertEqual(value, .list([.text("a"), .text("b")]))
    }

    /// A payload far larger than a pipe buffer, which the in-process path has no
    /// reason to deadlock on because there is no pipe.
    func testLargeResultCrossesBackIntact() async throws {
        try requireOptIn()
        let engine = AppleScriptEngine()
        let source = """
        set out to {}
        repeat with i from 1 to 4000
        \tset end of out to "0123456789012345678901234"
        end repeat
        return out
        """
        let value = try await engine.run(source, lane: "local",
                                         deadline: .now.advanced(by: .seconds(20)))
        XCTAssertEqual(value.items?.count, 4000)
        XCTAssertEqual((value.items?.count ?? 0) * 25, 100_000)
    }

    func testCompileErrorsSurfaceAsCompileFailures() async throws {
        try requireOptIn()
        let engine = AppleScriptEngine()
        do {
            _ = try await engine.run("this is not applescript!!", lane: "local",
                                      deadline: .now.advanced(by: .seconds(5)))
            XCTFail("expected a compile failure")
        } catch let error as ScriptError {
            guard case .compileFailed = error else { return XCTFail("got \(error)") }
        }
    }

    func testCompileCacheRemovesTheCompileCostOnRepeatCalls() async throws {
        try requireOptIn()
        let engine = AppleScriptEngine()
        let source = "return \"warm\""
        var timings: [Duration] = []
        for _ in 0..<5 {
            let started = ContinuousClock.now
            _ = try await engine.run(source, lane: "local", deadline: .now.advanced(by: .seconds(5)))
            timings.append(started.duration(to: .now))
        }
        print("local execution: cold=\(timings[0]) warm=\(timings.dropFirst())")
        XCTAssertLessThan(timings[4], timings[0])
    }

    /// The wedged-target case with the real executor. `do shell script` blocks
    /// the worker thread and, per Apple's own documentation, `with timeout` does
    /// not cut it short - only the engine's budget does, by writing the worker
    /// off. A second lane must stay responsive while that happens.
    func testWedgedScriptIsAbandonedWithinBudgetWithoutStallingOtherLanes() async throws {
        try requireOptIn()
        let engine = AppleScriptEngine()
        let blocking = BrowserScripts.timed("do shell script \"sleep 5\"")

        let started = ContinuousClock.now
        do {
            _ = try await engine.run(blocking, lane: "stuck",
                                     deadline: .now.advanced(by: .milliseconds(500)))
            XCTFail("expected a timeout")
        } catch let error as ScriptError {
            XCTAssertEqual(error, .timedOut)
        }
        let stuckElapsed = started.duration(to: .now)

        let otherStarted = ContinuousClock.now
        let other = try await engine.run("return \"ok\"", lane: "other",
                                         deadline: .now.advanced(by: .seconds(5)))
        let otherElapsed = otherStarted.duration(to: .now)

        let recoveredStarted = ContinuousClock.now
        let recovered = try await engine.run("return \"back\"", lane: "stuck",
                                             deadline: .now.advanced(by: .seconds(5)))
        let recoveredElapsed = recoveredStarted.duration(to: .now)

        print("wedged lane: timeout returned in \(stuckElapsed); other lane \(otherElapsed); same lane after replacement \(recoveredElapsed)")
        XCTAssertEqual(other, .text("ok"))
        XCTAssertEqual(recovered, .text("back"))
        XCTAssertLessThan(stuckElapsed, .milliseconds(900))
        XCTAssertLessThan(otherElapsed, .milliseconds(500))
    }

    /// Exercises the Carbon call itself (descriptor creation, widened OSErr,
    /// the off-main deadline) against a bundle id that is not running, which
    /// answers -600 without prompting anyone. It says nothing about whether we
    /// are authorised: a binary run from a shell inherits the terminal's grant
    /// (L1), so authorisation is only ever judged from the installed app.
    func testPermissionProbeAnswersForANonRunningTarget() async throws {
        try requireOptIn()
        let permission = AutomationPermission(log: DefaultsAutomationRequestLog())
        let started = ContinuousClock.now
        let status = await permission.status(of: "im.opentab.tests.absent",
                                             timeout: .milliseconds(500))
        let elapsed = started.duration(to: .now)
        print("permission probe for an absent target: \(status) in \(elapsed)")
        XCTAssertEqual(status, .targetNotRunning)
        XCTAssertLessThan(elapsed, .milliseconds(800))
    }

    /// The engine's worker thread outlives every job on it, so nothing it
    /// autoreleases is reclaimed unless each job drains its own pool. A read of
    /// this shape held around 97KB per call before it did, which at the
    /// coordinator's poll rate is a little over 1MB a minute, indefinitely.
    ///
    /// The bound covers what is legitimately still reachable at the end of the
    /// loop: `run` arms a `DispatchWorkItem` for the budget and cancelling it
    /// does not release it before its deadline, so up to one result per call in
    /// the loop can still be held. That is 200 results, and a result of this
    /// shape is roughly 20KB.
    func testRepeatedReadsDoNotAccumulateOnTheWorker() async throws {
        try requireOptIn()
        let engine = AppleScriptEngine()
        let source = """
        set out to {}
        repeat with i from 1 to 60
        \tset end of out to {"1234567890" & i, "a title as long as a real tab title", "https://example.com/some/path/that/is/long"}
        end repeat
        return out
        """
        // Compiling the script and faulting in the AppleScript machinery are
        // one-time costs that would otherwise land inside the measurement.
        for _ in 0..<20 {
            _ = try await engine.run(source, lane: "local", deadline: .now.advanced(by: ScriptBudget.read))
        }

        let before = Self.footprintBytes()
        for _ in 0..<200 {
            _ = try await engine.run(source, lane: "local", deadline: .now.advanced(by: ScriptBudget.read))
        }
        let growth = Int64(Self.footprintBytes()) - Int64(before)
        print("200 reads grew the footprint by \(growth) bytes")
        XCTAssertLessThan(growth, 8 * 1_048_576)
    }

    private static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}
