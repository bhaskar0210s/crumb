// The rows of the history list: drawn on the CPU, scrolled by Crumb itself, with each visible picture on a layer
// of its own.

import AppKit
import CoreText
import ImageIO

let rowHeight: CGFloat = 30
let gutter: CGFloat = 6        // between the panel edge and a row's highlight
private let inset: CGFloat = 10  // between a highlight's edge and its contents
private let thumbMaxHeight: CGFloat = 40   // tallest picture in the list (points)
private let thumbMaxWidth: CGFloat = 260

struct Row {
    var item = 0            // index into Store.items
    var id: UInt64 = 0
    var y: CGFloat = 0
    var height = rowHeight
    var matches: [UInt32] = []
    var line: CTLine?       // built on first draw
    var folder: Int8 = -1   // single-file rows: whether the file is a folder
}

@MainActor let rowFont = NSFont.systemFont(ofSize: 13)
@MainActor private let boldFont = NSFont.systemFont(ofSize: 13, weight: .bold)
@MainActor private let hintFont = NSFont.systemFont(ofSize: 12)

/// A line whose color comes from the context, so one line serves selected and unselected rows.
func makeLine(_ string: String, font: NSFont) -> CTLine {
    let text = NSAttributedString(string: string, attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
    return CTLineCreateWithAttributedString(text)
}

@MainActor
private func makeLine(_ line: Line, width: CGFloat, ellipsis: CTLine) -> CTLine {
    let text = NSMutableAttributedString(string: line.text, attributes: [
        .font: rowFont, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ])
    let length = (line.text as NSString).length
    for range in line.bold where range.offset + range.length <= length {
        text.addAttribute(.font, value: boldFont, range: NSRange(location: range.offset, length: range.length))
    }
    let full = CTLineCreateWithAttributedString(text)
    return CTLineCreateTruncatedLine(full, width, .end, ellipsis) ?? full
}

func lineWidth(_ line: CTLine?) -> CGFloat {
    line.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) } ?? 0
}

func drawLine(_ context: CGContext, _ line: CTLine, x: CGFloat, top: CGFloat, height: CGFloat, font: NSFont, color: CGColor) {
    let baseline = (top + (height - font.ascender + font.descender) / 2 + font.ascender).rounded()
    context.saveGState()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // the view is flipped
    context.textPosition = CGPoint(x: x, y: baseline)
    context.setFillColor(color)
    CTLineDraw(line, context)
    context.restoreGState()
}

private func fileCount(_ item: Item) -> Int {
    item.head.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
}

/// A picture's size in the list: its natural size on a Retina screen, scaled down to fit.
func thumbSize(_ item: Item) -> NSSize {
    let w = max(1, CGFloat(item.width) / 2), h = max(1, CGFloat(item.height) / 2)
    let scale = min(1, thumbMaxHeight / h, thumbMaxWidth / w)
    return NSSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
}

@MainActor
protocol ListViewDelegate: AnyObject {
    func listDidHover(_ row: Int)
    func listDidClick(_ row: Int)
}

final class ListView: CanvasView {
    private let store: Store
    weak var delegate: ListViewDelegate?
    var emptyText = ""
    private(set) var rows: [Row] = []
    private(set) var contentHeight: CGFloat = 0
    private var offset: CGFloat = 0  // how far the list is scrolled
    private var pressed = -1
    private var scrolling = false
    private var scrollGeneration = 0
    private var pictures: [UInt64: CALayer] = [:]  // the visible rows' pictures, by entry
    private var ellipsis: CTLine?
    private var hints: [CTLine?] = Array(repeating: nil, count: 9)
    private var elements: [NSAccessibilityElement]?  // the rows for VoiceOver, made when it first asks

    var selected = -1 {
        didSet {
            guard selected != oldValue else { return }
            needsDisplay = true
            selectionChangedForAccessibility()
        }
    }

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        layer?.masksToBounds = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc var count: Int { rows.count }
    func item(at row: Int) -> Int { rows[row].item }
    func id(at row: Int) -> UInt64 { rows[row].id }

