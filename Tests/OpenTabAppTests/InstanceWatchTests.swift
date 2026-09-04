import XCTest
@testable import OpenTab

final class InstanceWatchTests: XCTestCase {
    private let ownPID: pid_t = 501

    private func candidate(pid: pid_t, _ bundleID: String?, _ path: String,
                           terminated: Bool = false) -> InstanceWatch.Candidate {
        InstanceWatch.Candidate(pid: pid, bundleIdentifier: bundleID, bundleURL: URL(fileURLWithPath: path),
                                isTerminated: terminated)
    }

    /// The release and debug builds have different bundle ids and different
    /// display names; both are the switcher and both answer the shortcut.
    func testACopyWithAnIdInTheFamilyIsAnotherInstance() {
        let candidates = [candidate(pid: 900, "im.opentab.app", "/Applications/OpenTab.app"),
                          candidate(pid: 901, "im.opentab.app.dev", "/Users/example/Applications/OpenTab.app")]
        XCTAssertEqual(InstanceWatch.others(among: candidates, ownPID: ownPID),
                       [InstanceWatch.OtherInstance(pid: 900, path: "/Applications/OpenTab.app"),
                        InstanceWatch.OtherInstance(pid: 901, path: "/Users/example/Applications/OpenTab.app")])
    }

    /// Our own process is in the running-application list too, and reporting
    /// it would warn about a conflict with itself on every launch.
    func testOurOwnProcessIsNotAnotherInstance() {
        let candidates = [candidate(pid: ownPID, "im.opentab.app", "/Applications/OpenTab.app")]
        XCTAssertEqual(InstanceWatch.others(among: candidates, ownPID: ownPID), [])
    }

    /// A copy that has quit stays in the running-application list, marked
    /// terminated, long enough to be seen by the scan its own exit triggers.
    /// Counting it would leave the warning up with nothing left to conflict.
    func testACopyThatHasQuitIsNotAnotherInstance() {
        let candidates = [candidate(pid: 900, "im.opentab.app", "/Applications/OpenTab.app", terminated: true)]
        XCTAssertEqual(InstanceWatch.others(among: candidates, ownPID: ownPID), [])
    }

    /// The probes ship under the same `im.opentab` prefix and register no
    /// shortcuts.
    func testAnIdOutsideTheAppFamilyIsNotAnotherInstance() {
        let candidates = [candidate(pid: 902, "im.opentab.tools.axprobe", "/Users/example/axprobe.app"),
                          candidate(pid: 903, nil, "/usr/bin/login"),
                          candidate(pid: 904, "com.apple.finder", "/System/Library/CoreServices/Finder.app")]
        XCTAssertEqual(InstanceWatch.others(among: candidates, ownPID: ownPID), [])
    }
}
