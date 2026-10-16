// The history list: opens at the pointer, filters as you type, previews an entry after three seconds. Its gear turns
// it into the settings page.

import AppKit
import Carbon
import ImageIO
import QuartzCore

private let width: CGFloat = 440
private let radius: CGFloat = 12   // panel corners
private let headerHeight: CGFloat = 46
private let footerHeight: CGFloat = 40
private let maxList: CGFloat = 520
private let emptyList: CGFloat = 96
private let previewDelay = 3.0
private let previewMaxWidth: CGFloat = 520
private let previewMaxHeight: CGFloat = 640
private let previewMaxBytes = 2 << 20

let tracing = getenv("CRUMB_TRACE") != nil

private func screen(at point: NSPoint) -> NSScreen? {
    NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
}

/// Drawn once into an sRGB bitmap: a mask drawn on demand would be converted by Core Animation for every window.
@MainActor
private func roundedMask(_ radius: CGFloat) -> NSImage {
    let side = radius * 2 + 1, scale: CGFloat = 2
    let pixels = Int(side * scale)
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(black.cgColor)
    context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: pixels, height: pixels), cornerWidth: radius * scale,
                           cornerHeight: radius * scale, transform: nil))
    context.fillPath()
    let mask = NSImage(cgImage: context.makeImage()!, size: NSSize(width: side, height: side))
    mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    mask.resizingMode = .stretch
    return mask
}

/// The frosted material of macOS menus, with rounded corners.
@MainActor
private func makeBackground(_ content: NSView, radius: CGFloat) -> NSView {
    let effect = NSVisualEffectView(frame: content.frame)
    effect.material = .menu
    effect.state = .active
    effect.blendingMode = .behindWindow
    effect.maskImage = roundedMask(radius)
    content.autoresizingMask = [.width, .height]
    effect.addSubview(content)
    return effect
}

@MainActor
private func configure(_ panel: NSPanel) {
    // A fixed depth and color space. Left to the screen's, AppKit and Core Animation convert through a fresh ColorSync
    // transform for each new window and keep its 272 KB lookup table: one more every time the list or a preview opens.
    // Crumb draws in 8-bit sRGB anyway, and the window server matches that to the display.
    panel.setDynamicDepthLimit(false)
    panel.depthLimit = .twentyfourBitRGB
    panel.colorSpace = .sRGB
    panel.level = .popUpMenu
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.animationBehavior = .none  // appear and vanish instantly
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle, .transient]
}

