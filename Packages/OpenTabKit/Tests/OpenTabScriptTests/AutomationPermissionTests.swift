import XCTest
@testable import OpenTabScript

final class AutomationPermissionTests: XCTestCase {
    private let healthy = BundleAutomationConfig(usageDescription: "OpenTab lists your browser tabs.",
                                                 hasAppleEventsEntitlement: true)

    func testSelfCheckNamesEveryMissingPiece() {
        XCTAssertEqual(AutomationSelfCheck.defects(in: healthy), [])
        XCTAssertEqual(AutomationSelfCheck.defects(in: .init(usageDescription: nil,
                                                             hasAppleEventsEntitlement: true)),
                       [.missingUsageDescription])
        XCTAssertEqual(AutomationSelfCheck.defects(in: .init(usageDescription: "",
                                                             hasAppleEventsEntitlement: false)),
                       [.missingUsageDescription, .missingEntitlement])
    }

    /// -1743 has three indistinguishable causes. Our own bundle is checked first
    /// so a build mistake is never reported to the user as their own refusal.
    func testDeniedWithABrokenBundleIsOurBugNotAUserRefusal() {
        let broken = BundleAutomationConfig(usageDescription: nil, hasAppleEventsEntitlement: false)
        XCTAssertEqual(AutomationSelfCheck.guidance(for: .denied, config: broken,
                                                    hasRequestedBefore: true),
                       .fixBundle([.missingUsageDescription, .missingEntitlement]))
        XCTAssertEqual(AutomationSelfCheck.guidance(for: .denied, config: healthy,
                                                    hasRequestedBefore: true),
                       .userDenied)
    }

    /// -1744 cannot tell "never asked" from "asked and refused", so our own
    /// record of having asked decides.
    func testUndeterminedResolvesThroughOurOwnRequestRecord() {
        XCTAssertEqual(AutomationSelfCheck.guidance(for: .undetermined, config: healthy,
                                                    hasRequestedBefore: false),
                       .requestFromUser)
        XCTAssertEqual(AutomationSelfCheck.guidance(for: .undetermined, config: healthy,
                                                    hasRequestedBefore: true),
                       .userDenied)
    }

    func testAuthorizedIsReadyEvenBeforeTheSelfCheck() {
        XCTAssertEqual(AutomationSelfCheck.guidance(for: .authorized,
                                                    config: .init(usageDescription: nil,
                                                                  hasAppleEventsEntitlement: false),
                                                    hasRequestedBefore: false),
                       .ready)
    }

    func testTransientStatusesAskTheCallerToRetry() {
        for status in [AutomationStatus.targetNotRunning, .timedOut, .failed(-1712)] {
            XCTAssertEqual(AutomationSelfCheck.guidance(for: status, config: healthy,
                                                        hasRequestedBefore: true),
                           .retryLater)
        }
    }

    func testStatusCodeClassification() {
        XCTAssertEqual(AutomationPermission.classify(noErr), .authorized)
        XCTAssertEqual(AutomationPermission.classify(-1743), .denied)
        XCTAssertEqual(AutomationPermission.classify(-1744), .undetermined)
        XCTAssertEqual(AutomationPermission.classify(-600), .targetNotRunning)
        XCTAssertEqual(AutomationPermission.classify(-25211), .failed(-25211))
    }

    func testRequestLogRemembersEachTargetOnce() throws {
        // The suite name is a path, so the plist lands in the temp directory rather
        // than ~/Library/Preferences, where cfprefsd leaves an empty one per test.
        let suite = FileManager.default.temporaryDirectory
            .appending(path: "opentab.tests.\(UUID().uuidString)").path
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: URL(filePath: suite + ".plist"))
        }
        let log = DefaultsAutomationRequestLog(defaults: defaults)

        XCTAssertFalse(log.hasRequested("com.google.Chrome"))
        log.markRequested("com.google.Chrome")
        log.markRequested("com.google.Chrome")
        XCTAssertTrue(log.hasRequested("com.google.Chrome"))
        XCTAssertFalse(log.hasRequested("com.apple.Safari"))
        XCTAssertEqual(defaults.stringArray(forKey: "automation.requested"), ["com.google.Chrome"])
    }

    func testAutomationPaneDeepLink() {
        XCTAssertEqual(AutomationSettings.automationPane.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }
}
