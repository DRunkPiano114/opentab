import AppKit
import Carbon
import SwiftUI

/// Click-to-record shortcut field.
///
/// While it is recording, the app's own global chords must be unregistered:
/// a Carbon hotkey is consumed before any window sees it, so the field would
/// never be shown the very chord the user is trying to replace. That is what
/// `onRecordingChanged` is for.
final class HotKeyRecorderView: NSView {
    var binding: HotKeyBinding { didSet { needsDisplay = true } }
    /// Main and reverse chords must carry a modifier whose release can be
    /// observed, or the panel commits the instant it opens.
    var requiresHoldModifier: Bool
    /// Only a field whose chord switches the system's Cmd-Tab off can take
    /// Cmd-Tab: anywhere else it registers fine and never fires.
    var acceptsCmdTab: Bool
    /// Whether this Mac has the window-server call the takeover needs.
    var takeoverAvailable: Bool
    /// The other fields' chords. A second registration of one chord in one
    /// process is only logged, so a collision here is a silently dead field;
    /// the fallback pair counts too, because it is what gets bound while the
    /// takeover is off.
    var reservedChords: [HotKeyBinding]
    var onRecord: ((HotKeyBinding) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private var isRecording = false { didSet { needsDisplay = true } }
    private var message: String?

    init(binding: HotKeyBinding, requiresHoldModifier: Bool, acceptsCmdTab: Bool = true,
         takeoverAvailable: Bool = true, reservedChords: [HotKeyBinding] = []) {
        self.binding = binding
        self.requiresHoldModifier = requiresHoldModifier
        self.acceptsCmdTab = acceptsCmdTab
        self.takeoverAvailable = takeoverAvailable
        self.reservedChords = reservedChords
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 24) }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            window?.makeFirstResponder(self)
            startRecording()
        }
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return true
    }

    /// Chords that carry Command arrive as key equivalents rather than as
    /// key-down events, so both paths have to be taken.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        record(event)
    }

    private func startRecording() {
        guard !isRecording else { return }
        message = nil
        isRecording = true
        onRecordingChanged?(true)
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        message = nil
        onRecordingChanged?(false)
    }

    private func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
            stopRecording()
            return
        }
        guard let recorded = HotKeyBinding(event: event) else {
            fail("Add a modifier key")
            return
        }
        if requiresHoldModifier, !recorded.isUsableAsHoldChord {
            fail("Use \u{2325}, \u{2303} or \u{2318}")
            return
        }
        if recorded.needsSymbolicHotKeyTakeover, !acceptsCmdTab {
            fail("\u{2318}\u{2009}Tab is taken")
            return
        }
        if recorded.needsSymbolicHotKeyTakeover, !takeoverAvailable {
            fail("\u{2318}\u{2009}Tab is unavailable")
            return
        }
        if reservedChords.contains(recorded) || reservedChords.contains(recorded.withoutTakeover())
            || reservedChords.contains(where: { $0.withoutTakeover() == recorded }) {
            fail("Already in use")
            return
        }
        binding = recorded
        stopRecording()
        onRecord?(recorded)
    }

    private func fail(_ text: String) {
        message = text
        NSSound.beep()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        shape.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let text = message ?? (isRecording ? "Type a shortcut" : binding.displayString)
        let colour: NSColor = message != nil ? .systemRed : (isRecording ? .secondaryLabelColor : .labelColor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: colour,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                withAttributes: attributes)
    }
}

struct HotKeyRecorder: NSViewRepresentable {
    let binding: HotKeyBinding
    var requiresHoldModifier = true
    var acceptsCmdTab = true
    let takeoverAvailable: Bool
    let reservedChords: [HotKeyBinding]
    let onRecord: (HotKeyBinding) -> Void
    let onRecordingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView(binding: binding, requiresHoldModifier: requiresHoldModifier,
                                      acceptsCmdTab: acceptsCmdTab, takeoverAvailable: takeoverAvailable,
                                      reservedChords: reservedChords)
        view.onRecord = onRecord
        view.onRecordingChanged = onRecordingChanged
        return view
    }

    func updateNSView(_ view: HotKeyRecorderView, context: Context) {
        view.binding = binding
        view.requiresHoldModifier = requiresHoldModifier
        view.acceptsCmdTab = acceptsCmdTab
        view.takeoverAvailable = takeoverAvailable
        view.reservedChords = reservedChords
        view.onRecord = onRecord
        view.onRecordingChanged = onRecordingChanged
    }
}
