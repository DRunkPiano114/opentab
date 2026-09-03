import XCTest
@testable import OpenTab

@MainActor
final class OnboardingTests: XCTestCase {
    /// The Accessibility grant lands without a relaunch, so the flow must
    /// notice it and move on by itself. Telling the user to quit and reopen
    /// would be inventing a restriction macOS does not impose.
    func testAccessibilityStepAdvancesItselfWhenTheGrantLands() {
        let model = OnboardingModel()
        model.advance()
        model.advance()
        XCTAssertEqual(model.step, .accessibility)

        model.accessibilityChanged(true)
        XCTAssertEqual(model.step, .shortcuts)
    }

    func testAccessibilityStepDoesNotOfferAWayPast() {
        let model = OnboardingModel()
        model.advance()
        model.advance()
        XCTAssertEqual(model.step, .accessibility)
        XCTAssertFalse(model.canAdvance)

        model.advance()
        XCTAssertEqual(model.step, .accessibility, "nothing after this step works without the grant")
    }

    /// A grant that arrives before the user reaches the step must not skip
    /// past whatever step they are on.
    func testAGrantOnAnEarlierStepDoesNotJumpTheFlow() {
        let model = OnboardingModel()
        model.accessibilityChanged(true)
        XCTAssertEqual(model.step, .welcome)
        XCTAssertTrue(model.accessibilityGranted)

        model.advance()
        model.advance()
        XCTAssertEqual(model.step, .accessibility)
        XCTAssertTrue(model.canAdvance)
    }

    func testFlowRunsToTheEndAndStopsThere() {
        let model = OnboardingModel()
        model.accessibilityChanged(true)
        for _ in 0..<10 { model.advance() }
        XCTAssertEqual(model.step, .done)
        XCTAssertTrue(model.isLast)
    }

    func testBackStopsAtTheFirstStep() {
        let model = OnboardingModel()
        model.back()
        XCTAssertEqual(model.step, .welcome)
    }
}
