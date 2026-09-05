import SwiftUI

/// Literals the settings chrome repeats. Nothing from `Theme` belongs here and
/// nothing here belongs there: that one describes the panel, which is always
/// dark and never resolves against the system appearance.
enum ChromeTheme {
    /// Preference windows are a fixed width; only the height follows the page.
    static let windowWidth: CGFloat = 520
    static let recorderSize = CGSize(width: 130, height: 24)
    static let controlRadius: CGFloat = 5
}

extension View {
    /// The one sentence under a control.
    func settingsHelp() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}
