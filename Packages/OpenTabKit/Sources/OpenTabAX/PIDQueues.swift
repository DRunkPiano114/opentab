import Foundation
import os

/// One serial queue per target pid so a wedged app stalls only its own reads
/// (L13). Our own pid goes to the main queue: same-process AX runs inline in
/// AppKit, which is main-thread-only (L9).
final class PIDQueues: Sendable {
    private let queues = OSAllocatedUnfairLock<[pid_t: DispatchQueue]>(initialState: [:])

    func queue(for pid: pid_t) -> DispatchQueue {
        if pid == getpid() { return .main }
        return queues.withLock { table in
            if let queue = table[pid] { return queue }
            let queue = DispatchQueue(label: "com.paulwu.opentab.ax.\(pid)", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)
            table[pid] = queue
            return queue
        }
    }

    func forget(_ pid: pid_t) {
        _ = queues.withLock { $0.removeValue(forKey: pid) }
    }

    func perform<T: Sendable>(on pid: pid_t, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let queue = queue(for: pid)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: body))
            }
        }
    }
}
