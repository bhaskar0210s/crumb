// Renders Crumb's app icon into an .iconset directory (see `make icon`): a stack of three cards, the history, with a
// crumb on top, on a graphite tile.

import CoreGraphics
import Foundation
import ImageIO

func color(_ rgb: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}

/// A rectangle with continuous ("squircle") corners, the shape of macOS app icons.
func squircle(_ r: CGRect, _ k: CGFloat) -> CGPath {
    let x = r.minX, y = r.minY, w = r.width, h = r.height
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x + 1.52866483 * k, y: y))
    // From the end of one edge to the start of the next, around the corner (cx, cy). (dx1, dy1) points back along the
    // incoming edge, (dx2, dy2) along the outgoing one.
    func corner(_ cx: CGFloat, _ cy: CGFloat, _ dx1: CGFloat, _ dy1: CGFloat, _ dx2: CGFloat, _ dy2: CGFloat) {
        func pt(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: cx + dx1 * a * k + dx2 * b * k, y: cy + dy1 * a * k + dy2 * b * k) }
        p.addLine(to: pt(1.52866483, 0))
        p.addCurve(to: pt(0.63149399, 0.07491100), control1: pt(1.08849296, 0), control2: pt(0.86840694, 0))
        p.addCurve(to: pt(0.07491100, 0.63149399), control1: pt(0.37282383, 0.16906599), control2: pt(0.16906599, 0.37282383))
        p.addCurve(to: pt(0, 1.52866483), control1: pt(0, 0.86840694), control2: pt(0, 1.08849296))
    }
    corner(x + w, y, -1, 0, 0, 1)       // bottom right (y grows upward)
    corner(x + w, y + h, 0, -1, -1, 0)  // top right
    corner(x, y + h, 1, 0, 0, -1)       // top left
    corner(x, y, 0, 1, 1, 0)            // bottom left
    p.closeSubpath()
    return p
}

func fill(_ g: CGContext, _ path: CGPath, _ rgb: Int, _ alpha: CGFloat = 1) {
    g.addPath(path)
    g.setFillColor(color(rgb, alpha))
    g.fillPath()
}

func gradientFill(_ g: CGContext, _ path: CGPath, top: Int, bottom: Int, _ y0: CGFloat, _ y1: CGFloat) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(top), color(bottom)] as CFArray, locations: nil)!
    g.saveGState()
    g.addPath(path)
    g.clip()
    g.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y1), end: CGPoint(x: 0, y: y0), options: [])
    g.restoreGState()
}

func card(_ g: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, top: Int, bottom: Int, shadow: CGFloat) {
    let path = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: 56, cornerHeight: 56, transform: nil)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, shadow))
    fill(g, path, bottom)
    g.restoreGState()
    gradientFill(g, path, top: top, bottom: bottom, y, y + h)
}

func bar(_ g: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ rgb: Int, _ alpha: CGFloat) {
    fill(g, CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil), rgb, alpha)
}

func render(_ pixels: Int, to file: String) {
    let g = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    g.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // The tile: the macOS icon grid's 824-point square, with a soft shadow below it.
    let tile = squircle(CGRect(x: 100, y: 100, width: 824, height: 824), 120)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x000000, 0.32))
    fill(g, tile, 0x1C1C1E)
    g.restoreGState()
    gradientFill(g, tile, top: 0x48484C, bottom: 0x1C1C1E, 100, 924)

    // The history: three cards, the newest in front.
    card(g, 322, 404, 380, 300, top: 0x5E5E63, bottom: 0x48484D, shadow: 0.25)
    card(g, 287, 334, 450, 300, top: 0x9E9EA4, bottom: 0x84848A, shadow: 0.3)
    card(g, 252, 236, 520, 330, top: 0xFFFFFF, bottom: 0xE7E7EC, shadow: 0.35)
    bar(g, 312, 470, 300, 0x3A3A3C, 0.85)
    bar(g, 312, 410, 380, 0x3A3A3C, 0.55)
    bar(g, 312, 350, 240, 0x3A3A3C, 0.55)

    // The crumb: a toasted, slightly angular morsel resting on the front card.
    let cx: CGFloat = 672, cy: CGFloat = 296, r: CGFloat = 58
    let corners: [(CGFloat, CGFloat)] = [(-1.00, 0.10), (-0.72, 0.74), (-0.05, 0.98), (0.62, 0.80), (1.02, 0.18),
                                         (0.80, -0.62), (0.10, -0.92), (-0.62, -0.70)]
    let crumb = CGMutablePath()
    let n = corners.count
    for i in 0...n {
        // Rounded corners: each corner is a quadratic curve between the midpoints of its two edges.
        let a = corners[(i + n - 1) % n], b = corners[i % n], c = corners[(i + 1) % n]
        let m1 = CGPoint(x: cx + r * (a.0 + b.0) / 2, y: cy + r * (a.1 + b.1) / 2)
        let m2 = CGPoint(x: cx + r * (b.0 + c.0) / 2, y: cy + r * (b.1 + c.1) / 2)
        if i == 0 { crumb.move(to: m1) }
        crumb.addQuadCurve(to: m2, control: CGPoint(x: cx + r * b.0, y: cy + r * b.1))
    }
    crumb.closeSubpath()
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: color(0x4A2600, 0.45))
    fill(g, crumb, 0xC27A2C)
    g.restoreGState()
    gradientFill(g, crumb, top: 0xF6C978, bottom: 0xC27A2C, cy - r, cy + r)
    // A few pores.
    for (px, py, pr) in [(-0.38, 0.30, 0.13), (0.30, 0.38, 0.10), (0.05, -0.30, 0.12), (0.52, -0.18, 0.08)] as [(CGFloat, CGFloat, CGFloat)] {
        fill(g, CGPath(ellipseIn: CGRect(x: cx + r * px - r * pr, y: cy + r * py - r * pr, width: 2 * r * pr, height: 2 * r * pr), transform: nil),
             0x9A5A1C, 0.55)
    }

    let image = g.makeImage()!
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: file) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: icon <dir.iconset> [preview.png]\n".utf8))
    exit(1)
}
// Sizes above 256pt@2x are left out on purpose: Finder scales up, and the app stays small.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2)] {
    render(points * scale, to: arguments[1] + "/icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
}
if arguments.count > 2 { render(512, to: arguments[2]) }
