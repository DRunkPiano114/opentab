import ApplicationServices
import CoreGraphics
import Foundation

/// Strategy C — the remote-token path the original TabTab uses to reach windows
/// the plain AX enumeration cannot see (other Space, fullscreen).
///
/// Token layout, read off the arm64 disassembly of `_AXUIElementRemoteTokenCreate`
/// / `_AXUIElementCreateWithRemoteToken` on macOS 26.6.2 and confirmed by dumping
/// live windows here:
///
///   offset 0x00  4B  pid                      (element field +0x10)
///   offset 0x04  4B  0                         (element field +0x14)
///   offset 0x08  4B  0x636f636f "coco" magic   (element field +0x18)
///   offset 0x0c  8B  AXUIElementID             (element's extra CFData, +0x20)
///
/// `create` reads only the first 12 bytes for pid+magic and passes bytes 12+ as
/// the element's private id, so the first 12 bytes are a per-process constant and
/// the only per-window part is the 8-byte id. To reach a window AX will not hand
/// over, hold the constant prefix fixed and sweep the id until `_AXUIElementGetWindow`
/// on the synthesized element returns the target CGWindowID with role AXWindow.
///
/// One pid per process invocation, results flushed per window, so a segfault from
/// a bad token costs one data point rather than the whole run.
enum CommandToken {
    private static let cocoMagic: UInt32 = 0x636f_636f

    static func run(cli: CLI, output: Output) throws -> Int32 {
        guard AXIsProcessTrusted() else {
            try output.write("token-error", json: .object(["error": .string("not trusted")]),
                             summary: "NOT TRUSTED — run `make doctor`.")
            return 2
        }
        guard let create = PrivateSymbols.createWithRemoteToken,
              let tokenCreate = PrivateSymbols.remoteTokenCreate,
              let getWindow = PrivateSymbols.getWindow else {
            try output.write("token-error",
                             json: .object(["error": .string("remote-token symbols unavailable")]),
                             summary: "Remote-token or getWindow symbol missing — strategy C unavailable.")
            return 2
        }

        guard let pidString = cli.string("pid"), let pid = pid_t(pidString) else {
            throw CLIError("token requires --pid <pid>")
        }
        let targets = (cli.string("wid") ?? "")
            .split(separator: ",").compactMap { CGWindowID($0.trimmingCharacters(in: .whitespaces)) }
        let budget = try cli.double("budget", default: 8)
        let maxID = try cli.int("max-id", default: 0x8000)
        let renderer = try cli.renderer()

        let app = AXElement.application(pid: pid)
        let (axWindows, axError) = AXRead.elements(app, kAXWindowsAttribute)

        // 1. Dump the token of every reachable window: this is the empirical
        //    proof of the layout and the source of the constant prefix.
        var reachable: [ReachableWindow] = []
        var reachableJSON: [JSON] = []
        for window in axWindows {
            var wid: CGWindowID = 0
            let widErr = getWindow(window.raw, &wid)
            guard widErr == .success, wid != 0 else { continue }
            guard let tokenData = tokenCreate(window.raw)?.takeRetainedValue() as Data? else { continue }
            let bytes = [UInt8](tokenData)
            let elementID = bytes.count >= 20 ? bytes[12..<20].withUnsafeBytes { $0.load(as: UInt64.self) } : nil
            let role = AXRead.string(window, kAXRoleAttribute)
            let subrole = AXRead.string(window, kAXSubroleAttribute)
            reachable.append(ReachableWindow(wid: wid, elementID: elementID, prefix: Array(bytes.prefix(12))))
            reachableJSON.append(.object([
                "cgWindowID": .int(Int(wid)),
                "role": .string(role),
                "subrole": .string(subrole),
                "titleLength": .int((AXRead.string(window, kAXTitleAttribute) ?? "").count),
                "tokenLength": .int(bytes.count),
                "tokenHex": .string(hex(bytes)),
                "elementID": elementID.map { .int(Int($0)) } ?? .null,
            ]))
        }

        // 2. Constant prefix: prefer a live window's; else synthesize [pid][0]["coco"].
        //    Safari fullscreen reports zero AX windows, so it has no live prefix and
        //    must fall back to the canonical constant confirmed on the other apps.
        let synthesizedPrefix = canonicalPrefix(pid: pid)
        let prefix = reachable.first?.prefix ?? synthesizedPrefix
        let prefixSource = reachable.first != nil ? "liveWindow" : "synthesized"

        // 3. Sweep for each requested target the AX enumeration could not reach.
        var findings: [JSON] = []
        var lines = ["axprobe token — strategy C (remote token) for pid \(pid)", ""]
        lines.append("  AX windows enumerated       : \(axWindows.count) (\(axErrorName(axError)))")
        lines.append("  reachable-with-wid tokens   : \(reachable.count)")
        for r in reachable {
            lines.append("    wid \(r.wid)  elementID \(r.elementID.map(String.init) ?? "?")  prefix \(hex(r.prefix))")
        }
        lines.append("  constant prefix (\(prefixSource)) : \(hex(prefix))")
        lines.append("")

        let reachableIDs = Set(reachable.map(\.wid))
        for target in targets {
            let alreadyReachable = reachableIDs.contains(target)
            let start = Date()
            let result = sweep(target: target, prefix: prefix, maxID: maxID, budget: budget,
                               create: create, getWindow: getWindow)
            let elapsed = Date().timeIntervalSince(start)

            switch result {
            case let .found(elementID, element):
                let role = AXRead.string(element, kAXRoleAttribute)
                let subrole = AXRead.string(element, kAXSubroleAttribute)
                let rawTitle = AXRead.string(element, kAXTitleAttribute) ?? ""
                let description = AXRead.string(element, kAXDescriptionAttribute) ?? ""
                let title = rawTitle.isEmpty ? description : rawTitle  // L11
                let minimized = (AXRead.value(element, kAXMinimizedAttribute).value as? Bool)
                findings.append(.object([
                    "cgWindowID": .int(Int(target)),
                    "wasReachableViaPlainAX": .bool(alreadyReachable),
                    "outcome": .string("found"),
                    "elementID": .int(Int(elementID)),
                    "role": .string(role),
                    "subrole": .string(subrole),
                    "minimized": minimized.map(JSON.bool) ?? .null,
                    "title": .string(title),
                    "position": renderer.render(AXRead.value(element, kAXPositionAttribute).value),
                    "size": renderer.render(AXRead.value(element, kAXSizeAttribute).value),
                    "sweepSeconds": .number(elapsed),
                ]))
                lines.append("  wid \(target): FOUND at elementID \(elementID) in \(String(format: "%.2f", elapsed))s"
                    + " — role=\(role ?? "?") subrole=\(subrole ?? "?") minimized=\(minimized.map(String.init) ?? "?")")
                lines.append("      title: \(title.isEmpty ? "(empty)" : title)")
            case .notFound:
                findings.append(.object([
                    "cgWindowID": .int(Int(target)),
                    "wasReachableViaPlainAX": .bool(alreadyReachable),
                    "outcome": .string("notFound"),
                    "sweptTo": .int(maxID),
                    "sweepSeconds": .number(elapsed),
                ]))
                lines.append("  wid \(target): NOT FOUND — swept ids 0..<\(maxID) in \(String(format: "%.2f", elapsed))s (budget \(budget)s)")
            }
        }

        let json = JSON.object([
            "command": .string("token"),
            "pid": .int(Int(pid)),
            "symbolAvailability": PrivateSymbols.availability([
                "_AXUIElementRemoteTokenCreate", "_AXUIElementCreateWithRemoteToken", "_AXUIElementGetWindow",
            ]),
            "tokenLayout": .object([
                "totalBytes": .int(20),
                "0x00_pid": .int(4), "0x04_zero": .int(4),
                "0x08_magic": .string(String(format: "0x%08x 'coco'", cocoMagic)),
                "0x0c_axElementID": .int(8),
            ]),
            "constantPrefix": .object([
                "hex": .string(hex(prefix)), "source": .string(prefixSource),
            ]),
            "reachableWindows": .array(reachableJSON),
            "targets": .array(findings),
        ])
        let name = "token-pid\(pid)" + (targets.isEmpty ? "" : "-wid" + targets.map(String.init).joined(separator: "_"))
        try output.write(name, json: json, summary: lines.joined(separator: "\n"))
        return 0
    }

