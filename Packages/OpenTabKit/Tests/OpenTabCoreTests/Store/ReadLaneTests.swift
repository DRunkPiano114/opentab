import XCTest
import os
@testable import OpenTabCore

final class ReadLaneTests: XCTestCase {
    /// Records concurrent occupancy per key and the order operations ran.
    private final class Probe: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: (active: [String: Int](), peak: [String: Int](), order: [String]()))

        func enter(_ key: String, _ label: String) {
            lock.withLock { state in
                state.active[key, default: 0] += 1
                state.peak[key] = max(state.peak[key] ?? 0, state.active[key]!)
                state.order.append(label)
            }
        }

        func leave(_ key: String) {
            lock.withLock { $0.active[key]! -= 1 }
        }

        var peak: [String: Int] { lock.withLock { $0.peak } }
        var order: [String] { lock.withLock { $0.order } }
    }

    /// One-shot gate. `wait()` returns once `open()` has been called, in
    /// either order.
    private final class Gate: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(
            initialState: (isOpen: false, waiting: [CheckedContinuation<Void, Never>]()))

        func open() {
            let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.isOpen = true
                let pending = state.waiting
                state.waiting = []
                return pending
            }
            for continuation in waiting { continuation.resume() }
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let isOpen = state.withLock { state -> Bool in
                    if !state.isOpen { state.waiting.append(continuation) }
                    return state.isOpen
                }
                if isOpen { continuation.resume() }
            }
        }
    }

    func testSameKeyRunsSeriallyInOrder() async {
        let lane = ReadLane<String>()
        let probe = Probe()
        let firstStarted = Gate()
        let firstMayFinish = Gate()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await lane.run("chrome") {
                    probe.enter("chrome", "op0")
                    firstStarted.open()
                    await firstMayFinish.wait()
                    probe.leave("chrome")
                }
            }
            await firstStarted.wait()
            for i in 1..<5 {
                group.addTask {
                    await lane.run("chrome") {
                        probe.enter("chrome", "op\(i)")
                        await Task.yield()
                        probe.leave("chrome")
                    }
                }
                // Enqueue order decides run order, so each request has to
                // reach the lane before the next one is added.
                while lane.admittedRequests(for: "chrome") < i + 1 { await Task.yield() }
            }
            firstMayFinish.open()
        }
        XCTAssertEqual(probe.peak["chrome"], 1)
        XCTAssertEqual(probe.order, (0..<5).map { "op\($0)" })
        XCTAssertTrue(lane.isIdle)
    }

    func testDifferentKeysRunInParallel() async {
        let lane = ReadLane<String>()
        let started = OSAllocatedUnfairLock(initialState: 0)
        let sawPeer = OSAllocatedUnfairLock(initialState: 0)
        await withTaskGroup(of: Void.self) { group in
            for key in ["chrome", "safari"] {
                group.addTask {
                    await lane.run(key) {
                        started.withLock { $0 += 1 }
                        // Serialised keys would leave the peer unstarted. The
                        // bound turns that into a failed assertion rather than
                        // a test that never returns.
                        for _ in 0..<100_000 where started.withLock({ $0 }) < 2 { await Task.yield() }
                        if started.withLock({ $0 }) == 2 { sawPeer.withLock { $0 += 1 } }
                    }
                }
            }
        }
        XCTAssertEqual(sawPeer.withLock { $0 }, 2, "reads of different keys must overlap")
    }

    func testCoalescedRequestJoinsTheWaitingOperation() async {
        let lane = ReadLane<String>()
        let probe = Probe()
        let runs = OSAllocatedUnfairLock(initialState: 0)
        let firstStarted = Gate()
        let firstMayFinish = Gate()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await lane.run("chrome") {
                    probe.enter("chrome", "first")
                    firstStarted.open()
                    await firstMayFinish.wait()
                    probe.leave("chrome")
                }
            }
            // An operation is joinable until it starts, so the coalesced
            // requests must arrive after the first one is running.
            await firstStarted.wait()
            for _ in 0..<3 {
                group.addTask {
                    await lane.run("chrome", coalesce: true) {
                        probe.enter("chrome", "queued")
                        runs.withLock { $0 += 1 }
                        probe.leave("chrome")
                    }
                }
            }
            // Release the first operation only once all three have reached the
            // lane: one queues, the other two join it.
            while lane.admittedRequests(for: "chrome") < 4 { await Task.yield() }
            firstMayFinish.open()
        }
        XCTAssertEqual(runs.withLock { $0 }, 1, "three requests while one is waiting collapse into one read")
        XCTAssertEqual(probe.order, ["first", "queued"])
    }

    func testUncoalescedRequestsAllRun() async {
        let lane = ReadLane<String>()
        let runs = OSAllocatedUnfairLock(initialState: 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { await lane.run("chrome") { runs.withLock { $0 += 1 } } }
            }
        }
        XCTAssertEqual(runs.withLock { $0 }, 3)
    }
}
