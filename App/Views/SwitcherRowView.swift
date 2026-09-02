import SwiftUI

struct SwitcherRowView: View {
    let row: PanelViewModel.Row
    let isSelected: Bool

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
            Text(row.appName)
                .font(Theme.rowTitleFont)
                .foregroundStyle(Theme.textPrimary)
                .opacity(row.isMinimized ? Theme.minimizedTitleOpacity : 1)
                .lineLimit(1)
                .truncationMode(.tail)
            if !row.title.isEmpty {
                Text(row.title)
                    .font(Theme.rowSubtitleFont)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// The count is centred in a fixed-width column, not trailing-aligned: a
    /// right-aligned digit drifts by half an ink width between one- and
    /// two-digit counts, which is visible against the column of rows above it.
    @ViewBuilder
    private var count: some View {
        if let value = row.count {
            Text(String(value))
                .font(Theme.rowCountFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(width: Theme.countColumnWidth, alignment: .center)
                .padding(.leading, Theme.titleCountGap)
        }
    }
}
