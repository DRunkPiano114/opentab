import SwiftUI

/// Reads `model.selectedIndex` in its own body: a row inside a lazy stack is
/// built outside the parent's observation scope, so a highlight passed in as a
/// plain Bool went stale once the parent stopped re-evaluating that row —
/// leaving the old row lit while a freshly built row lit up as well.
struct SwitcherRowView: View {
    let model: PanelViewModel
    let index: Int
    let row: PanelViewModel.Row

    private var isSelected: Bool { index == model.selectedIndex }

    var body: some View {
        HStack(spacing: 0) {
            icon
                .padding(.trailing, Theme.iconTextGap)
            labels
            Spacer(minLength: 0)
            count
        }
        .padding(.horizontal, Theme.rowInnerPadH)
        .frame(height: Theme.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(isSelected ? Theme.rowSelectedFill : .clear)
        }
        // Keyboard repeat outruns the animator: an animated highlight visibly
        // lags behind the selection.
        .animation(nil, value: isSelected)
    }

    @ViewBuilder
    private var icon: some View {
        Group {
            if let image = row.icon {
                Image(nsImage: image)
                    .interpolation(.high)
                    .resizable()
            } else {
                RoundedRectangle(cornerRadius: Theme.iconPlaceholderRadius, style: .continuous)
                    .fill(Theme.iconPlaceholderFill)
            }
        }
        .frame(width: Theme.iconSize, height: Theme.iconSize)
        .opacity(row.isMinimized ? Theme.minimizedIconOpacity : 1)
    }

    /// A row without a window title shows the app name alone, vertically centred.
    private var labels: some View {
        VStack(alignment: .leading, spacing: Theme.titleSubtitleGap) {
            Text(Self.emphasised(row.appName, at: row.appNameMatches, font: Theme.rowTitleFont,
                                 color: Theme.textPrimary, emphasis: Theme.rowTitleMatchFont))
                .opacity(row.isMinimized ? Theme.minimizedTitleOpacity : 1)
                .lineLimit(1)
                .truncationMode(.tail)
            if !row.title.isEmpty {
                Text(Self.emphasised(row.title, at: row.titleMatches, font: Theme.rowSubtitleFont,
                                     color: Theme.textSecondary, emphasis: Theme.rowSubtitleMatchFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// `offsets` index `Array(text)`, as `SearchHit` reports them. Matched
    /// characters get the heavier font and full white.
    private static func emphasised(_ text: String, at offsets: [Int], font: Font, color: Color,
                                   emphasis: Font) -> AttributedString {
        var out = AttributedString(text)
        out.font = font
        out.foregroundColor = color
        guard !offsets.isEmpty else { return out }
        let characters = Array(text)
        for offset in offsets where offset >= 0 && offset < characters.count {
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(after: start)
            guard let lower = AttributedString.Index(start, within: out),
                  let upper = AttributedString.Index(end, within: out) else { continue }
            out[lower..<upper].font = emphasis
            out[lower..<upper].foregroundColor = Theme.textMatch
        }
        return out
    }

    /// The count is centred in a fixed-width column, not trailing-aligned: a
    /// right-aligned digit drifts by half an ink width between one- and
    /// two-digit counts, which is visible against the column of rows above it.
    ///
    /// A degraded row shows a marker in the column instead of its count: an
    /// ellipsis while the app's read is outstanding, a warning sign when its
    /// tabs cannot be read.
    @ViewBuilder
    private var count: some View {
        if let marker = Self.marker(for: row.status) {
            Text(marker)
                .font(Theme.rowCountFont)
                .foregroundStyle(Theme.textPlaceholder)
                .lineLimit(1)
                .frame(width: Theme.countColumnWidth, alignment: .center)
                .padding(.leading, Theme.titleCountGap)
                .accessibilityLabel(Self.markerLabel(for: row.status))
        } else if let value = row.count {
            Text(String(value))
                .font(Theme.rowCountFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(width: Theme.countColumnWidth, alignment: .center)
                .padding(.leading, Theme.titleCountGap)
        }
    }

    private static func marker(for status: PanelViewModel.Row.Status) -> String? {
        switch status {
        case .normal: nil
        case .unresponsive: "\u{2026}"
        case .tabsUnavailable: "\u{26A0}\u{FE0E}"
        }
    }

    private static func markerLabel(for status: PanelViewModel.Row.Status) -> String {
        switch status {
        case .normal: ""
        case .unresponsive: "Not responding"
        case .tabsUnavailable: "Tabs unavailable"
        }
    }
}
