import ApplicationServices
import Foundation

/// Adapts the accessibility hierarchy to `TreeSource`.
///
/// Every read goes through one batched `AXUIElementCopyMultipleAttributeValues`
/// plus the three name-list calls, so a node costs four round trips regardless
/// of how many attributes it advertises.
final class AXTreeSource: TreeSource {
    typealias Node = AXElement

    /// Also dump the value of every attribute the element advertises, not just
    /// the standard set. Expensive, but it is how undocumented attributes such
    /// as `AXTabs` get discovered.
    var dumpAllAttributeValues = false
    /// Menu bars are large, uniform, and irrelevant to window/tab discovery.
    var includeMenuBar = false

    private let renderer: AXValueRenderer
    private let getWindow: AXGetWindowFunction?
    private var roleCache: [AXElement: String] = [:]

    /// Attributes whose values are element references or full subtrees. Dumping
    /// them adds no information the tree structure does not already carry, and
    /// `AXChildren` in particular would duplicate the entire walk.
    private static let bulkAttributes: Set<String> = [
        kAXChildrenAttribute, kAXParentAttribute, kAXWindowAttribute,
        kAXTopLevelUIElementAttribute, kAXVisibleChildrenAttribute,
        kAXSelectedChildrenAttribute,
        "AXChildrenInNavigationOrder", "AXFocusableAncestor",
    ]

    private static let batched: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute,
        kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute,
        kAXHelpAttribute, kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute,
    ]

    init(renderer: AXValueRenderer, getWindow: AXGetWindowFunction?) {
        self.renderer = renderer
        self.getWindow = getWindow
    }

    func role(of node: AXElement) -> String? {
        if let cached = roleCache[node] { return cached }
        guard let role = AXRead.string(node, kAXRoleAttribute) else { return nil }
        roleCache[node] = role
        return role
    }

    func describe(_ node: AXElement, depth: Int, path: [Int]) -> [String: JSON] {
        var object: [String: JSON] = [:]

        if let values = AXRead.multiple(node, Self.batched) {
            for (index, name) in Self.batched.enumerated() where values[index] != nil {
                object[name] = renderer.render(values[index])
            }
            if let role = values[0] as? String { roleCache[node] = role }
        } else {
            // The batch call itself failed: fall back so a busy app still yields
            // a role rather than an empty node.
            let (value, error) = AXRead.value(node, kAXRoleAttribute)
            object[kAXRoleAttribute] = renderer.render(value)
            object["readError"] = .string(axErrorName(error))
        }

        let attributes = AXRead.attributeNames(node)
        object["attributeNames"] = .strings(attributes.names.sorted())
        if attributes.error != .success {
            object["attributeNamesError"] = .string(axErrorName(attributes.error))
        }

        let actions = AXRead.actionNames(node)
        if !actions.names.isEmpty { object["actionNames"] = .strings(actions.names.sorted()) }

        let parameterized = AXRead.parameterizedAttributeNames(node)
        if !parameterized.names.isEmpty {
            object["parameterizedAttributeNames"] = .strings(parameterized.names.sorted())
        }

        if dumpAllAttributeValues {
            let extra = attributes.names.filter {
                !Self.batched.contains($0) && !Self.bulkAttributes.contains($0)
            }.sorted()
            if !extra.isEmpty, let values = AXRead.multiple(node, extra) {
                var other: [String: JSON] = [:]
                for (index, name) in extra.enumerated() where values[index] != nil {
                    other[name] = renderer.render(values[index])
                }
                if !other.isEmpty { object["otherAttributes"] = .object(other) }
            }
        }

        if !includeMenuBar, role(of: node) == kAXMenuBarRole {
            object["skippedChildren"] = .string("menuBar")
        }

        if role(of: node) == kAXWindowRole, let getWindow {
            var windowID: CGWindowID = 0
            let error = getWindow(node.raw, &windowID)
            object["cgWindowID"] = error == .success ? .int(Int(windowID)) : .null
            if error != .success { object["cgWindowIDError"] = .string(axErrorName(error)) }
        }

        return object
    }

    func childCount(of node: AXElement) -> Int {
        AXRead.count(node, kAXChildrenAttribute).count
    }

    func children(of node: AXElement, limit: Int) -> [AXElement] {
        if !includeMenuBar, role(of: node) == kAXMenuBarRole { return [] }
        return AXRead.children(node, limit: limit)
    }
}
