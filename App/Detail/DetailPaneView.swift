import SwiftUI

/// The second-level pane. Fills the frame the host view is given, like the
/// main list; the panel body underneath stays fully opaque and only the back
/// chip and the search control transmit the desktop (iron laws §A, row 1).
struct DetailPaneView: View {
    let model: PanelViewModel
    let pane: DetailPane

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                Spacer().frame(height: DetailMetrics.backChipTop + DetailMetrics.backChipSize.height
                    + DetailMetrics.chipIconGap)
                appIcon
                Spacer().frame(height: DetailMetrics.iconNameGap)
                Text(pane.appName)
                    .font(DetailMetrics.headerFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, DetailMetrics.rowInset)
                Spacer().frame(height: DetailMetrics.nameDividerGap)
                Rectangle()
                    .fill(Theme.divider)
                    .frame(height: DetailMetrics.dividerThickness)
                    .padding(.horizontal, DetailMetrics.dividerInset)
                Spacer().frame(height: DetailMetrics.dividerFieldGap)
                searchControl
                Spacer().frame(height: DetailMetrics.fieldListGap)
            }
            .frame(maxWidth: .infinity)

            BackChip()
                .padding(.leading, DetailMetrics.backChipLeading)
                .padding(.top, DetailMetrics.backChipTop)
                .onTapGesture { model.onDetailBack() }
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        Group {
            if let image = pane.appIcon {
                Image(nsImage: image)
                    .interpolation(.high)
                    .resizable()
            } else {
                RoundedRectangle(cornerRadius: Theme.iconPlaceholderRadius, style: .continuous)
                    .fill(Theme.iconPlaceholderFill)
            }
        }
        .frame(width: DetailMetrics.appIconSize, height: DetailMetrics.appIconSize)
    }

    /// The idle pill invites Enter; the search state swaps in the same
    /// backdrop the main list uses, with the AppKit field laid over it.
    @ViewBuilder
    private var searchControl: some View {
        switch model.mode {
        case .navigating:
            SearchCapsule(text: "Enter to search")
        case .searching:
            SearchFieldBackdrop()
                .padding(.horizontal, Theme.contentInsetH)
        }
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if pane.rows.isEmpty {
            Text(pane.isFiltered ? "No results" : "No tabs in this window")
                .font(Theme.placeholderFont)
                .foregroundStyle(Theme.textPlaceholder)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DetailMetrics.rowInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pane.rows.enumerated()), id: \.element.id) { index, row in
                        VStack(spacing: 0) {
                            DetailRowView(model: model, index: index, row: row,
                                          fallbackIcon: pane.appIcon)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    guard model.hoverEnabled, case .active = phase else { return }
                                    model.onHover(index)
                                }
                                .onTapGesture { model.onActivate(index) }
                            if index < pane.rows.count - 1 {
                                Rectangle()
                                    .fill(Theme.divider)
                                    .frame(height: DetailMetrics.dividerThickness)
                                    .padding(.horizontal, DetailMetrics.rowInset)
                            }
                        }
                        .frame(height: DetailMetrics.rowPitch)
                    }
                }
            }
            .onChange(of: model.scrollRequest) { _, request in
                guard pane.rows.indices.contains(request.row) else { return }
                proxy.scrollTo(pane.rows[request.row].id, anchor: request.anchor)
            }
        }
    }
}

/// One tab. An 18pt favicon, then the title wrapped to at most two lines —
/// both differences from the main list are intentional (ui-spec.md §3).
private struct DetailRowView: View {
    let model: PanelViewModel
    let index: Int
    let row: DetailPane.Row
    let fallbackIcon: NSImage?

    private var isSelected: Bool { index == model.selectedIndex }

    var body: some View {
        HStack(spacing: DetailMetrics.faviconTextGap) {
            favicon
            Text(SwitcherRowView.emphasised(row.title, at: row.titleMatches,
                                            font: DetailMetrics.rowTitleFont,
                                            color: Theme.textPrimary,
                                            emphasis: DetailMetrics.rowTitleMatchFont))
                .lineLimit(DetailMetrics.titleLineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DetailMetrics.rowInset)
        .frame(height: DetailMetrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: DetailMetrics.rowRadius, style: .continuous)
                .fill(isSelected ? Theme.rowSelectedFill : .clear)
                .padding(.horizontal, Theme.contentInsetH)
        }
        .animation(nil, value: isSelected)
    }

    /// A favicon that could not be found falls back to the app icon rather
    /// than to empty space.
    @ViewBuilder
    private var favicon: some View {
        Group {
            if let image = row.favicon ?? fallbackIcon {
                Image(nsImage: image)
                    .interpolation(.high)
                    .resizable()
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.iconPlaceholderFill)
            }
        }
        .frame(width: DetailMetrics.faviconSize, height: DetailMetrics.faviconSize)
    }
}

/// The `‹ Back` control. One of the three surfaces that are deliberately
/// translucent while the panel body is opaque.
private struct BackChip: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .semibold))
            Text("Back")
                .font(.system(size: 12, weight: .regular))
        }
        .foregroundStyle(Theme.textSecondary)
        .frame(width: DetailMetrics.backChipSize.width, height: DetailMetrics.backChipSize.height)
        .background {
            VibrancyBackdrop(cornerRadius: DetailMetrics.backChipSize.height / 2)
        }
    }
}
