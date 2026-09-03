import XCTest
import OpenTabCore
@testable import OpenTabScript

final class ChromiumTabProviderTests: XCTestCase {
    private let chrome = AppInfo(bundleID: "com.google.Chrome", pid: 996, localizedName: "Chrome")
    private let deadline = ContinuousClock.now.advanced(by: .seconds(5))

    private func recorder() -> ScriptRecorder {
        ScriptRecorder { _ in
            .success(.list([
                .list([.text("1391121581"), .text("normal"), .text("2"),
                       .list([.text("t1"), .text("t2")]),
                       .list([.text("Docs"), .text("Mail")]),
                       .list([.text("https://docs.example/"), .text("https://mail.example/")])]),
                .list([.text("1391121538"), .text("incognito"), .text("1"),
                       .list([.text("t9")]),
                       .list([.text("Secret")]),
                       .list([.text("https://private.example/")])]),
            ]))
        }
    }

    private func provider(_ recorder: ScriptRecorder,
                          includesPrivateWindows: Bool = false,
                          running: Set<String> = ["com.google.Chrome"]) -> ChromiumTabProvider {
        ChromiumTabProvider(bundleIDs: ["com.google.Chrome", "com.microsoft.edgemac"],
                            engine: makeEngine(recorder),
                            includesPrivateWindows: includesPrivateWindows,
                            liveness: StubLiveness(running: running),
                            health: BrowserHealth())
    }

    /// L16: incognito is a dictionary value, so this exclusion is reliable.
    func testIncognitoWindowsAreExcludedByDefault() async throws {
        let tabs = try await provider(recorder()).readTabs(for: chrome, deadline: deadline)
        XCTAssertEqual(tabs.map(\.token), ["t1", "t2"])
        XCTAssertFalse(tabs.contains { $0.isPrivate })
    }

    func testOptingInMarksIncognitoTabsPrivate() async throws {
        let tabs = try await provider(recorder(), includesPrivateWindows: true)
            .readTabs(for: chrome, deadline: deadline)
        XCTAssertEqual(tabs.map(\.token), ["t1", "t2", "t9"])
        XCTAssertEqual(tabs.map(\.isPrivate), [false, false, true])
    }

    func testTabsCarryStableIDsAndTheActiveFlag() async throws {
        let provider = provider(recorder())
        XCTAssertEqual(provider.tokenStability, .stable)
        let tabs = try await provider.readTabs(for: chrome, deadline: deadline)
        XCTAssertEqual(tabs.map(\.isActive), [false, true])
        XCTAssertEqual(tabs.first?.windowKey,
                       .scripted(bundleID: "com.google.Chrome", token: "1391121581"))
        XCTAssertEqual(tabs.first?.url, URL(string: "https://docs.example/"))
    }

    func testNotRunningTargetIsNeverAddressed() async throws {
        let recorder = recorder()
        let tabs = try await provider(recorder, running: []).readTabs(for: chrome, deadline: deadline)
        XCTAssertTrue(tabs.isEmpty)
        XCTAssertTrue(recorder.sources.isEmpty)
    }

    func testActivateWalksTheTabListToRecoverTheIndex() async throws {
        let recorder = ScriptRecorder { _ in .success(.text("true")) }
        let tab = TabSnapshot(windowKey: .scripted(bundleID: "com.google.Chrome", token: "139"),
                              token: "t2", title: "", url: nil, isActive: false, isPrivate: false)
        try await provider(recorder).activate(tab, deadline: deadline)
        let source = try XCTUnwrap(recorder.sources.first)
        XCTAssertTrue(source.contains("if (id of browserWindow as text) is \"139\""))
        XCTAssertTrue(source.contains("if (id of tab position of browserWindow as text) is \"t2\""))
        XCTAssertTrue(source.contains("set active tab index of browserWindow to position"))
    }

    func testActivateReportsAVanishedTab() async {
        let recorder = ScriptRecorder { _ in .success(.text("false")) }
        let tab = TabSnapshot(windowKey: .scripted(bundleID: "com.google.Chrome", token: "139"),
                              token: "gone", title: "", url: nil, isActive: false, isPrivate: false)
        do {
            try await provider(recorder).activate(tab, deadline: deadline)
            XCTFail("expected a rejection")
        } catch let error as ScriptError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCloseDoesNotActivateTheWindow() async throws {
        let recorder = ScriptRecorder { _ in .success(.text("true")) }
        let tab = TabSnapshot(windowKey: .scripted(bundleID: "com.google.Chrome", token: "139"),
                              token: "t2", title: "", url: nil, isActive: false, isPrivate: false)
        try await provider(recorder).close(tab, deadline: deadline)
        let source = try XCTUnwrap(recorder.sources.first)
        XCTAssertTrue(source.contains("close tab position of browserWindow"))
        XCTAssertFalse(source.contains("activate"))
    }

    func testEachTargetGetsItsOwnLaneAndScript() async throws {
        let recorder = recorder()
        let edge = AppInfo(bundleID: "com.microsoft.edgemac", pid: 7, localizedName: "Edge")
        let provider = ChromiumTabProvider(bundleIDs: ["com.google.Chrome", "com.microsoft.edgemac"],
                                           engine: makeEngine(recorder),
                                           liveness: StubLiveness(running: ["com.google.Chrome",
                                                                            "com.microsoft.edgemac"]),
                                           health: BrowserHealth())
        _ = try await provider.readTabs(for: chrome, deadline: deadline)
        _ = try await provider.readTabs(for: edge, deadline: deadline)
        XCTAssertEqual(recorder.executorsCreated, 2, "one worker thread per target")
        XCTAssertTrue(recorder.sources[0].contains("com.google.Chrome"))
        XCTAssertTrue(recorder.sources[1].contains("com.microsoft.edgemac"))
    }
}
