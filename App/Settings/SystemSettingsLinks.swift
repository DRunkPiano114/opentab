import Foundation

/// Deep links into System Settings, verified on macOS 26.6.2.
enum SystemSettingsLinks {
    static let accessibility =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
