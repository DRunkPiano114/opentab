import AppKit
import SwiftUI

/// The idle search control: a centred, content-fitting pill.
///
/// P0 has no search, so this is display only.
struct SearchCapsule: View {
    var body: some View {
        Text("Search")
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

/// A dark vibrancy material that blurs whatever sits *behind the window*.
///
/// The panel body is fully opaque, yet this control still transmits the
/// desktop: `.behindWindow` blending is composited by the window server
/// underneath the window's own content, so it punches through the opaque
/// background drawn behind it. A flat grey fill would look obviously wrong on a
/// light desktop.
private struct VibrancyBackdrop: NSViewRepresentable {
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
