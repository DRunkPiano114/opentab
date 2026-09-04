import AppKit
import Carbon
import Foundation

// hkprobe — answers one question for OpenTab's Cmd+Tab takeover:
//
//   After CGSSetSymbolicHotKeyEnabled(1, false), does a Carbon
//   RegisterEventHotKey(Tab, Cmd) actually receive the key press, and can a
//   global flagsChanged monitor see the Cmd release that commits a selection?
//
// The three-call sequence under test is the one TabTab 2.x imports
// (CopySymbolicHotKeys, CGSSetSymbolicHotKeyEnabled, RegisterEventHotKey plus
// addGlobalMonitorForEventsMatchingMask:), so the experiment verifies the
// shipping mechanism on this machine rather than inventing one.
//
// Safety: the initial state is read before anything is changed and restored on
// normal exit, SIGINT, SIGTERM, and a hard watchdog. The state is WindowServer
// session state, not persisted, and any process can flip it back —
// `hkprobe restore` exists for a run that died before restoring.

// MARK: - Private symbols

enum CGS {
    /// `CGError CGSSetSymbolicHotKeyEnabled(int hotKey, Boolean enabled)`
    typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    /// `Boolean CGSIsSymbolicHotKeyEnabled(int hotKey)`
    typealias IsEnabled = @convention(c) (Int32) -> Bool

    static let setEnabled: SetEnabled? = resolve("CGSSetSymbolicHotKeyEnabled")
    static let isEnabled: IsEnabled? = resolve("CGSIsSymbolicHotKeyEnabled")

    static func resolve<T>(_ name: String) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}

/// Symbolic hotkey ids measured by probe runs on macOS 26.6.2:
/// 1 = Cmd+Tab, 2 = Cmd+Shift+Tab.
let symbolicIDs: [Int32] = [1, 2]

// MARK: - Logging

final class Log: @unchecked Sendable {
    private let handle: FileHandle?
    private let started = Date()
    private let lock = NSLock()

    init(path: String?) {
        if let path {
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path)
        } else {
            handle = nil
        }
    }

    func line(_ text: String) {
        let stamp = String(format: "%6.2fs", Date().timeIntervalSince(started))
        let full = "[\(stamp)] \(text)\n"
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardError.write(Data(full.utf8))
        handle?.write(Data(full.utf8))
    }
}

// MARK: - Hotkey state

struct HotKeyState: CustomStringConvertible {
    var enabled: [Int32: Bool?]
    var description: String {
        symbolicIDs.map { id in
            let value = enabled[id] ?? nil
            return "id\(id)=" + (value.map { $0 ? "on" : "OFF" } ?? "unknown")
        }.joined(separator: " ")
    }
}

func readState() -> HotKeyState {
    var state = HotKeyState(enabled: [:])
    for id in symbolicIDs { state.enabled[id] = CGS.isEnabled?(id) }
    return state
}

/// Read once before any mutation; the only value restore() ever writes back.
nonisolated(unsafe) var savedState: HotKeyState? = nil
nonisolated(unsafe) var restored = false
let log = Log(path: outputPath(suffix: nil))

/// Idempotent and callable from any thread and from signal/atexit context:
/// a plain C call per id, nothing else.
func restoreSavedState() {
    guard let saved = savedState, let set = CGS.setEnabled else { return }
    for id in symbolicIDs {
        // Unknown initial state (IsEnabled unresolved) restores to enabled,
        // which is the system default and the safe direction.
        let target = (saved.enabled[id] ?? nil) ?? true
        _ = set(id, target)
    }
    restored = true
}

func setHotKeys(enabled: Bool) -> [Int32: Int32] {
    var results: [Int32: Int32] = [:]
    guard let set = CGS.setEnabled else { return results }
    for id in symbolicIDs { results[id] = set(id, enabled) }
    return results
}

// MARK: - CopySymbolicHotKeys snapshot (public Carbon API)

struct SymbolicEntry { let index: Int; let code: Int; let modifiers: Int; let enabled: Bool }

func snapshotSymbolicHotKeys() -> [SymbolicEntry] {
    var array: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&array) == noErr, let cf = array?.takeRetainedValue() else { return [] }
    guard let entries = cf as NSArray as? [[String: Any]] else { return [] }
    return entries.enumerated().map { index, dict in
        SymbolicEntry(
            index: index,
            code: dict[kHISymbolicHotKeyCode as String] as? Int ?? -1,
            modifiers: dict[kHISymbolicHotKeyModifiers as String] as? Int ?? -1,
            enabled: dict[kHISymbolicHotKeyEnabled as String] as? Bool ?? false)
    }
}

