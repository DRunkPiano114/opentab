import XCTest
@testable import OpenTab

final class InstallLocationTests: XCTestCase {
    private let home = "/Users/example"

    private func placement(_ path: String, home: String? = nil) -> InstallLocation.Placement {
        InstallLocation.placement(ofBundlePath: path, homeDirectory: home ?? self.home)
    }

    func testTheSystemApplicationsFolderIsAPermanentHome() {
        XCTAssertEqual(placement("/Applications/OpenTab.app"), .applications)
        XCTAssertEqual(placement("/Applications/Utilities/OpenTab.app"), .applications)
    }

    /// A locally built copy is installed here, and its permissions are as
    /// durable as the system folder's. Treating it as misplaced would nag on
    /// every launch of a copy that is exactly where it belongs.
    func testThePerUserApplicationsFolderIsAPermanentHomeToo() {
        XCTAssertEqual(placement("/Users/example/Applications/OpenTab.app"), .applications)
        XCTAssertEqual(placement("/Users/example/Applications/OpenTab.app", home: "/Users/example/"),
                       .applications)
    }

    func testAnywhereElseIsNotAHome() {
        XCTAssertEqual(placement("/Users/example/Downloads/OpenTab.app"), .elsewhere)
        XCTAssertEqual(placement("/Volumes/OpenTab/OpenTab.app"), .elsewhere)
        XCTAssertEqual(placement("/Users/example/Desktop/Applications/OpenTab.app"), .elsewhere)
    }

    /// The comparison is against a whole path component: a folder whose name
    /// merely starts with "Applications" is somewhere else entirely.
    func testAFolderNamedLikeApplicationsIsNotIt() {
        XCTAssertEqual(placement("/Applications.old/OpenTab.app"), .elsewhere)
        XCTAssertEqual(placement("/Users/example/Applications Backup/OpenTab.app"), .elsewhere)
    }

    /// Another account's Applications folder is not this user's, and the app
    /// could not be granted anything useful from there.
    func testAnotherUsersApplicationsFolderIsNotAHome() {
        XCTAssertEqual(placement("/Users/other/Applications/OpenTab.app"), .elsewhere)
    }

    /// The mount identifier changes on every launch, so nothing may key on
    /// its shape; only the directory name is stable.
    func testTranslocationIsRecognisedWhateverTheMountIsCalled() {
        XCTAssertEqual(placement("/private/var/folders/2k/xy/T/AppTranslocation/9F3B2C1D-0000-4A5E-9B7C-2E1F4A6D8B03/d/OpenTab.app"),
                       .translocated)
        XCTAssertEqual(placement("/private/var/folders/2k/xy/T/AppTranslocation/anything-at-all/d/OpenTab.app"),
                       .translocated)
    }

    /// A translocated bundle sits under a path that resembles nothing else,
    /// but the check runs first regardless: the read-only copy is never a
    /// home, however it is spelled.
    func testTranslocationOutranksTheOtherAnswers() {
        XCTAssertEqual(placement("/Applications/AppTranslocation/d/OpenTab.app"), .translocated)
    }

    /// Without this symbol there is no way back from the read-only copy to
    /// what the user downloaded, and the flow degrades to written
    /// instructions. The test says which of the two is in force today.
    func testTheTranslocationOriginalPathSymbolIsAvailable() {
        XCTAssertNotNil(dlsym(UnsafeMutableRawPointer(bitPattern: -2), InstallLocation.originalPathSymbol),
                        "\(InstallLocation.originalPathSymbol) is gone: OpenTab can no longer offer to move itself out of a translocated copy")
    }
}
