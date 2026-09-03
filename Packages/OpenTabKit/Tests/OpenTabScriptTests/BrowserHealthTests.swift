import XCTest
@testable import OpenTabScript

final class BrowserHealthTests: XCTestCase {
    func testHealthyTargetIsNeverSkipped() {
        let health = BrowserHealth()
        XCTAssertFalse(health.isCoolingDown("com.google.Chrome"))
    }

    func testBackoffDoublesAndIsCapped() {
        let health = BrowserHealth(base: .seconds(2), cap: .seconds(8))
        let start = ContinuousClock.now

        health.recordFailure("chrome", now: start)
        XCTAssertTrue(health.isCoolingDown("chrome", now: start.advanced(by: .milliseconds(1900))))
        XCTAssertFalse(health.isCoolingDown("chrome", now: start.advanced(by: .seconds(3))))

        health.recordFailure("chrome", now: start)
        XCTAssertTrue(health.isCoolingDown("chrome", now: start.advanced(by: .seconds(3))))

        for _ in 0..<10 { health.recordFailure("chrome", now: start) }
        XCTAssertTrue(health.isCoolingDown("chrome", now: start.advanced(by: .seconds(7))))
        XCTAssertFalse(health.isCoolingDown("chrome", now: start.advanced(by: .seconds(9))),
                       "backoff should stop at the cap")
    }

    func testSuccessClearsTheBackoff() {
        let health = BrowserHealth()
        let start = ContinuousClock.now
        health.recordFailure("chrome", now: start)
        health.recordSuccess("chrome")
        XCTAssertFalse(health.isCoolingDown("chrome", now: start))
    }

    func testTargetsAreTrackedIndependently() {
        let health = BrowserHealth()
        let start = ContinuousClock.now
        health.recordFailure("chrome", now: start)
        XCTAssertFalse(health.isCoolingDown("safari", now: start))
    }
}
