import ApplicationServices
import CoreGraphics
import Foundation

/// CGS Space queries — the piece that makes `Entry.isOnActiveSpace` decidable.
///
/// Answers, without any AX call:
///   - which Space id each requested CGWindowID sits on (`CGSCopySpacesForWindows`, mask 0x7);
///   - which Space is currently active on each display (`CGSCopyManagedDisplaySpaces`);
/// so "is this window on the currently active Space of its display" is a set membership test.
///
/// Optionally cross-checks window *existence* against SkyLight enumeration
/// (`SLSCopyWindowsWithOptionsAndTags`, options 0x7) — strategy B — purely to
/// confirm the CGS answers against an independent source, not because OpenTab
/// needs SkyLight if strategy C works.
enum CommandSpaceMap {
    static func run(cli: CLI, output: Output) throws -> Int32 {
        guard let cid = PrivateSymbols.mainConnectionID?() else {
            try output.write("spacemap-error",
                             json: .object(["error": .string("CGSMainConnectionID unavailable")]),
                             summary: "CGSMainConnectionID missing — CGS Space queries unavailable.")
            return 2
        }

        let wids = (cli.string("wid") ?? "")
            .split(separator: ",").compactMap { CGWindowID($0.trimmingCharacters(in: .whitespaces)) }

        // Active Space per display.
        var displays: [JSON] = []
        var activeSpaceIDs: Set<UInt64> = []
        var lines = ["axprobe spacemap — CGS Space attribution (connection \(cid))", ""]
        if let copyDisplays = PrivateSymbols.copyManagedDisplaySpaces,
           let raw = copyDisplays(cid)?.takeRetainedValue() as? [[String: Any]] {
            lines.append("  managed displays: \(raw.count)")
            for display in raw {
                let identifier = display["Display Identifier"] as? String
                let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? UInt64
                    ?? (display["Current Space"] as? [String: Any])?["id64"] as? UInt64
                let spaceList = (display["Spaces"] as? [[String: Any]]) ?? []
                let spaceIDs = spaceList.compactMap { ($0["ManagedSpaceID"] as? UInt64) ?? ($0["id64"] as? UInt64) }
                if let current { activeSpaceIDs.insert(current) }
                displays.append(.object([
                    "displayIdentifier": .string(identifier),
                    "currentSpaceID": current.map { .int(Int($0)) } ?? .null,
                    "spaceCount": .int(spaceList.count),
                    "spaceIDs": .array(spaceIDs.map { .int(Int($0)) }),
                ]))
                lines.append("    display \(identifier ?? "?"): current space \(current.map(String.init) ?? "?"), "
                    + "\(spaceList.count) spaces \(spaceIDs.map(String.init))")
            }
        } else {
            lines.append("  CGSCopyManagedDisplaySpaces unavailable or unreadable")
        }
        if let getActive = PrivateSymbols.getActiveSpace {
            let active = getActive(cid)
            activeSpaceIDs.insert(active)
            lines.append("  SLSGetActiveSpace: \(active)")
        }
        lines.append("")

        // Space attribution per requested window.
        var perWindow: [JSON] = []
        if let copySpaces = PrivateSymbols.copySpacesForWindows {
            lines.append("  window -> space (mask 0x7):")
            for wid in wids {
                let arr = [NSNumber(value: wid)] as CFArray
                let spaces = (copySpaces(cid, 0x7, arr)?.takeRetainedValue() as? [NSNumber])?.map { $0.uint64Value } ?? []
                let onActive = spaces.contains { activeSpaceIDs.contains($0) }
                let onCurrent = PrivateSymbols.windowIsOnCurrentSpace?(cid, wid)
                perWindow.append(.object([
                    "cgWindowID": .int(Int(wid)),
                    "spaceIDs": .array(spaces.map { .int(Int($0)) }),
                    "onActiveSpace": spaces.isEmpty ? .null : .bool(onActive),
                    "slsIsOnCurrentSpace": onCurrent.map(JSON.bool) ?? .null,
                ]))
                lines.append("    wid \(wid): spaces \(spaces.map(String.init))  "
                    + "onActiveSpace=\(spaces.isEmpty ? "?" : String(onActive))  "
                    + "SLSIsOnCurrentSpace=\(onCurrent.map(String.init) ?? "?")")
            }
        } else {
            lines.append("  CGSCopySpacesForWindows unavailable")
        }

        let json = JSON.object([
            "command": .string("spacemap"),
            "connectionID": .int(Int(cid)),
            "symbolAvailability": PrivateSymbols.availability([
                "CGSMainConnectionID", "CGSCopySpacesForWindows", "CGSCopyManagedDisplaySpaces",
                "SLSGetActiveSpace", "SLSWindowIsOnCurrentSpace", "SLSCopyWindowsWithOptionsAndTags",
            ]),
            "activeSpaceIDs": .array(activeSpaceIDs.sorted().map { .int(Int($0)) }),
            "displays": .array(displays),
            "windows": .array(perWindow),
        ])
        try output.write("spacemap", json: json, summary: lines.joined(separator: "\n"))
        return 0
    }
}