func describeTabEntries(_ entries: [SymbolicEntry]) -> [String] {
    entries.filter { $0.code == kVK_Tab }.map {
        String(format: "  CopySymbolicHotKeys[%d]: code=%d modifiers=0x%X enabled=%@",
               $0.index, $0.code, $0.modifiers, $0.enabled ? "true" : "false")
    }
}

// MARK: - Output path

func outputDirectory() -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--out"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func outputPath(suffix: String?) -> String? {
    guard let dir = outputDirectory() else { return nil }
    let command = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") } ?? "run"
    return (dir as NSString).appendingPathComponent(command + (suffix ?? "") + ".txt")
}

// MARK: - Experiment

@MainActor
final class Experiment {
    static let shared = Experiment()

    private(set) var phase = "setup"
    private var counts: [String: [String: Int]] = [:]   // phase -> event -> count
    private var cmdDown = false
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var baselineDockWindows: Set<CGWindowID> = []
    private var switcherVisible = false
    private var lastFrontmost: String?
    private var pollTimer: Timer?

    func record(_ event: String) {
        counts[phase, default: [:]][event, default: 0] += 1
        log.line("phase \(phase): \(event)")
    }

    func summary(of phase: String) -> String {
        let c = counts[phase] ?? [:]
        return c.isEmpty ? "(nothing received)" : c.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    func hotKey(id: UInt32, kind: UInt32) {
        let key = id == 1 ? "Cmd+Tab" : id == 2 ? "Cmd+Shift+Tab" : "hotkey\(id)"
        record(kind == UInt32(kEventHotKeyPressed) ? "\(key) pressed" : "\(key) released")
    }

    func flags(_ flags: NSEvent.ModifierFlags) {
        let down = flags.contains(.command)
        guard down != cmdDown else { return }
        cmdDown = down
        record(down ? "Cmd down (global monitor)" : "Cmd UP (global monitor)")
    }

    // Observers that replace "did the person see the switcher": the system app
    // switcher is a Dock-owned window that is on screen only while Cmd is held,
    // and releasing Cmd in front of it changes the frontmost application.
    // Only owner name, layer and size are read — never window titles.

    private func onScreenDockWindows() -> [[String: Any]] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        return (info as? [[String: Any]] ?? []).filter { ($0[kCGWindowOwnerName as String] as? String) == "Dock" }
    }

    private func windowID(_ window: [String: Any]) -> CGWindowID {
        CGWindowID(window[kCGWindowNumber as String] as? Int ?? 0)
    }

