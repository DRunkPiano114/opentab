import Foundation

/// Resolves once, whichever of several racing producers gets there first, and
/// hands the value to an awaiting continuation.
///
/// The value carries everything the awaiting side needs to know, including who
/// settled it: the waiter is resumed from inside `settle`, so anything written
/// after that call can be read too late to be seen.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var waiter: CheckedContinuation<Value, Never>?

    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value != nil
    }

    func attach(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if let value {
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        waiter = continuation
        lock.unlock()
    }

    @discardableResult
    func settle(_ value: Value) -> Bool {
        lock.lock()
        guard self.value == nil else {
            lock.unlock()
            return false
        }
        self.value = value
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: value)
        return true
    }
}
