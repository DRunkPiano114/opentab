import ApplicationServices
import CoreGraphics
import Foundation

/// Hashable handle for an accessibility element.
///
/// `CFEqual`/`CFHash` are stable across independent fetches, which is what makes
/// ancestor-based cycle detection in the tree walker possible.
struct AXElement: Hashable {
    let raw: AXUIElement

    init(_ raw: AXUIElement) { self.raw = raw }

    static func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    static func == (lhs: AXElement, rhs: AXElement) -> Bool { CFEqual(lhs.raw, rhs.raw) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }

    /// Still answers correctly for an element whose target window is gone.
    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(raw, &pid) == .success ? pid : nil
    }
}

func axErrorName(_ error: AXError) -> String {
    switch error {
    case .success: return "success"
    case .failure: return "failure(-25200)"
    case .illegalArgument: return "illegalArgument(-25201)"
    case .invalidUIElement: return "invalidUIElement(-25202)"
    case .invalidUIElementObserver: return "invalidUIElementObserver(-25203)"
    case .cannotComplete: return "cannotComplete(-25204)"
    case .attributeUnsupported: return "attributeUnsupported(-25205)"
    case .actionUnsupported: return "actionUnsupported(-25206)"
    case .notificationUnsupported: return "notificationUnsupported(-25207)"
    case .notImplemented: return "notImplemented(-25208)"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered(-25209)"
    case .notificationNotRegistered: return "notificationNotRegistered(-25210)"
    case .apiDisabled: return "apiDisabled(-25211)"
    case .noValue: return "noValue(-25212)"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported(-25213)"
    case .notEnoughPrecision: return "notEnoughPrecision(-25214)"
    @unknown default: return "unknown(\(error.rawValue))"
    }
}

/// Read-only accessors. This tool never calls `AXUIElementPerformAction` or
/// `AXUIElementSetAttributeValue`: probing must not mutate the apps it observes.
enum AXRead {
    /// Applies to every element in this process, including ones created earlier.
    /// Setting the timeout on an application element does NOT propagate to its
    /// windows, so the system-wide element is the only useful target.
    static func setGlobalTimeout(_ seconds: Float) -> AXError {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    static func value(_ element: AXElement, _ attribute: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element.raw, attribute as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    static func attributeNames(_ element: AXElement) -> (names: [String], error: AXError) {
        var names: CFArray?
        let error = AXUIElementCopyAttributeNames(element.raw, &names)
        return ((names as? [String]) ?? [], error)
    }

    static func actionNames(_ element: AXElement) -> (names: [String], error: AXError) {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element.raw, &names)
        return ((names as? [String]) ?? [], error)
    }

    static func parameterizedAttributeNames(_ element: AXElement) -> (names: [String], error: AXError) {
        var names: CFArray?
        let error = AXUIElementCopyParameterizedAttributeNames(element.raw, &names)
        return ((names as? [String]) ?? [], error)
    }

    static func count(_ element: AXElement, _ attribute: String) -> (count: Int, error: AXError) {
        var count: CFIndex = 0
        let error = AXUIElementGetAttributeValueCount(element.raw, attribute as CFString, &count)
        return (error == .success ? Int(count) : 0, error)
    }

    /// One IPC round trip for the whole batch — roughly 6x cheaper per attribute
    /// than N single reads. Returns positional slots; a failed slot is `nil`.
    static func multiple(_ element: AXElement, _ attributes: [String]) -> [CFTypeRef?]? {
        var out: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element.raw, attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &out)
        guard error == .success, let values = out as? [CFTypeRef], values.count == attributes.count else {
            return nil
        }
        return values.map(unwrap)
    }

    /// A failure slot in a multi-value result is a `kAXValueAXErrorType` AXValue,
    /// and it casts happily to `AXUIElement` yielding a zeroed object. Unwrap first.
    static func unwrap(_ value: CFTypeRef) -> CFTypeRef? {
        if CFGetTypeID(value) == CFNullGetTypeID() { return nil }
        if CFGetTypeID(value) == AXValueGetTypeID(),
           AXValueGetType(value as! AXValue) == .axError { return nil }
        return value
    }

    /// Ranged read so a node with 50,000 children costs one bounded round trip.
    static func children(_ element: AXElement, limit: Int) -> [AXElement] {
        guard limit > 0 else { return [] }
        var out: CFArray?
        let error = AXUIElementCopyAttributeValues(
            element.raw, kAXChildrenAttribute as CFString, 0, CFIndex(limit), &out)
        guard error == .success, let raw = out as? [AXUIElement] else { return [] }
        return raw.map(AXElement.init)
    }

