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
        inputs.windowIDBridgeAvailable = false
        inputs.tabsUnavailable = ["Safari", "Chrome"]
        let expected = [
            Condition(title: "Accessibility Is Not Granted", action: .openAccessibilitySettings),
            Condition(title: "Some Windows Are Matched Less Precisely", action: .openPrivacyTab),
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

    private func updateItem(_ items: [Item]) -> Item? {
        items.first { item in
            if case let .action(action, _, _, _) = item { action == .checkForUpdates } else { false }
        }
    }

    func testAWaitingUpdateRetitlesTheUpdateItemInPlace() {
        var inputs = healthy()
        inputs.waitingUpdate = StatusMenuSpec.WaitingUpdate(version: "0.4.0")
        let items = StatusMenuSpec.items(inputs)
        XCTAssertEqual(items[4], .action(.checkForUpdates, title: "Update Available: 0.4.0\u{2026}",
                                         keyEquivalent: nil, isEnabled: true))
        XCTAssertEqual(items.count, StatusMenuSpec.items(healthy()).count)
    }

    func testASeenUpdateKeepsItsItem() {
        var inputs = healthy()
        inputs.waitingUpdate = StatusMenuSpec.WaitingUpdate(version: "0.4.0", seen: true)
        XCTAssertEqual(updateItem(StatusMenuSpec.items(inputs)),
                       .action(.checkForUpdates, title: "Update Available: 0.4.0\u{2026}",
                               keyEquivalent: nil, isEnabled: true))
    }

    func testAWaitingUpdateItemFollowsTheUpdaterGate() {
        var inputs = healthy()
        inputs.waitingUpdate = StatusMenuSpec.WaitingUpdate(version: "0.4.0")
        inputs.canCheckForUpdates = false
        XCTAssertEqual(updateItem(StatusMenuSpec.items(inputs)),
                       .action(.checkForUpdates, title: "Update Available: 0.4.0\u{2026}",
                               keyEquivalent: nil, isEnabled: false))
    }

    func testNoUpdaterShowsNoUpdateEvenWithAVersionSet() {
        var inputs = healthy()
        inputs.hasUpdater = false
        inputs.waitingUpdate = StatusMenuSpec.WaitingUpdate(version: "0.4.0")
        XCTAssertNil(updateItem(StatusMenuSpec.items(inputs)))
        XCTAssertEqual(StatusMenuSpec.badge(inputs), .none)
    }

    func testHealthyWithNothingWaitingHasNoBadge() {
        XCTAssertEqual(StatusMenuSpec.badge(healthy()), .none)
    }

    func testAnUnseenUpdateAloneMarksTheItem() {
        var inputs = healthy()
        inputs.waitingUpdate = StatusMenuSpec.WaitingUpdate(version: "0.4.0")
        XCTAssertEqual(StatusMenuSpec.badge(inputs), .update)
    }

    func testASeenUpdateLeavesNoMark() {
        var inputs = healthy()
        inputs.waitingUpdate = StatusMenuSpec.WaitingUpdate(version: "0.4.0", seen: true)
        XCTAssertEqual(StatusMenuSpec.badge(inputs), .none)
    }

    func testADegradationOutranksAnUnseenUpdate() {
        var inputs = healthy()
        inputs.accessibilityGranted = false
        inputs.waitingUpdate = StatusMenuSpec.WaitingUpdate(version: "0.4.0")
        XCTAssertEqual(StatusMenuSpec.badge(inputs), .attention)
    }

    func testADegradationAloneMarksTheItem() {
        var inputs = healthy()
        inputs.tabsUnavailable = ["Safari"]
        XCTAssertEqual(StatusMenuSpec.badge(inputs), .attention)
    }

    private func ready(_ version: String = "0.4.0") -> StatusMenuSpec.Inputs {
        var inputs = healthy()
        inputs.readyToInstall = version
        return inputs
    }

    func testAReadyUpdateOffersARestartInTheUpdateSlot() {
        let items = StatusMenuSpec.items(ready())
        XCTAssertEqual(items[4], .action(.restartToUpdate, title: "Restart to Update to 0.4.0",
                                         keyEquivalent: nil, isEnabled: true))
        XCTAssertEqual(items.count, StatusMenuSpec.items(healthy()).count)
        XCTAssertFalse(titles(items).contains("Check for Updates\u{2026}"))
    }

    /// Holding the downloaded update keeps the updater busy, so following its
    /// gate would leave the item disabled for good.
    func testTheRestartItemIgnoresTheUpdaterGate() {
        var inputs = ready()
        inputs.canCheckForUpdates = false
        XCTAssertEqual(StatusMenuSpec.items(inputs)[4],
                       .action(.restartToUpdate, title: "Restart to Update to 0.4.0",
                               keyEquivalent: nil, isEnabled: true))
    }

    func testAReadyUpdateWinsTheSlotOverAWaitingOne() {
        var inputs = ready("0.4.1")
        inputs.waitingUpdate = StatusMenuSpec.WaitingUpdate(version: "0.4.0")
        let items = StatusMenuSpec.items(inputs)
        XCTAssertEqual(items[4], .action(.restartToUpdate, title: "Restart to Update to 0.4.1",
                                         keyEquivalent: nil, isEnabled: true))
        XCTAssertNil(updateItem(items))
    }

    func testAReadyUpdateLeavesNoMark() {
        XCTAssertEqual(StatusMenuSpec.badge(ready()), .none)
        var inputs = ready()
        inputs.waitingUpdate = StatusMenuSpec.WaitingUpdate(version: "0.4.0")
        XCTAssertEqual(StatusMenuSpec.badge(inputs), .none, "the waiting update's item is not in the menu")
    }

    func testADegradationStillMarksTheItemWithAReadyUpdate() {
        var inputs = ready()
        inputs.accessibilityGranted = false
        XCTAssertEqual(StatusMenuSpec.badge(inputs), .attention)
    }

    func testADegradationKeepsAWaitingUpdateInItsSlot() {
        var inputs = healthy()
        inputs.accessibilityGranted = false
        inputs.waitingUpdate = StatusMenuSpec.WaitingUpdate(version: "0.4.0")
        let items = StatusMenuSpec.items(inputs)
        XCTAssertEqual(items[0], .attention(title: "Accessibility Is Not Granted", conditions: [
            Condition(title: "Accessibility Is Not Granted", action: .openAccessibilitySettings),
        ]))
        XCTAssertEqual(items[1], .separator)
        XCTAssertEqual(items[6], .action(.checkForUpdates, title: "Update Available: 0.4.0\u{2026}",
                                         keyEquivalent: nil, isEnabled: true))
        XCTAssertFalse(titles(items).contains("Check for Updates\u{2026}"))
    }

    func testADegradationKeepsAReadyUpdateInItsSlot() {
        var inputs = ready()
        inputs.tabsUnavailable = ["Safari"]
        let items = StatusMenuSpec.items(inputs)
        XCTAssertEqual(items[0], .attention(title: "Safari Tabs Need Automation Access", conditions: [
            Condition(title: "Safari Tabs Need Automation Access", action: .openAutomationSettings),
        ]))
        XCTAssertEqual(items[1], .separator)
        XCTAssertEqual(items[6], .action(.restartToUpdate, title: "Restart to Update to 0.4.0",
                                         keyEquivalent: nil, isEnabled: true))
        XCTAssertFalse(titles(items).contains("Check for Updates\u{2026}"))
    }

    func testNoUpdaterOffersNoRestart() {
        var inputs = ready()
        inputs.hasUpdater = false
        XCTAssertFalse(titles(StatusMenuSpec.items(inputs)).contains("Restart to Update to 0.4.0"))
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
