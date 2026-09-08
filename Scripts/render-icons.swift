#!/usr/bin/env swift

// Renders the OpenTab mark into the asset catalog.
//
// The app icon and the menu bar glyph are one design at two optical sizes.
// Below roughly 64px the gap between the two cards lands sub-pixel and the
// mark fuses into a single blob, so `gap(forInk:)` widens it as the artwork
// shrinks. That ramp is the reason this is a renderer rather than two
// exported SVGs: proportional scaling produces a mark that is correct on
// paper and unreadable in the menu bar.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

/// The mark lives in a 100x100 design space. Each card is a square with
/// rounded corners turned 45 degrees; the pair is offset along `angle` so the
/// composition squares up enough to fill an icon without costing menu bar
/// height, which is the scarce dimension there.
enum Mark {
    static let angle: CGFloat = 34 * .pi / 180
    static let distance: CGFloat = 27
    static let radius: CGFloat = 27
    static let corner: CGFloat = 9

    static var halfX: CGFloat { cos(angle) * distance / 2 }
    static var halfY: CGFloat { sin(angle) * distance / 2 }

    /// Front card sits low and left, back card high and right, so the pair
    /// reads as a stack receding rather than as two shapes side by side.
    /// Core Graphics puts the origin at the bottom left, so the front card
    /// takes the smaller y.
    static var front: CGPoint { CGPoint(x: 50 - halfX, y: 50 - halfY) }
    static var back: CGPoint { CGPoint(x: 50 + halfX, y: 50 + halfY) }

    /// How far the drawn ink actually reaches from a card's centre. Rounding a
    /// corner pulls the tip in by `corner * (sqrt(2) - 1)`, so the sharp
    /// diamond's half-diagonal overstates the mark by about a tenth of its
    /// width and every ratio measured against it comes out short.
    static var reach: CGFloat { radius - corner * (2.squareRoot() - 1) }

    /// Tight bounds of the ink. Sizing against this rather than the 100x100
    /// space is what keeps the mark from floating inside the icon.
    static var bounds: CGRect {
        CGRect(x: 50 - halfX - reach, y: 50 - halfY - reach,
               width: 2 * (halfX + reach), height: 2 * (halfY + reach))
    }
}

func cardPath(center: CGPoint, radius: CGFloat, corner: CGFloat) -> CGPath {
    let side = radius * 2.squareRoot()
    let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    var turn = CGAffineTransform(translationX: center.x, y: center.y)
        .rotated(by: .pi / 4)
        .translatedBy(x: -center.x, y: -center.y)
    let rounded = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    return rounded.copy(using: &turn) ?? rounded
}

/// macOS corners are a continuous curve rather than a circular arc. Sampling a
/// superellipse is close enough at every size we ship and avoids hand-fitting
/// Beziers.
func squirclePath(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let x = rect.midX + a * copysign(pow(abs(cos(t)), 2 / exponent), cos(t))
        let y = rect.midY + b * copysign(pow(abs(sin(t)), 2 / exponent), sin(t))
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// How much the front card grows by when it is knocked out of the back one,
/// for a given rendered ink width in pixels. The value is added to a
/// half-diagonal, so the gap it opens perpendicular to the seam is `1/sqrt(2)`
/// of what is returned.
func gap(forInk width: CGFloat) -> CGFloat {
    switch width {
    case ..<40: 11
    case ..<80: 9
    case ..<200: 7
    default: 5
    }
}

// MARK: - Drawing

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let groundTop: UInt32 = 0x2E3543
let groundBottom: UInt32 = 0x161B25
let frontFill: UInt32 = 0x6FC0F7
/// Deliberately below the front card's luminance. Near-white here reverses the
/// reading: the card meant to sit behind becomes the brightest thing in the
/// icon and out-shouts the one in front.
let backFill: UInt32 = 0xC9D3E0

func makeContext(width: Int, height: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create a \(width)x\(height) bitmap context")
    }
    return ctx
}

