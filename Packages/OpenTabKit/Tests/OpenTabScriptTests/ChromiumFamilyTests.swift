import XCTest
@testable import OpenTabScript

final class ChromiumFamilyTests: XCTestCase {
    private func makeBundle(named name: String, sdef: String?) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "\(name)-\(UUID().uuidString).app")
        let resources = root.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        if let sdef {
            try sdef.write(to: resources.appending(path: "scripting.sdef"), atomically: true,
                           encoding: .utf8)
        }
        return root
    }

    func testSuiteCodeIdentifiesAChromiumFork() throws {
        let url = try makeBundle(named: "Fork", sdef: """
            <dictionary><suite name="Chromium Suite" code="CrSu"><class name="tab" code="CrTb"/></suite></dictionary>
            """)
        XCTAssertTrue(ChromiumFamily.isChromium(appURL: url))
    }

    func testNonChromiumBundleIsRejected() throws {
        let url = try makeBundle(named: "Editor", sdef: """
            <dictionary><suite name="Editor Suite" code="EdSu"/></dictionary>
            """)
        XCTAssertFalse(ChromiumFamily.isChromium(appURL: url))
    }

    func testBundleWithoutAScriptingDefinitionIsRejected() throws {
        let url = try makeBundle(named: "Mute", sdef: nil)
        XCTAssertFalse(ChromiumFamily.isChromium(appURL: url))
    }

    func testKnownIDsAreOnlyASeedList() {
        XCTAssertTrue(ChromiumFamily.knownBundleIDs.contains("com.google.Chrome"))
        XCTAssertTrue(ChromiumFamily.knownBundleIDs.contains("com.microsoft.edgemac"))
    }
}
