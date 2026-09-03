import Carbon
import Foundation

/// The system's symbolic hotkeys the takeover touches. Reading goes through
/// the public `CopySymbolicHotKeys` (array index = symbolic id, E2); writing
/// needs the private `CGSSetSymbolicHotKeyEnabled` (dlsym, L10).
enum SymbolicHotKeys {
    /// 1 = Cmd+Tab, 2 = Cmd+Shift+Tab (`reference/keymap.md` §3).
    static let takeoverIDs: [Int32] = [1, 2]

    static var canSet: Bool { WSPrivateSymbols.setSymbolicHotKeyEnabled != nil }

    /// `nil` for an id the table does not have.
    static func readEnabled(_ ids: [Int32] = takeoverIDs) -> [Int32: Bool] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr,
              let entries = array?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        var result: [Int32: Bool] = [:]
        for id in ids where Int(id) < entries.count {
            result[id] = entries[Int(id)][kHISymbolicHotKeyEnabled as String] as? Bool ?? false
        }
        return result
    }

    @discardableResult
    static func set(_ id: Int32, enabled: Bool) -> Bool {
        guard let set = WSPrivateSymbols.setSymbolicHotKeyEnabled else { return false }
        return set(id, enabled) == 0
    }
}

/// Crash recovery for the takeover. The disabled state lives in the
/// WindowServer and any process can flip it back, so the original state is
/// written to our own defaults before anything is disabled and replayed
/// unconditionally at the next launch; replaying a stale marker is a no-op.
/// Apple's `com.apple.symbolichotkeys.plist` is never written: that would let
/// a crash outlive a reboot.
struct CmdTabRecovery: @unchecked Sendable {
    static let markerKey = "ws.cmdTab.originalState"

    let defaults: UserDefaults
    let setEnabled: @Sendable (Int32, Bool) -> Bool

    init(defaults: UserDefaults, setEnabled: @escaping @Sendable (Int32, Bool) -> Bool = SymbolicHotKeys.set) {
        self.defaults = defaults
        self.setEnabled = setEnabled
    }

    func remember(original: [Int32: Bool]) {
        let marker = Dictionary(uniqueKeysWithValues: original.map { (String($0.key), $0.value) })
        defaults.set(marker, forKey: Self.markerKey)
        defaults.synchronize()
    }

    func forget() {
        defaults.removeObject(forKey: Self.markerKey)
        defaults.synchronize()
    }

    var marker: [Int32: Bool]? {
        guard let stored = defaults.dictionary(forKey: Self.markerKey) as? [String: Bool] else { return nil }
        let pairs = stored.compactMap { key, value in Int32(key).map { ($0, value) } }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    /// Writes the remembered state back and clears the marker. Returns what
    /// was restored, `nil` when there was nothing to do.
    @discardableResult
    func restoreIfCrashed() -> [Int32: Bool]? {
        guard let marker else { return nil }
        for (id, enabled) in marker { _ = setEnabled(id, enabled) }
        forget()
        return marker
    }

    /// The standalone restore: replay a marker when there is one, otherwise
    /// enable everything, which is the system default and the safe direction.
    @discardableResult
    func forceRestore(ids: [Int32] = SymbolicHotKeys.takeoverIDs) -> [Int32: Bool] {
        if let restored = restoreIfCrashed() { return restored }
        var result: [Int32: Bool] = [:]
        for id in ids { result[id] = setEnabled(id, true) }
        return result
    }
}