    func setRows(_ rows: [Row]) {
        self.rows = rows
        let items = store.items
        var y = gutter
        for i in self.rows.indices {
            let item = items[self.rows[i].item]
            self.rows[i].y = y
            self.rows[i].id = item.id
            self.rows[i].height = item.kind == .image ? max(rowHeight, thumbSize(item).height + 10) : rowHeight
            y += self.rows[i].height
        }
        contentHeight = rows.isEmpty ? 0 : y + gutter
        offset = 0
        elements = nil
        selected = rows.isEmpty ? -1 : 0
        needsDisplay = true
    }

    func clear() {
        elements = nil
        rows = []
        for layer in pictures.values { layer.removeFromSuperlayer() }
        pictures = [:]
        selected = -1
        offset = 0
    }

    /// A row's rectangle in view coordinates, after scrolling.
    func rect(ofRow index: Int) -> NSRect {
        let row = rows[index]
        return NSRect(x: gutter, y: row.y - offset, width: bounds.width - 2 * gutter, height: row.height)
    }

    private func row(at point: NSPoint) -> Int {
        guard point.x >= 0, point.x <= bounds.width, point.y >= 0, point.y <= bounds.height else { return -1 }
        let y = point.y + offset
        let i = firstRow(endingAfter: y)
        return i < rows.count && y >= rows[i].y ? i : -1
    }

