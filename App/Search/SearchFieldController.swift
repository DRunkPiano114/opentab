import AppKit
import OpenTabCore
import os

/// The search-state text field. A stock `NSTextField` gets full IME support
/// for free once the app is active and the panel is key (appendix d §10.3),
/// so this class only owns activation, the navigation-key mapping, and the
/// rules for which keys belong to the input method.
@MainActor
final class SearchFieldController: NSObject, NSTextFieldDelegate {
    enum Command: Equatable { case moveUp, moveDown, moveNext, movePrevious, commit, cancel }

    /// Fired on every change of the field's full string, marked text
    /// included, so the list filters while pinyin is still being composed.
    /// Identical consecutive values are reported once.
    var onTextChange: ((String) -> Void)?
    /// Fired for navigation keys the IME did not consume. Never fires for
    /// Return/Escape while marked text is pending.
    var onCommand: ((Command) -> Void)?

    /// The field, for the owner to place in the panel. The owner sets the
    /// frame; no autoresizing.
    var view: NSTextField { field }

    /// Ceiling on the wait for activation to land. Activation is granted
    /// asynchronously; measured 7-17 ms when called directly and 18-49 ms
    /// from inside the Carbon hotkey handler in the app-hosted tests.
    static let activationTimeout: Duration = .milliseconds(200)

    private let field: SearchTextField
    private var lastReported = ""
    private var suppressChanges = false
    private let log = Log.make("search")

