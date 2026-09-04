import Foundation

/// Where the running app bundle lives, which decides whether the
/// Accessibility permission the user is about to grant will keep working.
///
/// macOS binds a grant to a code identity at a path. A copy left in
/// `~/Downloads` can be moved or deleted afterwards, and a downloaded copy
/// opened where it was unzipped is not even run from its own path, so the
/// permission the user grants applies to a location that will not exist next
/// time.
///
/// The judgement is a pure function over strings so it can be tested without
/// installing anything.
enum InstallLocation {
    enum Placement: Equatable {
        /// `/Applications` or `~/Applications`. Both are permanent homes; the
        /// per-user one is where a locally built copy is installed.
        case applications
        /// Running from the read-only mount macOS substitutes for a
        /// quarantined app opened outside `/Applications`. The mount carries a
        /// fresh identifier on every launch.
        case translocated
        case elsewhere
    }

    /// The mount looks like
    /// `/private/var/folders/<…>/AppTranslocation/<uuid>/d/OpenTab.app`.
    /// Only this directory name is stable, so it is all that is matched.
    static let translocationMarker = "/AppTranslocation/"

    static func placement(ofBundlePath path: String, homeDirectory: String) -> Placement {
        let bundle = normalized(path)
        guard !bundle.contains(translocationMarker) else { return .translocated }
        let userApplications = normalized(homeDirectory + "/Applications") + "/"
        guard bundle.hasPrefix("/Applications/") || bundle.hasPrefix(userApplications) else { return .elsewhere }
        return .applications
    }

    /// What launching from this location calls for.
    enum Action: Equatable {
        /// Running from a permanent home. Nothing to do, on every launch but
        /// the first few.
        case none
        /// Move this bundle into `/Applications`, then start it from there.
        case move(from: String)
        /// The bundle is already in a permanent home, and macOS is running a
        /// throwaway copy of it only because the download flag is still set.
        /// Clearing that flag and starting the real one is the whole fix, and
        /// it needs no question put to the user.
        case relaunch(from: String)
        /// Running from a throwaway copy the system will not trace back to an
        /// original. Only the user can fix this, in the Finder.
        case explain
    }

    /// The whole first-launch decision, pure so that every branch is testable
    /// without installing anything. `resolveOriginal` is asked for the
    /// pre-translocation path only when there is one to ask about, and
    /// answers nil when the system cannot say.
    static func action(bundlePath: String, homeDirectory: String,
                       resolveOriginal: (String) -> String?) -> Action {
        switch placement(ofBundlePath: bundlePath, homeDirectory: homeDirectory) {
        case .applications:
            return .none
        case .elsewhere:
            return .move(from: bundlePath)
        case .translocated:
            guard let original = resolveOriginal(bundlePath) else { return .explain }
            switch placement(ofBundlePath: original, homeDirectory: homeDirectory) {
            case .applications:
                return .relaunch(from: original)
            case .elsewhere:
                return .move(from: original)
            case .translocated:
                // A throwaway copy of a throwaway copy: there is no location
                // here that moving would make permanent.
                return .explain
            }
        }
    }

    /// Collapses repeated separators and drops a trailing one, so that the
    /// prefix comparisons above do not depend on how the path was spelled.
    private static func normalized(_ path: String) -> String {
        var result = path
        while result.contains("//") { result = result.replacingOccurrences(of: "//", with: "/") }
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

/// `CFURLRef SecTranslocateCreateOriginalPathForURL(CFURLRef, CFErrorRef *)`,
/// which returns a +1 reference.
private typealias TranslocateOriginalPath =
    @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

extension InstallLocation {
    /// Security.framework SPI. It is resolved at first use and never linked:
    /// a private symbol declared with the wrong signature crashes instead of
    /// returning an error, and one that disappears has to leave a degradation
    /// path rather than fail to launch.
    static let originalPathSymbol = "SecTranslocateCreateOriginalPathForURL"

    /// The location the user actually put the app, for a bundle running from
    /// the translocation mount. `nil` when the symbol is unavailable, which
    /// the caller turns into instructions instead of a move.
    static func originalPath(ofTranslocatedBundle url: URL) -> URL? {
        guard let resolve = translocateOriginalPath else { return nil }
        var error: Unmanaged<CFError>?
        guard let original = resolve(url as CFURL, &error) else {
            error?.release()
            return nil
        }
        return original.takeRetainedValue() as URL
    }

    private static let translocateOriginalPath: TranslocateOriginalPath? = {
        // RTLD_DEFAULT: searches the images already loaded, so nothing is
        // linked against the SPI and a missing symbol is just a nil.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), originalPathSymbol) else { return nil }
        return unsafeBitCast(symbol, to: TranslocateOriginalPath.self)
    }()
}