    private struct ReachableWindow {
        let wid: CGWindowID
        let elementID: UInt64?
        let prefix: [UInt8]
    }

    private enum SweepResult {
        case found(elementID: UInt64, element: AXElement)
        case notFound
    }

    /// Hold the 12-byte prefix fixed, walk the id at offset 0x0c, and stop at the
    /// first synthesized element whose window id is the target AND whose role is
    /// AXWindow. The role gate matters: `_AXUIElementGetWindow` on any descendant
    /// (tab group, button) returns the containing window's id, so an id-only match
    /// silently returns a child element.
    private static func sweep(target: CGWindowID, prefix: [UInt8], maxID: Int, budget: TimeInterval,
                              create: PrivateSymbols.CreateWithRemoteToken,
                              getWindow: AXGetWindowFunction) -> SweepResult {
        let deadline = Date().addingTimeInterval(budget)
        var token = Data(prefix)
        token.append(Data(count: 8))
        var elementID: UInt64 = 0
        while elementID < UInt64(maxID) {
            if elementID & 0x3ff == 0, Date() >= deadline { return .notFound }
            token.withUnsafeMutableBytes { $0.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self) }
            if let element = create(token as CFData)?.takeRetainedValue() {
                var wid: CGWindowID = 0
                if getWindow(element, &wid) == .success, wid == target,
                   AXRead.string(AXElement(element), kAXRoleAttribute) == (kAXWindowRole as String) {
                    return .found(elementID: elementID, element: AXElement(element))
                }
            }
            elementID += 1
        }
        return .notFound
    }

    private static func canonicalPrefix(pid: pid_t) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 12)
        withUnsafeBytes(of: UInt32(bitPattern: Int32(pid)).littleEndian) { bytes.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: cocoMagic.littleEndian) { bytes.replaceSubrange(8..<12, with: $0) }
        return bytes
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
