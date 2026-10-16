// The settings page, shown inside the list's own panel (the gear in its footer). Everything is drawn by Crumb itself:
// a separate window and the standard controls would cost several megabytes of memory for four options.

import AppKit
import ServiceManagement

private let rowSpacing: CGFloat = 40
private let side: CGFloat = 16
private let noticeHeight: CGFloat = 44  // the note about pasteboard access, when there is one

private func attributes(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> [NSAttributedString.Key: Any] {
    [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
}

private func drawText(_ text: String, x: CGFloat, midY: CGFloat, _ attributes: [NSAttributedString.Key: Any]) {
    let size = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: x, y: (midY - size.height / 2).rounded()), withAttributes: attributes)
}

/// An on/off switch. Flips the moment it is clicked.
private final class Toggle: CanvasView {
    var on = false { didSet { needsDisplay = true } }
    var label = ""
    var onChange: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds
        let radius = track.height / 2
        (on ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.16)).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let knob = track.height - 4
        let circle = NSRect(x: on ? track.maxX - knob - 2 : 2, y: 2, width: knob, height: knob)
        black.withAlphaComponent(0.12).setFill()
        NSBezierPath(ovalIn: circle.offsetBy(dx: 0, dy: 0.5)).fill()
        white.setFill()
        NSBezierPath(ovalIn: circle).fill()
    }

    override func mouseDown(with event: NSEvent) {
        flip()
    }

    private func flip() {
        on.toggle()
        onChange?(on)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .switch }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityValue() -> Any? { NSNumber(value: on) }
    override func accessibilityPerformPress() -> Bool {
        flip()
        return true
    }
}

/// − value + : steps of ten.
private final class Stepper: CanvasView {
    var value = 0 { didSet { needsDisplay = true } }
    var minimum = 10, maximum = 1000, step = 10
    var label = ""
    var onChange: ((Int) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        let third = box.width / 3
        let sign = attributes(15, .medium, .secondaryLabelColor)
        let number: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor,
        ]
        func centered(_ text: String, _ midX: CGFloat, _ attributes: [NSAttributedString.Key: Any]) {
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (midX - size.width / 2).rounded(), y: (box.midY - size.height / 2).rounded()), withAttributes: attributes)
        }
        centered("−", third / 2, sign)
        centered(String(value), box.midX, number)
        centered("+", box.width - third / 2, sign)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let third = bounds.width / 3
        if point.x < third { change(by: -step) } else if point.x > 2 * third { change(by: step) }
    }

    private func change(by delta: Int) {
        let next = min(max(value + delta, minimum), maximum)
        if next == value { return }
        value = next
        onChange?(next)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .incrementor }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityValue() -> Any? { NSNumber(value: value) }
    override func accessibilityPerformIncrement() -> Bool {
        change(by: step)
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        change(by: -step)
        return true
    }
}

final class SettingsPage: CanvasView {
    private weak var updater: Updater?
    private let shortcut = ShortcutField(frame: .zero)
    private let login = Toggle(frame: .zero)
    private var updates: Toggle?
    private let size = Stepper(frame: .zero)
    private let check: NSView?
    @objc private(set) var status = ""
    private var labels: [String] = []
    private var notice: String?  // why copies may not be saved
    var onLimit: ((Int) -> Void)?

    init(updater: Updater?, checkButton: NSView?) {
        self.updater = updater
        check = checkButton
        super.init(frame: .zero)
        (shortcut.keyCode, shortcut.modifiers) = HotKey.saved
        addSubview(shortcut)

        labels = ["Open Crumb", "Launch at login"]
        login.label = labels[1]
        login.onChange = { [weak self] on in self?.setLaunchAtLogin(on) }
        addSubview(login)

        if updater?.available == true {
            labels.append("Check for updates automatically")
            let updates = Toggle(frame: .zero)
            updates.label = labels[2]
            updates.onChange = { on in UserDefaults.standard.set(on, forKey: Defaults.checkForUpdates) }
            addSubview(updates)
            self.updates = updates
        }
        labels.append("History size")
        size.label = "History size"
        size.onChange = { [weak self] value in
            UserDefaults.standard.set(value, forKey: Defaults.historySize)
            self?.onLimit?(value)
        }
        addSubview(size)
        if let check { addSubview(check) }
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    private var rowsTop: CGFloat { 8 + (notice == nil ? 0 : noticeHeight) }
    var preferredHeight: CGFloat { rowsTop + CGFloat(labels.count) * rowSpacing + 30 + 36 }
    var recording: Bool { shortcut.recording }

    /// Gets the keyboard back after a shortcut is recorded.
    var returnResponder: NSResponder? {
        get { shortcut.returnResponder }
        set { shortcut.returnResponder = newValue }
    }

    func refresh() {
        let defaults = UserDefaults.standard
        login.on = SMAppService.mainApp.status == .enabled
        updates?.on = defaults.bool(forKey: Defaults.checkForUpdates)
        size.value = defaults.integer(forKey: Defaults.historySize)
        // macOS lets each app read what other apps copied only if the user allows it.
        switch NSPasteboard.general.accessBehavior {
        case .ask: notice = "macOS asks before Crumb can save each copy."
        case .alwaysDeny: notice = "macOS doesn't let Crumb save copies."
        default: notice = nil
        }
        layoutControls()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutControls()
    }

    private func layoutControls() {
        let width = bounds.width, top = rowsTop
        func place(_ index: Int, _ control: NSView, _ size: NSSize) {
            control.frame = NSRect(x: width - side - size.width, y: top + CGFloat(index) * rowSpacing + ((rowSpacing - size.height) / 2).rounded(),
                                   width: size.width, height: size.height)
        }
        var index = 0
        place(index, shortcut, NSSize(width: 104, height: 26))
        index += 1
        place(index, login, NSSize(width: 34, height: 20))
        index += 1
        if let updates {
            place(index, updates, NSSize(width: 34, height: 20))
            index += 1
        }
        place(index, size, NSSize(width: 104, height: 26))
        check?.frame = NSRect(x: width - side + 10 - 140, y: top + CGFloat(labels.count) * rowSpacing + 30 + 4, width: 140, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width, top = rowsTop
        if let notice {
            drawText(notice, x: side, midY: 8 + 13, attributes(12, .semibold, .systemOrange))
            drawText("Allow it in System Settings → Privacy & Security → Paste from Other Apps.", x: side, midY: 8 + 31,
                     attributes(11, .regular, .secondaryLabelColor))
        }
        let label = attributes(13, .regular, .labelColor)
        for (i, text) in labels.enumerated() {
            let rowTop = top + CGFloat(i) * rowSpacing
            drawText(text, x: side, midY: rowTop + rowSpacing / 2, label)
            if i + 1 < labels.count {
                NSColor.separatorColor.setFill()
                NSRect(x: side, y: rowTop + rowSpacing - 0.5, width: width - 2 * side, height: 1).fill()
            }
        }
        let hintTop = top + CGFloat(labels.count) * rowSpacing
        let small = attributes(11, .regular, .secondaryLabelColor)
        drawText("In the list: ⌘1–⌘9 copy an entry, ⌥⌫ deletes one, Esc closes.", x: side, midY: hintTop + 15, small)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        drawText("Crumb " + version + (status.isEmpty ? "" : "  ·  " + status), x: side, midY: hintTop + 30 + 18, small)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Defaults.launchAtLogin)
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
        refresh()
    }

    @objc func checkForUpdates() {
        guard let updater, updater.available else { return }
        status = "Checking…"
        needsDisplay = true
        updater.checkNow { [weak self] status in
            self?.status = status
            self?.needsDisplay = true
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Crumb Settings" }
}
