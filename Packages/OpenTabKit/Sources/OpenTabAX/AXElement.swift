import ApplicationServices
import Foundation

/// Hashable, Sendable handle for an accessibility element.
///
/// `AXUIElement` is an immutable opaque token addressing a remote element and
/// CF retain/release is thread-safe, so the value itself may cross isolation
/// domains. What must be serialised is messaging the element, and every
/// message goes through the owning pid's queue (`PIDQueues`).
struct AXElement: @unchecked Sendable, Hashable {
    let raw: AXUIElement

    init(_ raw: AXUIElement) { self.raw = raw }

    static func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    static func == (lhs: AXElement, rhs: AXElement) -> Bool { CFEqual(lhs.raw, rhs.raw) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }

    /// Stable across independent `kAXWindows` fetches, which is what makes it
    /// usable as the fallback window identity when `_AXUIElementGetWindow`
    /// is unavailable.
    var stableID: UInt64 { UInt64(CFHash(raw)) }
}

enum AXRead {
    static func value(_ element: AXElement, _ attribute: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element.raw, attribute as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    /// One IPC round trip for the whole batch. Slots are positional; a slot
    /// whose read failed is `nil`.
    static func multiple(_ element: AXElement, _ attributes: [String]) -> (values: [CFTypeRef?]?, error: AXError) {
        var out: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element.raw, attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &out)
        guard error == .success, let values = out as? [CFTypeRef], values.count == attributes.count else {
            return (nil, error == .success ? .failure : error)
        }
        return (values.map(unwrap), .success)
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

    static func element(_ value: CFTypeRef?) -> AXElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }
}

func axErrorName(_ error: AXError) -> String {
    switch error {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "unknown(\(error.rawValue))"
    }
}
