import Carbon
import XCTest
@testable import OpenTab

@MainActor
final class HotKeyBindingTests: XCTestCase {
    /// The panel is dismissed by the release of the modifier that opened it.
    /// A chord with none of the modifiers the monitors watch would open the
    /// panel and commit it in the same instant.
    func testHoldModifierIsTheOneTheMonitorsWatch() {
        XCTAssertEqual(HotKeyBinding.mainDefault.hold, .option)
        XCTAssertEqual(HotKeyBinding(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(cmdKey)).hold, .command)
        XCTAssertEqual(HotKeyBinding(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey)).hold, .control)
        XCTAssertNil(HotKeyBinding(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(shiftKey)).hold,
                     "shift is the reverse-direction modifier, never the hold")
        XCTAssertFalse(HotKeyBinding(keyCode: UInt32(kVK_F13), carbonModifiers: 0).isUsableAsHoldChord)
    }

    func testStorageRoundTripsAndRejectsRubbish() {
        let binding = HotKeyBinding(keyCode: 48, carbonModifiers: 2048)
        XCTAssertEqual(HotKeyBinding(stored: binding.stored), binding)
        XCTAssertNil(HotKeyBinding(stored: nil))
        XCTAssertNil(HotKeyBinding(stored: ["keyCode": 48]))
        XCTAssertNil(HotKeyBinding(stored: "48"))
    }

    /// These are the shipped defaults; the recorder writes the same shape, so
    /// a drift here is a silently different default hotkey.
    func testDefaultsAreTheMeasuredValues() {
        XCTAssertEqual(HotKeyBinding.mainDefault.keyCode, 48)
        XCTAssertEqual(HotKeyBinding.mainDefault.carbonModifiers, 2048)
        XCTAssertEqual(HotKeyBinding.reverseDefault.carbonModifiers, 2560)
        XCTAssertEqual(HotKeyBinding.searchDefault.keyCode, 37)
        XCTAssertEqual(HotKeyBinding.searchDefault.carbonModifiers, 768)
    }

    /// Modifier glyphs in the system's order, the key as a word where it has
    /// one, and one thin space between every pair of tokens.
    func testDisplayStringOrdersModifiersLikeTheSystemAndSeparatesTokensWithThinSpaces() {
        let all = HotKeyBinding(keyCode: UInt32(kVK_ANSI_L),
                                carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(all.displayString, "\u{2303}\u{2009}\u{2325}\u{2009}\u{21E7}\u{2009}\u{2318}\u{2009}L")
        XCTAssertEqual(HotKeyBinding(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(optionKey)).displayString,
                       "\u{2325}\u{2009}Tab")
        XCTAssertEqual(HotKeyBinding(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(cmdKey | shiftKey)).displayString,
                       "\u{21E7}\u{2009}\u{2318}\u{2009}Tab")
        XCTAssertEqual(HotKeyBinding(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey)).displayString,
                       "\u{2318}\u{2009}Space")
    }

    /// Only the two chords the window server owns need it taken over; a chord
    /// that merely contains Command is an ordinary global hotkey.
    func testCmdTabChordsAreTheOnesTheTakeoverCovers() {
        XCTAssertTrue(HotKeyBinding.cmdTab.needsSymbolicHotKeyTakeover)
        XCTAssertTrue(HotKeyBinding.cmdShiftTab.needsSymbolicHotKeyTakeover)
        XCTAssertFalse(HotKeyBinding.optionTab.needsSymbolicHotKeyTakeover)
        XCTAssertFalse(HotKeyBinding.searchDefault.needsSymbolicHotKeyTakeover)
        XCTAssertFalse(HotKeyBinding(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey)).needsSymbolicHotKeyTakeover)
        XCTAssertFalse(HotKeyBinding(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(controlKey | cmdKey))
            .needsSymbolicHotKeyTakeover)
        XCTAssertFalse(HotKeyBinding(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(optionKey | cmdKey))
            .needsSymbolicHotKeyTakeover)
    }

    func testFallbackSwapsCommandForOptionAndKeepsShift() {
        XCTAssertEqual(HotKeyBinding.cmdTab.withoutTakeover(), .optionTab)
        XCTAssertEqual(HotKeyBinding.cmdShiftTab.withoutTakeover(), .optionShiftTab)
        XCTAssertEqual(HotKeyBinding.optionTab.withoutTakeover(), .optionTab)
        let cmdShiftL = HotKeyBinding(keyCode: UInt32(kVK_ANSI_L), carbonModifiers: UInt32(cmdKey | shiftKey))
        XCTAssertEqual(cmdShiftL.withoutTakeover(), cmdShiftL)
        let controlCmdTab = HotKeyBinding(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(controlKey | cmdKey))
        XCTAssertEqual(controlCmdTab.withoutTakeover(), controlCmdTab)
    }

    /// An unusable chord must not reach the Carbon layer: `configure` binds
    /// Option-Tab instead of something that cannot work.
    func testCentreRejectsAChordWithNoHoldModifier() {
        let centre = HotKeyCenter()
        let unusable = HotKeyBinding(keyCode: UInt32(kVK_F13), carbonModifiers: 0)
        centre.configure(main: unusable, reverse: .reverseDefault, search: .searchDefault)
        XCTAssertEqual(centre.persistentChords.first, HotKeyBinding.optionTab)

        let usable = HotKeyBinding(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey))
        centre.configure(main: usable, reverse: .reverseDefault, search: .searchDefault)
        XCTAssertEqual(centre.persistentChords.first, usable)
    }
}
