import os

public enum Log {
    public static let subsystem = "com.paulwu.opentab"

    public static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    public static let core = make("core")
}
