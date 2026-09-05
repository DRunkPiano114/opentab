import XCTest
@testable import OpenTabWS

final class TakeoverPolicyTests: XCTestCase {
    private let bools = [false, true]

    func testOnlyWantedTrustedAvailableAndAloneEnables() {
        for wanted in bools {
            for trusted in bools {
                for available in bools {
                    for other in bools {
                        let policy = TakeoverPolicy.resolve(wanted: wanted, trusted: trusted,
                                                            available: available, otherInstanceRunning: other)
                        XCTAssertEqual(policy.isEnabled, wanted && trusted && available && !other,
                                       "wanted=\(wanted) trusted=\(trusted) available=\(available) other=\(other)")
                    }
                }
            }
        }
    }

    /// The revoke case: the grant goes away while everything else still holds.
    func testMissingGrantDisablesEvenWhenAvailable() {
        XCTAssertEqual(TakeoverPolicy.resolve(wanted: true, trusted: false, available: true,
                                              otherInstanceRunning: false), .untrusted)
    }

    func testMissingSymbolOutranksEverything() {
        for trusted in bools {
            for other in bools {
                XCTAssertEqual(TakeoverPolicy.resolve(wanted: true, trusted: trusted, available: false,
                                                      otherInstanceRunning: other), .unavailable,
                               "trusted=\(trusted) other=\(other)")
            }
        }
    }

    func testAnotherRunningCopyNeverTakesOver() {
        for trusted in bools {
            XCTAssertEqual(TakeoverPolicy.resolve(wanted: true, trusted: trusted, available: true,
                                                  otherInstanceRunning: true), .otherInstance,
                           "trusted=\(trusted)")
        }
    }

    func testNotWantedNeedsNoReason() {
        for trusted in bools {
            for available in bools {
                for other in bools {
                    XCTAssertEqual(TakeoverPolicy.resolve(wanted: false, trusted: trusted, available: available,
                                                          otherInstanceRunning: other), .notWanted,
                                   "trusted=\(trusted) available=\(available) other=\(other)")
                }
            }
        }
    }
}
