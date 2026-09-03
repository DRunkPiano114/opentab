import Foundation
import CoreServices
import Security

public enum AutomationStatus: Sendable, Equatable {
    case authorized
    /// `-1743`. Three indistinguishable causes; `AutomationSelfCheck` separates
    /// our own misconfiguration from a user refusal.
    case denied
    /// `-1744`. No authorisation record, which does not distinguish "never
    /// asked" from "asked and refused" (appendix K §1.3).
    case undetermined
    /// `-600`. Nothing to ask about yet.
    case targetNotRunning
    /// `AEDeterminePermissionToAutomateTarget` has a known intermittent hang,
    /// reproducible on Spotify even with `askUserIfNeeded: false`.
    case timedOut
    case failed(OSStatus)
}

public enum AutomationDefect: String, Sendable, Equatable {
    case missingUsageDescription
    case missingEntitlement
}

/// What our own bundle declares. Read from `Bundle.main` in the app; injected in
/// tests.
public struct BundleAutomationConfig: Sendable, Equatable {
    public let usageDescription: String?
    public let hasAppleEventsEntitlement: Bool

    public init(usageDescription: String?, hasAppleEventsEntitlement: Bool) {
        self.usageDescription = usageDescription
        self.hasAppleEventsEntitlement = hasAppleEventsEntitlement
    }
}

public enum AutomationGuidance: Sendable, Equatable {
    case ready
    /// Our bug, not a user decision. Ship-blocking.
    case fixBundle([AutomationDefect])
    /// Never requested: run the onboarding request. Never do this from the
    /// hotkey path.
    case requestFromUser
    /// Requested and refused. The Automation pane exists by now, so deep-link.
    case userDenied
    case retryLater
}

public enum AutomationSelfCheck {
    public static func defects(in config: BundleAutomationConfig) -> [AutomationDefect] {
        var defects: [AutomationDefect] = []
        if (config.usageDescription ?? "").isEmpty { defects.append(.missingUsageDescription) }
        if !config.hasAppleEventsEntitlement { defects.append(.missingEntitlement) }
        return defects
    }

    /// `hasRequestedBefore` is the caller's own record; it is the only way to
    /// resolve the `-1744` ambiguity.
    public static func guidance(for status: AutomationStatus,
                                config: BundleAutomationConfig,
                                hasRequestedBefore: Bool) -> AutomationGuidance {
        if status == .authorized { return .ready }
        let defects = defects(in: config)
        if !defects.isEmpty { return .fixBundle(defects) }
        switch status {
        case .denied: return .userDenied
        case .undetermined: return hasRequestedBefore ? .userDenied : .requestFromUser
        case .authorized, .targetNotRunning, .timedOut, .failed: return .retryLater
        }
    }

    public static func currentBundleConfig(bundle: Bundle = .main) -> BundleAutomationConfig {
        let usage = bundle.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String
        return BundleAutomationConfig(usageDescription: usage,
                                      hasAppleEventsEntitlement: hasAppleEventsEntitlement())
    }

    private static func hasAppleEventsEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return false }
        let key = "com.apple.security.automation.apple-events" as CFString
        guard let value = SecTaskCopyValueForEntitlement(task, key, nil) else { return false }
        return (value as? Bool) ?? false
    }
}

/// Remembers whether we have ever put the consent prompt in front of the user,
/// because `-1744` cannot tell us.
public protocol AutomationRequestLog: Sendable {
    func hasRequested(_ bundleID: String) -> Bool
    func markRequested(_ bundleID: String)
}

/// `UserDefaults` is thread-safe but predates `Sendable`.
public final class DefaultsAutomationRequestLog: AutomationRequestLog, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "automation.requested"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func hasRequested(_ bundleID: String) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(bundleID)
    }

    public func markRequested(_ bundleID: String) {
        var requested = defaults.stringArray(forKey: key) ?? []
        guard !requested.contains(bundleID) else { return }
        requested.append(bundleID)
        defaults.set(requested, forKey: key)
    }
}

public final class AutomationPermission: Sendable {
    private let log: any AutomationRequestLog
    private let timers = DispatchQueue(label: "im.opentab.app.script.permission")

    public init(log: any AutomationRequestLog = DefaultsAutomationRequestLog()) {
        self.log = log
    }

    /// Never prompts. Safe to call on a refresh path.
    public func status(of bundleID: String, timeout: Duration = .milliseconds(500)) async -> AutomationStatus {
        await determine(bundleID: bundleID, askUserIfNeeded: false, timeout: timeout)
    }

    /// Puts the system consent prompt in front of the user. Onboarding only:
    /// this call blocks on a modal dialog, so it must never run from the hotkey
    /// path.
    public func request(for bundleID: String, timeout: Duration = .seconds(120)) async -> AutomationStatus {
        log.markRequested(bundleID)
        return await determine(bundleID: bundleID, askUserIfNeeded: true, timeout: timeout)
    }

    public func guidance(for status: AutomationStatus, bundleID: String,
                         config: BundleAutomationConfig = AutomationSelfCheck.currentBundleConfig()) -> AutomationGuidance {
        AutomationSelfCheck.guidance(for: status, config: config,
                                     hasRequestedBefore: log.hasRequested(bundleID))
    }

    /// The call runs on a throwaway thread, never the main one: Apple documents
    /// that it may take arbitrarily long, and it is known to hang outright.
    /// On timeout the thread is abandoned rather than waited on.
    private func determine(bundleID: String, askUserIfNeeded: Bool,
                           timeout: Duration) async -> AutomationStatus {
        let box = OneShot<AutomationStatus>()
        let thread = Thread {
            box.settle(Self.classify(Self.rawDetermine(bundleID: bundleID,
                                                       askUserIfNeeded: askUserIfNeeded)))
        }
        thread.name = "im.opentab.app.script.permission.\(bundleID)"
        thread.start()
        let expiry = DispatchWorkItem { box.settle(.timedOut) }
        timers.asyncAfter(deadline: .now() + .nanoseconds(Self.nanoseconds(timeout)), execute: expiry)
        let status = await withCheckedContinuation { box.attach($0) }
        expiry.cancel()
        return status
    }

    static func classify(_ status: OSStatus) -> AutomationStatus {
        switch status {
        case noErr: .authorized
        case -1743: .denied
        case -1744: .undetermined
        case -600, -609: .targetNotRunning
        default: .failed(status)
        }
    }

    private static func rawDetermine(bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        // AECreateDesc returns OSErr (Int16), not OSStatus; widening it is not
        // optional, the sign bit is otherwise misread.
        let created: OSStatus = bytes.withUnsafeBufferPointer { buffer in
            OSStatus(AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count, &target))
        }
        guard created == noErr else { return created }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard,
                                                     askUserIfNeeded)
    }

    private static func nanoseconds(_ duration: Duration) -> Int {
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }
        return Int(min(components.seconds, 600)) * 1_000_000_000
            + Int(components.attoseconds / 1_000_000_000)
    }
}

public enum AutomationSettings {
    /// Verified on macOS 26.6.2. The Automation pane does not exist until some
    /// app has asked for Apple Events at least once, so only offer this link
    /// after the first request.
    public static let automationPane = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}
