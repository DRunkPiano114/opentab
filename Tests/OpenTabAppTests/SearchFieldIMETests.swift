import AppKit
import ApplicationServices
import Carbon
import OpenTabCore
import XCTest
import os
@testable import OpenTab

/// Drives the real search field with synthetic HID key events under the
/// Pinyin - Simplified input method, inside the signed app that carries the
/// Accessibility grant. Every key press is gated on this process owning the
/// keyboard (active app, key panel, field editor first responder), because a
/// synthetic keystroke posted while another app is frontmost would be typed
/// into that app.
@MainActor
final class SearchFieldIMETests: XCTestCase {
    private static let pinyinID = "com.apple.inputmethod.SCIM.ITABC"
    private static let usID = "com.apple.keylayout.US"

    private enum Key {
        static let a: CGKeyCode = 0
        static let b: CGKeyCode = 11
        static let c: CGKeyCode = 8
        static let h: CGKeyCode = 4
        static let i: CGKeyCode = 34
        static let n: CGKeyCode = 45
        static let o: CGKeyCode = 31
        static let space: CGKeyCode = 49
        static let tab: CGKeyCode = 48
        static let `return`: CGKeyCode = 36
        static let escape: CGKeyCode = 53
        static let downArrow: CGKeyCode = 125
        static let upArrow: CGKeyCode = 126
    }

    private struct SetupFailure: Error {}

    private var panel: SwitcherPanel!
    private var controller: SearchFieldController!
    private var previousApp: NSRunningApplication?
    private var originalSource: TISInputSource?
    private var changes: [String] = []
    private var commands: [SearchFieldController.Command] = []
    private let log = Log.make("search-test")

