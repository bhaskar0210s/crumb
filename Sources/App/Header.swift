// The list's title and, while searching, the query. Crumb reads the keyboard here itself (with input method support)
// instead of using a system text field: those bring the whole text system along, plus an AutoFill helper process.

import AppKit
import Carbon
import CoreText

@MainActor
protocol HeaderViewDelegate: AnyObject {
    func queryChanged()
    func runCommand(_ command: Selector)
}

private func usingInputMethod() -> Bool {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType)
    else { return false }
    let type = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    return [kTISTypeKeyboardInputMode, kTISTypeKeyboardInputMethodModeEnabled, kTISTypeKeyboardInputMethodWithoutModes]
        .contains { $0 as String == type }
}

/// One line: line breaks and tabs become spaces.
private func singleLine(_ string: Any) -> String {
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    return text.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
}

final class HeaderView: CanvasView, @preconcurrency NSTextInputClient {
    weak var delegate: HeaderViewDelegate?
    @objc private(set) var query = ""
    private var marked = ""  // an input method's composition, not part of the query yet
    private var caretX: CGFloat = 0

    @objc var title = "Crumb" {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    // With an ordinary keyboard layout Crumb reads keys itself and has no input context: a text input context makes
    // macOS start an AutoFill helper process (about 13 MB) for the app. Input methods (Chinese, Japanese, Korean…)
    // need one to compose text, so it exists only while one of them is the current input source.
    override var inputContext: NSTextInputContext? {
        usingInputMethod() ? super.inputContext : nil
    }

    func clear() {
        query = ""
        marked = ""
        inputContext?.discardMarkedText()
        needsDisplay = true
    }

    private func changed() {
        needsDisplay = true
        delegate?.queryChanged()
    }

    func paste() {
        guard var text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        if text.utf16.count > 1000 {
            let ns = text as NSString
            text = ns.substring(to: ns.rangeOfComposedCharacterSequence(at: 1000).location)
        }
        query += singleLine(text)
        marked = ""
        changed()
    }

    override func keyDown(with event: NSEvent) {
        if inputContext != nil {
            interpretKeyEvents([event])
            return
        }
        let flags = event.modifierFlags
        let option = flags.contains(.option), command = flags.contains(.command), control = flags.contains(.control)
        var selector: Selector?
        switch Int(event.keyCode) {
        case kVK_UpArrow: selector = #selector(moveUp(_:))
        case kVK_DownArrow: selector = #selector(moveDown(_:))
        case kVK_PageUp: selector = #selector(pageUp(_:))
        case kVK_PageDown: selector = #selector(pageDown(_:))
        case kVK_Home: selector = #selector(moveToBeginningOfDocument(_:))
        case kVK_End: selector = #selector(moveToEndOfDocument(_:))
        case kVK_Return, kVK_ANSI_KeypadEnter: selector = #selector(insertNewline(_:))
        case kVK_Escape: selector = #selector(cancelOperation(_:))
        case kVK_Delete:
            selector = option ? #selector(deleteWordBackward(_:)) : command ? #selector(deleteToBeginningOfLine(_:)) : #selector(deleteBackward(_:))
        case kVK_ANSI_N where control: selector = #selector(moveDown(_:))
        case kVK_ANSI_P where control: selector = #selector(moveUp(_:))
        default: break
        }
        if let selector {
            doCommand(by: selector)
            return
        }
        if command || control { return }
        // Printable characters only (the keyboard layout has already applied dead keys such as ⌥E E → é).
        let text = String(String.UnicodeScalarView((event.characters ?? "").unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
        }))
        if !text.isEmpty { insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = singleLine(string)
        marked = ""
        guard !text.isEmpty else {
            needsDisplay = true
            return
        }
        query += text
        changed()
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(deleteBackward(_:)) {
            if !query.isEmpty {
                query.removeLast()  // one character, as the user sees it
                changed()
            }
            return
        }
        if selector == #selector(deleteToBeginningOfLine(_:)) || selector == #selector(deleteToBeginningOfParagraph(_:)) {
            if !query.isEmpty {
                query = ""
                changed()
            }
            return
        }
        delegate?.runCommand(selector)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = singleLine(string)
        needsDisplay = true
    }

    func unmarkText() {
        guard !marked.isEmpty else { return }
        query += marked
        marked = ""
        changed()
    }

    func selectedRange() -> NSRange {
        NSRange(location: (query as NSString).length + (marked as NSString).length, length: 0)
    }

    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: (query as NSString).length, length: (marked as NSString).length)
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let all = (query + marked) as NSString
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: all.length))
        actualRange?.pointee = clipped
        return NSAttributedString(string: all.substring(with: clipped))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    // Input methods put their candidate window at the caret.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let local = NSRect(x: caretX, y: 0, width: 1, height: bounds.height)
        return window?.convertToScreen(convert(local, to: nil)) ?? .zero
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let height = bounds.height
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let label = resolved(.labelColor)
        let titleLine = makeLine(title, font: titleFont)
        drawLine(context, titleLine, x: 16, top: 0, height: height, font: titleFont, color: label)
        caretX = 16 + lineWidth(titleLine) + 14
        if query.isEmpty && marked.isEmpty { return }  // the search field only shows while searching

        drawIcon(.search, in: NSRect(x: caretX, y: ((height - 15) / 2).rounded(), width: 15, height: 15), color: .tertiaryLabelColor)
        let x = caretX + 21, available = bounds.width - x - 18
        let font = NSFont.systemFont(ofSize: 14)
        let text = NSMutableAttributedString(string: query + marked, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        if !marked.isEmpty {
            text.addAttribute(NSAttributedString.Key(kCTUnderlineStyleAttributeName as String), value: CTUnderlineStyle.single.rawValue,
                              range: NSRange(location: (query as NSString).length, length: (marked as NSString).length))
        }
        var line = CTLineCreateWithAttributedString(text)
        if lineWidth(line) > available {  // keep the end of a long query in view
            if let cut = CTLineCreateTruncatedLine(line, available, .start, makeLine("…", font: font)) { line = cut }
        }
        drawLine(context, line, x: x, top: 0, height: height, font: font, color: label)
        caretX = x + lineWidth(line) + 1
        NSColor.controlAccentColor.setFill()
        NSRect(x: caretX.rounded(), y: ((height - 18) / 2).rounded(), width: 2, height: 18).fill()
    }

    // MARK: VoiceOver

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textField }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .searchField }
    override func accessibilityLabel() -> String? { "Search " + title }
    override func accessibilityValue() -> Any? { query }
}

// A search box wants none of the system's text services.
extension HeaderView: @preconcurrency NSTextInputTraits {
    var autocorrectionType: NSTextInputTraitType { get { .no } set {} }
    var spellCheckingType: NSTextInputTraitType { get { .no } set {} }
    var grammarCheckingType: NSTextInputTraitType { get { .no } set {} }
    var smartQuotesType: NSTextInputTraitType { get { .no } set {} }
    var smartDashesType: NSTextInputTraitType { get { .no } set {} }
    var smartInsertDeleteType: NSTextInputTraitType { get { .no } set {} }
    var textReplacementType: NSTextInputTraitType { get { .no } set {} }
    var dataDetectionType: NSTextInputTraitType { get { .no } set {} }
    var linkDetectionType: NSTextInputTraitType { get { .no } set {} }
    var textCompletionType: NSTextInputTraitType { get { .no } set {} }
    var inlinePredictionType: NSTextInputTraitType { get { .no } set {} }
    var mathExpressionCompletionType: NSTextInputTraitType { get { .no } set {} }
    var writingToolsBehavior: NSWritingToolsBehavior { get { .none } set {} }
}
