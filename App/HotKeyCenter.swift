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

/// Carbon hotkeys plus `flagsChanged` monitors. Carbon hotkeys are immune to
/// Secure Input and are consumed before the frontmost app sees them; the
/// monitors only observe, which is all the modifier edge needs.
@MainActor
final class HotKeyCenter {
    var onNavigationKey: ((NavigationKey, KeyPhase) -> Void)?
    /// Option is no longer held. Fires only from the monitors, never from
    /// Carbon's release event (E2: the two are not ordered against each other).
    var onModifierReleased: (() -> Void)?
    private(set) var modifierMonitorsInstalled = false

    private struct Binding {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
        let key: NavigationKey
    }

    private static let signature: OSType = 0x4F50_5442 // 'OPTB'

    /// Registered for the whole process lifetime.
    private static let persistent: [Binding] = [
        Binding(id: 1, keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey), key: .next),
        Binding(id: 2, keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | shiftKey), key: .previous),
        Binding(id: 3, keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | shiftKey), key: .search),
    ]

    /// Registered only while the panel is visible: these steal plain keys
    /// from every app. No Cmd combinations (L14). Each key is registered both
    /// unmodified and with Option held: Carbon matches the modifier set
    /// exactly, and while the panel is up the user is holding Option, so a
    /// physical Esc press arrives as Option+Esc.
    private static let navigation: [Binding] = [
        Binding(id: 10, keyCode: UInt32(kVK_Tab), modifiers: 0, key: .next),
        Binding(id: 11, keyCode: UInt32(kVK_Tab), modifiers: UInt32(shiftKey), key: .previous),
        Binding(id: 12, keyCode: UInt32(kVK_Escape), modifiers: 0, key: .escape),
        Binding(id: 13, keyCode: UInt32(kVK_Return), modifiers: 0, key: .commit),
        Binding(id: 14, keyCode: UInt32(kVK_UpArrow), modifiers: 0, key: .up),
        Binding(id: 15, keyCode: UInt32(kVK_DownArrow), modifiers: 0, key: .down),
        Binding(id: 16, keyCode: UInt32(kVK_LeftArrow), modifiers: 0, key: .left),
        Binding(id: 17, keyCode: UInt32(kVK_RightArrow), modifiers: 0, key: .right),
        Binding(id: 22, keyCode: UInt32(kVK_Escape), modifiers: UInt32(optionKey), key: .escape),
        Binding(id: 23, keyCode: UInt32(kVK_Return), modifiers: UInt32(optionKey), key: .commit),
        Binding(id: 24, keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(optionKey), key: .up),
        Binding(id: 25, keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(optionKey), key: .down),
        Binding(id: 26, keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey), key: .left),
        Binding(id: 27, keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(optionKey), key: .right),
    ]

    private var handlerRef: EventHandlerRef?
    private var persistentRefs: [EventHotKeyRef] = []
    private var navigationRefs: [EventHotKeyRef] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var optionHeld = false
    private let log = Log.make("hotkey")

    init() {
        installCarbonHandler()
    }

    func registerPersistent() {
        guard persistentRefs.isEmpty else { return }
        persistentRefs = register(Self.persistent)
    }

    func registerNavigationKeys() {
        guard navigationRefs.isEmpty else { return }
        navigationRefs = register(Self.navigation)
    }

    func unregisterNavigationKeys() {
        for ref in navigationRefs {
            UnregisterEventHotKey(ref)
        }
        navigationRefs = []
    }

    /// Global monitors installed before the Accessibility grant deliver nothing
    /// even after it lands, so this removes and re-adds on every call.
    func installModifierMonitors() {
        removeModifierMonitors()
        optionHeld = Self.optionCurrentlyHeld
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

    /// The session-wide key state, valid whether or not this app is active.
    static var optionCurrentlyHeld: Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
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
        guard hotKeyID.signature == Self.signature,
              let binding = (Self.persistent + Self.navigation).first(where: { $0.id == hotKeyID.id })
        else { return }
        let phase: KeyPhase = kind == UInt32(kEventHotKeyPressed) ? .pressed : .released
        onNavigationKey?(binding.key, phase)
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
        let held = flags.contains(.option)
        guard held != optionHeld else { return }
        optionHeld = held
        if !held {
            onModifierReleased?()
        }
    }
}
