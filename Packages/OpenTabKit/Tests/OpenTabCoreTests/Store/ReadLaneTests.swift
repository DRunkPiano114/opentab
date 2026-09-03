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

    func testSameKeyRunsSeriallyInOrder() async {
        let lane = ReadLane<String>()
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    await lane.run("chrome") {
                        probe.enter("chrome", "op\(i)")
                        try? await Task.sleep(for: .milliseconds(2))
                        probe.leave("chrome")
                    }
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        XCTAssertEqual(probe.peak["chrome"], 1)
        XCTAssertEqual(probe.order, (0..<5).map { "op\($0)" })
        XCTAssertTrue(lane.isIdle)
    }

    func testDifferentKeysRunInParallel() async {
        let lane = ReadLane<String>()
        let probe = Probe()
        let started = OSAllocatedUnfairLock(initialState: 0)
        await withTaskGroup(of: Void.self) { group in
            for key in ["chrome", "safari"] {
                group.addTask {
                    await lane.run(key) {
                        probe.enter(key, key)
                        started.withLock { $0 += 1 }
                        // Neither may finish before both have started.
                        for _ in 0..<200 where started.withLock({ $0 }) < 2 {
                            try? await Task.sleep(for: .milliseconds(1))
                        }
                        probe.leave(key)
                    }
                }
            }
        }
        XCTAssertEqual(started.withLock { $0 }, 2)
    }

    func testCoalescedRequestJoinsTheWaitingOperation() async {
        let lane = ReadLane<String>()
        let probe = Probe()
        let runs = OSAllocatedUnfairLock(initialState: 0)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await lane.run("chrome") {
                    probe.enter("chrome", "first")
                    try? await Task.sleep(for: .milliseconds(10))
                    probe.leave("chrome")
                }
            }
            try? await Task.sleep(for: .milliseconds(2))
            for _ in 0..<3 {
                group.addTask {
                    await lane.run("chrome", coalesce: true) {
                        probe.enter("chrome", "queued")
                        runs.withLock { $0 += 1 }
                        probe.leave("chrome")
                    }
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
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
