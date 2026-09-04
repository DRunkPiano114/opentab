import Foundation

public enum ReadKind: Sendable, Hashable {
    case windows
    case tabs
}

/// Identifies one asynchronous read. Issued by `TabStore.beginRead(for:kind:)`
/// before the read starts and handed back with its result, so the store can
/// drop what arrived too late: a read issued under an earlier focus
/// generation, or one a later read of the same app has superseded. Window and
/// tab reads of one app are sequenced independently: they run on different
/// paths and neither supersedes the other.
public struct ReadStamp: Sendable, Hashable {
    public let app: AppKey
    public let kind: ReadKind
    public let generation: FocusGeneration
    public let sequence: UInt64
}

public enum ReadDisposition: Sendable, Equatable {
    case applied
    /// Issued under an earlier focus generation; a slow read of the previous
    /// app must not touch the store after the user moved on.
    case staleGeneration
    /// A later read of the same app was issued after this one; applying it
    /// would roll the app back.
    case superseded
    /// Empty. An empty read never deletes.
    case rejectedEmpty
}

/// The three claim rules, in the order they are tried.
public enum ClaimRule: Sendable, Equatable {
    /// The window title and the script window's active tab corroborate.
    case title
    /// The window has no title and exactly one unowned script window exists.
    case elimination
    /// The window key was resolved to the script window by the caller.
    case resolution
}

/// An AX window entry removed because a script window proved it owns the
/// same window.
public struct Claim: Sendable, Equatable {
    public let window: EntryID
    public let scriptWindow: WindowKey
    public let rule: ClaimRule
}

public struct ApplyResult: Sendable, Equatable {
    public let disposition: ReadDisposition
    /// Whether what the list shows changed.
    public let changed: Bool
    public let claims: [Claim]
    /// Claimed window entries whose script window vanished from a tab read.
    /// They are not shown again until a window read lists them, so the caller
    /// should refresh the app's windows.
    public let releasedWindows: [EntryID]

    static func dropped(_ disposition: ReadDisposition) -> ApplyResult {
        ApplyResult(disposition: disposition, changed: false, claims: [], releasedWindows: [])
    }
}

public enum RemovalReason: Sendable, Equatable {
    case windowClosed
    case tabClosed
    case struck
    case appGone
    case activationFailed
}
