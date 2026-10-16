// Drawing helpers shared by Crumb's views: CPU rendering into IOSurfaces, and the few icons (drawn with paths:
// system symbol images would load the whole symbol catalog for six glyphs).

import AppKit
import IOSurface

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// White and black in sRGB, like the system colors: NSColor.white and .black are gray-space colors, and drawing one
// into an sRGB surface goes through a ColorSync conversion that leaves a lookup table behind.
let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

/// An 8-bit BGRA IOSurface drawn on the CPU, tagged with the color space it was drawn in. Used as a layer's
/// contents, the window server composites straight from this memory, so the pixels exist only once (a CGImage
/// would be copied for it), and it matches colors to the display itself, outside Crumb.
func makeSurface(width: Int, height: Int, space: CGColorSpace = sRGB, draw: (CGContext) -> Void) -> IOSurface? {
    guard width > 0, height > 0,
          let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4, .pixelFormat: 0x4247_5241])  // 'BGRA'
    else { return nil }
    if let description = space.copyPropertyList() { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, description) }
    surface.lock(options: [], seed: nil)
    defer { surface.unlock(options: [], seed: nil) }
    guard let context = CGContext(data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: surface.bytesPerRow, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    draw(context)
    return surface
}

/// A picture copied into a surface in its own color space, so no color conversion (and none of the lookup tables
/// ColorSync would keep for it) ever happens in Crumb. Pictures in other kinds of color space are drawn in sRGB.
func pictureSurface(_ image: CGImage, width: Int, height: Int) -> IOSurface? {
    func draw(_ context: CGContext) {
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    if let own = image.colorSpace, own.model == .rgb, let surface = makeSurface(width: width, height: height, space: own, draw: draw) {
        return surface
    }
    return makeSurface(width: width, height: height, draw: draw)
}

/// Renders a view's drawing on the CPU into its layer's contents. The system's own drawing path moves larger
/// views onto the GPU, which loads a couple of megabytes of shaders for good.
@MainActor
func renderIntoLayer(_ view: NSView, _ draw: (NSRect) -> Void) {
    let size = view.bounds.size
    let scale = view.window?.backingScaleFactor ?? 2
    let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
    let surface = makeSurface(width: width, height: height) { context in
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    view.layer?.contentsScale = scale
    view.layer?.contents = surface
}

/// A flipped view drawn through renderIntoLayer: subclasses just implement draw(_:).
class CanvasView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        renderIntoLayer(self) { draw($0) }
    }
}

/// A color resolved for this view's appearance (light or dark), for Core Graphics and Core Animation.
extension NSView {
    func resolved(_ color: NSColor) -> CGColor {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return cg
    }
}

enum Icon {
    case search, gear, power, document, documents, folder
}

private func stroked(_ width: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

/// A page with a folded corner; (x, y) is its top-left corner in a flipped view.
private func page(_ path: NSBezierPath, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ fold: CGFloat) {
    path.move(to: NSPoint(x: x, y: y))
    path.line(to: NSPoint(x: x + w - fold, y: y))
    path.line(to: NSPoint(x: x + w, y: y + fold))
    path.line(to: NSPoint(x: x + w, y: y + h))
    path.line(to: NSPoint(x: x, y: y + h))
    path.close()
    path.move(to: NSPoint(x: x + w - fold, y: y))
    path.line(to: NSPoint(x: x + w - fold, y: y + fold))
    path.line(to: NSPoint(x: x + w, y: y + fold))
}

/// Draws one of Crumb's icons into a square in a flipped view.
func drawIcon(_ icon: Icon, in box: NSRect, color: NSColor) {
    let s = min(box.width, box.height)
    let x0 = box.minX + (box.width - s) / 2, y0 = box.minY + (box.height - s) / 2
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x0 + x * s, y: y0 + y * s) }
    let path = stroked(max(1.25, s * 0.095))
    color.setStroke()

    switch icon {
    case .search:
        path.appendOval(in: NSRect(x: x0 + 0.14 * s, y: y0 + 0.14 * s, width: 0.56 * s, height: 0.56 * s))
        path.move(to: p(0.63, 0.63))
        path.line(to: p(0.88, 0.88))
    case .power:
        // An open ring with a bar through the gap (the views are flipped: angles run clockwise).
        path.appendArc(withCenter: p(0.5, 0.54), radius: 0.34 * s, startAngle: -58, endAngle: 238, clockwise: false)
        path.move(to: p(0.5, 0.1))
        path.line(to: p(0.5, 0.5))
    case .gear:
        // One outline around eight teeth, and the hole in the middle.
        let c = p(0.5, 0.5)
        let outer = 0.45 * s, inner = 0.33 * s
        func at(_ degrees: CGFloat, _ radius: CGFloat) -> NSPoint {
            let a = degrees * .pi / 180
            return NSPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a))
        }
        for i in 0..<8 {
            let a = CGFloat(i * 45)
            if i == 0 {
                path.move(to: at(a - 15, inner))
            } else {
                path.appendArc(withCenter: c, radius: inner, startAngle: a - 30, endAngle: a - 15, clockwise: false)
            }
            path.line(to: at(a - 8, outer))
            path.appendArc(withCenter: c, radius: outer, startAngle: a - 8, endAngle: a + 8, clockwise: false)
            path.line(to: at(a + 15, inner))
        }
        path.appendArc(withCenter: c, radius: inner, startAngle: 315 + 15, endAngle: 360 - 15, clockwise: false)
        path.close()
        path.appendOval(in: NSRect(x: c.x - 0.13 * s, y: c.y - 0.13 * s, width: 0.26 * s, height: 0.26 * s))
    case .document:
        page(path, x0 + 0.2 * s, y0 + 0.08 * s, 0.6 * s, 0.84 * s, 0.22 * s)
    case .documents:
        page(path, x0 + 0.14 * s, y0 + 0.2 * s, 0.56 * s, 0.74 * s, 0.2 * s)
        // The page behind peeks out above and to the right.
        path.move(to: p(0.3, 0.2))
        path.line(to: p(0.3, 0.06))
        path.line(to: p(0.86, 0.06))
        path.line(to: p(0.86, 0.8))
        path.line(to: p(0.7, 0.8))
    case .folder:
        path.move(to: p(0.08, 0.22))
        path.line(to: p(0.38, 0.22))
        path.line(to: p(0.47, 0.32))
        path.line(to: p(0.92, 0.32))
        path.line(to: p(0.92, 0.82))
        path.line(to: p(0.08, 0.82))
        path.close()
    }
    path.stroke()
}
