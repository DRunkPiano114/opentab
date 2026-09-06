import Foundation

/// Which windows never appear in the list.
///
/// The default list holds bundle ids only: display names localise and the
/// original product's mixed list had both spellings of "Notification Centre"
/// in it for exactly that reason. Title patterns are the one sanctioned
/// exception: the caller supplies the expressions and the default is empty, so
/// a localised string is matched only where one was asked for.
public struct IgnoreRules: Sendable {
    public static let defaultBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.notificationcenterui",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.WindowManager",
    ]

    public var bundleIDs: Set<String>
    public private(set) var titlePatterns: [NSRegularExpression]

    public init(bundleIDs: Set<String> = IgnoreRules.defaultBundleIDs, titlePatterns: [String] = []) {
        self.bundleIDs = bundleIDs
        self.titlePatterns = titlePatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    public func ignores(app: AppInfo) -> Bool {
        bundleIDs.contains(app.bundleID)
    }

    public func ignores(_ snapshot: WindowSnapshot) -> Bool {
        if ignores(app: snapshot.app) { return true }
        let range = NSRange(snapshot.title.startIndex..., in: snapshot.title)
        return titlePatterns.contains { $0.firstMatch(in: snapshot.title, range: range) != nil }
    }
}
