import ApplicationServices
import CoreGraphics
import Foundation

/// Every private symbol this tool touches, resolved with `dlsym` at first use
/// and `nil` when absent. Nothing here is linked directly.
///
/// The signatures were read off the arm64 disassembly of HIServices on
/// macOS 26.6.2 (see the `token` command's header comment for the token
/// layout) and off the SkyLight probes recorded in `appendix/a-skylight.md`.
/// A wrong signature segfaults instead of returning an error, so treat any
/// change here as unverified until a `token probe` run has survived it.
enum PrivateSymbols {
    // MARK: HIServices

    /// `CFDataRef _AXUIElementRemoteTokenCreate(AXUIElementRef)` — +1 retained.
    typealias RemoteTokenCreate = @convention(c) (AXUIElement) -> Unmanaged<CFData>?
    /// `AXUIElementRef _AXUIElementCreateWithRemoteToken(CFDataRef)` — +1 retained,
    /// NULL when the token is shorter than 12 bytes. Creation is local: no IPC
    /// happens until an attribute is read.
    typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    static let remoteTokenCreate: RemoteTokenCreate? = resolve("_AXUIElementRemoteTokenCreate")
    static let createWithRemoteToken: CreateWithRemoteToken? = resolve("_AXUIElementCreateWithRemoteToken")
    static let getWindow: AXGetWindowFunction? = lookupAXUIElementGetWindow()

    // MARK: SkyLight / CGS (the CGS* names are aliases of the SLS* ones)

    typealias MainConnectionID = @convention(c) () -> Int32
    /// `CFArrayRef CGSCopySpacesForWindows(int cid, int mask, CFArrayRef wids)`;
    /// mask 0x7 = every Space. Returns the union for all wids passed, so
    /// attribution needs one call per window.
    typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias GetActiveSpace = @convention(c) (Int32) -> UInt64
    typealias CopyManagedDisplayForWindow = @convention(c) (Int32, UInt32) -> Unmanaged<CFString>?
    typealias ManagedDisplayGetCurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    typealias WindowIsOnCurrentSpace = @convention(c) (Int32, UInt32) -> Bool
    typealias SpaceGetType = @convention(c) (Int32, UInt64) -> Int32
    typealias CopySpaces = @convention(c) (Int32, Int32) -> Unmanaged<CFArray>?
    typealias CopyWindowsWithOptionsAndTags = @convention(c)
        (Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?

    static let mainConnectionID: MainConnectionID? = resolve("CGSMainConnectionID")
    static let copySpacesForWindows: CopySpacesForWindows? = resolve("CGSCopySpacesForWindows")
    static let copyManagedDisplaySpaces: CopyManagedDisplaySpaces? = resolve("CGSCopyManagedDisplaySpaces")
    static let getActiveSpace: GetActiveSpace? = resolve("SLSGetActiveSpace")
    static let copyManagedDisplayForWindow: CopyManagedDisplayForWindow? = resolve("SLSCopyManagedDisplayForWindow")
    static let managedDisplayGetCurrentSpace: ManagedDisplayGetCurrentSpace? = resolve("SLSManagedDisplayGetCurrentSpace")
    static let windowIsOnCurrentSpace: WindowIsOnCurrentSpace? = resolve("SLSWindowIsOnCurrentSpace")
    static let spaceGetType: SpaceGetType? = resolve("SLSSpaceGetType")
    static let copySpaces: CopySpaces? = resolve("SLSCopySpaces")
    static let copyWindowsWithOptionsAndTags: CopyWindowsWithOptionsAndTags? = resolve("SLSCopyWindowsWithOptionsAndTags")

    static func exists(_ name: String) -> Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
    }

    /// Availability table for the output files, so a run on a machine where a
    /// symbol vanished is distinguishable from one where the call failed.
    static func availability(_ names: [String]) -> JSON {
        .object(Dictionary(uniqueKeysWithValues: names.map { ($0, JSON.bool(exists($0))) }))
    }

    private static func resolve<T>(_ name: String) -> T? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
