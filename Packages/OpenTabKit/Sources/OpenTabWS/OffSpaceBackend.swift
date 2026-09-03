import ApplicationServices
import CoreGraphics
import Foundation
import OpenTabCore

/// What one attribute read of a candidate element said.
enum WindowRead: Sendable, Equatable {
    case window(subrole: String, title: String, isMinimized: Bool)
    /// Reached, but not a window worth listing (role or subrole). Permanent
    /// for that element; it is not scanned for again.
    case notListable(String)
    /// The app did not answer or the element is gone. Transient.
    case unreadable
}

/// Every call the off-space source makes that crosses a process boundary,
/// bundled so the merge logic can be driven by a fake in unit tests. The
/// live implementation is the only one outside the test target.
struct OffSpaceBackend: Sendable {
    /// `nil` when the WindowServer could not be read this round.
    var rows: @Sendable (pid_t) -> [WindowRow]?
    /// `nil` when the CGS Space symbols are unavailable or the topology
    /// came back without a current Space for any display.
    var activeSpaces: @Sendable () -> Set<UInt64>?
    var spacesOfWindow: @Sendable (CGWindowID) -> [UInt64]
    /// The 12-byte token prefix for a pid, from a live window when one is
    /// reachable and synthesized otherwise.
    var prefix: @Sendable (pid_t) -> [UInt8]
    var makeElement: @Sendable ([UInt8], UInt64) -> RemoteElement?
    var probe: @Sendable ([UInt8]) -> ElementScanner.Probe
    /// Whether a previously reached element still belongs to `wid`.
    var verify: @Sendable (RemoteElement, CGWindowID) -> Bool
    var read: @Sendable (RemoteElement) -> WindowRead
    var focusedWindowID: @Sendable (pid_t) -> CGWindowID?

    /// Positional. Slot 3 feeds only the L11 title fallback.
    private static let windowAttributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                                           kAXDescriptionAttribute, kAXMinimizedAttribute]

    static func live(table: WindowServerTable, spaceMap: SpaceMap?) -> OffSpaceBackend? {
        guard let create = WSPrivateSymbols.createWithRemoteToken,
              let getWindow = WSPrivateSymbols.getWindow else { return nil }
        let tokenCreate = WSPrivateSymbols.remoteTokenCreate

        return OffSpaceBackend(
            rows: { table.rows(ownedBy: $0) },
            activeSpaces: {
                guard let active = spaceMap?.activeSpaces(), !active.isEmpty else { return nil }
                return active
            },
            spacesOfWindow: { spaceMap?.spaces(of: $0) ?? [] },
            prefix: { pid in
                if let tokenCreate,
                   let windows = AXReader.value(.application(pid: pid), kAXWindowsAttribute) as? [AXUIElement],
                   let first = windows.first,
                   let data = tokenCreate(first)?.takeRetainedValue() as Data?,
                   let token = RemoteToken(bytes: [UInt8](data)), token.pid == pid {
                    return token.prefix
                }
                return RemoteToken.synthesizedPrefix(pid: pid)
            },
            makeElement: { prefix, elementID in
                let token = RemoteToken(prefix: prefix, elementID: elementID)
                return create(Data(token.bytes) as CFData).map { RemoteElement($0.takeRetainedValue()) }
            },
            probe: { prefix in
                // The window-id probe keeps its element so the role gate that
                // follows a match does not synthesize it a second time.
                final class Last { var id: UInt64 = .max; var element: AXUIElement? }
                let last = Last()
                func element(_ id: UInt64) -> AXUIElement? {
                    if last.id == id { return last.element }
                    let token = RemoteToken(prefix: prefix, elementID: id)
                    last.id = id
                    last.element = create(Data(token.bytes) as CFData)?.takeRetainedValue()
                    return last.element
                }
                return ElementScanner.Probe(
                    windowID: { id in
                        guard let element = element(id) else { return nil }
                        var wid: CGWindowID = 0
                        return getWindow(element, &wid) == .success && wid != 0 ? wid : nil
                    },
                    isWindow: { id in
                        guard let element = element(id) else { return false }
                        return (AXReader.value(RemoteElement(element), kAXRoleAttribute) as? String) == kAXWindowRole
                    })
            },
            verify: { element, wid in AXReader.windowID(of: element) == wid },
            read: { element in
                guard let slots = AXReader.multiple(element, windowAttributes) else { return .unreadable }
                guard let role = slots[0] as? String else { return .unreadable }
                guard role == kAXWindowRole else { return .notListable("role:\(role)") }
                let subrole = (slots[1] as? String) ?? ""
                guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else {
                    return .notListable("subrole:\(subrole.isEmpty ? "<none>" : subrole)")
                }
                let title = (slots[2] as? String) ?? ""
                let description = (slots[3] as? String) ?? ""
                return .window(subrole: subrole, title: title.isEmpty ? description : title,
                               isMinimized: (slots[4] as? Bool) ?? false)
            },
            focusedWindowID: { AXReader.focusedWindowID(pid: $0) })
    }
}
