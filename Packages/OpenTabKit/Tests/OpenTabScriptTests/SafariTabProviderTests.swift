import XCTest
import OpenTabCore
@testable import OpenTabScript

final class SafariTabProviderTests: XCTestCase {
    private let safari = AppInfo(bundleID: "com.apple.Safari", pid: 501, localizedName: "Safari")
    private let deadline = ContinuousClock.now.advanced(by: .seconds(5))

    private func recorder() -> ScriptRecorder {
        ScriptRecorder { _ in
            .success(.list([
                .list([.text("36879"), .text("2"),
                       .list([.text("1"), .text("2")]),
                       .list([.text("Example Domain"), .text("Apple")]),
                       .list([.text("https://example.com/"), .text("https://www.apple.com/")])]),
                .list([.text("36860"), .text("1"),
                       .list([.text("1")]),
                       .list([.text("Start Page")]),
                       .list([.text("favorites://")])]),
            ]))
        }
    }

    private func provider(_ recorder: ScriptRecorder,
                          policy: SafariTabPolicy,
                          running: Set<String> = ["com.apple.Safari"],
                          health: BrowserHealth = BrowserHealth()) -> SafariTabProvider {
        SafariTabProvider(engine: makeEngine(recorder), policy: policy,
                          liveness: StubLiveness(running: running), health: health)
    }

    /// Safari's dictionary cannot flag a private window, so the default
    /// contributes no tabs at all rather than leaking private titles.
    func testDefaultPolicyReadsNoTabsAndSendsNothing() async throws {
        let recorder = recorder()
        let provider = provider(recorder, policy: .windowsOnly)
        let tabs = try await provider.readTabs(for: safari, deadline: deadline)
        XCTAssertTrue(tabs.isEmpty)
        XCTAssertTrue(recorder.sources.isEmpty)
        XCTAssertEqual(provider.tokenStability, .positional)
    }

    func testTabsCarryIndexTokensAndTheActiveFlag() async throws {
        let recorder = recorder()
        let tabs = try await provider(recorder, policy: .allTabs).readTabs(for: safari, deadline: deadline)
        XCTAssertEqual(tabs.count, 3)
        XCTAssertEqual(tabs.map(\.token), ["1", "2", "1"])
        XCTAssertEqual(tabs.map(\.isActive), [false, true, true])
        XCTAssertEqual(tabs.first?.windowKey, .cg(36879))
        XCTAssertEqual(tabs.first?.url, URL(string: "https://example.com/"))
        XCTAssertEqual(tabs.map(\.isPrivate), [false, false, false])
    }

    func testClassifiedPrivateWindowsAreDropped() async throws {
        let recorder = recorder()
        let provider = provider(recorder, policy: .tabsExcludingPrivate { [36860] })
        let tabs = try await provider.readTabs(for: safari, deadline: deadline)
        XCTAssertEqual(tabs.map(\.windowKey), [.cg(36879), .cg(36879)])
    }

    /// A `tell` would launch Safari, so a target that is not running is never
    /// addressed at all.
    func testNotRunningTargetIsNeverAddressed() async throws {
        let recorder = recorder()
        let provider = provider(recorder, policy: .allTabs, running: [])
        let tabs = try await provider.readTabs(for: safari, deadline: deadline)
        XCTAssertTrue(tabs.isEmpty)
        XCTAssertTrue(recorder.sources.isEmpty)
    }

    func testWedgedTargetIsSkippedWhileCoolingDownSoTheCallerKeepsItsCache() async {
        let recorder = recorder()
        let health = BrowserHealth()
        health.recordFailure("com.apple.Safari")
        let provider = provider(recorder, policy: .allTabs, health: health)
        do {
            _ = try await provider.readTabs(for: safari, deadline: deadline)
            XCTFail("expected a timeout")
        } catch let error as ScriptError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(recorder.sources.isEmpty)
    }

    func testTimeoutOpensTheCircuitBreaker() async {
        let recorder = ScriptRecorder { _ in .failure(.timedOut) }
        let health = BrowserHealth()
        let provider = provider(recorder, policy: .allTabs, health: health)
        _ = try? await provider.readTabs(for: safari, deadline: deadline)
        XCTAssertTrue(health.isCoolingDown("com.apple.Safari"))
    }

    func testWrongAppIsRejected() async {
        let recorder = recorder()
        let provider = provider(recorder, policy: .allTabs)
        let chrome = AppInfo(bundleID: "com.google.Chrome", pid: 9, localizedName: "Chrome")
        do {
            _ = try await provider.readTabs(for: chrome, deadline: deadline)
            XCTFail("expected a rejection")
        } catch let error as ScriptError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testActivateAddressesTheWindowAndTabFromTheSnapshot() async throws {
        let recorder = ScriptRecorder { _ in .success(.empty) }
        let provider = provider(recorder, policy: .allTabs)
        let tab = TabSnapshot(windowKey: .cg(36879), token: "3", title: "", url: nil,
                              isActive: false, isPrivate: false)
        try await provider.activate(tab, deadline: deadline)
        let source = try XCTUnwrap(recorder.sources.first)
        XCTAssertTrue(source.contains("first window whose id is 36879"))
        XCTAssertTrue(source.contains("set current tab of target to tab 3 of target"))
        XCTAssertEqual(recorder.recordedCalls.first?.cacheable, false)
    }

    func testCloseDoesNotSelectTheTab() async throws {
        let recorder = ScriptRecorder { _ in .success(.empty) }
        let provider = provider(recorder, policy: .allTabs)
        let tab = TabSnapshot(windowKey: .cg(36879), token: "3", title: "", url: nil,
                              isActive: false, isPrivate: false)
        try await provider.close(tab, deadline: deadline)
        let source = try XCTUnwrap(recorder.sources.first)
        XCTAssertTrue(source.contains("close tab 3 of target"))
        XCTAssertFalse(source.contains("current tab"))
    }

    func testUnusableSnapshotKeysAreRejected() async {
        let recorder = ScriptRecorder { _ in .success(.empty) }
        let provider = provider(recorder, policy: .allTabs)
        let axKeyed = TabSnapshot(windowKey: .ax(pid: 1, elementID: 2), token: "1", title: "",
                                  url: nil, isActive: false, isPrivate: false)
        let badToken = TabSnapshot(windowKey: .cg(1), token: "0", title: "", url: nil,
                                   isActive: false, isPrivate: false)
        let nonNumericWindow = TabSnapshot(windowKey: .scripted(bundleID: "com.apple.Safari",
                                                                token: "abc"),
                                           token: "1", title: "", url: nil,
                                           isActive: false, isPrivate: false)
        for tab in [axKeyed, badToken, nonNumericWindow] {
            do {
                try await provider.activate(tab, deadline: deadline)
                XCTFail("expected a rejection")
            } catch let error as ScriptError {
                XCTAssertEqual(error, .notFound)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertTrue(recorder.sources.isEmpty)
    }
}
