import SwiftUI
import os

/// Design tokens measured from the reference switcher. Every value is fixed:
/// the panel is always dark, so nothing here resolves against the system
/// appearance.
enum Theme {
    // MARK: Settings-driven

    /// The two tokens the settings window controls. Written from the main
    /// actor and read from wherever SwiftUI evaluates a body, so the pair is
    /// held under a lock rather than as loose mutable globals.
    struct Style: Sendable, Equatable {
        /// Multiplies every font in the main list.
        var textScale: CGFloat = 1
        var isWide = false
    }

    private static let style = OSAllocatedUnfairLock(initialState: Style())

    static func apply(_ new: Style) { style.withLock { $0 = new } }

    static var textScale: CGFloat { style.withLock(\.textScale) }
    static var isWide: Bool { style.withLock(\.isWide) }

    // MARK: Panel

    static var panelWidth: CGFloat { isWide ? 300 : 260 }
    static let panelRadius: CGFloat = 20
    static let panelBorderWidth: CGFloat = 1
    static let panelPadTop: CGFloat = 12
    static let fieldListGap: CGFloat = 12

    // MARK: List

    /// Panel edge to the selected-row rectangle.
    static let contentInsetH: CGFloat = 10
    /// Selected-row rectangle to the icon.
    static let rowInnerPadH: CGFloat = 8
    static let rowPitch: CGFloat = 50
    static let rowHeight: CGFloat = 46
    static let rowGap: CGFloat = 4
    static let rowRadius: CGFloat = 9
    static let iconSize: CGFloat = 28
    static let iconPlaceholderRadius: CGFloat = 6
    static let iconTextGap: CGFloat = 11
    static let titleSubtitleGap: CGFloat = 1
    /// Distance from the panel's right edge to the centre of the count column.
    static let countCentreFromRight: CGFloat = 34
    /// Width of the count column, chosen so that the column's centre lands
    /// exactly `countCentreFromRight` from the panel edge once the content
    /// inset and the row's inner padding are taken off.
    static let countColumnWidth: CGFloat = 2 * (countCentreFromRight - contentInsetH - rowInnerPadH)
    /// Minimum breathing room between a truncated title and the count column;
    /// leading padding on the column, so the column itself stays put.
    static let titleCountGap: CGFloat = 8

    // MARK: Search control

    static let fieldHeight: CGFloat = 36
    static let fieldInsetH: CGFloat = 14
    static let fieldRadius: CGFloat = 10
    /// Vertical inset of the text field inside the field backdrop.
    static let fieldTextInsetV: CGFloat = 7
    static let idlePillHeight: CGFloat = 36
    static let idlePillRadius: CGFloat = 18

    // MARK: Colours

    static let panelBackground = Color(.sRGB, red: 10 / 255, green: 10 / 255, blue: 10 / 255, opacity: 1)
    static let panelBorder = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.10)
    static let rowSelectedFill = Color(.sRGB, red: 51 / 255, green: 51 / 255, blue: 51 / 255, opacity: 1)
    static let textPrimary = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1)
    static let textSecondary = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.85)
    static let textPlaceholder = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.30)
    /// Matched characters in a search result.
    static let textMatch = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1)
    static let iconPlaceholderFill = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.15)
    /// Hairline separator. The main list has none; the detail pane draws one
    /// between rows and under its header.
    static let divider = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.045)

    /// Minimized windows are dimmed rather than badged.
    static let minimizedIconOpacity: Double = 0.55
    static let minimizedTitleOpacity: Double = 0.70

    // MARK: Fonts

    static var rowTitleFont: Font { .system(size: 13.5 * textScale, weight: .semibold) }
    static var rowSubtitleFont: Font { .system(size: 12 * textScale, weight: .regular) }
    static var rowTitleMatchFont: Font { .system(size: 13.5 * textScale, weight: .heavy) }
    static var rowSubtitleMatchFont: Font { .system(size: 12 * textScale, weight: .bold) }
    static var rowCountFont: Font { .system(size: 13 * textScale, weight: .bold) }
    static let placeholderFont = Font.system(size: 15, weight: .regular)
    static let messageFont = Font.system(size: 12, weight: .regular)
    static let messageHintFont = Font.system(size: 11, weight: .regular)
}
