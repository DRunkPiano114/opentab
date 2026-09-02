import AppKit

/// Borderless, non-activating overlay that exists on every Space and draws
/// over full-screen apps. In P0 it never becomes key; `canBecomeKey` stays
/// true for the later search state, where the app is activated on purpose.
final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered,
                   defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // NSPanel defaults this to true, which would hide the panel the moment
        // it is shown under another app's focus.
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        worksWhenModal = true
        sharingType = .none
        isMovable = false
        isMovableByWindowBackground = false
        appearance = NSAppearance(named: .darkAqua)
    }
}
