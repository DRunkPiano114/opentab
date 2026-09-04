import ApplicationServices
import CoreGraphics
import Foundation
import OpenTabCore
import os

/// Reason a resolution failed. The cascade tries several stages in turn, so
/// its failures have to stay distinguishable in the log, otherwise a field
/// report cannot be traced back to the stage that gave up.
enum WindowResolutionFailure: Error, Sendable, Equatable {
    /// A brute-force scan of the app's AX windows did not contain the element.
    case elementNotFound
    /// Several CGWindowList rows share the frame: give up rather than guess.
    case frameAmbiguous
    /// No CGWindowList row matched the frame.
    case cgFallbackFailed
    case timedOut(stage: String)
    /// Out of stages: the element is there but nothing could name its window.
    case unresolved

    var name: String {
        switch self {
        case .elementNotFound: return "elementNotFound"
        case .frameAmbiguous: return "frameAmbiguous"
        case .cgFallbackFailed: return "cgFallbackFailed"
        case .timedOut(let stage): return "timedOut:\(stage)"
        case .unresolved: return "unresolved"
        }
    }
}

protocol WindowResolving: Sendable {
    /// `nil` when unresolved; the reason is logged, never a title.
    func resolve(_ snapshot: WindowSnapshot, deadline: ContinuousClock.Instant) async -> UInt32?
}

/// Upgrades a window keyed by AX element to its `CGWindowID`.
///
/// `_AXUIElementGetWindow` is a one-way bridge with no inverse, so a window
/// that missed it on enumeration has to be re-found and re-asked, then matched
/// against the window server by frame.
final class WindowResolver: WindowResolving, Sendable {
    typealias CGRow = (id: UInt32, bounds: CGRect)

    /// `AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *)`.
    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// One point per edge: AX and CGWindowList agree up to rounding, and a
    /// looser window starts catching the neighbour behind a stacked window.
    private static let frameTolerance: CGFloat = 1

    private let getWindow: GetWindowFunction?
    private let queues = OSAllocatedUnfairLock<[pid_t: DispatchQueue]>(initialState: [:])
    private let log = Log.make("resolve")

    /// `directBridge`: whether `_AXUIElementGetWindow` is usable — pass
    /// `AXWindowSource.isWindowIDBridgeAvailable`. When it is false only the
    /// frame fallback runs; retrying a bridge that does not exist is pointless.
    init(directBridge: Bool) {
        // Resolved through dlsym with a nil check, never linked directly: a
        // wrong signature on a private symbol segfaults instead of failing.
        getWindow = directBridge ? Self.loadGetWindow() : nil
    }

    func resolve(_ snapshot: WindowSnapshot, deadline: ContinuousClock.Instant) async -> UInt32? {
        switch snapshot.key {
        case .cg(let id):
            return id
        case .scripted:
            return nil
        case .ax(let pid, let elementID):
            // Same-process AX runs inline in AppKit and is main-thread
            // only, and our own windows are never switch targets.
            guard pid != getpid() else { return nil }
            // AX blocks the whole thread, so it stays off the cooperative
            // pool and off the main thread, on a queue this pid owns alone.
            let outcome: Outcome = await withCheckedContinuation { continuation in
                queue(for: pid).async {
                    continuation.resume(returning: self.cascade(pid: pid, elementID: elementID, deadline: deadline))
                }
            }
            switch outcome.result {
            case .success(let id):
                log.debug("""
                    resolved pid=\(pid, privacy: .public) element=\(elementID, privacy: .public) \
                    stage=\(outcome.stage, privacy: .public) wid=\(id, privacy: .public)
                    """)
                return id
            case .failure(let failure):
                log.notice("""
                    unresolved pid=\(pid, privacy: .public) element=\(elementID, privacy: .public) \
                    stage=\(outcome.stage, privacy: .public) reason=\(failure.name, privacy: .public)
                    """)
                return nil
            }
        }
    }