    override init() {
        field = SearchTextField(frame: .zero)
        super.init()
        field.delegate = self
        field.onCompositionChange = { [weak self] in self?.reportTextIfChanged() }
        field.autoresizingMask = []
        field.font = .systemFont(ofSize: 15)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(
            string: "Search",
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.30),
                         .font: NSFont.systemFont(ofSize: 15)])
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.allowsEditingTextAttributes = false
        field.importsGraphics = false
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.isScrollable = true
            cell.wraps = false
            cell.sendsActionOnEndEditing = false
        }
    }

    /// The field's full string: committed text plus any marked text.
    /// Setting it discards a pending composition and does not fire
    /// `onTextChange`.
    var text: String {
        get { fieldEditor?.string ?? field.stringValue }
        set {
            suppressChanges = true
            defer { suppressChanges = false }
            fieldEditor?.inputContext?.discardMarkedText()
            field.stringValue = newValue
            lastReported = newValue
        }
    }

    var hasMarkedText: Bool {
        fieldEditor?.hasMarkedText() ?? false
    }

    /// Activates the app, makes `panel` key and front, and focuses the field.
    /// Returns true when the field editor is first responder and
    /// `NSTextInputContext.current` is non-nil: the honest IME-alive signal.
    /// `view.inputContext` is non-nil even in an inactive app, and
    /// `handleEvent` then returns true while dropping every key (appendix d
    /// §10.2), so neither of those may be used as the check.
    ///
    /// Activation lands asynchronously, so this pumps activation events until
    /// the field is ready or `activationTimeout` passes. The input method
    /// attaches to a fresh input context ~500 ms later; keys typed before that
    /// are inserted as plain letters without composition. The field editor is
    /// kept for the field's lifetime, so this is paid once, not per search.
    @discardableResult
    func beginEditing(in panel: NSWindow) -> Bool {
        let start = ContinuousClock.now
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        var ready = waitUntilReady(in: panel)
        var path = "activate"
        if !ready {
            // Cooperative activation (macOS 14+) can be declined when another
            // app owns the user's attention. It was granted on every call in
            // the app-hosted tests, so this path has not been observed taken.
            // `activate(ignoringOtherApps:)` is the legacy forced path; the
            // `NSRunningApplication` option of the same name is documented as
            // having no effect since macOS 14.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(field)
            ready = waitUntilReady(in: panel)
            path = "activate(ignoringOtherApps:)"
        }
        let elapsed = start.duration(to: .now)
        log.notice("""
            beginEditing ready=\(ready, privacy: .public) path=\(path, privacy: .public) \
            active=\(NSApp.isActive, privacy: .public) key=\(panel.isKeyWindow, privacy: .public) \
            focused=\(self.isFocused(in: panel), privacy: .public) \
            imeContext=\(NSTextInputContext.current != nil, privacy: .public) \
            took=\(Self.milliseconds(elapsed), format: .fixed(precision: 2), privacy: .public)ms
            """)
        return ready
    }

    /// Resigns first responder and clears the text without firing
    /// `onTextChange`. The app stays active; leaving search mode is the
    /// owner's decision.
    func endEditing() {
        suppressChanges = true
        defer { suppressChanges = false }
        fieldEditor?.inputContext?.discardMarkedText()
        field.abortEditing()
        field.stringValue = ""
        lastReported = ""
    }

    // MARK: - NSTextFieldDelegate

    /// Committed-text changes arrive here; marked-text changes do not post
    /// `textDidChange`, so the field editor reports those separately.
    func controlTextDidChange(_ notification: Notification) {
        reportTextIfChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let command: Command
        switch selector {
        case #selector(NSResponder.moveUp(_:)): command = .moveUp
        case #selector(NSResponder.moveDown(_:)): command = .moveDown
        case #selector(NSResponder.insertTab(_:)): command = .moveNext
        case #selector(NSResponder.insertBacktab(_:)): command = .movePrevious
        case #selector(NSResponder.insertNewline(_:)): command = .commit
        case #selector(NSResponder.cancelOperation(_:)): command = .cancel
        default: return false
        }
        // While marked text is pending, Return commits the composition and
        // Escape discards it: both belong to the IME. With Pinyin - Simplified
        // the input method consumes both inside `NSTextInputContext.handleEvent`
        // and this method is never reached (Return committed the raw letters,
        // Escape emptied the field, no log line below in any run). The guard
        // stays for input methods that pass the key through instead.
        if textView.hasMarkedText(), command == .commit || command == .cancel {
            log.notice("doCommandBy \(NSStringFromSelector(selector), privacy: .public) while composing: deferred to IME")
            return false
        }
        // The Return that entered search mode may still be held when the field
        // becomes first responder; its auto-repeat must not commit a row.
        if command == .commit, let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat {
            return true
        }
        onCommand?(command)
        return true
    }

    // MARK: - Private

    private func reportTextIfChanged() {
        guard !suppressChanges else { return }
        let current = text
        guard current != lastReported else { return }
        lastReported = current
        onTextChange?(current)
    }

    private var fieldEditor: NSTextView? {
        field.currentEditor() as? NSTextView
    }

    private func isFocused(in panel: NSWindow) -> Bool {
        guard let editor = fieldEditor else { return false }
        return panel.firstResponder === editor
    }

    private func isReady(in panel: NSWindow) -> Bool {
        isFocused(in: panel) && NSTextInputContext.current != nil
    }

    /// Activation reaches AppKit as an `.appKitDefined` event. When this runs
    /// inside a hotkey handler, a bare run-loop turn leaves that event queued
    /// and the wait times out with the app still inactive (observed: 418 ms,
    /// both activation calls declined). Only that event class is dequeued, so
    /// key and mouse events stay in the queue and nothing re-enters the owner.
    private func waitUntilReady(in panel: NSWindow) -> Bool {
        let deadline = ContinuousClock.now + Self.activationTimeout
        while !isReady(in: panel) {
            guard ContinuousClock.now < deadline else { return false }
            if let event = NSApp.nextEvent(matching: .appKitDefined, until: Date(timeIntervalSinceNow: 0.005),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        return true
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}

/// Supplies its own field editor so composition changes can be observed;
/// the window's shared editor offers no hook for marked text.
private final class SearchTextField: NSTextField {
    var onCompositionChange: (() -> Void)?

    override class var cellClass: AnyClass? {
        get { SearchTextFieldCell.self }
        set {}
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        (currentEditor() as? SearchFieldEditor)?.onCompositionChange = onCompositionChange
        return true
    }
}

private final class SearchTextFieldCell: NSTextFieldCell {
    /// One editor for the field's lifetime: a fresh editor is a fresh input
    /// context, and the input method takes ~500 ms to attach to one.
    private lazy var editor: SearchFieldEditor = {
        let editor = SearchFieldEditor(frame: .zero)
        editor.isFieldEditor = true
        editor.insertionPointColor = .controlAccentColor
        // Search terms are matched verbatim; nothing here should be corrected
        // or predicted behind the user's back.
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor
    }
}

private final class SearchFieldEditor: NSTextView {
    var onCompositionChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionChange?()
    }
}
