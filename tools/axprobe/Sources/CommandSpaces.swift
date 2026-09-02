import ApplicationServices
import CoreGraphics
import Foundation

/// Tests the reported hazard that windows on other Spaces have no obtainable
/// `AXUIElement`, and that the AX <-> CGWindowID bridge is one-directional.
///
/// Method: enumerate every AX window of every app, resolve each one to a
/// CGWindowID with `_AXUIElementGetWindow`, and difference that against the
/// WindowServer's own list. Whatever the WindowServer knows about and AX cannot
/// reach is exactly the set OpenTab's reconciliation layer has to cover.
enum CommandSpaces {
    /// Candidate reverse-direction routines. Every one of these being absent is
    /// the evidence that the bridge cannot be inverted.
    private static let reverseSymbols = [
        "_AXUIElementGetWindow",
        "_AXUIElementCreateWithRemoteToken",
        "_AXUIElementRemoteTokenCreate",
        "AXUIElementCreateWithWindowID",
        "_AXUIElementCreateWithWindow",
        "AXUIElementCopyElementAtPosition",
    ]

    static func run(cli: CLI, output: Output) throws -> Int32 {
        let trusted = AXIsProcessTrusted()
        let getWindow = lookupAXUIElementGetWindow()
        let renderer = try cli.renderer()

        let allRows = CGWindowRow.list([.optionAll, .excludeDesktopElements])
        let onScreenRows = CGWindowRow.list([.optionOnScreenOnly, .excludeDesktopElements])
        let layer0 = allRows.filter { $0.layer == 0 }
        let onScreenIDs = Set(onScreenRows.filter { $0.layer == 0 }.map(\.windowID))
        let layer0ByID = Dictionary(layer0.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })

        var axWindows: [JSON] = []
        var perApp: [JSON] = []
        var reachableIDs: Set<CGWindowID> = []
        var unresolvedCount = 0

        for target in Targets.windowOwners() {
            let (windows, error) = AXRead.elements(target.element, kAXWindowsAttribute)
            guard error == .success || !windows.isEmpty else {
                if error != .attributeUnsupported && error != .noValue {
                    perApp.append(.object([
                        "target": target.json,
                        "axWindowsError": .string(axErrorName(error)),
                        "axWindowCount": .null,
                        "cgLayer0Count": .int(layer0.filter { $0.pid == target.pid }.count),
                    ]))
                }
                continue
            }

            var appReachable: Set<CGWindowID> = []
            for (index, window) in windows.enumerated() {
                let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                                  kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute]
                let values = AXRead.multiple(window, attributes)

                var windowID: CGWindowID = 0
                var idError: AXError = .failure
                if let getWindow { idError = getWindow(window.raw, &windowID) }
                let resolved = getWindow != nil && idError == .success
                if resolved {
                    reachableIDs.insert(windowID)
                    appReachable.insert(windowID)
                } else {
                    unresolvedCount += 1
                }

                axWindows.append(.object([
                    "pid": .int(Int(target.pid)),
                    "bundleIdentifier": .string(target.bundleIdentifier),
                    "index": .int(index),
                    "role": .string(values?[0] as? String),
                    "subrole": .string(values?[1] as? String),
                    "title": .string(values?[2] as? String),
                    "minimized": (values?[3] as? Bool).map(JSON.bool) ?? .null,
                    "position": renderer.render(values?[4] ?? nil),
                    "size": renderer.render(values?[5] ?? nil),
                    "cgWindowID": resolved ? .int(Int(windowID)) : .null,
                    "cgWindowIDError": resolved ? .null : .string(
                        getWindow == nil ? "_AXUIElementGetWindow unavailable" : axErrorName(idError)),
                    "inCGLayer0List": resolved ? .bool(layer0ByID[windowID] != nil) : .null,
                    "onScreenNow": resolved ? .bool(onScreenIDs.contains(windowID)) : .null,
                ]))
            }

