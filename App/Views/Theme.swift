import SwiftUI

/// Design tokens measured from the reference switcher. Every value is fixed:
/// the panel is always dark, so nothing here resolves against the system
/// appearance.
enum Theme {
    // MARK: Panel

    static let panelWidth: CGFloat = 260
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

    /// Minimized windows are dimmed rather than badged.
    static let minimizedIconOpacity: Double = 0.55
    static let minimizedTitleOpacity: Double = 0.70

    // MARK: Fonts

    static let rowTitleFont = Font.system(size: 13.5, weight: .semibold)
    static let rowSubtitleFont = Font.system(size: 12, weight: .regular)
    static let rowTitleMatchFont = Font.system(size: 13.5, weight: .heavy)
    static let rowSubtitleMatchFont = Font.system(size: 12, weight: .bold)
    static let rowCountFont = Font.system(size: 13, weight: .bold)
    static let placeholderFont = Font.system(size: 15, weight: .regular)
    static let messageFont = Font.system(size: 12, weight: .regular)
    static let messageHintFont = Font.system(size: 11, weight: .regular)
}