    func startObservers() {
        baselineDockWindows = Set(onScreenDockWindows().map(windowID))
        lastFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        log.line("baseline: \(baselineDockWindows.count) Dock windows on screen, frontmost=\(lastFrontmost ?? "?")")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated { Experiment.shared.poll() }
        }
    }

    private func poll() {
        let dock = onScreenDockWindows()
        let extra = dock.filter { !baselineDockWindows.contains(windowID($0)) }
        let visible = !extra.isEmpty
        if visible != switcherVisible {
            switcherVisible = visible
            if visible {
                let detail = extra.map { w -> String in
                    let layer = w[kCGWindowLayer as String] as? Int ?? -1
                    let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                    return "layer=\(layer) \(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0))"
                }.joined(separator: ", ")
                record("system switcher APPEARED")
                log.line("    dock window(s): \(detail)")
            } else {
                record("system switcher hidden")
            }
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        if let last = lastFrontmost, last != front {
            record("frontmost app CHANGED")
            log.line("    \(last) → \(front)")
        }
        lastFrontmost = front
    }

    func show(_ text: String) {
        label?.stringValue = text
        log.line("panel: \(text.replacingOccurrences(of: "\n", with: " / "))")
    }

    func enter(_ name: String) { phase = name }

    // Registration

    func registerHotKeys() {
        var spec = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let install = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let kind = GetEventKind(event)
            MainActor.assumeIsolated { Experiment.shared.hotKey(id: hotKeyID.id, kind: kind) }
            return noErr
        }, spec.count, &spec, nil, nil)
        log.line("InstallEventHandler → \(install)")

        let signature = OSType(0x484B5052) // 'HKPR'
        for (id, modifiers) in [(UInt32(1), UInt32(cmdKey)), (UInt32(2), UInt32(cmdKey | shiftKey))] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(kVK_Tab), modifiers, EventHotKeyID(signature: signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            hotKeyRefs.append(ref)
            log.line(String(format: "RegisterEventHotKey(Tab, 0x%X) id=%d → status %d (%@)",
                            modifiers, id, status, status == noErr ? "ok" : "FAILED"))
        }
    }

    func installMonitors() {
        let trusted = AXIsProcessTrusted()
        log.line("AXIsProcessTrusted: \(trusted)  (global monitor delivers nothing without it)")
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { Experiment.shared.flags(flags) }
        }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { Experiment.shared.flags(flags) }
            return event
        }
    }

    func buildPanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 150),
                            styleMask: [.titled, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "hkprobe"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 18, weight: .medium)
        field.frame = NSRect(x: 20, y: 20, width: 520, height: 110)
        panel.contentView?.addSubview(field)
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
        self.label = field
    }

    // Schedule

    func start() {
        buildPanel()
        installMonitors()
        startObservers()

        savedState = readState()
        log.line("symbols: SetEnabled=\(CGS.setEnabled != nil) IsEnabled=\(CGS.isEnabled != nil)")
        log.line("initial state: \(savedState!)")
        describeTabEntries(snapshotSymbolicHotKeys()).forEach { log.line($0) }

        registerHotKeys()

        let a = 10.0, b = 12.0, c = 6.0
        enter("A")
        show("阶段 A（系统 Cmd+Tab 仍开启）\n请按 3 次 Cmd+Tab，每次都松开 Cmd。\n剩余 \(Int(a)) 秒")
        countdown(from: Int(a), prefix: "阶段 A（系统 Cmd+Tab 仍开启）\n请按 3 次 Cmd+Tab，每次都松开 Cmd。")

        DispatchQueue.main.asyncAfter(deadline: .now() + a) {
            log.line("phase A result: \(self.summary(of: "A"))")
            let results = setHotKeys(enabled: false)
            log.line("CGSSetSymbolicHotKeyEnabled(false) → \(results)")
            log.line("state after disable: \(readState())")
            describeTabEntries(snapshotSymbolicHotKeys()).forEach { log.line($0) }
            self.enter("B")
            self.countdown(from: Int(b), prefix: "阶段 B（系统 Cmd+Tab 已关闭）\n请按 3 次 Cmd+Tab，再按 1 次 Cmd+Shift+Tab。")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + a + b) {
            log.line("phase B result: \(self.summary(of: "B"))")
            restoreSavedState()
            log.line("restored; state now: \(readState())")
            describeTabEntries(snapshotSymbolicHotKeys()).forEach { log.line($0) }
            self.enter("C")
            self.countdown(from: Int(c), prefix: "阶段 C（已恢复）\n请再按 1 次 Cmd+Tab，确认系统切换器回来了。")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + a + b + c) {
            log.line("phase C result: \(self.summary(of: "C"))")
            log.line("final state: \(readState())")
            log.line("DONE")
            NSApp.terminate(nil)
        }
    }

    private func countdown(from seconds: Int, prefix: String) {
        for remaining in stride(from: seconds, through: 1, by: -1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds - remaining)) {
                self.show("\(prefix)\n剩余 \(remaining) 秒")
            }
        }
    }
}

// MARK: - Commands

func commandStatus() {
    log.line("AXIsProcessTrusted: \(AXIsProcessTrusted())")
    log.line("symbols: SetEnabled=\(CGS.setEnabled != nil) IsEnabled=\(CGS.isEnabled != nil)")
    log.line("state: \(readState())")
    describeTabEntries(snapshotSymbolicHotKeys()).forEach { log.line($0) }
}

func commandRestore() {
    log.line("before: \(readState())")
    let results = setHotKeys(enabled: true)
    log.line("CGSSetSymbolicHotKeyEnabled(true) → \(results)")
    log.line("after: \(readState())")
}

@MainActor
func commandRun() {
    // Every exit path restores. Signals are routed through dispatch sources so
    // the handler can run ordinary code; atexit covers NSApp.terminate.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    for sig in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            log.line("signal \(sig): restoring and exiting")
            restoreSavedState()
            exit(128 + sig)
        }
        source.resume()
        _ = Unmanaged.passRetained(source) // keep alive for process lifetime
    }
    atexit { if !restored { restoreSavedState() } }

    // Hard watchdog off the main queue: a wedged run loop still restores.
    DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
        log.line("WATCHDOG: 45s elapsed, restoring and exiting")
        restoreSavedState()
        exit(3)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async { Experiment.shared.start() }
    app.run()
}

let command = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") } ?? "status"
switch command {
case "status": commandStatus()
case "restore": commandRestore()
case "run": MainActor.assumeIsolated { commandRun() }
default:
    log.line("unknown command '\(command)' (status | run | restore)")
    exit(2)
}
