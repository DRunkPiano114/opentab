import ApplicationServices
import Foundation
import os

/// Hashable, Sendable handle for an accessibility element, including ones
/// synthesized from a remote token. The value is an immutable token and CF
/// retain/release is thread-safe; messaging it is serialised on the owning
/// pid's queue (`SerialQueues`).
struct RemoteElement: @unchecked Sendable, Hashable {
    let raw: AXUIElement

    init(_ raw: AXUIElement) { self.raw = raw }

    static func application(pid: pid_t) -> RemoteElement {
        RemoteElement(AXUIElementCreateApplication(pid))
    }

    static func == (lhs: RemoteElement, rhs: RemoteElement) -> Bool { CFEqual(lhs.raw, rhs.raw) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }
}

enum AXReader {
    static func value(_ element: RemoteElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element.raw, attribute as CFString, &value)
        return error == .success ? value : nil
    }

    /// One IPC round trip for the whole batch. Slots are positional; a slot
    /// whose read failed is `nil`. `nil` overall when the element is gone or
    /// the app did not answer.
    static func multiple(_ element: RemoteElement, _ attributes: [String]) -> [CFTypeRef?]? {
        var out: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element.raw, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
        guard error == .success, let values = out as? [CFTypeRef], values.count == attributes.count else {
            return nil
        }
        return values.map(unwrap)
    }

    /// A failed slot in a multi-value result is a `kAXValueAXErrorType`
    /// AXValue, and it casts happily to `AXUIElement` yielding a zeroed
    /// object. Unwrap before casting.
    static func unwrap(_ value: CFTypeRef) -> CFTypeRef? {
        if CFGetTypeID(value) == CFNullGetTypeID() { return nil }
        if CFGetTypeID(value) == AXValueGetTypeID(),
           AXValueGetType(value as! AXValue) == .axError { return nil }
        return value
    }

    static func element(_ value: CFTypeRef?) -> RemoteElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return RemoteElement(value as! AXUIElement)
    }

    /// `_AXUIElementGetWindow`; `nil` when the symbol is missing or the
    /// element has no window.
    static func windowID(of element: RemoteElement) -> CGWindowID? {
        guard let getWindow = WSPrivateSymbols.getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(element.raw, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// The app's own `kAXFrontmostAttribute` (L2).
    static func isFrontmost(pid: pid_t) -> Bool {
        (value(.application(pid: pid), kAXFrontmostAttribute) as? Bool) ?? false
    }

    static func focusedWindowID(pid: pid_t) -> CGWindowID? {
        element(value(.application(pid: pid), kAXFocusedWindowAttribute)).flatMap(windowID(of:))
    }
}

/// One serial queue per target pid so a wedged app stalls only its own reads
/// (L13). Our own pid goes to the main queue: same-process AX runs inline in
/// AppKit, which is main-thread-only (L9).
final class SerialQueues: Sendable {
    private let queues = OSAllocatedUnfairLock<[pid_t: DispatchQueue]>(initialState: [:])

    func queue(for pid: pid_t) -> DispatchQueue {
        if pid == getpid() { return .main }
        return queues.withLock { table in
            if let queue = table[pid] { return queue }
            let queue = DispatchQueue(label: "im.opentab.app.ws.\(pid)", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)
            table[pid] = queue
            return queue
        }
    }

    func perform<T: Sendable>(on pid: pid_t, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let queue = queue(for: pid)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }
}
