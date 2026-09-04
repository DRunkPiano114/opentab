import Foundation
import os

/// One serial queue per key. Tab reads of the same app must not overlap:
/// AppleScript takes hundreds of milliseconds and two re-entrant reads of one
/// browser produce duplicate entries. Reads of different apps still run in
/// parallel.
///
/// Only the ordering lives here. The blocking call itself belongs on the
/// provider's dedicated thread; this class merely awaits it.
public final class ReadLane<Key: Hashable & Sendable>: @unchecked Sendable {
    private struct Slot {
        var tail: Task<Void, Never>?
        var tailID: UInt64 = 0
        /// The operation waiting for its turn, if any. A coalesced request
        /// joins it instead of queueing a second read of the same state.
        var queued: (id: UInt64, task: Task<Void, Never>)?
    }

    private struct State {
        var slots: [Key: Slot] = [:]
        var nextID: UInt64 = 1
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Runs `operation` after every operation enqueued earlier for `key` has
    /// finished, and returns when it is done. With `coalesce`, an operation
    /// that is still waiting its turn for `key` is awaited instead of adding
    /// another: it has not started, so it will see the same state.
    public func run(_ key: Key, coalesce: Bool = false, _ operation: @escaping @Sendable () async -> Void) async {
        let task: Task<Void, Never> = state.withLock { state in
            var slot = state.slots[key] ?? Slot()
            if coalesce, let queued = slot.queued { return queued.task }
            let id = state.nextID
            state.nextID += 1
            let previous = slot.tail
            let lock = self.state
            let task = Task {
                await previous?.value
                lock.withLock { state in
                    if state.slots[key]?.queued?.id == id { state.slots[key]?.queued = nil }
                }
                await operation()
                lock.withLock { state in
                    if state.slots[key]?.tailID == id { state.slots[key] = nil }
                }
            }
            slot.tail = task
            slot.tailID = id
            slot.queued = (id, task)
            state.slots[key] = slot
            return task
        }
        await task.value
    }

    /// No operation is running or waiting on any key.
    public var isIdle: Bool {
        state.withLock { $0.slots.isEmpty }
    }
}
