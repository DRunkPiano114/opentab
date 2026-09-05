import AppKit
import Carbon

/// One recorded chord: a virtual key code and a Carbon modifier mask.
///
/// The key code is the physical key, which is what `RegisterEventHotKey`
/// wants; only the label shown to the user depends on the keyboard layout.
struct HotKeyBinding: Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let optionTab = HotKeyBinding(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(optionKey))
    static let optionShiftTab = HotKeyBinding(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(optionKey | shiftKey))
    static let cmdTab = HotKeyBinding(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(cmdKey))
    static let cmdShiftTab = HotKeyBinding(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(cmdKey | shiftKey))

    static let mainDefault = HotKeyBinding.cmdTab
    static let reverseDefault = HotKeyBinding.cmdShiftTab
    static let searchDefault = HotKeyBinding(keyCode: UInt32(kVK_ANSI_L),
                                            carbonModifiers: UInt32(cmdKey | shiftKey))

    /// The modifier whose release commits the selection. Nil when the chord
    /// carries none of the modifiers the release monitors track, which makes
    /// it unusable as the panel's hold chord.
    var hold: HoldModifier? {
        HoldModifier.allCases.first { carbonModifiers & $0.carbonModifier != 0 }
    }

    /// A chord with no key or no hold modifier cannot drive the panel: the
    /// session waits for a modifier release that never arrives and commits
    /// the moment it opens.
    var isUsableAsHoldChord: Bool { hold != nil }

    /// Whether binding this chord means taking Cmd-Tab away from the system.
    /// Exactly the two chords the window server owns: a chord that merely
    /// contains Command, such as Control-Command-Tab, is an ordinary global
    /// hotkey and must not switch the system's own Cmd-Tab off.
    var needsSymbolicHotKeyTakeover: Bool { self == .cmdTab || self == .cmdShiftTab }

    /// The chord bound in place of this one while the takeover is off:
    /// Option-Tab for Cmd-Tab, keeping Shift; anything else is itself.
    func withoutTakeover() -> HotKeyBinding {
        switch self {
        case .cmdTab: .optionTab
        case .cmdShiftTab: .optionShiftTab
        default: self
        }
    }

    // MARK: Persistence

    private enum Field {
        static let keyCode = "keyCode"
        static let modifiers = "modifiers"
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init?(stored: Any?) {
        guard let dictionary = stored as? [String: Int],
              let keyCode = dictionary[Field.keyCode], let modifiers = dictionary[Field.modifiers],
              keyCode >= 0, modifiers >= 0 else { return nil }
        self.init(keyCode: UInt32(keyCode), carbonModifiers: UInt32(modifiers))
    }

    var stored: [String: Int] { [Field.keyCode: Int(keyCode), Field.modifiers: Int(carbonModifiers)] }

    // MARK: Recording

    /// The chord an `NSEvent` key-down carries, or nil when the event is a
    /// bare key with no modifier at all: a global hotkey with no modifier
    /// would swallow that key from every app.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        guard carbon != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
    }

    // MARK: Display

    /// Modifier glyphs in the order the system draws them, then the key as a
    /// word when it has a name, every token separated by a thin space.
    var displayString: String {
        var tokens: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { tokens.append("\u{2303}") }
        if carbonModifiers & UInt32(optionKey) != 0 { tokens.append("\u{2325}") }
        if carbonModifiers & UInt32(shiftKey) != 0 { tokens.append("\u{21E7}") }
        if carbonModifiers & UInt32(cmdKey) != 0 { tokens.append("\u{2318}") }
        tokens.append(KeyCodeNames.label(for: keyCode))
        return tokens.joined(separator: "\u{2009}")
    }
}

/// Labels for virtual key codes. Printing keys are resolved through the
/// active keyboard layout, so a Dvorak or AZERTY user sees the character
/// their key actually produces rather than the ANSI one.
enum KeyCodeNames {
    private static let named: [Int: String] = [
        kVK_Tab: "Tab", kVK_Space: "Space", kVK_Return: "Return", kVK_Escape: "Escape",
        kVK_Delete: "Delete", kVK_ForwardDelete: "Forward Delete", kVK_ANSI_KeypadEnter: "Enter",
        kVK_LeftArrow: "Left Arrow", kVK_RightArrow: "Right Arrow", kVK_UpArrow: "Up Arrow", kVK_DownArrow: "Down Arrow",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func label(for keyCode: UInt32) -> String {
        if let name = named[Int(keyCode)] { return name }
        if let character = layoutCharacter(for: keyCode), !character.isEmpty {
            return character.uppercased()
        }
        return "Key \(keyCode)"
    }

    /// The unmodified character the current layout produces for this physical
    /// key. Dead keys answer nothing and fall back to the numeric label.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}