final class Panel: NSPanel {
    weak var popup: Popup?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        configure(self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if popup?.recording == true { return super.performKeyEquivalent(with: event) }  // the shortcut field takes every key
        return popup?.handleKeyEquivalent(event) == true || super.performKeyEquivalent(with: event)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class FooterButton: CanvasView {
    var title = "" { didSet { needsDisplay = true } }
    var icon: Icon?
    var tint: NSColor? { didSet { needsDisplay = true } }
    var action: (() -> Void)?
    private var hovered = false {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let color = tint ?? (hovered ? .labelColor : .secondaryLabelColor)
        if let icon {
            drawIcon(icon, in: NSRect(x: (bounds.midX - 8).rounded(), y: (bounds.midY - 8).rounded(), width: 16, height: 16), color: color)
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: 10, y: (bounds.midY - size.height / 2).rounded()), withAttributes: attributes)
    }

    var fittingWidth: CGFloat {
        (title.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width).rounded(.up) + 20
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool {
        action?()
        return true
    }
}

private final class Rule: CanvasView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

@MainActor
final class Popup: NSObject, NSWindowDelegate, ListViewDelegate, HeaderViewDelegate {
    private let store: Store
    private let clipboard: Clipboard
    weak var updater: Updater?
    var onLimit: ((Int) -> Void)?

    // The window is built only when it opens and torn down when it closes, so a closed Crumb holds no views.
    @objc private(set) var panel: Panel?
    private var content: NSView?
    @objc private(set) var header: HeaderView?
    private var topRule: Rule?
    private var bottomRule: Rule?
    @objc private(set) var list: ListView?
    @objc private(set) var page: SettingsPage?
    private var clear: FooterButton?
    private var settings: FooterButton?
    private var quit: FooterButton?
    private var preview: NSPanel?
    private var previewGeneration = 0
    private var clearGeneration = 0
    private var confirmingClear = false
    @objc private(set) var isOpen = false
    @objc private(set) var settingsMode = false
    private var left: CGFloat = 0, top: CGFloat = 0  // where the panel's top-left corner sits while it is open
    private var haystacks: [UInt64: Haystack] = [:]

    init(store: Store, clipboard: Clipboard) {
        self.store = store
        self.clipboard = clipboard
    }

    var recording: Bool { page?.recording == true }

    private func build() {
        guard panel == nil else { return }
        let panel = Panel(frame: NSRect(x: 0, y: 0, width: width, height: 300))
        panel.popup = self
        panel.delegate = self
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
        let header = HeaderView(frame: .zero)
        header.delegate = self
        content.addSubview(header)
        let topRule = Rule(frame: .zero), bottomRule = Rule(frame: .zero)
        content.addSubview(topRule)
        content.addSubview(bottomRule)
        let list = ListView(store: store)
        list.delegate = self
        content.addSubview(list)

        let clear = FooterButton(frame: .zero)
        clear.title = "Clear History"
        clear.action = { [weak self] in self?.clearPressed() }
        let settings = FooterButton(frame: .zero)
        settings.title = "Settings"
        settings.icon = .gear
        settings.toolTip = "Settings (⌘,)"
        settings.action = { [weak self] in self?.toggleSettings() }
        let quit = FooterButton(frame: .zero)
        quit.title = "Quit Crumb"
        quit.icon = .power
        quit.toolTip = "Quit Crumb (⌘Q)"
        quit.action = { NSApp.terminate(nil) }
        for button in [clear, settings, quit] { content.addSubview(button) }

        panel.contentView = makeBackground(content, radius: radius)
        (self.panel, self.content, self.header, self.topRule, self.bottomRule, self.list) = (panel, content, header, topRule, bottomRule, list)
        (self.clear, self.settings, self.quit) = (clear, settings, quit)
    }

    private func releaseWindow() {
        guard !isOpen, let panel else { return }
        panel.delegate = nil
        panel.contentView = nil
        self.panel = nil
        (content, header, topRule, bottomRule, list, page, clear, settings, quit) = (nil, nil, nil, nil, nil, nil, nil, nil, nil)
    }

    // MARK: Showing

    func toggle() {
        if isOpen { close() } else { show(at: NSEvent.mouseLocation, settings: false) }
    }

    /// The settings page, in the middle of the screen.
    func showSettings() {
        if isOpen {
            if !settingsMode { toggleSettings() }
            return
        }
        guard let visible = NSScreen.main?.visibleFrame else { return }
        show(at: NSPoint(x: visible.midX - width / 2, y: visible.midY + 180), settings: true)
    }

    @objc func show(at point: NSPoint, settings: Bool) {
        let start = CACurrentMediaTime()
        build()
        clipboard.pollNow()
        header?.clear()
        resetClear()
        settingsMode = settings
        filter()

        // The top-left corner goes at the pointer, like a context menu.
        guard let visible = screen(at: point)?.visibleFrame, let panel else { return }
        let height = min(headerHeight + bodyHeight + footerHeight, visible.height - 16)
        left = point.x + width > visible.maxX ? point.x - width : point.x
        left = min(max(left, visible.minX + 4), visible.maxX - width - 4)
        top = min(max(point.y, visible.minY + height + 4), visible.maxY)
        applyMode()
        layout()

        isOpen = true
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(header)
        if !settings { schedulePreview() }
        if tracing { NSLog("open %.1f ms (%ld rows)", (CACurrentMediaTime() - start) * 1000, list?.count ?? 0) }
    }

    private var bodyHeight: CGFloat {
        if settingsMode { return page?.preferredHeight ?? 0 }
        guard let list, list.count > 0 else { return emptyList }
        return min(list.contentHeight, maxList)
    }

    private func applyMode() {
        if settingsMode && page == nil, let content {
            var check: FooterButton?
            if updater?.available == true {
                let button = FooterButton(frame: .zero)
                button.title = "Check for Updates"
                button.action = { [weak self] in self?.page?.checkForUpdates() }
                check = button
            }
            let page = SettingsPage(updater: updater, checkButton: check)
            page.onLimit = { [weak self] limit in self?.onLimit?(limit) }
            page.returnResponder = header
            content.addSubview(page)
            self.page = page
        }
        if settingsMode { page?.refresh() }
        page?.isHidden = !settingsMode
        list?.isHidden = settingsMode
        clear?.isHidden = settingsMode
        settings?.tint = settingsMode ? .controlAccentColor : nil
        header?.title = settingsMode ? "Crumb Settings" : "Crumb"
    }

    @objc private func toggleSettings() {
        hidePreview()
        previewGeneration += 1
        settingsMode.toggle()
        header?.clear()
        if !settingsMode { filter() }
        applyMode()
        layout()
        panel?.makeFirstResponder(header)
    }

    private func layout() {
        guard let panel, let content else { return }
        let visible = screen(at: NSPoint(x: left + 1, y: top - 1))?.visibleFrame ?? .zero
        let height = min(headerHeight + bodyHeight + footerHeight, max(headerHeight + footerHeight + rowHeight, top - visible.minY - 4))
        let body = height - headerHeight - footerHeight
        panel.setFrame(NSRect(x: left, y: top - height, width: width, height: height), display: false, animate: false)
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        header?.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        topRule?.frame = NSRect(x: 0, y: headerHeight - 1, width: width, height: 1)
        list?.frame = NSRect(x: 0, y: headerHeight, width: width, height: body)
        page?.frame = NSRect(x: 0, y: headerHeight, width: width, height: body)
        bottomRule?.frame = NSRect(x: 0, y: height - footerHeight, width: width, height: 1)

        let footerY = height - footerHeight + 6, buttonHeight = footerHeight - 12
        if let clear { clear.frame = NSRect(x: 6, y: footerY, width: clear.fittingWidth, height: buttonHeight) }
        quit?.frame = NSRect(x: width - 6 - 32, y: footerY, width: 32, height: buttonHeight)
        settings?.frame = NSRect(x: width - 6 - 32 - 2 - 32, y: footerY, width: 32, height: buttonHeight)
        panel.invalidateShadow()
    }

    @objc func close() {
        guard isOpen else { return }
        isOpen = false
        previewGeneration += 1
        hidePreview()
        if recording { panel?.makeFirstResponder(header) }  // ends the recording and registers the shortcut again
        panel?.close()
        list?.clear()
        haystacks = [:]
        resetClear()
        // The window goes once AppKit is done with it, then the freed memory goes back to the system.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.releaseWindow() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                if let self, !self.isOpen { malloc_zone_pressure_relief(nil, 0) }
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    func reload() {
        guard isOpen, !settingsMode, let list else { return }
        let selected = list.selected >= 0 ? list.id(at: list.selected) : 0
        filter()
        layout()
        if let row = (0..<list.count).first(where: { list.id(at: $0) == selected }) {
            list.selected = row
            list.scrollToSelection()
        }
    }

    // MARK: Search

    private func filter() {
        guard let list else { return }
        let items = store.items
        let query = Query(header?.query ?? "")
        var rows: [Row] = []
        if query.isEmpty {
            rows = items.indices.map { Row(item: $0) }
        } else {
            var hits: [(item: Int, score: Int, matches: [UInt32])] = []
            var matches: [UInt32] = []
            for (i, item) in items.enumerated() where item.kind != .image || item.flags.contains(.text) {
                let haystack = haystacks[item.id] ?? prepare(displayText(item))
                haystacks[item.id] = haystack
                var score = 0
                if query.match(haystack, score: &score, positions: &matches) { hits.append((i, score, matches)) }
            }
            // Best first; equal scores keep the history's order.
            let order = hits.indices.sorted { hits[$0].score != hits[$1].score ? hits[$0].score > hits[$1].score : $0 < $1 }
            rows = order.map { Row(item: hits[$0].item, matches: hits[$0].matches) }
        }
        list.emptyText = query.isEmpty ? "Nothing copied yet" : "No matches"
        list.setRows(rows)
    }

    func queryChanged() {
        if tracing { NSLog("query: [%@]", header?.query ?? "") }
        if settingsMode {  // typing on the settings page starts a search in the list
            settingsMode = false
            applyMode()
        }
        filter()
        layout()
        schedulePreview()
    }

    @objc func runCommand(_ command: Selector) {
        if command == #selector(NSResponder.cancelOperation(_:)) {
            if settingsMode { toggleSettings() } else { close() }
            return
        }
        guard !settingsMode, let list else { return }
        switch command {
        case #selector(NSResponder.moveUp(_:)): move(to: list.selected - 1)
        case #selector(NSResponder.moveDown(_:)): move(to: list.selected + 1)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.scrollToBeginningOfDocument(_:)): move(to: 0)
        case #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.scrollToEndOfDocument(_:)): move(to: list.count - 1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(to: max(0, list.selected - 10))
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(to: min(list.count - 1, list.selected + 10))
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)): activate(list.selected)
        case #selector(NSResponder.deleteWordBackward(_:)): deleteSelected()  // ⌥⌫ deletes the selected entry
        default: break
        }
    }