/// The mark is composited from its own transparent layer so the knockout gap
/// clears only the back card and lets the ground show through it. Punching the
/// gap straight into the icon would cut a hole in the gradient instead.
func markImage(fitting box: CGRect, canvas: CGSize, front: CGColor, back: CGColor) -> CGImage {
    let ctx = makeContext(width: Int(canvas.width), height: Int(canvas.height))
    let source = Mark.bounds
    let scale = min(box.width / source.width, box.height / source.height)

    ctx.translateBy(x: box.midX - source.midX * scale, y: box.midY - source.midY * scale)
    ctx.scaleBy(x: scale, y: scale)

    let inkWidth = source.width * scale
    let cut = gap(forInk: inkWidth)

    ctx.addPath(cardPath(center: Mark.back, radius: Mark.radius, corner: Mark.corner))
    ctx.setFillColor(back)
    ctx.fillPath()

    ctx.setBlendMode(.clear)
    ctx.addPath(cardPath(center: Mark.front, radius: Mark.radius + cut, corner: Mark.corner + cut))
    ctx.fillPath()

    ctx.setBlendMode(.normal)
    ctx.addPath(cardPath(center: Mark.front, radius: Mark.radius, corner: Mark.corner))
    ctx.setFillColor(front)
    ctx.fillPath()

    guard let image = ctx.makeImage() else { fatalError("could not compose the mark") }
    return image
}

/// macOS draws the icon body inset in its canvas: 824pt of artwork inside
/// 1024pt, the margin reserved for the system's own shadow.
let bodyRatio: CGFloat = 824.0 / 1024.0
/// Share of the body width the ink spans. Below this the mark floats; above it
/// the cards crowd the corners.
let inkRatio: CGFloat = 0.68

func appIcon(size: Int) -> CGImage {
    let px = CGFloat(size)
    let ctx = makeContext(width: size, height: size)

    let body = px * bodyRatio
    let bodyRect = CGRect(x: (px - body) / 2, y: (px - body) / 2, width: body, height: body)

    ctx.saveGState()
    ctx.addPath(squirclePath(in: bodyRect))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [color(groundBottom), color(groundTop)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: bodyRect.minY),
                           end: CGPoint(x: 0, y: bodyRect.maxY),
                           options: [])
    ctx.restoreGState()

    let inkWidth = body * inkRatio
    let inkBox = CGRect(x: (px - inkWidth) / 2, y: (px - inkWidth) / 2, width: inkWidth, height: inkWidth)
    let mark = markImage(fitting: inkBox, canvas: CGSize(width: px, height: px),
                         front: color(frontFill), back: color(backFill))
    ctx.draw(mark, in: CGRect(x: 0, y: 0, width: px, height: px))

    guard let image = ctx.makeImage() else { fatalError("could not compose the app icon") }
    return image
}

/// Template images keep only their alpha: macOS discards the colour and tints
/// for the light or dark bar, so both cards are drawn in the same opaque black
/// and the knockout gap is the only thing separating them.
func menuBarGlyph(width: Int, height: Int) -> CGImage {
    let ctx = makeContext(width: width, height: height)
    let inset = CGFloat(height) * 0.09
    let box = CGRect(x: inset, y: inset,
                     width: CGFloat(width) - inset * 2, height: CGFloat(height) - inset * 2)
    let mark = markImage(fitting: box, canvas: CGSize(width: width, height: height),
                         front: color(0x000000), back: color(0x000000))
    ctx.draw(mark, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    guard let image = ctx.makeImage() else { fatalError("could not compose the menu bar glyph") }
    return image
}

// MARK: - Output

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not open \(path) for writing")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(path)") }
    print("  \(url.lastPathComponent)")
}

let root = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath
let iconSet = "\(root)/App/Assets.xcassets/AppIcon.appiconset"
let glyphSet = "\(root)/App/Assets.xcassets/MenuBarIcon.imageset"

print("app icon")
for point in [16, 32, 128, 256, 512] {
    write(appIcon(size: point), to: "\(iconSet)/icon_\(point)x\(point).png")
    write(appIcon(size: point * 2), to: "\(iconSet)/icon_\(point)x\(point)@2x.png")
}

// The mark is wider than it is tall and the menu bar rations height, not
// width, so the glyph is not square.
print("menu bar glyph")
write(menuBarGlyph(width: 20, height: 18), to: "\(glyphSet)/menubar.png")
write(menuBarGlyph(width: 40, height: 36), to: "\(glyphSet)/menubar@2x.png")