    static func elements(_ element: AXElement, _ attribute: String) -> (elements: [AXElement], error: AXError) {
        let (value, error) = self.value(element, attribute)
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID(), let raw = value as? [AXUIElement] else {
            return ([], error)
        }
        return (raw.map(AXElement.init), error)
    }

    static func string(_ element: AXElement, _ attribute: String) -> String? {
        value(element, attribute).value as? String
    }
}

/// `_AXUIElementGetWindow` is the only element -> CGWindowID bridge that exists.
/// There is no reverse routine, which is why window reconciliation has to be
/// driven from the AX side.
typealias AXGetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

func lookupAXUIElementGetWindow() -> AXGetWindowFunction? {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = dlsym(rtldDefault, "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(symbol, to: AXGetWindowFunction.self)
}

/// Renders an arbitrary attribute value as JSON.
///
/// String values are truncated: an `AXValue` on a text view can be an entire
/// document or a whole terminal scrollback, and these dumps get committed.
struct AXValueRenderer {
    var maxStringLength: Int = 200
    var maxArrayCount: Int = 64
    var maxDepth: Int = 3

    func render(_ value: CFTypeRef?, depth: Int = 0) -> JSON {
        guard let value else { return .null }
        if depth > maxDepth { return .string("<nested>") }
        let typeID = CFGetTypeID(value)

        switch typeID {
        case CFNullGetTypeID():
            return .null
        case CFStringGetTypeID():
            return renderString(value as! String)
        case CFBooleanGetTypeID():
            return .bool(CFBooleanGetValue((value as! CFBoolean)))
        case CFNumberGetTypeID():
            let number = value as! NSNumber
            if CFNumberIsFloatType(number as CFNumber) { return .number(number.doubleValue) }
            return .int(number.intValue)
        case CFURLGetTypeID():
            return renderString((value as! URL).absoluteString)
        case CFAttributedStringGetTypeID():
            return renderString((value as! NSAttributedString).string)
        case AXUIElementGetTypeID():
            return .string("<AXUIElement>")
        case AXValueGetTypeID():
            return renderAXValue(value as! AXValue)
        case CFArrayGetTypeID():
            let array = value as! [CFTypeRef]
            let head = array.prefix(maxArrayCount).map { render($0, depth: depth + 1) }
            if array.count > maxArrayCount {
                return .array(head + [.string("<\(array.count - maxArrayCount) more>")])
            }
            return .array(head)
        case CFDictionaryGetTypeID():
            guard let dict = value as? [String: CFTypeRef] else { return .string("<CFDictionary>") }
            return .object(dict.mapValues { render($0, depth: depth + 1) })
        default:
            return .string("<\(CFCopyTypeIDDescription(typeID) as String? ?? "unknown")>")
        }
    }

    private func renderString(_ string: String) -> JSON {
        guard string.count > maxStringLength else { return .string(string) }
        return .string(String(string.prefix(maxStringLength)) + "…<truncated \(string.count) chars>")
    }

    private func renderAXValue(_ value: AXValue) -> JSON {
        switch AXValueGetType(value) {
        case .cgPoint:
            var point = CGPoint.zero
            guard AXValueGetValue(value, .cgPoint, &point) else { return .string("<CGPoint?>") }
            return .object(["x": .number(point.x), "y": .number(point.y)])
        case .cgSize:
            var size = CGSize.zero
            guard AXValueGetValue(value, .cgSize, &size) else { return .string("<CGSize?>") }
            return .object(["w": .number(size.width), "h": .number(size.height)])
        case .cgRect:
            var rect = CGRect.zero
            guard AXValueGetValue(value, .cgRect, &rect) else { return .string("<CGRect?>") }
            return .object(["x": .number(rect.origin.x), "y": .number(rect.origin.y),
                            "w": .number(rect.size.width), "h": .number(rect.size.height)])
        case .cfRange:
            var range = CFRange()
            guard AXValueGetValue(value, .cfRange, &range) else { return .string("<CFRange?>") }
            return .object(["location": .int(range.location), "length": .int(range.length)])
        case .axError:
            var error = AXError.success
            guard AXValueGetValue(value, .axError, &error) else { return .string("<AXError?>") }
            return .string("AXError(\(axErrorName(error)))")
        case .illegal:
            return .string("<illegal AXValue>")
        @unknown default:
            return .string("<unknown AXValue>")
        }
    }
}

/// `AXValueGetValue` leaves its out-parameter untouched on failure, so a failed
/// size read is otherwise indistinguishable from a real 0x0.
func axPoint(_ value: CFTypeRef?) -> CGPoint? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
}

func axSize(_ value: CFTypeRef?) -> CGSize? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
}
