import Foundation
import os

public enum Log {
    /// The bundle id, so a Debug build (`im.opentab.app.dev`) and the
    /// installed release (`im.opentab.app`) log to separate subsystems. A
    /// process without a bundle id (a bare executable) falls back to the
    /// release id; under the SwiftPM test host it is xctest's own id.
    public static let subsystem = Bundle.main.bundleIdentifier ?? "im.opentab.app"

    public static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    public static let core = make("core")
}
