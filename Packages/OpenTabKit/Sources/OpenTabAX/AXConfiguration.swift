import ApplicationServices
import OpenTabCore

public enum AXConfiguration {
    /// Sets the AX messaging timeout for this process. Only a value set on the
    /// system-wide element propagates to elements created later; the
    /// default is ~1.5s, which is far too long to hold a worker queue.
    public static func configureGlobalTimeout(seconds: Float = 0.15) {
        let error = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
        if error != .success {
            Log.make("ax").error("set messaging timeout failed error=\(axErrorName(error), privacy: .public)")
        }
    }
}

public enum AXTrust {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt when not yet trusted.
    public static func prompt() {
        // The kAXTrustedCheckOptionPrompt global is a mutable CFString and is
        // not concurrency-safe under Swift 6; the literal is its documented value.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
