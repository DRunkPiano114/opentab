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

    /// keymap.md §2 records the shipped values; the recorder writes the same
    /// shape, so a drift here is a silently different default hotkey.
    func testDefaultsAreTheMeasuredValues() {
        XCTAssertEqual(HotKeyBinding.mainDefault.keyCode, 48)
        XCTAssertEqual(HotKeyBinding.mainDefault.carbonModifiers, 2048)
        XCTAssertEqual(HotKeyBinding.reverseDefault.carbonModifiers, 2560)
        XCTAssertEqual(HotKeyBinding.searchDefault.keyCode, 37)
        XCTAssertEqual(HotKeyBinding.searchDefault.carbonModifiers, 768)
    }

    func testDisplayStringOrdersModifiersLikeTheSystemDoes() {
        let all = HotKeyBinding(keyCode: UInt32(kVK_ANSI_L),
                                carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(all.displayString, "\u{2303}\u{2325}\u{21E7}\u{2318}L")
        XCTAssertEqual(HotKeyBinding.mainDefault.displayString, "\u{2325}\u{21E5}")
    }

    /// An unusable chord must not reach the Carbon layer: `configure` keeps
    /// the default instead of binding something that cannot work.
    func testCentreRejectsAChordWithNoHoldModifier() {
        let centre = HotKeyCenter()
        let unusable = HotKeyBinding(keyCode: UInt32(kVK_F13), carbonModifiers: 0)
        centre.configure(main: unusable, reverse: .reverseDefault, search: .searchDefault)
        XCTAssertEqual(centre.persistentChords.first, HotKeyBinding.mainDefault)

        let usable = HotKeyBinding(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey))
        centre.configure(main: usable, reverse: .reverseDefault, search: .searchDefault)
        XCTAssertEqual(centre.persistentChords.first, usable)
    }
}
