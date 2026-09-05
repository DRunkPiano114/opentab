import AppKit
import OpenTabCore
import os

/// Restores the system hotkeys from any exit path: normal termination
/// (`atexit`), SIGINT / SIGTERM / SIGHUP (dispatch sources), or a plain
/// call. One process-wide instance because `atexit` takes a C function
/// pointer.
private final class RestoreGuard: Sendable {
    private struct Armed {
        let recovery: CmdTabRecovery
        let original: [Int32: Bool]
    }

    static let shared = RestoreGuard()
    private let armed = OSAllocatedUnfairLock<Armed?>(initialState: nil)
    private let installed = OSAllocatedUnfairLock(initialState: false)
    /// Signal sources live off the main queue: a wedged main thread is the
    /// case where someone reaches for `kill`, and the restore must still run
    /// and the process must still die.
    private let signalQueue = DispatchQueue(label: "im.opentab.app.ws.signals")
    private let signalSources = OSAllocatedUnfairLock<[DispatchSourceSignal]>(initialState: [])

    func arm(_ recovery: CmdTabRecovery, original: [Int32: Bool]) {
        armed.withLock { $0 = Armed(recovery: recovery, original: original) }
        let first = installed.withLock { installed -> Bool in
            defer { installed = true }
            return !installed
        }
        guard first else { return }
        atexit { RestoreGuard.shared.restoreNow() }
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            source.setEventHandler {
                RestoreGuard.shared.restoreNow()
                exit(128 + sig)
            }
            source.resume()
            sources.append(source)
        }
        let installedSources = sources
        signalSources.withLock { $0 = installedSources }
    }

    /// Idempotent; safe from any thread.
    func restoreNow() {
        guard let armed = armed.withLock({ armed -> Armed? in
            defer { armed = nil }
            return armed
        }) else { return }
        for (id, enabled) in armed.original { _ = armed.recovery.setEnabled(id, enabled) }
        armed.recovery.forget()
    }
}

/// The system side of the Cmd+Tab takeover: disables symbolic hotkeys 1 and 2
/// in the WindowServer so the app's own Carbon bindings for the same chords
/// receive the keys, and puts them back. The app derives `ws.cmdTabTakeover`
/// from its bound chord and decides with `TakeoverPolicy` whether to enable
/// it. The chords themselves are bound by the app's `HotKeyCenter`, which
/// also reports the Cmd release from its `flagsChanged` monitors.
///
/// The state read before the change is what gets written back, from every
/// exit path plus a marker replayed at the next launch.
@MainActor
public final class CmdTabTakeover {
    public static let defaultsKey = "ws.cmdTabTakeover"
    /// `open -n -a OpenTab.app --args --restore-cmd-tab`: `-n` because
    /// `open` hands arguments only to a process it launches, never to one
    /// already running (which would have replayed the marker itself).
    public static let restoreArgument = "--restore-cmd-tab"
    /// Makes `isAvailable` report false for this process, so the fallback the
    /// app takes on a Mac without the window-server call can be exercised
    /// on one that has it.
    public static let disableArgument = "--disable-cmd-tab-takeover"
    public internal(set) static var isDisabledForThisProcess = false

    public private(set) var isEnabled = false
    public private(set) var originalState: [Int32: Bool] = [:]

    public static var isAvailable: Bool { !isDisabledForThisProcess && SymbolicHotKeys.canSet }

    private let recovery: CmdTabRecovery
    private let log = Log.make("cmdtab")

    public init(defaults: UserDefaults = .standard) {
        recovery = CmdTabRecovery(defaults: defaults)
    }

    public static func isConfigured(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    /// The WindowServer's current answer for the takeover chords.
    public static func systemState() -> [Int32: Bool] {
        SymbolicHotKeys.readEnabled()
    }

    /// Writes an explicit state; for tests and tools that must put back what
    /// they recorded.
    public static func setSystemState(_ state: [Int32: Bool]) {
        for (id, enabled) in state { SymbolicHotKeys.set(id, enabled: enabled) }
    }

    /// Runs unconditionally at launch; a stale marker is a harmless replay.
    @discardableResult
    public static func restoreIfCrashed(defaults: UserDefaults = .standard) -> [Int32: Bool]? {
        let restored = CmdTabRecovery(defaults: defaults).restoreIfCrashed()
        if let restored {
            Log.make("cmdtab").error("restored system hotkeys after an unclean exit: \(String(describing: restored), privacy: .public)")
        }
        return restored
    }

    /// The standalone restore: any process can restore, so a fresh one does
    /// it and exits. Returns what it wrote.
    public static func runRestoreCommand(defaults: UserDefaults = .standard) -> [Int32: Bool] {
        let result = CmdTabRecovery(defaults: defaults).forceRestore()
        Log.make("cmdtab").notice("restore command wrote \(String(describing: result), privacy: .public) now=\(String(describing: SymbolicHotKeys.readEnabled()), privacy: .public)")
        return result
    }

    /// Disables the system chords. Register the app's own bindings after
    /// this returns `true`: a Carbon hotkey registered while the system chord
    /// is enabled reports success and never fires.
    @discardableResult
    public func enable() -> Bool {
        guard !isEnabled else { return true }
        guard Self.isAvailable else {
            log.error("\(WSPrivateSymbols.Name.setSymbolicHotKeyEnabled, privacy: .public) unavailable: Cmd+Tab takeover disabled")
            return false
        }
        var original = SymbolicHotKeys.readEnabled()
        for id in SymbolicHotKeys.takeoverIDs where original[id] == nil {
            // Unknown reads back as enabled: the system default and the safe direction.
            original[id] = WSPrivateSymbols.isSymbolicHotKeyEnabled?(id) ?? true
        }
        originalState = original
        recovery.remember(original: original)
        RestoreGuard.shared.arm(recovery, original: original)
        for id in SymbolicHotKeys.takeoverIDs where !SymbolicHotKeys.set(id, enabled: false) {
            log.error("CGSSetSymbolicHotKeyEnabled(\(id, privacy: .public), false) failed")
        }
        isEnabled = true
        log.notice("Cmd+Tab takeover enabled original=\(String(describing: original), privacy: .public) now=\(String(describing: SymbolicHotKeys.readEnabled()), privacy: .public)")
        return true
    }

    /// Puts the system chords back. Unregister the app's bindings first.
    public func disable() {
        guard isEnabled else { return }
        RestoreGuard.shared.restoreNow()
        isEnabled = false
        log.notice("Cmd+Tab takeover disabled now=\(String(describing: SymbolicHotKeys.readEnabled()), privacy: .public)")
    }
}
