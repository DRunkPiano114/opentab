import Foundation

/// Resolves once, whichever of several racing producers gets there first, and
/// hands the value to an awaiting continuation.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var waiter: CheckedContinuation<Value, Never>?

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