    /// The first row whose bottom lies below `y` (rows are sorted by position).
    private func firstRow(endingAfter y: CGFloat) -> Int {
        var low = 0, high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].y + rows[mid].height <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func scroll(to target: CGFloat) {
        let target = min(max(target, 0), max(0, contentHeight - bounds.height))
        if target == offset { return }
        offset = target
        if let elements {
            for (index, element) in elements.enumerated() { element.setAccessibilityFrameInParentSpace(rect(ofRow: index)) }
        }
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

    func scrollToSelection() {
        guard selected >= 0 else { return }
        let row = rows[selected]
        let height = bounds.height
        if selected == 0 {
            scroll(to: 0)
        } else if selected == count - 1 {
            scroll(to: contentHeight - height)
        } else if row.y < offset {
            scroll(to: row.y)
        } else if row.y + row.height > offset + height {
            scroll(to: row.y + row.height - height)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let width = bounds.width
        var shown = Set<UInt64>()
        defer { hidePictures(except: shown) }

        if rows.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: rowFont, .foregroundColor: NSColor.secondaryLabelColor]
            let size = emptyText.size(withAttributes: attributes)
            emptyText.draw(at: NSPoint(x: ((width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded()),
                           withAttributes: attributes)
            return
        }
        let ellipsis = self.ellipsis ?? makeLine("…", font: rowFont)
        self.ellipsis = ellipsis
        let items = store.items
        let label = resolved(.labelColor), selectedText = white.cgColor
        let hint = resolved(.tertiaryLabelColor), selectedHint = white.withAlphaComponent(0.75).cgColor
        let top = dirtyRect.minY + offset, bottom = dirtyRect.maxY + offset

        var index = firstRow(endingAfter: top)
        while index < rows.count && rows[index].y < bottom {
            defer { index += 1 }
            let isSelected = index == selected
            let item = items[rows[index].item]
            let box = NSRect(x: gutter, y: rows[index].y - offset, width: width - 2 * gutter, height: rows[index].height)
            if isSelected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            }
            var right = box.maxX - inset
            if index < 9 {
                let line = hints[index] ?? makeLine("⌘\(index + 1)", font: hintFont)
                hints[index] = line
                let w = lineWidth(line)
                drawLine(context, line, x: right - w, top: box.minY, height: box.height, font: hintFont, color: isSelected ? selectedHint : hint)
                right -= w + 12
            }
            var x = box.minX + inset

            if item.kind == .image {
                let size = thumbSize(item)
                let frame = NSRect(x: x, y: (box.minY + (box.height - size.height) / 2).rounded(), width: size.width, height: size.height)
                if showPicture(item, frame: frame) { shown.insert(item.id) }
                continue
            }
            if item.kind == .files {
                let files = fileCount(item)
                if files == 1 && rows[index].folder < 0 {
                    var directory: ObjCBool = false
                    let path = String(decoding: item.head, as: UTF8.self)
                    rows[index].folder = FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue ? 1 : 0
                }
                let icon: Icon = files > 1 ? .documents : rows[index].folder == 1 ? .folder : .document
                drawIcon(icon, in: NSRect(x: x, y: (box.minY + (box.height - 16) / 2).rounded(), width: 16, height: 16),
                         color: isSelected ? white : .labelColor)
                x += 24
            }
            let line = rows[index].line ?? makeLine(Crumb.makeLine(displayText(item), matches: rows[index].matches, maxChars: 300),
                                                     width: right - x, ellipsis: ellipsis)
            rows[index].line = line
            drawLine(context, line, x: x, top: box.minY, height: box.height, font: rowFont, color: isSelected ? selectedText : label)
        }

        // A slim scroll indicator while scrolling.
        let height = bounds.height
        if scrolling && contentHeight > height {
            let knob = max(24, height * height / contentHeight)
            let y = (height - knob) * offset / (contentHeight - height)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: width - 5, y: y + 2, width: 3, height: knob - 4), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    /// Puts a row's picture on its own layer. The window server matches its colors to the display: drawn into the
    /// list here, every picture's color profile would leave a large lookup table behind in Crumb.
    private func showPicture(_ item: Item, frame: NSRect) -> Bool {
        guard let host = layer else { return false }
        var picture = pictures[item.id]
        if picture == nil {
            let scale = window?.backingScaleFactor ?? 2
            let url = URL(fileURLWithPath: store.file(item.id, "thumb.png")) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let surface = pictureSurface(image, width: Int((frame.width * scale).rounded(.up)), height: Int((frame.height * scale).rounded(.up)))
            else { return false }
            let created = CALayer()
            created.contents = surface
            created.contentsGravity = .resize
            created.cornerRadius = 4
            created.masksToBounds = true
            created.borderWidth = 0.5
            created.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "contents": NSNull(), "borderColor": NSNull()]
            host.addSublayer(created)
            pictures[item.id] = created
            picture = created
        }
        guard let picture else { return false }
        // A hairline keeps pale pictures from melting into the background.
        picture.borderColor = resolved(NSColor.labelColor.withAlphaComponent(0.12))
        picture.frame = convertToLayer(frame)
        picture.isHidden = false
        return true
    }

    private func hidePictures(except shown: Set<UInt64>) {
        for (id, layer) in pictures where !shown.contains(id) { layer.isHidden = true }
    }

    // MARK: Mouse

    private func row(for event: NSEvent) -> Int {
        row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let row = row(for: event)
        if row >= 0 && row != selected { delegate?.listDidHover(row) }
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = row(for: event)
        if pressed >= 0 && pressed != selected { delegate?.listDidHover(pressed) }
    }

    override func mouseUp(with event: NSEvent) {
        let row = row(for: event)
        if row >= 0 && row == pressed { delegate?.listDidClick(row) }
        pressed = -1
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * rowHeight
        scroll(to: offset - delta)
        // The rows moved under the pointer.
        let row = row(for: event)
        if row >= 0 && row != selected { delegate?.listDidHover(row) }
    }

    // MARK: VoiceOver

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Clipboard history" }

    override func accessibilityChildren() -> [Any]? {
        if let elements { return elements }
        let items = store.items
        let made = rows.indices.map { index in
            let item = items[rows[index].item]
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(item.kind == .image && !item.flags.contains(.text)
                ? "Picture, \(item.width) by \(item.height)" : String(decoding: item.head.prefix(300), as: UTF8.self))
            element.setAccessibilityFrameInParentSpace(rect(ofRow: index))
            element.setAccessibilitySelected(index == selected)
            return element
        }
        elements = made
        return made
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        guard let elements = accessibilityChildren() as? [NSAccessibilityElement], elements.indices.contains(selected) else { return [] }
        return [elements[selected]]
    }

    /// Keeps VoiceOver with the selection: the keyboard stays in the search field while the arrows move it.
    private func selectionChangedForAccessibility() {
        guard let elements else { return }
        for (index, element) in elements.enumerated() { element.setAccessibilitySelected(index == selected) }
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        if NSWorkspace.shared.isVoiceOverEnabled, elements.indices.contains(selected), let label = elements[selected].accessibilityLabel() {
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: label, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}
