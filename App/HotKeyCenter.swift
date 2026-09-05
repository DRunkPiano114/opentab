import AppKit
import Carbon
import OpenTabCore
import os

enum NavigationKey {
    case next, previous, escape, commit, up, down, left, right
    /// The direct-to-search hotkey.
    case search
}

enum KeyPhase {
    case pressed, released
}

/// The modifier the user holds while the panel is up; releasing it commits
/// the selection. Command is the hold when the main chord is Cmd-Tab and
/// Option when it is Option-Tab; a recorded chord may use any of the three,
/// and the monitors track all of them.
///
/// Shift is deliberately not one: it is the reverse-direction modifier, so
/// holding it could not be told apart from asking to go backwards.
struct HoldModifier: Hashable, Sendable, CustomStringConvertible {
    let carbonModifier: UInt32

    static let option = HoldModifier(carbonModifier: UInt32(optionKey))
    static let command = HoldModifier(carbonModifier: UInt32(cmdKey))
    static let control = HoldModifier(carbonModifier: UInt32(controlKey))

    static let allCases: [HoldModifier] = [.option, .command, .control]

    private static let table: [UInt32: (NSEvent.ModifierFlags, CGEventFlags, String)] = [
        UInt32(optionKey): (.option, .maskAlternate, "option"),
        UInt32(cmdKey): (.command, .maskCommand, "command"),
        UInt32(controlKey): (.control, .maskControl, "control"),
    ]

    var flag: NSEvent.ModifierFlags { Self.table[carbonModifier]?.0 ?? [] }

    /// The session-wide key state, valid whether or not this app is active.
    var currentlyHeld: Bool {
        guard let mask = Self.table[carbonModifier]?.1 else { return false }
        return CGEventSource.flagsState(.combinedSessionState).contains(mask)
    }

    var description: String { Self.table[carbonModifier]?.2 ?? "carbon\(carbonModifier)" }
}

/// Carbon hotkeys plus `flagsChanged` monitors. Carbon hotkeys are immune to
/// Secure Input and are consumed before the frontmost app sees them; the
/// monitors only observe, which is all the modifier edge needs.
@MainActor
final class HotKeyCenter {
    /// `hold` is the modifier a persistent Tab chord was pressed with; `nil`
    /// for the keys registered while the panel is up.
    var onNavigationKey: ((NavigationKey, KeyPhase, HoldModifier?) -> Void)?
    /// A hold modifier is no longer held. Fires only from the monitors, never
    /// from Carbon's release event: the two are not ordered against each
    /// other.
    var onModifierReleased: ((HoldModifier) -> Void)?
    private(set) var modifierMonitorsInstalled = false

    private struct Binding: Equatable {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
        let key: NavigationKey
        var hold: HoldModifier? = nil
    }

    private nonisolated static let signature: OSType = 0x4F50_5442 // 'OPTB'

    /// The chords registered for the whole process lifetime. Replaced when
    /// the user records new ones; the defaults live on `HotKeyBinding`.
    /// Starts on the fallback pair, never on Cmd-Tab: a center registered
    /// before anything configured it must still bind chords that fire.
    private static func persistent(main: HotKeyBinding, reverse: HotKeyBinding,
                                   search: HotKeyBinding) -> [Binding] {
        [
            Binding(id: 1, keyCode: main.keyCode, modifiers: main.carbonModifiers, key: .next, hold: main.hold),
            Binding(id: 2, keyCode: reverse.keyCode, modifiers: reverse.carbonModifiers, key: .previous,
                    hold: reverse.hold),
            Binding(id: 3, keyCode: search.keyCode, modifiers: search.carbonModifiers, key: .search),
        ]
    }

    /// Registered only while the panel is visible: these steal plain keys
    /// from every app. Each key is registered both unmodified and with the
    /// hold modifier: Carbon matches the modifier set exactly, and while the
    /// panel is up the user is holding it, so a physical Esc press arrives
    /// as Option+Esc or Cmd+Esc.
    private static func navigation(for hold: HoldModifier) -> [Binding] {
        let plain: [Binding] = [
            Binding(id: 10, keyCode: UInt32(kVK_Tab), modifiers: 0, key: .next),
            Binding(id: 11, keyCode: UInt32(kVK_Tab), modifiers: UInt32(shiftKey), key: .previous),
            Binding(id: 12, keyCode: UInt32(kVK_Escape), modifiers: 0, key: .escape),
            Binding(id: 13, keyCode: UInt32(kVK_Return), modifiers: 0, key: .commit),
            Binding(id: 14, keyCode: UInt32(kVK_UpArrow), modifiers: 0, key: .up),
            Binding(id: 15, keyCode: UInt32(kVK_DownArrow), modifiers: 0, key: .down),
            Binding(id: 16, keyCode: UInt32(kVK_LeftArrow), modifiers: 0, key: .left),
            Binding(id: 17, keyCode: UInt32(kVK_RightArrow), modifiers: 0, key: .right),
        ]
        let held: [Binding] = [
            Binding(id: 22, keyCode: UInt32(kVK_Escape), modifiers: hold.carbonModifier, key: .escape),
            Binding(id: 23, keyCode: UInt32(kVK_Return), modifiers: hold.carbonModifier, key: .commit),
            Binding(id: 24, keyCode: UInt32(kVK_UpArrow), modifiers: hold.carbonModifier, key: .up),
            Binding(id: 25, keyCode: UInt32(kVK_DownArrow), modifiers: hold.carbonModifier, key: .down),
            Binding(id: 26, keyCode: UInt32(kVK_LeftArrow), modifiers: hold.carbonModifier, key: .left),
            Binding(id: 27, keyCode: UInt32(kVK_RightArrow), modifiers: hold.carbonModifier, key: .right),
        ]
        return plain + held
    }

