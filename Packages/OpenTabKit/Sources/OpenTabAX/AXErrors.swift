import ApplicationServices
import OpenTabCore

/// Failure of one application read. Codes are distinguished because they call
/// for different reactions (appendix B §2.6).
public enum AXSourceError: Error, Sendable, Equatable {
    /// The deadline passed before the read finished. Nothing partial is
    /// returned (L5).
    case deadlineExceeded
    /// `kAXErrorAPIDisabled`: this process is not trusted. Not per-app.
    case notTrusted
    /// `kAXErrorCannotComplete`: the app is busy, not ready, or timed out.
    /// Retry later.
    case cannotComplete
    /// `kAXErrorNotImplemented`: the process does not speak AX.
    case notImplemented
    /// `kAXErrorInvalidUIElement`: the application element is gone.
    case invalidElement
    case failure(code: Int32)

    /// Short label for reports and logs.
    public var name: String {
        switch self {
        case .deadlineExceeded: return "deadlineExceeded"
        case .notTrusted: return "apiDisabled"
        case .cannotComplete: return "cannotComplete"
        case .notImplemented: return "notImplemented"
        case .invalidElement: return "invalidUIElement"
        case .failure(let code): return axErrorName(AXError(rawValue: code) ?? .failure)
        }
    }

    static func from(_ error: AXError) -> AXSourceError {
        switch error {
        case .apiDisabled: return .notTrusted
        case .cannotComplete: return .cannotComplete
        case .notImplemented: return .notImplemented
        case .invalidUIElement: return .invalidElement
        default: return .failure(code: error.rawValue)
        }
    }
}

public enum AXActivationError: Error, Sendable, Equatable {
    /// No snapshot has listed this key, so there is no element to act on.
    case unknownWindow(WindowKey)
    /// The app never reported `kAXFrontmostAttribute` before the deadline.
    /// AppKit return values are not consulted (L2).
    case unconfirmed
}
