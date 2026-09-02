import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct Target {
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String
    let bundleURL: URL?
    let activationPolicy: String

    var element: AXElement { .application(pid: pid) }

    var label: String { bundleIdentifier ?? name }

    var json: JSON {
        .object([
            "pid": .int(Int(pid)),
            "bundleIdentifier": .string(bundleIdentifier),
            "name": .string(name),
            "bundlePath": .string(bundleURL?.path),
            "activationPolicy": .string(activationPolicy),
        ])
    }
}

enum Targets {
    /// Same-process AX is not IPC — it dispatches inline into AppKit, which is
    /// main-thread-only and will crash a background caller. Never probe self.
    static func running() -> [Target] {
        let ownPID = getpid()
        return NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != ownPID && !$0.isTerminated }
            .map { application in
                Target(pid: application.processIdentifier,
                       bundleIdentifier: application.bundleIdentifier,
                       name: application.localizedName ?? "(unnamed)",
                       bundleURL: application.bundleURL,
                       activationPolicy: describe(application.activationPolicy))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Candidates for window enumeration: regular and accessory apps only.
    static func windowOwners() -> [Target] {
        running().filter { $0.activationPolicy != "prohibited" }
    }

    /// Exact bundle id wins, then exact name. The substring fallback is
    /// convenient interactively but dangerous in batch: "com.apple.Safari" is a
    /// substring of "com.apple.SafariPlatformSupport.Helper", so a run intended
    /// for Safari silently probes a helper process instead.
    static func resolve(_ query: String, exactOnly: Bool = false) -> [Target] {
        let all = running()
        if let exact = all.filter({ $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame })
            .nilIfEmpty { return exact }
        if let byName = all.filter({ $0.name.caseInsensitiveCompare(query) == .orderedSame })
            .nilIfEmpty { return byName }
        guard !exactOnly else { return [] }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    static func resolve(pid: pid_t) -> Target? {
        running().first { $0.pid == pid }
    }

    private static func describe(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }
}

/// One row from `CGWindowListCopyWindowInfo`. Never needs any permission,
/// though `kCGWindowName` is withheld without Screen Recording.
struct CGWindowRow {
    let windowID: CGWindowID
    let pid: pid_t
    let ownerName: String?
    let name: String?
    let layer: Int
    let bounds: CGRect
    let alpha: Double
    let isOnscreen: Bool

    var json: JSON {
        .object([
            "windowID": .int(Int(windowID)),
            "pid": .int(Int(pid)),
            "ownerName": .string(ownerName),
            "name": .string(name),
            "layer": .int(layer),
            "bounds": .object(["x": .number(bounds.origin.x), "y": .number(bounds.origin.y),
                               "w": .number(bounds.size.width), "h": .number(bounds.size.height)]),
            "alpha": .number(alpha),
            "isOnscreen": .bool(isOnscreen),
        ])
    }

    static func list(_ options: CGWindowListOption) -> [CGWindowRow] {
        let raw = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
        return raw.compactMap { entry in
            guard let windowID = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int else { return nil }
            var bounds = CGRect.zero
            if let dict = entry[kCGWindowBounds as String] {
                bounds = CGRect(dictionaryRepresentation: dict as! CFDictionary) ?? .zero
            }
            return CGWindowRow(
                windowID: CGWindowID(windowID),
                pid: pid_t(pid),
                ownerName: entry[kCGWindowOwnerName as String] as? String,
                name: entry[kCGWindowName as String] as? String,
                layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                bounds: bounds,
                alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                isOnscreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }
}

extension Array {
    fileprivate var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
