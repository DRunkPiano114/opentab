import AppKit
import SwiftUI

/// The idle search control: a centred, content-fitting pill. Pressing Enter
/// swaps it for `SearchFieldBackdrop` with the real text field on top.
struct SearchCapsule: View {
    var text = "Enter to search"

    var body: some View {
        Text(text)
            .font(Theme.placeholderFont)
            .foregroundStyle(Theme.textPlaceholder)
            .padding(.horizontal, Theme.fieldInsetH)
            .frame(height: Theme.idlePillHeight)
            .background {
                VibrancyBackdrop(cornerRadius: Theme.idlePillRadius)
            }
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// The active search control: a full-width rounded rectangle (not a pill).
/// It draws only the material; the text, caret and placeholder come from the
/// `NSTextField` that `PanelController` lays over this exact frame.
struct SearchFieldBackdrop: View {
    var body: some View {
        VibrancyBackdrop(cornerRadius: Theme.fieldRadius)
            .frame(height: Theme.fieldHeight)
    }
}

/// A dark vibrancy material that blurs whatever sits *behind the window*.
///
/// The panel body is fully opaque, yet this control still transmits the
/// desktop: `.behindWindow` blending is composited by the window server
/// underneath the window's own content, so it punches through the opaque
/// background drawn behind it. A flat grey fill would look obviously wrong on a
/// light desktop.
struct VibrancyBackdrop: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.maskImage = Self.mask(cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.maskImage = Self.mask(cornerRadius: cornerRadius)
    }

    /// A stretchable rounded-rect mask; `NSVisualEffectView` rounds its material
    /// through `maskImage` rather than through layer clipping.
    private static func mask(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                       bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}
