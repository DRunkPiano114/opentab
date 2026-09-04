import ApplicationServices
import CoreGraphics
import Foundation

/// `AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *)`.
typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

/// Every private symbol this module touches, resolved with `dlsym` at first
/// use and `nil` when absent. Nothing is linked directly, and every caller
/// has a degradation path for a `nil`.
///
/// Signatures come from the arm64 disassembly of HIServices on macOS 26.6.2
/// and from SkyLight probe runs on the same version; the `CGS*` names are
/// shared-cache aliases of the `SLS*` exports. A wrong signature segfaults
/// instead of returning an error, so a change here is unverified until the
/// app-hosted symbol tests pass.
enum WSPrivateSymbols {
    // MARK: HIServices

    /// `CFDataRef _AXUIElementRemoteTokenCreate(AXUIElementRef)` — +1 retained.
    typealias RemoteTokenCreate = @convention(c) (AXUIElement) -> Unmanaged<CFData>?
    /// `AXUIElementRef _AXUIElementCreateWithRemoteToken(CFDataRef)` — +1
    /// retained, NULL for a token shorter than 12 bytes. Creation is local; no
    /// IPC happens until an attribute is read.
    typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    // MARK: SkyLight / CGS

    typealias MainConnectionID = @convention(c) () -> Int32
    /// `CFArrayRef CGSCopySpacesForWindows(int cid, int mask, CFArrayRef wids)`;
    /// mask 0x7 = every Space. The result is the union over all wids passed.
    typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    /// `CGError CGSGetWindowLevel(int cid, CGWindowID wid, CGWindowLevel *level)`.
    /// No probe run has confirmed this symbol, so the diagnostics compare it
    /// against the public `kCGWindowLayer` before anything relies on it.
    typealias GetWindowLevel = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Int32>) -> Int32
    /// `CGError CGSSetSymbolicHotKeyEnabled(int hotKey, Boolean enabled)`.
    typealias SetSymbolicHotKeyEnabled = @convention(c) (Int32, Bool) -> Int32
    /// `Boolean CGSIsSymbolicHotKeyEnabled(int hotKey)`.
    typealias IsSymbolicHotKeyEnabled = @convention(c) (Int32) -> Bool

    enum Name {
        static let remoteTokenCreate = "_AXUIElementRemoteTokenCreate"
        static let createWithRemoteToken = "_AXUIElementCreateWithRemoteToken"
        static let getWindow = "_AXUIElementGetWindow"
        static let mainConnectionID = "CGSMainConnectionID"
        static let copySpacesForWindows = "CGSCopySpacesForWindows"
        static let copyManagedDisplaySpaces = "CGSCopyManagedDisplaySpaces"
        static let getWindowLevel = "CGSGetWindowLevel"
        static let setSymbolicHotKeyEnabled = "CGSSetSymbolicHotKeyEnabled"
        static let isSymbolicHotKeyEnabled = "CGSIsSymbolicHotKeyEnabled"

        /// Diagnostics order.
        static let all = [remoteTokenCreate, createWithRemoteToken, getWindow, mainConnectionID,
                          copySpacesForWindows, copyManagedDisplaySpaces, getWindowLevel,
                          setSymbolicHotKeyEnabled, isSymbolicHotKeyEnabled]
    }

    static let remoteTokenCreate: RemoteTokenCreate? = resolve(Name.remoteTokenCreate)
    static let createWithRemoteToken: CreateWithRemoteToken? = resolve(Name.createWithRemoteToken)
    static let getWindow: GetWindowFunction? = resolve(Name.getWindow)
    static let mainConnectionID: MainConnectionID? = resolve(Name.mainConnectionID)
    static let copySpacesForWindows: CopySpacesForWindows? = resolve(Name.copySpacesForWindows)
    static let copyManagedDisplaySpaces: CopyManagedDisplaySpaces? = resolve(Name.copyManagedDisplaySpaces)
    static let getWindowLevel: GetWindowLevel? = resolve(Name.getWindowLevel)
    static let setSymbolicHotKeyEnabled: SetSymbolicHotKeyEnabled? = resolve(Name.setSymbolicHotKeyEnabled)
    static let isSymbolicHotKeyEnabled: IsSymbolicHotKeyEnabled? = resolve(Name.isSymbolicHotKeyEnabled)

    static func isResolved(_ name: String) -> Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
    }

    /// One line per symbol, for the diagnostics report and the launch log.
    static var availabilityTable: [(name: String, resolved: Bool)] {
        Name.all.map { ($0, isResolved($0)) }
    }

    private static func resolve<T>(_ name: String) -> T? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
