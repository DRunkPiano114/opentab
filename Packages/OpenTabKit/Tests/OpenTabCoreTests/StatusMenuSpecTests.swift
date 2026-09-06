import XCTest
@testable import OpenTabCore

final class StatusMenuSpecTests: XCTestCase {
    private typealias Item = StatusMenuSpec.Item
    private typealias Condition = StatusMenuSpec.Condition
    private typealias KeyEquivalent = StatusMenuSpec.KeyEquivalent

    private func healthy() -> StatusMenuSpec.Inputs {
        var inputs = StatusMenuSpec.Inputs()
        inputs.hasUpdater = true
        return inputs
    }

    private func hasAttentionRow(_ items: [Item]) -> Bool {
        for case .attention in items { return true }
        return false
    }

    private func titles(_ items: [Item]) -> [String] {
        var titles: [String] = []
        for item in items {
            switch item {
            case let .action(_, title, _, _):
                titles.append(title)
            case let .attention(title, conditions):
                titles.append(title)
                titles.append(contentsOf: conditions.map(\.title))
            case .separator:
                break
            }
        }
        return titles
    }

    func testHealthyMenuIsTheFixedListInOrder() {
        let expected: [Item] = [
            .action(.openSwitcher, title: "Open Switcher", keyEquivalent: nil, isEnabled: true),
            .action(.searchWindows, title: "Search Windows", keyEquivalent: nil, isEnabled: true),
            .separator,
            .action(.about, title: "About OpenTab", keyEquivalent: nil, isEnabled: true),
            .action(.checkForUpdates, title: "Check for Updates\u{2026}", keyEquivalent: nil, isEnabled: true),
            .separator,
            .action(.settings, title: "Settings\u{2026}", keyEquivalent: nil, isEnabled: true),
            .separator,
            .action(.quit, title: "Quit", keyEquivalent: nil, isEnabled: true),
        ]
        XCTAssertEqual(StatusMenuSpec.items(healthy()), expected)
    }

    func testHealthyMenuHasNoAttentionRowAndNoLeadingSeparator() {
        let items = StatusMenuSpec.items(healthy())
        XCTAssertEqual(items.first, .action(.openSwitcher, title: "Open Switcher",
                                            keyEquivalent: nil, isEnabled: true))
        XCTAssertFalse(hasAttentionRow(items))
    }

    func testEachConditionAloneMakesOneClickableRow() {
        let cases: [(String, StatusMenuSpec.Action, (inout StatusMenuSpec.Inputs) -> Void)] = [
            ("Accessibility Is Not Granted", .openAccessibilitySettings, { $0.accessibilityGranted = false }),
            ("Another Copy of OpenTab Is Running", .openShortcutsTab, { $0.otherInstanceRunning = true }),
            ("\u{2318}\u{2009}Tab Is Not Available on This Mac", .openShortcutsTab, { $0.takeoverUnavailable = true }),
            ("Some Windows Are Matched Less Precisely", .openPrivacyTab, { $0.windowIDBridgeAvailable = false }),
            ("Secure Input Is Blocking Shortcuts", .openShortcutsTab, { $0.secureInputActive = true }),
            ("Safari Tabs Need Automation Access", .openAutomationSettings, { $0.tabsUnavailable = ["Safari"] }),
        ]
        for (title, action, degrade) in cases {
            var inputs = healthy()
            degrade(&inputs)
            let items = StatusMenuSpec.items(inputs)
            XCTAssertEqual(items.first, .attention(title: title, conditions: [Condition(title: title, action: action)]))
            XCTAssertEqual(items.dropFirst().first, .separator)
        }
    }

    func testSeveralConditionsAreListedUnderTheWorst() {
        var inputs = healthy()
        inputs.accessibilityGranted = false
        inputs.secureInputActive = true
        inputs.tabsUnavailable = ["Safari", "Chrome"]
        let expected = [
            Condition(title: "Accessibility Is Not Granted", action: .openAccessibilitySettings),
            Condition(title: "Secure Input Is Blocking Shortcuts", action: .openShortcutsTab),
            Condition(title: "Safari Tabs Need Automation Access", action: .openAutomationSettings),
            Condition(title: "Chrome Tabs Need Automation Access", action: .openAutomationSettings),
        ]
        XCTAssertEqual(StatusMenuSpec.items(inputs).first,
                       .attention(title: "Accessibility Is Not Granted", conditions: expected))
    }

    func testAwaitingRequestIsNotDegraded() {
        var inputs = healthy()
        inputs.tabsAwaitingRequest = ["Chrome"]
        XCTAssertEqual(StatusMenuSpec.conditions(inputs), [])
        XCTAssertFalse(hasAttentionRow(StatusMenuSpec.items(inputs)))
    }

    func testNoUpdaterOmitsCheckForUpdatesAndLeavesNoEmptyGroup() {
        var inputs = healthy()
        inputs.hasUpdater = false
        let items = StatusMenuSpec.items(inputs)
        XCTAssertFalse(items.contains { item in
            if case let .action(action, _, _, _) = item { action == .checkForUpdates } else { false }
        })
        for (first, second) in zip(items, items.dropFirst()) {
            XCTAssertFalse(first == .separator && second == .separator, "a group with no rows draws two rules")
        }
    }

    func testCheckForUpdatesIsDisabledWhileACheckIsRunning() {
        var inputs = healthy()
        inputs.canCheckForUpdates = false
        XCTAssertEqual(StatusMenuSpec.items(inputs).first { item in
            if case let .action(action, _, _, _) = item { action == .checkForUpdates } else { false }
        }, .action(.checkForUpdates, title: "Check for Updates\u{2026}", keyEquivalent: nil, isEnabled: false))
    }

    func testSwitcherItemsCarryTheBoundChords() {
        var inputs = healthy()
        let main = KeyEquivalent(key: "\t", command: true)
        let search = KeyEquivalent(key: "l", command: true, shift: true)
        inputs.mainShortcut = main
        inputs.searchShortcut = search
        let items = StatusMenuSpec.items(inputs)
        XCTAssertEqual(items[0], .action(.openSwitcher, title: "Open Switcher",
                                         keyEquivalent: main, isEnabled: true))
        XCTAssertEqual(items[1], .action(.searchWindows, title: "Search Windows",
                                         keyEquivalent: search, isEnabled: true))

        let unbound = StatusMenuSpec.items(healthy())
        XCTAssertEqual(unbound[0], .action(.openSwitcher, title: "Open Switcher",
                                           keyEquivalent: nil, isEnabled: true))
        XCTAssertEqual(unbound[1], .action(.searchWindows, title: "Search Windows",
                                           keyEquivalent: nil, isEnabled: true))
    }

    func testNothingAboutFaviconsOrTabEnablingRemains() {
        var inputs = healthy()
        inputs.tabsAwaitingRequest = ["Google Chrome"]
        let drawn = titles(StatusMenuSpec.items(inputs))
        for gone in ["Favicon", "Safari", "Google", "Enable Tabs"] {
            XCTAssertFalse(drawn.contains { $0.contains(gone) }, gone)
        }
    }
}
