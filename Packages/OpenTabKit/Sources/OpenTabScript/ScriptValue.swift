import Foundation

/// A Sendable snapshot of an AppleScript result.
///
/// `NSAppleEventDescriptor` is a reference type that must not leave the worker
/// thread, so results are flattened here before they cross back. Scalars are
/// coerced to their text form: an AppleScript integer arrives as `"36879"` and
/// a boolean as `"true"`, which is all the tab scripts need.
public enum ScriptValue: Sendable, Hashable {
    case list([ScriptValue])
    case text(String)
    case empty
}

public extension ScriptValue {
    var items: [ScriptValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    var string: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var integer: Int? {
        guard let string else { return nil }
        return Int(string)
    }
}

extension ScriptValue {
    init(descriptor: NSAppleEventDescriptor) {
        if descriptor.descriptorType == typeAEList {
            let count = descriptor.numberOfItems
            guard count > 0 else { self = .list([]); return }
            self = .list((1...count).map { index in
                guard let item = descriptor.atIndex(index) else { return .empty }
                return ScriptValue(descriptor: item)
            })
            return
        }
        if descriptor.descriptorType == typeNull { self = .empty; return }
        if let string = descriptor.stringValue { self = .text(string); return }
        self = .empty
    }
}
