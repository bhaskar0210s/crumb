// What an entry looks like in full, shown beside the list after three seconds.

import AppKit
import CoreText

private let insetX: CGFloat = 14
private let insetY: CGFloat = 12
private let blockChars = 2000  // long paragraphs are laid out in pieces of about this size
@MainActor private let previewFont = NSFont.systemFont(ofSize: 13)

/// Text drawn with Core Text, laid out a paragraph at a time as it scrolls into view, so even megabytes of text open
/// at once and never pull in the system text engine.
final class TextPreview: CanvasView {
    private struct Block {
        var location: Int, length: Int
        var height: CGFloat
        var measured = false
    }

    private let text: NSString
    private var blocks: [Block] = []
    private var tops: [CGFloat] = []  // top of each block, plus the total height at the end
    private var frames: [Int: CTFrame] = [:]
    private let textWidth: CGFloat
    private let lineHeight: CGFloat
    private var offset: CGFloat = 0
    private var scrolling = false
    private var scrollGeneration = 0

    init(text: String, maxWidth: CGFloat, maxHeight: CGFloat) {
        self.text = text as NSString
        textWidth = maxWidth - 2 * insetX
        lineHeight = (previewFont.ascender - previewFont.descender + previewFont.leading).rounded(.up)
        super.init(frame: .zero)
        split()
        updateTops(from: 0)
        var width = maxWidth
        if self.text.length <= 20000 {  // short texts get a snug window
            var widest: CGFloat = 0
            for i in blocks.indices { widest = max(widest, measure(i)) }
            updateTops(from: 0)
            width = min(maxWidth, widest.rounded(.up) + 2 * insetX + 2)
        }
        let height = min(maxHeight, tops[tops.count - 1] + 2 * insetY)
        frame = NSRect(x: 0, y: 0, width: max(width, 120), height: max(height, 36))
    }

    required init?(coder: NSCoder) { nil }

    private func split() {
        let length = text.length
        let newlines = CharacterSet.newlines, spaces = CharacterSet.whitespaces
        var start = 0
        while start < length || (start == 0 && length == 0) {
            let lineBreak = text.rangeOfCharacter(from: newlines, options: [], range: NSRange(location: start, length: length - start))
            let end = lineBreak.location == NSNotFound ? length : lineBreak.location
            var piece = start
            repeat {
                var cut = min(end, piece + blockChars)
                if cut < end {
                    let space = text.rangeOfCharacter(from: spaces, options: .backwards,
                                                      range: NSRange(location: piece + blockChars / 2, length: cut - piece - blockChars / 2))
                    cut = space.location != NSNotFound ? space.location + 1 : text.rangeOfComposedCharacterSequence(at: cut).location
                    if cut <= piece { cut = min(end, piece + blockChars) }
                }
                blocks.append(Block(location: piece, length: cut - piece, height: 0))
                piece = cut
            } while piece < end
            if lineBreak.location == NSNotFound { break }
            start = NSMaxRange(lineBreak)
            if text.character(at: lineBreak.location) == 0x0D && start < length && text.character(at: start) == 0x0A { start += 1 }
        }
        let perLine = max(1, textWidth / (previewFont.pointSize * 0.52))
        for i in blocks.indices {
            blocks[i].height = lineHeight * max(1, (CGFloat(blocks[i].length) / perLine).rounded(.up))
        }
    }

    private func string(_ index: Int) -> NSAttributedString {
        let block = blocks[index]
        return NSAttributedString(string: text.substring(with: NSRange(location: block.location, length: block.length)), attributes: [
            .font: previewFont, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
    }

    /// Lays out one block; returns its width.
    @discardableResult
    private func measure(_ index: Int) -> CGFloat {
        if blocks[index].length == 0 {
            blocks[index].height = lineHeight
            blocks[index].measured = true
            return 0
        }
        let setter = CTFramesetterCreateWithAttributedString(string(index))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: textWidth, height: .greatestFiniteMagnitude), nil)
        blocks[index].height = size.height.rounded(.up)
        blocks[index].measured = true
        return size.width
    }

    private func updateTops(from index: Int) {
        if tops.count != blocks.count + 1 { tops = Array(repeating: 0, count: blocks.count + 1) }
        for i in index..<blocks.count { tops[i + 1] = tops[i] + blocks[i].height }
    }

    private func block(at y: CGFloat) -> Int {
        var low = 0, high = blocks.count  // the last block whose top is at or above y
        while low < high {
            let mid = (low + high) / 2
            if tops[mid + 1] <= y { low = mid + 1 } else { high = mid }
        }
        return min(low, max(blocks.count - 1, 0))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !blocks.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let visibleTop = offset, visibleBottom = offset + bounds.height
        // Measure what is about to show; real heights replace the estimates.
        var i = block(at: max(0, visibleTop - insetY))
        while i < blocks.count && tops[i] < visibleBottom {
            if !blocks[i].measured {
                measure(i)
                updateTops(from: i)
            }
            i += 1
        }
        if frames.count > 64 { frames = [:] }

        let color = resolved(.labelColor)
        i = block(at: max(0, visibleTop - insetY))
        while i < blocks.count && insetY + tops[i] - offset < dirtyRect.maxY {
            defer { i += 1 }
            let height = blocks[i].height
            if blocks[i].length == 0 { continue }
            let frame = frames[i] ?? {
                let setter = CTFramesetterCreateWithAttributedString(string(i))
                let path = CGPath(rect: CGRect(x: 0, y: 0, width: textWidth, height: height + lineHeight), transform: nil)
                return CTFramesetterCreateFrame(setter, CFRange(), path, nil)
            }()
            frames[i] = frame
            context.saveGState()
            context.translateBy(x: insetX, y: insetY + tops[i] - offset + height + lineHeight)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.setFillColor(color)
            CTFrameDraw(frame, context)
            context.restoreGState()
        }

        let total = tops[tops.count - 1] + 2 * insetY, viewHeight = bounds.height
        if scrolling && total > viewHeight {
            let knob = max(24, viewHeight * viewHeight / total)
            let y = (viewHeight - knob) * offset / (total - viewHeight)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.width - 6, y: y + 3, width: 3, height: knob - 6), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * lineHeight * 3
        let total = tops[tops.count - 1] + 2 * insetY
        let target = min(max(offset - delta, 0), max(0, total - bounds.height))
        if target == offset { return }
        offset = target
        scrolling = true
        scrollGeneration += 1
        let generation = scrollGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(800)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.scrollGeneration == generation else { return }
                self.scrolling = false
                self.needsDisplay = true
            }
        }
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text.length > 2000 ? text.substring(to: 2000) : text as String }
}

/// A picture on a layer of its own, in its own color space (the window server matches it to the display).
final class ImagePreview: NSView {
    init(picture: CGImage, size: NSSize, scale: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size.width + 16, height: size.height + 16))
        wantsLayer = true
        let layer = CALayer()
        layer.frame = CGRect(x: 8, y: 8, width: size.width, height: size.height)
        layer.contents = pictureSurface(picture, width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)))
        layer.contentsGravity = .resize
        layer.cornerRadius = 6
        layer.masksToBounds = true
        self.layer?.addSublayer(layer)
    }

    required init?(coder: NSCoder) { nil }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { "Picture" }
}
