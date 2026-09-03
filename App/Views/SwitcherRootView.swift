import SwiftUI

/// The whole panel. The hosting view supplies a fixed frame; this view fills it
/// and never resizes itself to the content.
struct SwitcherRootView: View {
    private let model: PanelViewModel

    init(model: PanelViewModel) {
        self.model = model
    }

    var body: some View {
        ZStack {
            panelShape.fill(Theme.panelBackground)
            panelShape.strokeBorder(Theme.panelBorder, lineWidth: Theme.panelBorderWidth)
            VStack(spacing: 0) {
                SearchCapsule()
                    .padding(.bottom, Theme.fieldListGap)
                content
            }
            .padding(.top, Theme.panelPadTop)
        }
        .clipShape(panelShape)
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
    }

    @ViewBuilder
    private var content: some View {
        if !model.accessibilityGranted {
            onboarding
        } else if model.rows.isEmpty {
            message("No windows", font: Theme.placeholderFont, color: Theme.textPlaceholder)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: Theme.rowGap) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        SwitcherRowView(model: model, index: index, row: row)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                guard model.hoverEnabled, case .active = phase else { return }
                                model.onHover(index)
                            }
                            .onTapGesture { model.onActivate(index) }
                    }
                }
                .padding(.horizontal, Theme.contentInsetH)
            }
            .onChange(of: model.scrollRequest) { _, request in
                // Unanimated on purpose: held arrow keys fire faster than the
                // animator settles, and the list would trail the highlight.
                guard model.rows.indices.contains(request.row) else { return }
                proxy.scrollTo(model.rows[request.row].id, anchor: request.anchor)
            }
        }
    }

    private var onboarding: some View {
        VStack(spacing: 8) {
            Text("Grant Accessibility to OpenTab in System Settings → Privacy & Security → Accessibility")
                .font(Theme.messageFont)
                .foregroundStyle(Theme.textSecondary)
            Text("Press Esc to close")
                .font(Theme.messageHintFont)
                .foregroundStyle(Theme.textPlaceholder)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Theme.contentInsetH + Theme.rowInnerPadH)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String, font: Font, color: Color) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