    private func move(to row: Int) {
        guard let list, list.count > 0 else { return }
        let row = min(max(row, 0), list.count - 1)
        if row == list.selected { return }
        list.selected = row
        list.scrollToSelection()
        schedulePreview()
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command else { return false }
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let keypad = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                      kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        if let i = digits.firstIndex(of: Int(event.keyCode)) ?? keypad.firstIndex(of: Int(event.keyCode)) {
            if !settingsMode { activate(i) }
            return true
        }
        switch keyCharacter(event) {
        case ",": toggleSettings()
        case "q": NSApp.terminate(nil)
        case "w": close()
        case "v":
            if settingsMode { toggleSettings() }
            header?.paste()
        default: return false
        }
        return true
    }

    // MARK: Actions

    func listDidHover(_ row: Int) {
        list?.selected = row
        schedulePreview()
    }

    func listDidClick(_ row: Int) {
        activate(row)
    }

    private func activate(_ row: Int) {
        guard let list, row >= 0, row < list.count else { return }
        let item = list.item(at: row)
        close()
        clipboard.copyItem(at: item)
    }

    private func deleteSelected() {
        guard let list, list.selected >= 0 else { return }
        let row = list.selected
        let item = list.item(at: row)
        haystacks[store.items[item].id] = nil
        store.remove(item)
        filter()
        layout()
        if list.count > 0 { move(to: min(row, list.count - 1)) }
        schedulePreview()
    }