            let appLayer0 = layer0.filter { $0.pid == target.pid }
            perApp.append(.object([
                "target": target.json,
                "axWindowsError": .string(axErrorName(error)),
                "axWindowCount": .int(windows.count),
                "axResolvedWindowIDs": .int(appReachable.count),
                "cgLayer0Count": .int(appLayer0.count),
                "cgOnScreenCount": .int(appLayer0.filter { onScreenIDs.contains($0.windowID) }.count),
                "cgLayer0NotReachableViaAX": .array(
                    appLayer0.filter { !appReachable.contains($0.windowID) }.map(\.json)),
            ]))
        }

        let layer0IDs = Set(layer0.map(\.windowID))
        let cgOnly = layer0IDs.subtracting(reachableIDs)
        let axOnly = reachableIDs.subtracting(layer0IDs)

        // A CG window the WindowServer lists but AX cannot reach is either an
        // artifact, minimized, hidden, or on another Space. Only the last case
        // is a reconciliation problem, so the raw difference has to be
        // classified before it means anything: `.optionAll` layer-0 heavily
        // over-reports, mostly with shadow and toolbar slivers.
        let cgOnlyDetail = cgOnly.compactMap { layer0ByID[$0] }.sorted { $0.windowID < $1.windowID }
        let classified = cgOnlyDetail.map { ($0, classify($0, onScreen: onScreenIDs)) }
        let plausible = classified
            .filter { $0.1 == "candidateOffSpaceOrMinimized" || $0.1 == "onScreenButUnreachable" }
            .map(\.0)
        let cgOnlyOffScreen = cgOnlyDetail.filter { !onScreenIDs.contains($0.windowID) }
        let cgOnlyOnScreen = cgOnlyDetail.filter { onScreenIDs.contains($0.windowID) }
        var classCounts: [String: Int] = [:]
        for entry in classified { classCounts[entry.1, default: 0] += 1 }

        let json = JSON.object([
            "command": .string("spaces"),
            "axIsProcessTrusted": .bool(trusted),
            "symbolAvailability": .object(Dictionary(uniqueKeysWithValues:
                reverseSymbols.map { ($0, JSON.bool(symbolExists($0))) })),
            "counts": .object([
                "cgLayer0Total": .int(layer0.count),
                "cgLayer0OnScreen": .int(onScreenIDs.count),
                "axWindowsEnumerated": .int(axWindows.count),
                "axResolvedToWindowID": .int(reachableIDs.count),
                "axWindowsWithoutWindowID": .int(unresolvedCount),
                "cgOnlyTotal": .int(cgOnly.count),
                "cgOnlyOffScreen": .int(cgOnlyOffScreen.count),
                "cgOnlyOnScreen": .int(cgOnlyOnScreen.count),
                "cgOnlyCandidateRealWindows": .int(plausible.count),
                "axOnlyTotal": .int(axOnly.count),
            ]),
            "cgOnlyClassification": .object(classCounts.mapValues(JSON.int)),
            "cgOnlyCandidateRealWindows": .array(plausible.map(\.json)),
            "axReachableWindowIDs": .array(reachableIDs.sorted().map { .int(Int($0)) }),
            "cgOnlyWindowIDs": .array(classified.map { row, kind in
                guard case .object(var fields) = row.json else { return row.json }
                fields["classification"] = .string(kind)
                return .object(fields)
            }),
            "axOnlyWindowIDs": .array(axOnly.sorted().map { .int(Int($0)) }),
            "axWindows": .array(axWindows),
            "perApplication": .array(perApp),
        ])

        var lines = ["axprobe spaces — AX reachability vs the WindowServer", ""]
        lines.append("  _AXUIElementGetWindow available : \(getWindow != nil)")
        for symbol in reverseSymbols where symbol != "_AXUIElementGetWindow" {
            lines.append("  \(symbol.padding(toLength: 32, withPad: " ", startingAt: 0)): \(symbolExists(symbol))")
        }
        lines.append("")
        lines.append("  CGWindowList layer-0, all Spaces : \(layer0.count)")
        lines.append("  CGWindowList layer-0, on screen  : \(onScreenIDs.count)")
        lines.append("  AX windows enumerated            : \(axWindows.count)")
        lines.append("  AX windows resolved to a wid     : \(reachableIDs.count)")
        lines.append("  AX windows with no wid           : \(unresolvedCount)")
        lines.append("")
        lines.append("  In WindowServer but NOT reachable via AX : \(cgOnly.count)")
        lines.append("    of which off screen (other Space / minimized) : \(cgOnlyOffScreen.count)")
        lines.append("    of which on screen right now                  : \(cgOnlyOnScreen.count)")
        for (kind, count) in classCounts.sorted(by: { $0.key < $1.key }) {
            lines.append("    classified \(kind.padding(toLength: 22, withPad: " ", startingAt: 0)): \(count)")
        }
        lines.append("  Reachable via AX but absent from CG layer-0     : \(axOnly.count)")
        lines.append("")
        lines.append("  Candidate real windows the WindowServer sees and AX cannot reach: \(plausible.count)")
        lines.append("  (size heuristic: rows under \(Int(artifactSizeThreshold))pt in either axis are treated as shadow/toolbar artifacts)")
        for row in plausible.prefix(25) {
            let onScreen = onScreenIDs.contains(row.windowID) ? "on-screen" : "off-screen"
            lines.append("    wid \(row.windowID)  \(row.ownerName ?? "?")  \(onScreen)  "
                + "\(Int(row.bounds.width))x\(Int(row.bounds.height))")
        }
        if plausible.count > 25 { lines.append("    … \(plausible.count - 25) more in the .json") }
        if !trusted {
            lines.append("")
            lines.append("NOT TRUSTED: no AX window could be enumerated, so every CG window shows as")
            lines.append("unreachable. This run proves nothing about Spaces. Run `make doctor`.")
        } else {
            lines.append("")
            lines.append("  For this to be meaningful, open windows on a second Space, on a third Space,")
            lines.append("  and a fullscreen window, then re-run. See the README for the exact procedure.")
        }

        try output.write("spaces", json: json, summary: lines.joined(separator: "\n"))
        return trusted ? 0 : 2
    }

    /// `.optionAll` layer-0 lists far more than real windows: drop shadows,
    /// toolbar strips and fully transparent helpers all appear, which is why the
    /// raw AX-vs-WindowServer difference is not by itself evidence of anything.
    ///
    /// This is an admitted size heuristic, not a classification the system
    /// provides. Every row keeps its label in the JSON so the cut can be
    /// re-judged without re-running the probe.
    private static let artifactSizeThreshold: CGFloat = 100

    private static func classify(_ row: CGWindowRow, onScreen: Set<CGWindowID>) -> String {
        if row.alpha == 0 { return "transparent" }
        if row.bounds.width < artifactSizeThreshold || row.bounds.height < artifactSizeThreshold {
            return "smallOrArtifact"
        }
        if onScreen.contains(row.windowID) { return "onScreenButUnreachable" }
        return "candidateOffSpaceOrMinimized"
    }

    private static func symbolExists(_ name: String) -> Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
    }
}
