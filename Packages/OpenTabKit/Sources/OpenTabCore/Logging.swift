import os

public enum Log {
    public static let subsystem = "im.opentab.app"

    public static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    public static let core = make("core")
}