    @objc private func clearPressed() {
        guard let clear else { return }
        if !confirmingClear {
            confirmingClear = true
            clear.title = "Click Again to Clear"
            clear.tint = .systemRed
            clear.frame.size.width = clear.fittingWidth
            clearGeneration += 1
            let generation = clearGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated {
                    if let self, self.clearGeneration == generation { self.resetClear() }
                }
            }
            return
        }
        resetClear()
        hidePreview()
        haystacks = [:]
        clipboard.clearHistory()  // also drops copies still being saved; the list reloads when it's done
    }

    private func resetClear() {
        clearGeneration += 1
        guard confirmingClear, let clear else { return }
        confirmingClear = false
        clear.title = "Clear History"
        clear.tint = nil
        clear.frame.size.width = clear.fittingWidth
    }

    // MARK: Preview

    private func schedulePreview() {
        hidePreview()
        previewGeneration += 1
        let generation = previewGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + previewDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, !self.settingsMode, self.previewGeneration == generation else { return }
                self.showPreview()
            }
        }
    }

    private func hidePreview() {
        preview?.close()
        preview = nil
    }

    private func showPreview() {
        guard let list, let panel, list.selected >= 0 else { return }
        let row = list.selected
        let item = store.items[list.item(at: row)]
        guard let visible = screen(at: NSPoint(x: left + 1, y: top - 1))?.visibleFrame else { return }
        let maxHeight = min(previewMaxHeight, visible.height - 16)
        let scale = panel.backingScaleFactor

        let view: NSView
        if item.kind == .image {
            let w = max(1, CGFloat(item.width) / 2), h = max(1, CGFloat(item.height) / 2)
            let fit = min(1, (previewMaxWidth - 16) / w, (maxHeight - 16) / h)
            let size = NSSize(width: max(1, (w * fit).rounded()), height: max(1, (h * fit).rounded()))
            let url = URL(fileURLWithPath: store.imageFile(item)) as CFURL
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: (max(size.width, size.height) * scale).rounded(.up),
            ]
            guard let source = CGImageSourceCreateWithURL(url, nil),
                  let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return }
            view = ImagePreview(picture: picture, size: size, scale: scale)
        } else {
            // A few spare bytes let the cut fall on a character boundary.
            var bytes = readFile(store.file(item.id, item.kind == .files ? "files" : "txt"), maxBytes: previewMaxBytes + 3)
            let cut = bytes.count > previewMaxBytes
            bytes = utf8Prefix(bytes, maxBytes: previewMaxBytes)
            var text = String(validating: bytes, as: UTF8.self) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
            if cut { text += "\n…" }
            if text.isEmpty { return }
            view = TextPreview(text: text, maxWidth: previewMaxWidth, maxHeight: maxHeight)
        }
        let size = view.frame.size

        // Beside the list, level with the selected row; on the other side if there is no room.
        let frame = panel.frame
        let rowTop = frame.maxY - headerHeight - list.rect(ofRow: row).minY
        var x = frame.maxX + 8
        if x + size.width > visible.maxX { x = frame.minX - 8 - size.width }
        x = max(x, visible.minX + 4)
        let y = min(max(rowTop - size.height, visible.minY + 4), visible.maxY - size.height)

        let preview = NSPanel(contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        configure(preview)
        preview.contentView = makeBackground(view, radius: 12)
        preview.orderFrontRegardless()
        self.preview = preview
    }
}