    /// Exactly one row within tolerance wins. Ambiguity is a give-up, not a
    /// guess: picking the wrong row switches to the wrong window.
    static func match(frame: CGRect, rows: [CGRow]) -> Result<UInt32, WindowResolutionFailure> {
        let hits = rows.filter { isSameFrame(frame, $0.bounds) }
        switch hits.count {
        case 1: return .success(hits[0].id)
        case 0: return .failure(.cgFallbackFailed)
        default: return .failure(.frameAmbiguous)
        }
    }

    // MARK: The cascade (runs on the pid's queue)

    private struct Outcome: Sendable {
        let stage: String
        let result: Result<UInt32, WindowResolutionFailure>
    }

    /// Every stage rechecks the deadline: one hung app answers an attribute
    /// read only after the process-wide messaging timeout (150ms), so the
    /// deadline can only be overrun by a single read.
    private func cascade(pid: pid_t, elementID: UInt64, deadline: ContinuousClock.Instant) -> Outcome {
        guard ContinuousClock.now < deadline else {
            return Outcome(stage: "scan", result: .failure(.timedOut(stage: "scan")))
        }
        var rawWindows: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                                  kAXWindowsAttribute as CFString, &rawWindows)
        guard error == .success, let windows = rawWindows as? [AXUIElement],
              let element = windows.first(where: { UInt64(CFHash($0)) == elementID })
        else { return Outcome(stage: "scan", result: .failure(.elementNotFound)) }

        if let getWindow {
            guard ContinuousClock.now < deadline else {
                return Outcome(stage: "bridge", result: .failure(.timedOut(stage: "bridge")))
            }
            var id: CGWindowID = 0
            if getWindow(element, &id) == .success, id != 0 {
                return Outcome(stage: "bridge", result: .success(id))
            }
        }

        guard ContinuousClock.now < deadline else {
            return Outcome(stage: "frame", result: .failure(.timedOut(stage: "frame")))
        }
        guard let frame = Self.frame(of: element) else {
            return Outcome(stage: "frame", result: .failure(.unresolved))
        }
        return Outcome(stage: "frame", result: Self.match(frame: frame, rows: Self.rows(ownedBy: pid)))
    }

    /// Position and size in one IPC. AX reports the top-left origin in the
    /// global display space, the same convention as `kCGWindowBounds`.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var out: CFArray?
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, attributes,
                                                     AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
              let slots = out as? [CFTypeRef], slots.count == 2,
              CFGetTypeID(slots[0]) == AXValueGetTypeID(), CFGetTypeID(slots[1]) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        // A slot whose read failed is an AXValue of type axError, and it
        // refuses .cgPoint / .cgSize rather than yielding a zeroed struct.
        guard AXValueGetValue(slots[0] as! AXValue, .cgPoint, &origin),
              AXValueGetValue(slots[1] as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// `kCGWindowName` is deliberately never read: it needs Screen Recording,
    /// and no window title may leave the process at all. Matching is by frame,
    /// so a title-ambiguity failure cannot arise here.
    private static func rows(ownedBy pid: pid_t) -> [CGRow] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { row in
            guard (row[kCGWindowOwnerPID as String] as? Int) == Int(pid),
                  (row[kCGWindowLayer as String] as? Int) == 0,
                  let id = row[kCGWindowNumber as String] as? UInt32,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return (id: id, bounds: rect)
        }
    }

    private static func isSameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= frameTolerance && abs(a.minY - b.minY) <= frameTolerance
            && abs(a.maxX - b.maxX) <= frameTolerance && abs(a.maxY - b.maxY) <= frameTolerance
    }

    private static func loadGetWindow() -> GetWindowFunction? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }

    private func queue(for pid: pid_t) -> DispatchQueue {
        queues.withLock { table in
            if let queue = table[pid] { return queue }
            let queue = DispatchQueue(label: "im.opentab.app.resolve.\(pid)", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)
            table[pid] = queue
            return queue
        }
    }
}