    private var handlerRef: EventHandlerRef?
    private var persistentBindings: [Binding] = HotKeyCenter.persistent(main: .optionTab, reverse: .optionShiftTab,
                                                                        search: .searchDefault)
    private var persistentRefs: [EventHotKeyRef] = []
    private var navigationRefs: [EventHotKeyRef] = []
    private var navigationBindings: [Binding] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var held: [HoldModifier: Bool] = [:]
    private let log = Log.make("hotkey")

    init() {
        installCarbonHandler()
    }

    func registerPersistent() {
        guard persistentRefs.isEmpty else { return }
        persistentRefs = register(persistentBindings)
    }

    /// The chords currently bound, in main / reverse / search order.
    var persistentChords: [HotKeyBinding] {
        persistentBindings.map { HotKeyBinding(keyCode: $0.keyCode, carbonModifiers: $0.modifiers) }
    }

    func unregisterPersistent() {
        for ref in persistentRefs {
            UnregisterEventHotKey(ref)
        }
        persistentRefs = []
    }

    /// Applies recorded chords, re-registering if the hotkeys are live. A
    /// main or reverse chord with no hold modifier is rejected and Option-Tab
    /// bound instead: the session waits for a release that would never come
    /// and would commit the panel the instant it opened. The substitute is
    /// never Cmd-Tab, which only fires while the system chord is off.
    func configure(main: HotKeyBinding, reverse: HotKeyBinding, search: HotKeyBinding) {
        let main = main.isUsableAsHoldChord ? main : .optionTab
        let reverse = reverse.isUsableAsHoldChord ? reverse : .optionShiftTab
        let bindings = Self.persistent(main: main, reverse: reverse, search: search)
        guard bindings != persistentBindings else { return }
        let wasRegistered = !persistentRefs.isEmpty
        unregisterPersistent()
        persistentBindings = bindings
        if wasRegistered { registerPersistent() }
        log.notice("hotkeys configured main=\(main.displayString, privacy: .public) reverse=\(reverse.displayString, privacy: .public) search=\(search.displayString, privacy: .public)")
    }

    func registerNavigationKeys(for hold: HoldModifier) {
        guard navigationRefs.isEmpty else { return }
        navigationBindings = Self.navigation(for: hold)
        navigationRefs = register(navigationBindings)
    }

    func unregisterNavigationKeys() {
        for ref in navigationRefs {
            UnregisterEventHotKey(ref)
        }
        navigationRefs = []
        navigationBindings = []
    }

    /// Whether `modifier` is down right now, from the monitors' own edge
    /// tracking or the session-wide key state. Either source alone misses a
    /// case: the session state is not updated for a synthetic Command press,
    /// and the monitors can see a quick tap's release before the hotkey
    /// event arrives (their `held` is then already false, which is right).
    func isHeld(_ modifier: HoldModifier) -> Bool {
        (held[modifier] ?? false) || modifier.currentlyHeld
    }

    /// Global monitors installed before the Accessibility grant deliver nothing
    /// even after it lands, so this removes and re-adds on every call.
    func installModifierMonitors() {
        removeModifierMonitors()
        for modifier in HoldModifier.allCases {
            held[modifier] = modifier.currentlyHeld
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.modifierFlagsChanged(flags) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.modifierFlagsChanged(flags) }
            return event
        }
        modifierMonitorsInstalled = globalMonitor != nil
        log.info("modifier monitors installed=\(self.modifierMonitorsInstalled, privacy: .public) trusted=\(AXIsProcessTrusted(), privacy: .public)")
    }

    // MARK: - Carbon

    private func installCarbonHandler() {
        var spec = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            // Another handler on this target may own the hotkey.
            guard hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let kind = GetEventKind(event)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { center.dispatch(hotKeyID, kind: kind) }
            return noErr
        }, spec.count, &spec, userData, &handlerRef)
        if status != noErr {
            log.error("InstallEventHandler status=\(status, privacy: .public)")
        }
    }

    private func dispatch(_ hotKeyID: EventHotKeyID, kind: UInt32) {
        guard let binding = (persistentBindings + navigationBindings).first(where: { $0.id == hotKeyID.id })
        else { return }
        let phase: KeyPhase = kind == UInt32(kEventHotKeyPressed) ? .pressed : .released
        onNavigationKey?(binding.key, phase, binding.hold)
    }

    private func register(_ bindings: [Binding]) -> [EventHotKeyRef] {
        var refs: [EventHotKeyRef] = []
        for binding in bindings {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                                             EventHotKeyID(signature: Self.signature, id: binding.id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                log.error("RegisterEventHotKey keyCode=\(binding.keyCode, privacy: .public) modifiers=\(binding.modifiers, privacy: .public) status=\(status, privacy: .public)")
            }
        }
        return refs
    }

    // MARK: - Modifier monitors

    private func removeModifierMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        modifierMonitorsInstalled = false
    }

    private func modifierFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        for modifier in HoldModifier.allCases {
            let isHeld = flags.contains(modifier.flag)
            guard isHeld != held[modifier] else { continue }
            held[modifier] = isHeld
            if !isHeld {
                onModifierReleased?(modifier)
            }
        }
    }
}