    override func setUp() async throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs the Accessibility grant")
        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        originalSource = original
        if Self.identifier(of: original) != Self.pinyinID {
            guard let pinyin = Self.enabledSource(id: Self.pinyinID) else {
                throw XCTSkip("Pinyin - Simplified (\(Self.pinyinID)) is not enabled")
            }
            try select(pinyin)
        }
        previousApp = NSWorkspace.shared.frontmostApplication

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 300, height: 60)
        panel = SwitcherPanel(contentRect: NSRect(x: screen.midX - size.width / 2,
                                                  y: screen.midY - size.height / 2,
                                                  width: size.width, height: size.height))
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.04, alpha: 1).cgColor
        panel.contentView = content

        controller = SearchFieldController()
        controller.view.frame = NSRect(x: 14, y: 18, width: size.width - 28, height: 24)
        content.addSubview(controller.view)
        controller.onTextChange = { [weak self] text in self?.changes.append(text) }
        controller.onCommand = { [weak self] command in self?.commands.append(command) }

        let started = ContinuousClock.now
        let ready = controller.beginEditing(in: panel)
        log.notice("beginEditing ready=\(ready, privacy: .public) took=\(Self.milliseconds(started.duration(to: .now)), format: .fixed(precision: 2), privacy: .public)ms")
        guard ready else {
            XCTFail("beginEditing did not make the field IME-ready: active=\(NSApp.isActive) key=\(panel.isKeyWindow)")
            throw SetupFailure()
        }
        try requireKeyboardOwnership()
        try primeInputMethod()
    }

    override func tearDown() async throws {
        controller?.endEditing()
        panel?.orderOut(nil)
        panel?.close()
        if let originalSource,
           Self.identifier(of: TISCopyCurrentKeyboardInputSource().takeRetainedValue()) != Self.identifier(of: originalSource) {
            try? select(originalSource)
        }
        if let previousApp {
            _ = previousApp.activate(options: [])
            let deadline = ContinuousClock.now + .seconds(2)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != previousApp.processIdentifier,
                  ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: - Composition

    func testPinyinComposesAndCommitsWithSpace() throws {
        try press(Key.n, Key.i, Key.h, Key.a, Key.o, Key.space)
        XCTAssertEqual(controller.text, "你好")
        XCTAssertFalse(controller.hasMarkedText)
        XCTAssertEqual(changes.last, "你好")
        XCTAssertGreaterThanOrEqual(changes.count, 2, "composition must report changes before the commit")
        let composing = changes.dropLast()
        for (previous, next) in zip(composing, composing.dropFirst()) {
            XCTAssertGreaterThan(next.count, previous.count, "composition must grow: \(changes)")
        }
        for (previous, next) in zip(changes, changes.dropFirst()) {
            XCTAssertNotEqual(previous, next, "identical consecutive values must be reported once: \(changes)")
        }
    }

    func testMarkedTextAdvancesDuringComposition() throws {
        var sequence: [String] = []
        try press(Key.n)
        sequence.append(markedString())
        try press(Key.i)
        sequence.append(markedString())
        log.notice("marked text sequence=\(sequence.joined(separator: " -> "), privacy: .public)")
        XCTAssertTrue(controller.hasMarkedText)
        XCTAssertFalse(sequence[0].isEmpty, "marked text must appear after the first letter")
        XCTAssertGreaterThan(sequence[1].count, sequence[0].count, "marked text must grow with each letter")
    }

    func testReturnDuringCompositionIsNotACommitCommand() throws {
        try press(Key.n, Key.i, Key.h, Key.a, Key.o)
        XCTAssertTrue(controller.hasMarkedText)
        try press(Key.return)
        log.notice("return during composition committed=\(self.controller.text == "你好" ? "candidate" : "raw letters", privacy: .public) commands=\(String(describing: self.commands), privacy: .public)")
        XCTAssertFalse(commands.contains(.commit), "Return while composing belongs to the IME")
        XCTAssertFalse(controller.hasMarkedText)
        XCTAssertFalse(controller.text.isEmpty, "Return must have committed either the candidate or the raw letters")
    }

    func testEscapeDuringCompositionIsNotACancelCommand() throws {
        try press(Key.n, Key.i)
        XCTAssertTrue(controller.hasMarkedText)
        try press(Key.escape)
        XCTAssertFalse(commands.contains(.cancel), "Escape while composing belongs to the IME")
        XCTAssertFalse(controller.hasMarkedText)
        XCTAssertEqual(controller.text, "")
    }

    func testSettingTextDiscardsComposition() throws {
        try press(Key.n, Key.i)
        XCTAssertTrue(controller.hasMarkedText)
        let reported = changes.count
        controller.text = ""
        settle(0.1)
        XCTAssertFalse(controller.hasMarkedText)
        XCTAssertEqual(controller.text, "")
        XCTAssertEqual(changes.count, reported, "setting text must not fire onTextChange: \(changes)")
    }

    // MARK: - Commands

    func testReturnWithoutCompositionCommits() throws {
        try press(Key.return)
        XCTAssertEqual(commands, [.commit])
        try press(Key.n, Key.i, Key.h, Key.a, Key.o, Key.space)
        try press(Key.return)
        XCTAssertEqual(commands, [.commit, .commit])
        XCTAssertEqual(controller.text, "你好")
    }

    func testAutoRepeatedReturnIsIgnored() throws {
        try press(Key.return, autorepeat: true)
        XCTAssertEqual(commands, [], "a held Return's auto-repeat must not commit")
        try press(Key.return)
        XCTAssertEqual(commands, [.commit], "a fresh Return must still commit")
    }

    func testEscapeWithoutCompositionCancels() throws {
        try press(Key.escape)
        XCTAssertEqual(commands, [.cancel])
    }

    func testArrowsAndTabAreCommands() throws {
        try press(Key.downArrow)
        try press(Key.upArrow)
        try press(Key.tab)
        try press(Key.tab, flags: .maskShift)
        XCTAssertEqual(commands, [.moveDown, .moveUp, .moveNext, .movePrevious])
        XCTAssertEqual(controller.text, "")
    }

    // MARK: - Delivery

    func testNoDoubleDelivery() throws {
        let pinyin = try XCTUnwrap(Self.enabledSource(id: Self.pinyinID))
        let us = try XCTUnwrap(Self.enabledSource(id: Self.usID), "U.S. layout is not enabled")
        try select(us)
        defer { try? select(pinyin) }
        settle(0.3)
        try press(Key.a, Key.b, Key.c)
        XCTAssertEqual(controller.text, "abc")
        XCTAssertFalse(controller.hasMarkedText)
    }

    // MARK: - Focus

    func testBeginEditingReportsIMEContext() {
        XCTAssertTrue(controller.beginEditing(in: panel))
        XCTAssertNotNil(NSTextInputContext.current)
        controller.endEditing()
        XCTAssertTrue(NSApp.isActive)
        XCTAssertNil(controller.view.currentEditor())
        XCTAssertFalse(panel.firstResponder is NSTextView)
        XCTAssertEqual(controller.text, "")
    }

    /// The real flow: search, leave, search again. The field editor and its
    /// input context are kept, so the second entry must compose at once.
    func testCompositionSurvivesReEntry() throws {
        controller.endEditing()
        XCTAssertTrue(controller.beginEditing(in: panel))
        try press(Key.n)
        XCTAssertTrue(controller.hasMarkedText, "the first key after re-entry must compose")
        XCTAssertEqual(changes, ["n"])
    }

    func testCaretUsesAccentColour() throws {
        let editor = try XCTUnwrap(controller.view.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.insertionPointColor, .controlAccentColor)
    }

    func testCandidateWindowIsPositionedOnScreen() throws {
        try press(Key.n)
        let editor = try XCTUnwrap(controller.view.currentEditor() as? NSTextView)
        let rect = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        log.notice("firstRect=\(NSStringFromRect(rect), privacy: .public) panel=\(NSStringFromRect(self.panel.frame), privacy: .public)")
        XCTAssertGreaterThan(rect.width, 0, "the range must cover the marked text, or the check is vacuous")
        XCTAssertGreaterThan(rect.height, 0)
        XCTAssertTrue(panel.frame.contains(rect), "firstRect must be in screen coordinates inside the panel")
    }

    // MARK: - Keyboard

    /// The input method attaches to a fresh input context a few hundred
    /// milliseconds after activation; keys before that are inserted as plain
    /// letters. Types a probe letter until the IME composes it, then discards
    /// the probe so every test starts from an empty, composing field.
    private func primeInputMethod() throws {
        let started = ContinuousClock.now
        settle(0.5)
        var probes = 0
        while !controller.hasMarkedText {
            guard probes < 20 else {
                XCTFail("input method never started composing; text=\(controller.text.count) chars")
                throw SetupFailure()
            }
            probes += 1
            try press(Key.n)
        }
        controller.text = ""
        settle(0.1)
        changes = []
        commands = []
        log.notice("input method warm-up probes=\(probes, privacy: .public) took=\(Self.milliseconds(started.duration(to: .now)), format: .fixed(precision: 0), privacy: .public)ms")
        guard controller.text.isEmpty, !controller.hasMarkedText else {
            XCTFail("probe was not discarded: marked=\(controller.hasMarkedText) text=\(controller.text.count) chars")
            throw SetupFailure()
        }
    }

    /// Posts keyDown+keyUp for each key at the HID tap, then lets the run loop
    /// turn so the input method can react.
    private func press(_ keys: CGKeyCode..., flags: CGEventFlags = [], autorepeat: Bool = false) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        for key in keys {
            try requireKeyboardOwnership()
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            else { throw SetupFailure() }
            down.flags = flags
            up.flags = flags
            if autorepeat {
                down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            settle(0.08)
        }
    }

    /// Keyboard focus is judged by the AX server's system-wide focused
    /// application, which is independent of this process. `NSApp.isActive`
    /// is AppKit's own opinion, and `NSWorkspace.frontmostApplication` is
    /// LaunchServices' view that never reported this test host at all.
    private func requireKeyboardOwnership() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let deadline = ContinuousClock.now + .milliseconds(500)
        while Self.systemFocusedPid() != pid, ContinuousClock.now < deadline {
            settle(0.02)
        }
        let focusedPid = Self.systemFocusedPid()
        let editorFocused = (controller.view.currentEditor()).map { panel.firstResponder === $0 } ?? false
        guard NSApp.isActive, panel.isKeyWindow, focusedPid == pid, editorFocused else {
            XCTFail("""
                refusing to post keys: active=\(NSApp.isActive) key=\(panel.isKeyWindow) \
                axFocusedPid=\(focusedPid.map(String.init) ?? "nil") pid=\(pid) \
                workspaceFront=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") \
                editorFocused=\(editorFocused)
                """)
            throw SetupFailure()
        }
    }

    private static func systemFocusedPid() -> pid_t? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(value as! AXUIElement, &pid) == .success else { return nil }
        return pid
    }

    /// Turns the run loop with event dispatch. The tests run inside
    /// `NSApp.run()`'s own dispatch, and a nested `RunLoop.run` never dequeues
    /// `NSEvent`s: posted keystrokes would sit in the queue until the test
    /// returned. `nextEvent` blocks in the run loop while it waits, so the
    /// input method's replies are serviced as well.
    private func settle(_ seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            guard let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) else { break }
            NSApp.sendEvent(event)
        }
    }

    private func markedString() -> String {
        guard let editor = controller.view.currentEditor() as? NSTextView, editor.hasMarkedText() else { return "" }
        let range = editor.markedRange()
        let full = editor.string as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= full.length else { return "" }
        return full.substring(with: range)
    }

    // MARK: - Input sources

    private static func identifier(of source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func enabledSource(id: String) -> TISInputSource? {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first { identifier(of: $0) == id }
    }

    private func select(_ source: TISInputSource) throws {
        let status = TISSelectInputSource(source)
        guard status == noErr else {
            XCTFail("TISSelectInputSource(\(Self.identifier(of: source))) status=\(status)")
            throw SetupFailure()
        }
        settle(0.15)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
