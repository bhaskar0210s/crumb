// The history list: opens at the pointer, filters as you type, previews an entry after three seconds.

#import "app.h"

#import <Carbon/Carbon.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#include <malloc/malloc.h>

#include <algorithm>
#include <unordered_map>

#include "../core/fuzzy.hpp"
#include "../core/text.hpp"

namespace {

constexpr CGFloat kWidth = 440;
constexpr CGFloat kRadius = 12;   // panel corners
constexpr CGFloat kHeader = 46;
constexpr CGFloat kFooter = 40;
constexpr CGFloat kRow = 30;
constexpr CGFloat kThumb = 40;    // tallest picture in the list (points)
constexpr CGFloat kThumbMaxWidth = 260;
constexpr CGFloat kGutter = 6;    // between the panel edge and a row's highlight
constexpr CGFloat kInset = 10;    // between a highlight's edge and its contents
constexpr CGFloat kMaxList = 520;
constexpr CGFloat kEmptyList = 96;
constexpr double kPreviewDelay = 3.0;
constexpr CGFloat kPreviewMaxWidth = 520;
constexpr CGFloat kPreviewMaxHeight = 640;
constexpr size_t kPreviewMaxBytes = 2 << 20;

// Owns one Core Foundation reference.
template <class T>
class CF {
public:
    CF() = default;
    explicit CF(T ref) : ref_(ref) {}
    CF(const CF& other) : ref_(other.ref_) {
        if (ref_) CFRetain(ref_);
    }
    CF(CF&& other) noexcept : ref_(other.ref_) { other.ref_ = nullptr; }
    CF& operator=(CF other) noexcept {
        std::swap(ref_, other.ref_);
        return *this;
    }
    ~CF() {
        if (ref_) CFRelease(ref_);
    }
    T get() const { return ref_; }
    explicit operator bool() const { return ref_ != nullptr; }

private:
    T ref_ = nullptr;
};

struct Row {
    size_t item = 0;  // index into Store::items()
    uint64_t id = 0;
    CGFloat y = 0;
    CGFloat height = kRow;
    std::vector<uint32_t> matches;
    CF<CTLineRef> line;  // built on first draw
    int8_t folder = -1;  // single-file rows: whether the file is a folder
};

NSFont* rowFont() {
    static NSFont* font = [NSFont systemFontOfSize:13];
    return font;
}

NSFont* boldFont() {
    static NSFont* font = [NSFont systemFontOfSize:13 weight:NSFontWeightBold];
    return font;
}

NSFont* hintFont() {
    static NSFont* font = [NSFont systemFontOfSize:12];
    return font;
}

// A line whose colour comes from the context, so one line serves selected and unselected rows.
CF<CTLineRef> makeLine(NSString* string, NSFont* font) {
    NSDictionary* attributes =
        @{NSFontAttributeName : font, (__bridge NSString*)kCTForegroundColorFromContextAttributeName : @YES};
    NSAttributedString* text = [[NSAttributedString alloc] initWithString:string attributes:attributes];
    return CF<CTLineRef>(CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text));
}

CF<CTLineRef> makeLine(const crumb::Line& line, CGFloat width, CTLineRef ellipsis) {
    NSString* string = [[NSString alloc] initWithBytes:line.text.data() length:line.text.size() encoding:NSUTF8StringEncoding];
    if (!string) string = @"";
    NSDictionary* attributes =
        @{NSFontAttributeName : rowFont(), (__bridge NSString*)kCTForegroundColorFromContextAttributeName : @YES};
    NSMutableAttributedString* text = [[NSMutableAttributedString alloc] initWithString:string attributes:attributes];
    for (const auto& [offset, length] : line.bold)
        if (offset + length <= string.length) [text addAttribute:NSFontAttributeName value:boldFont() range:NSMakeRange(offset, length)];
    CTLineRef full = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
    CTLineRef truncated = CTLineCreateTruncatedLine(full, width, kCTLineTruncationEnd, ellipsis);
    if (!truncated) return CF<CTLineRef>(full);
    CFRelease(full);
    return CF<CTLineRef>(truncated);
}

CGFloat lineWidth(CTLineRef line) {
    return line ? CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr) : 0;
}

void drawLine(CGContextRef ctx, CTLineRef line, CGFloat x, CGFloat top, CGFloat height, NSFont* font, NSColor* color) {
    const CGFloat ascent = font.ascender, descent = -font.descender;
    const CGFloat baseline = std::round(top + (height - ascent - descent) / 2 + ascent);
    CGContextSaveGState(ctx);
    CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1, -1));  // the view is flipped
    CGContextSetTextPosition(ctx, x, baseline);
    CGContextSetFillColorWithColor(ctx, color.CGColor);
    CTLineDraw(line, ctx);
    CGContextRestoreGState(ctx);
}

// The text a row shows and searches: the start of a text, or the names of copied files.
std::u32string displayText(const crumb::Item& item) {
    if (item.kind != crumb::Kind::Files) return crumb::decodeUtf8(item.head);
    std::u32string out;
    const std::string& paths = item.head;
    size_t start = 0;
    while (start < paths.size()) {
        size_t end = paths.find('\n', start);
        if (end == std::string::npos) end = paths.size();
        std::string_view path(paths.data() + start, end - start);
        const size_t slash = path.rfind('/');
        if (slash != std::string_view::npos && slash + 1 < path.size()) path.remove_prefix(slash + 1);
        if (!out.empty()) out += U", ";
        out += crumb::decodeUtf8(path);
        start = end + 1;
    }
    return out;
}

size_t fileCount(const crumb::Item& item) {
    return static_cast<size_t>(std::count(item.head.begin(), item.head.end(), '\n')) + 1;
}

// A picture's size in the list: its natural size on a Retina screen, scaled down to fit.
NSSize thumbSize(const crumb::Item& item) {
    const CGFloat w = std::max<CGFloat>(1, item.width / 2.0), h = std::max<CGFloat>(1, item.height / 2.0);
    const CGFloat scale = std::min({CGFloat(1), kThumb / h, kThumbMaxWidth / w});
    return NSMakeSize(std::max<CGFloat>(1, std::round(w * scale)), std::max<CGFloat>(1, std::round(h * scale)));
}

NSScreen* screenAt(NSPoint point) {
    for (NSScreen* screen in NSScreen.screens)
        if (NSMouseInRect(point, screen.frame, NO)) return screen;
    return NSScreen.mainScreen;
}

NSImage* roundedMask(CGFloat radius) {
    const CGFloat side = radius * 2 + 1;
    NSImage* mask = [NSImage imageWithSize:NSMakeSize(side, side)
                                   flipped:NO
                            drawingHandler:^BOOL(NSRect rect) {
                                [NSColor.blackColor setFill];
                                [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
                                return YES;
                            }];
    mask.capInsets = NSEdgeInsetsMake(radius, radius, radius, radius);
    mask.resizingMode = NSImageResizingModeStretch;
    return mask;
}

// The frosted material of macOS menus, with rounded corners.
NSView* makeBackground(NSView* content, CGFloat radius) {
    NSVisualEffectView* effect = [[NSVisualEffectView alloc] initWithFrame:content.frame];
    effect.material = NSVisualEffectMaterialMenu;
    effect.state = NSVisualEffectStateActive;
    effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effect.maskImage = roundedMask(radius);
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [effect addSubview:content];
    return effect;
}

NSPanel* makePanel(NSRect frame, Class cls) {
    NSPanel* panel = [[cls alloc] initWithContentRect:frame
                                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                              backing:NSBackingStoreBuffered
                                                defer:YES];
    panel.level = NSPopUpMenuWindowLevel;
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = YES;
    panel.animationBehavior = NSWindowAnimationBehaviorNone;  // appear and vanish instantly
    panel.releasedWhenClosed = NO;
    panel.hidesOnDeactivate = NO;
    panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorTransient;
    return panel;
}

bool trace() {
    static const bool on = getenv("CRUMB_TRACE") != nullptr;
    return on;
}

}  // namespace

@interface CRPopup ()
@property(nonatomic, readonly) BOOL recording;
- (BOOL)handleKeyEquivalent:(NSEvent*)event;
- (void)listDidHover:(NSInteger)row;
- (void)listDidClick:(NSInteger)row;
- (void)queryChanged;
- (void)performCommand:(SEL)command;
@end

#pragma mark - Panel

@interface CRPanel : NSPanel
@property(nonatomic, weak) CRPopup* popup;
@end

@implementation CRPanel

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return NO;
}

- (BOOL)performKeyEquivalent:(NSEvent*)event {
    if (self.popup.recording) return [super performKeyEquivalent:event];  // the shortcut field takes every key
    return [self.popup handleKeyEquivalent:event] || [super performKeyEquivalent:event];
}

@end

@interface CRFlippedView : NSView
@end

@implementation CRFlippedView

- (BOOL)isFlipped {
    return YES;
}

@end

#pragma mark - List

@interface CRListView : NSView
- (instancetype)initWithStore:(crumb::Store*)store popup:(CRPopup*)popup;
@property(nonatomic) NSInteger selected;
@property(nonatomic, copy) NSString* emptyText;
@property(nonatomic, readonly) NSInteger count;
@property(nonatomic, readonly) CGFloat contentHeight;
- (void)setRows:(std::vector<Row>)rows;
- (size_t)itemAt:(NSInteger)row;
- (uint64_t)idAt:(NSInteger)row;
- (NSRect)rectOfRow:(NSInteger)row;  // in view coordinates, after scrolling
- (void)scrollToSelection;
- (void)clear;
@end

@implementation CRListView {
    crumb::Store* _store;
    __weak CRPopup* _popup;
    std::vector<Row> _rows;
    CGFloat _offset;  // how far the list is scrolled
    CGFloat _contentHeight;
    NSInteger _pressed;
    BOOL _scrolling;
    NSInteger _scrollGeneration;
    std::unordered_map<uint64_t, CF<CGImageRef>> _thumbs;
    CF<CTLineRef> _ellipsis;
    CF<CTLineRef> _hints[9];
}

- (instancetype)initWithStore:(crumb::Store*)store popup:(CRPopup*)popup {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _store = store;
        _popup = popup;
        _pressed = -1;
        _selected = -1;
        // System colours are Display P3, which makes Core Animation choose a 64-bit backing store; 8 bits do.
        // Drawn on the CPU into a plain image (see updateLayer): the system's own drawing path moves large views
        // to the GPU, which loads a couple of megabytes of shaders that never go away.
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
        [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                           options:NSTrackingMouseMoved | NSTrackingActiveAlways |
                                                                   NSTrackingInVisibleRect
                                                             owner:self
                                                          userInfo:nil]];
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    return YES;
}

- (NSInteger)count {
    return static_cast<NSInteger>(_rows.size());
}

- (size_t)itemAt:(NSInteger)row {
    return _rows[static_cast<size_t>(row)].item;
}

- (uint64_t)idAt:(NSInteger)row {
    return _rows[static_cast<size_t>(row)].id;
}

- (void)setRows:(std::vector<Row>)rows {
    _rows = std::move(rows);
    const auto& items = _store->items();
    CGFloat y = kGutter;
    for (auto& row : _rows) {
        row.y = y;
        const auto& item = items[row.item];
        row.id = item.id;
        row.height = item.kind == crumb::Kind::Image ? std::max(kRow, thumbSize(item).height + 10) : kRow;
        y += row.height;
    }
    _contentHeight = _rows.empty() ? 0 : y + kGutter;
    _offset = 0;
    _selected = _rows.empty() ? -1 : 0;
    self.needsDisplay = YES;
}

- (void)clear {
    _rows.clear();
    _rows.shrink_to_fit();
    _thumbs.clear();
    _thumbs.rehash(0);
    _selected = -1;
    _offset = 0;
}

- (void)setSelected:(NSInteger)selected {
    if (selected == _selected) return;
    _selected = selected;
    self.needsDisplay = YES;
}

- (NSRect)rectOfRow:(NSInteger)index {
    const Row& row = _rows[static_cast<size_t>(index)];
    return NSMakeRect(kGutter, row.y - _offset, self.bounds.size.width - 2 * kGutter, row.height);
}

- (NSInteger)rowAtPoint:(NSPoint)point {
    if (point.x < 0 || point.x > self.bounds.size.width || point.y < 0 || point.y > self.bounds.size.height) return -1;
    const CGFloat y = point.y + _offset;
    auto it = std::partition_point(_rows.begin(), _rows.end(), [y](const Row& row) { return row.y + row.height <= y; });
    if (it == _rows.end() || y < it->y) return -1;
    return it - _rows.begin();
}

- (void)scrollTo:(CGFloat)offset {
    offset = std::clamp<CGFloat>(offset, 0, std::max<CGFloat>(0, _contentHeight - self.bounds.size.height));
    if (offset == _offset) return;
    _offset = offset;
    _scrolling = YES;
    const NSInteger generation = ++_scrollGeneration;
    __weak CRListView* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        CRListView* list = weakSelf;
        if (!list || list->_scrollGeneration != generation) return;
        list->_scrolling = NO;
        list.needsDisplay = YES;
    });
    self.needsDisplay = YES;
}

- (void)scrollToSelection {
    if (_selected < 0) return;
    const Row& row = _rows[static_cast<size_t>(_selected)];
    const CGFloat height = self.bounds.size.height;
    if (_selected == 0)
        [self scrollTo:0];
    else if (_selected == self.count - 1)
        [self scrollTo:_contentHeight - height];
    else if (row.y < _offset)
        [self scrollTo:row.y];
    else if (row.y + row.height > _offset + height)
        [self scrollTo:row.y + row.height - height];
}

#pragma mark Drawing

- (CGImageRef)thumbFor:(const crumb::Item&)item {
    auto it = _thumbs.find(item.id);
    if (it != _thumbs.end()) return it->second.get();
    CGImageRef image = nullptr;
    NSURL* url = [NSURL fileURLWithPath:@(_store->file(item.id, "thumb.png").c_str())];
    if (CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr)) {
        image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef) @{(id)kCGImageSourceShouldCacheImmediately : @YES});
        CFRelease(source);
    }
    _thumbs.emplace(item.id, CF<CGImageRef>(image));
    return image;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    CRRenderIntoLayer(self, ^(NSRect bounds) {
        [self drawRows:bounds];
    });
}

- (void)drawRows:(NSRect)dirtyRect {
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    const CGFloat width = self.bounds.size.width;

    if (_rows.empty()) {
        NSDictionary* attributes = @{NSFontAttributeName : rowFont(), NSForegroundColorAttributeName : NSColor.secondaryLabelColor};
        const NSSize size = [self.emptyText sizeWithAttributes:attributes];
        [self.emptyText drawAtPoint:NSMakePoint(std::round((width - size.width) / 2), std::round((self.bounds.size.height - size.height) / 2))
                     withAttributes:attributes];
        return;
    }
    if (!_ellipsis) _ellipsis = makeLine(@"…", rowFont());

    const auto& items = _store->items();
    const CGFloat top = NSMinY(dirtyRect) + _offset, bottom = NSMaxY(dirtyRect) + _offset;
    auto it = std::partition_point(_rows.begin(), _rows.end(), [top](const Row& row) { return row.y + row.height <= top; });
    for (; it != _rows.end() && it->y < bottom; ++it) {
        Row& row = *it;
        const size_t index = static_cast<size_t>(it - _rows.begin());
        const bool selected = static_cast<NSInteger>(index) == _selected;
        const crumb::Item& item = items[row.item];
        const NSRect box = NSMakeRect(kGutter, row.y - _offset, width - 2 * kGutter, row.height);
        if (selected) {
            [NSColor.controlAccentColor setFill];
            [[NSBezierPath bezierPathWithRoundedRect:box xRadius:8 yRadius:8] fill];
        }
        NSColor* color = selected ? NSColor.whiteColor : NSColor.labelColor;
        CGFloat right = NSMaxX(box) - kInset;
        if (index < 9) {
            if (!_hints[index]) _hints[index] = makeLine([NSString stringWithFormat:@"⌘%zu", index + 1], hintFont());
            const CGFloat w = lineWidth(_hints[index].get());
            drawLine(ctx, _hints[index].get(), right - w, box.origin.y, box.size.height, hintFont(),
                     selected ? [NSColor colorWithWhite:1 alpha:0.75] : NSColor.tertiaryLabelColor);
            right -= w + 12;
        }
        CGFloat x = NSMinX(box) + kInset;

        if (item.kind == crumb::Kind::Image) {
            if (CGImageRef image = [self thumbFor:item]) {
                const NSSize size = thumbSize(item);
                const CGRect rect = CGRectMake(x, std::round(box.origin.y + (box.size.height - size.height) / 2), size.width, size.height);
                CGContextSaveGState(ctx);
                CGPathRef clip = CGPathCreateWithRoundedRect(rect, 4, 4, nullptr);
                CGContextAddPath(ctx, clip);
                CGContextClip(ctx);
                CGPathRelease(clip);
                CGContextTranslateCTM(ctx, rect.origin.x, rect.origin.y + rect.size.height);
                CGContextScaleCTM(ctx, 1, -1);
                CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
                CGContextDrawImage(ctx, CGRectMake(0, 0, rect.size.width, rect.size.height), image);
                CGContextRestoreGState(ctx);
                // A hairline keeps pale pictures from melting into the background.
                [[NSColor.labelColor colorWithAlphaComponent:0.12] setStroke];
                NSBezierPath* edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 0.25, 0.25) xRadius:4 yRadius:4];
                edge.lineWidth = 0.5;
                [edge stroke];
            }
            continue;
        }

        if (item.kind == crumb::Kind::Files) {
            const size_t files = fileCount(item);
            if (files == 1 && row.folder < 0) {
                BOOL directory = NO;
                const std::string path = item.head;
                row.folder = [NSFileManager.defaultManager fileExistsAtPath:@(path.c_str()) isDirectory:&directory] && directory;
            }
            const CRIcon icon = files > 1 ? CRIconDocuments : row.folder == 1 ? CRIconFolder : CRIconDocument;
            CRDrawIcon(icon, NSMakeRect(x, std::round(box.origin.y + (box.size.height - 16) / 2), 16, 16), color);
            x += 24;
        }
        if (!row.line) row.line = makeLine(crumb::makeLine(displayText(item), row.matches, 300), right - x, _ellipsis.get());
        drawLine(ctx, row.line.get(), x, box.origin.y, box.size.height, rowFont(), color);
    }

    // A slim scroll indicator while scrolling.
    const CGFloat height = self.bounds.size.height;
    if (_scrolling && _contentHeight > height) {
        const CGFloat knob = std::max<CGFloat>(24, height * height / _contentHeight);
        const CGFloat y = (height - knob) * _offset / (_contentHeight - height);
        [NSColor.tertiaryLabelColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(width - 5, y + 2, 3, knob - 4) xRadius:1.5 yRadius:1.5] fill];
    }
}

#pragma mark Mouse

- (NSInteger)rowForEvent:(NSEvent*)event {
    return [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)mouseMoved:(NSEvent*)event {
    const NSInteger row = [self rowForEvent:event];
    if (row >= 0 && row != _selected) [_popup listDidHover:row];
}

- (void)mouseDragged:(NSEvent*)event {
    [self mouseMoved:event];
}

- (void)mouseDown:(NSEvent*)event {
    _pressed = [self rowForEvent:event];
    if (_pressed >= 0 && _pressed != _selected) [_popup listDidHover:_pressed];
}

- (void)mouseUp:(NSEvent*)event {
    const NSInteger row = [self rowForEvent:event];
    if (row >= 0 && row == _pressed) [_popup listDidClick:row];
    _pressed = -1;
}

- (void)scrollWheel:(NSEvent*)event {
    const CGFloat delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * kRow;
    [self scrollTo:_offset - delta];
    // The rows moved under the pointer.
    const NSInteger row = [self rowForEvent:event];
    if (row >= 0 && row != _selected) [_popup listDidHover:row];
}

@end

#pragma mark - Footer buttons

@interface CRFooterButton : CRView
@property(nonatomic, copy) NSString* title;
@property(nonatomic) CRIcon icon;
@property(nonatomic) BOOL hasIcon;
@property(nonatomic, strong, nullable) NSColor* tint;
@property(nonatomic, copy) void (^action)(void);
@end

@implementation CRFooterButton {
    BOOL _hovered;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                                                                   NSTrackingInVisibleRect
                                                             owner:self
                                                          userInfo:nil]];
    }
    return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    return YES;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setTitle:(NSString*)title {
    _title = [title copy];
    self.needsDisplay = YES;
}

- (void)setTint:(NSColor*)tint {
    _tint = tint;
    self.needsDisplay = YES;
}

- (void)setHovered:(BOOL)hovered {
    _hovered = hovered;
    self.needsDisplay = YES;
}

- (void)mouseEntered:(NSEvent*)event {
    [self setHovered:YES];
}

- (void)mouseExited:(NSEvent*)event {
    [self setHovered:NO];
}

- (void)mouseDown:(NSEvent*)event {
}

- (void)mouseUp:(NSEvent*)event {
    if (NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds) && self.action) self.action();
}

- (void)drawRect:(NSRect)dirtyRect {
    if (_hovered) {
        [[NSColor.labelColor colorWithAlphaComponent:0.08] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:7 yRadius:7] fill];
    }
    NSColor* color = self.tint ?: (_hovered ? NSColor.labelColor : NSColor.secondaryLabelColor);
    if (self.hasIcon) {
        CRDrawIcon(self.icon, NSMakeRect(std::round(NSMidX(self.bounds) - 8), std::round(NSMidY(self.bounds) - 8), 16, 16), color);
        return;
    }
    NSDictionary* attributes = @{
        NSFontAttributeName : [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName : color,
    };
    const NSSize size = [self.title sizeWithAttributes:attributes];
    [self.title drawAtPoint:NSMakePoint(10, std::round(NSMidY(self.bounds) - size.height / 2)) withAttributes:attributes];
}

- (CGFloat)fittingWidth {
    NSDictionary* attributes = @{NSFontAttributeName : [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]};
    return std::ceil([self.title sizeWithAttributes:attributes].width) + 20;
}

@end

#pragma mark - Hairline

@interface CRRule : CRView
@end

@implementation CRRule

- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.separatorColor setFill];
    NSRectFill(self.bounds);
}

@end

#pragma mark - Header and search

namespace {

bool usingInputMethod() {
    TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
    if (!source) return false;
    auto type = static_cast<CFStringRef>(TISGetInputSourceProperty(source, kTISPropertyInputSourceType));
    const bool method = type && (CFEqual(type, kTISTypeKeyboardInputMode) || CFEqual(type, kTISTypeKeyboardInputMethodModeEnabled) ||
                                 CFEqual(type, kTISTypeKeyboardInputMethodWithoutModes));
    CFRelease(source);
    return method;
}

}  // namespace

// The title and, while searching, the query. Crumb reads the keyboard here itself (with input method support)
// instead of using a system text field: those bring the whole text system along, plus an AutoFill helper
// process.
@interface CRHeaderView : CRView <NSTextInputClient, NSTextInputTraits>
- (instancetype)initWithPopup:(CRPopup*)popup;
@property(nonatomic, readonly) NSString* query;
@property(nonatomic, copy) NSString* title;
- (void)clear;
- (void)paste;
@end

@implementation CRHeaderView {
    __weak CRPopup* _popup;
    NSMutableString* _query;
    NSString* _marked;  // an input method's composition, not part of the query yet
    CGFloat _caretX;
}

- (instancetype)initWithPopup:(CRPopup*)popup {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _popup = popup;
        _query = [NSMutableString string];
        _title = @"Crumb";
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

// With an ordinary keyboard layout Crumb reads keys itself and has no input context: a text input context makes
// macOS start an AutoFill helper process (about 13 MB) for the app. Input methods (Chinese, Japanese, Korean…)
// need one to compose text, so it exists only while one of them is the current input source.
- (NSTextInputContext*)inputContext {
    return usingInputMethod() ? [super inputContext] : nil;
}

// A search box wants none of the system's text services.
- (NSTextInputTraitType)autocorrectionType { return NSTextInputTraitTypeNo; }
- (void)setAutocorrectionType:(NSTextInputTraitType)type {}
- (NSTextInputTraitType)spellCheckingType { return NSTextInputTraitTypeNo; }
- (void)setSpellCheckingType:(NSTextInputTraitType)type {}
- (NSTextInputTraitType)grammarCheckingType { return NSTextInputTraitTypeNo; }
- (void)setGrammarCheckingType:(NSTextInputTraitType)type {}
- (NSTextInputTraitType)smartQuotesType { return NSTextInputTraitTypeNo; }
- (void)setSmartQuotesType:(NSTextInputTraitType)type {}
- (NSTextInputTraitType)smartDashesType { return NSTextInputTraitTypeNo; }
- (void)setSmartDashesType:(NSTextInputTraitType)type {}
- (NSTextInputTraitType)smartInsertDeleteType { return NSTextInputTraitTypeNo; }
- (void)setSmartInsertDeleteType:(NSTextInputTraitType)type {}
- (NSTextInputTraitType)textReplacementType { return NSTextInputTraitTypeNo; }
- (void)setTextReplacementType:(NSTextInputTraitType)type {}
- (NSTextInputTraitType)dataDetectionType { return NSTextInputTraitTypeNo; }
- (void)setDataDetectionType:(NSTextInputTraitType)type {}
- (NSTextInputTraitType)linkDetectionType { return NSTextInputTraitTypeNo; }
- (void)setLinkDetectionType:(NSTextInputTraitType)type {}
- (NSTextInputTraitType)textCompletionType { return NSTextInputTraitTypeNo; }
- (void)setTextCompletionType:(NSTextInputTraitType)type {}
- (NSTextInputTraitType)inlinePredictionType { return NSTextInputTraitTypeNo; }
- (void)setInlinePredictionType:(NSTextInputTraitType)type {}
- (NSTextInputTraitType)mathExpressionCompletionType { return NSTextInputTraitTypeNo; }
- (void)setMathExpressionCompletionType:(NSTextInputTraitType)type {}
- (NSWritingToolsBehavior)writingToolsBehavior { return NSWritingToolsBehaviorNone; }
- (void)setWritingToolsBehavior:(NSWritingToolsBehavior)behavior {}

- (NSString*)query {
    return _query;
}

- (void)setTitle:(NSString*)title {
    _title = [title copy];
    self.needsDisplay = YES;
}

- (void)clear {
    [_query setString:@""];
    _marked = nil;
    if (self.inputContext) [self.inputContext discardMarkedText];
    self.needsDisplay = YES;
}

- (void)changed {
    self.needsDisplay = YES;
    [_popup queryChanged];
}

// One line: line breaks and tabs become spaces.
- (NSString*)singleLine:(id)string {
    NSString* text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    if (![text isKindOfClass:NSString.class]) return @"";
    NSArray* parts = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    return [[parts componentsJoinedByString:@" "] stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
}

- (void)paste {
    NSString* text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!text.length) return;
    if (text.length > 1000) text = [text substringToIndex:[text rangeOfComposedCharacterSequenceAtIndex:1000].location];
    [_query appendString:[self singleLine:text]];
    _marked = nil;
    [self changed];
}

- (void)keyDown:(NSEvent*)event {
    if (self.inputContext) {
        [self interpretKeyEvents:@[ event ]];
        return;
    }
    const NSEventModifierFlags flags = event.modifierFlags;
    const bool option = flags & NSEventModifierFlagOption, command = flags & NSEventModifierFlagCommand;
    const bool control = flags & NSEventModifierFlagControl;
    SEL command_ = nullptr;
    switch (event.keyCode) {
        case kVK_UpArrow: command_ = @selector(moveUp:); break;
        case kVK_DownArrow: command_ = @selector(moveDown:); break;
        case kVK_PageUp: command_ = @selector(pageUp:); break;
        case kVK_PageDown: command_ = @selector(pageDown:); break;
        case kVK_Home: command_ = @selector(moveToBeginningOfDocument:); break;
        case kVK_End: command_ = @selector(moveToEndOfDocument:); break;
        case kVK_Return:
        case kVK_ANSI_KeypadEnter: command_ = @selector(insertNewline:); break;
        case kVK_Escape: command_ = @selector(cancelOperation:); break;
        case kVK_Delete:
            command_ = option ? @selector(deleteWordBackward:) : command ? @selector(deleteToBeginningOfLine:) : @selector(deleteBackward:);
            break;
        case kVK_ANSI_N: if (control) command_ = @selector(moveDown:); break;
        case kVK_ANSI_P: if (control) command_ = @selector(moveUp:); break;
        default: break;
    }
    if (command_) {
        [self doCommandBySelector:command_];
        return;
    }
    if (command || control) return;
    // Printable characters only (the keyboard layout has already applied dead keys such as ⌥E E → é).
    NSMutableString* text = [NSMutableString string];
    NSString* characters = event.characters ?: @"";
    for (NSUInteger i = 0; i < characters.length; ++i) {
        const unichar c = [characters characterAtIndex:i];
        if (c >= 0x20 && c != 0x7F && (c < 0xF700 || c > 0xF8FF)) [text appendFormat:@"%C", c];
    }
    if (text.length) [self insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSString* text = [self singleLine:string];
    _marked = nil;
    if (!text.length) {
        self.needsDisplay = YES;
        return;
    }
    [_query appendString:text];
    [self changed];
}

- (void)doCommandBySelector:(SEL)selector {
    if (selector == @selector(deleteBackward:)) {
        if (_query.length) {
            [_query deleteCharactersInRange:[_query rangeOfComposedCharacterSequenceAtIndex:_query.length - 1]];
            [self changed];
        }
        return;
    }
    if (selector == @selector(deleteToBeginningOfLine:) || selector == @selector(deleteToBeginningOfParagraph:)) {
        if (_query.length) {
            [_query setString:@""];
            [self changed];
        }
        return;
    }
    [_popup performCommand:selector];
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    NSString* text = [self singleLine:string];
    _marked = text.length ? text : nil;
    self.needsDisplay = YES;
}

- (void)unmarkText {
    if (!_marked) return;
    [_query appendString:_marked];
    _marked = nil;
    [self changed];
}

- (NSRange)selectedRange {
    return NSMakeRange(_query.length + _marked.length, 0);
}

- (NSRange)markedRange {
    return _marked.length ? NSMakeRange(_query.length, _marked.length) : NSMakeRange(NSNotFound, 0);
}

- (BOOL)hasMarkedText {
    return _marked.length > 0;
}

- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    NSString* all = [_query stringByAppendingString:_marked ?: @""];
    const NSRange clipped = NSIntersectionRange(range, NSMakeRange(0, all.length));
    if (actualRange) *actualRange = clipped;
    return [[NSAttributedString alloc] initWithString:[all substringWithRange:clipped]];
}

- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText {
    return @[];
}

// Input methods put their candidate window at the caret.
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (actualRange) *actualRange = range;
    const NSRect local = NSMakeRect(_caretX, 0, 1, self.bounds.size.height);
    return [self.window convertRectToScreen:[self convertRect:local toView:nil]];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    return NSNotFound;
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    const CGFloat height = self.bounds.size.height;
    NSFont* titleFont = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    CF<CTLineRef> title = makeLine(self.title, titleFont);
    drawLine(ctx, title.get(), 16, 0, height, titleFont, NSColor.labelColor);
    _caretX = 16 + lineWidth(title.get()) + 14;
    if (!_query.length && !_marked.length) return;  // the search field only shows while searching

    CRDrawIcon(CRIconSearch, NSMakeRect(_caretX, std::round((height - 15) / 2), 15, 15), NSColor.tertiaryLabelColor);
    const CGFloat x = _caretX + 21, available = self.bounds.size.width - x - 18;
    NSFont* font = [NSFont systemFontOfSize:14];
    NSMutableAttributedString* text = [[NSMutableAttributedString alloc]
        initWithString:[_query stringByAppendingString:_marked ?: @""]
            attributes:@{NSFontAttributeName : font, (__bridge NSString*)kCTForegroundColorFromContextAttributeName : @YES}];
    if (_marked.length)
        [text addAttribute:(__bridge NSString*)kCTUnderlineStyleAttributeName
                     value:@(kCTUnderlineStyleSingle)
                     range:NSMakeRange(_query.length, _marked.length)];
    CF<CTLineRef> line(CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text));
    if (lineWidth(line.get()) > available) {  // keep the end of a long query in view
        CF<CTLineRef> ellipsis = makeLine(@"…", font);
        CTLineRef cut = CTLineCreateTruncatedLine(line.get(), available, kCTLineTruncationStart, ellipsis.get());
        if (cut) line = CF<CTLineRef>(cut);
    }
    drawLine(ctx, line.get(), x, 0, height, font, NSColor.labelColor);
    _caretX = x + lineWidth(line.get()) + 1;
    [NSColor.controlAccentColor setFill];
    NSRectFill(NSMakeRect(std::round(_caretX), std::round((height - 18) / 2), 2, 18));
}

@end

#pragma mark - Previews

namespace {

constexpr CGFloat kPreviewInsetX = 14;
constexpr CGFloat kPreviewInsetY = 12;
constexpr NSUInteger kBlockChars = 2000;  // long paragraphs are laid out in pieces of about this size

NSFont* previewFont() {
    static NSFont* font = [NSFont systemFontOfSize:13];
    return font;
}

}  // namespace

// Text drawn with Core Text, laid out a paragraph at a time as it scrolls into view, so even megabytes of text
// open at once and never pull in the system text engine.
@interface CRTextPreview : CRView
- (instancetype)initWithText:(NSString*)text maxWidth:(CGFloat)maxWidth maxHeight:(CGFloat)maxHeight;
@end

@implementation CRTextPreview {
    NSString* _text;
    struct Block {
        uint32_t location, length;
        float height;
        bool measured;
    };
    std::vector<Block> _blocks;
    std::vector<CGFloat> _tops;  // top of each block, plus the total height at the end
    std::unordered_map<size_t, CF<CTFrameRef>> _frames;
    CGFloat _textWidth, _lineHeight, _offset;
    BOOL _scrolling;
    NSInteger _scrollGeneration;
}

- (instancetype)initWithText:(NSString*)text maxWidth:(CGFloat)maxWidth maxHeight:(CGFloat)maxHeight {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _text = text;
        _textWidth = maxWidth - 2 * kPreviewInsetX;
        NSFont* font = previewFont();
        _lineHeight = std::ceil(font.ascender - font.descender + font.leading);
        [self split];
        [self updateTops:0];
        CGFloat width = maxWidth;
        if (text.length <= 20000) {  // short texts get a snug window
            CGFloat widest = 0;
            for (size_t i = 0; i < _blocks.size(); ++i) widest = std::max(widest, [self measure:i]);
            [self updateTops:0];
            width = std::min(maxWidth, std::ceil(widest) + 2 * kPreviewInsetX + 2);
        }
        const CGFloat height = std::min(maxHeight, _tops.back() + 2 * kPreviewInsetY);
        self.frame = NSMakeRect(0, 0, std::max<CGFloat>(width, 120), std::max<CGFloat>(height, 36));
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)split {
    const NSUInteger length = _text.length;
    NSCharacterSet* newlines = NSCharacterSet.newlineCharacterSet;
    NSCharacterSet* spaces = NSCharacterSet.whitespaceCharacterSet;
    NSUInteger start = 0;
    while (start < length || (start == 0 && length == 0)) {
        const NSRange lineBreak = [_text rangeOfCharacterFromSet:newlines options:0 range:NSMakeRange(start, length - start)];
        const NSUInteger end = lineBreak.location == NSNotFound ? length : lineBreak.location;
        NSUInteger piece = start;
        do {
            NSUInteger cut = std::min(end, piece + kBlockChars);
            if (cut < end) {
                const NSRange space = [_text rangeOfCharacterFromSet:spaces
                                                             options:NSBackwardsSearch
                                                               range:NSMakeRange(piece + kBlockChars / 2, cut - piece - kBlockChars / 2)];
                cut = space.location != NSNotFound ? space.location + 1 : [_text rangeOfComposedCharacterSequenceAtIndex:cut].location;
                if (cut <= piece) cut = std::min(end, piece + kBlockChars);
            }
            _blocks.push_back({static_cast<uint32_t>(piece), static_cast<uint32_t>(cut - piece), 0, false});
            piece = cut;
        } while (piece < end);
        if (lineBreak.location == NSNotFound) break;
        start = NSMaxRange(lineBreak);
        if ([_text characterAtIndex:lineBreak.location] == '\r' && start < length && [_text characterAtIndex:start] == '\n') ++start;
    }
    const CGFloat perLine = std::max<CGFloat>(1, _textWidth / (previewFont().pointSize * 0.52));
    for (auto& block : _blocks)
        block.height = static_cast<float>(_lineHeight * std::max<CGFloat>(1, std::ceil(block.length / perLine)));
}

- (NSAttributedString*)stringFor:(size_t)index {
    const Block& block = _blocks[index];
    NSString* text = [_text substringWithRange:NSMakeRange(block.location, block.length)];
    return [[NSAttributedString alloc]
        initWithString:text
            attributes:@{NSFontAttributeName : previewFont(), (__bridge NSString*)kCTForegroundColorFromContextAttributeName : @YES}];
}

// Lays out one block; returns its width.
- (CGFloat)measure:(size_t)index {
    Block& block = _blocks[index];
    if (block.length == 0) {
        block.height = static_cast<float>(_lineHeight);
        block.measured = true;
        return 0;
    }
    CTFramesetterRef setter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)[self stringFor:index]);
    const CGSize size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRangeMake(0, 0), nullptr,
                                                                     CGSizeMake(_textWidth, CGFLOAT_MAX), nullptr);
    CFRelease(setter);
    block.height = static_cast<float>(std::ceil(size.height));
    block.measured = true;
    return size.width;
}

- (void)updateTops:(size_t)from {
    _tops.resize(_blocks.size() + 1);
    if (from == 0) _tops[0] = 0;
    for (size_t i = from; i < _blocks.size(); ++i) _tops[i + 1] = _tops[i] + _blocks[i].height;
}

- (size_t)blockAt:(CGFloat)y {
    auto it = std::upper_bound(_tops.begin(), _tops.end() - 1, y);
    return it == _tops.begin() ? 0 : static_cast<size_t>(it - _tops.begin()) - 1;
}

- (void)drawRect:(NSRect)dirtyRect {
    if (_blocks.empty()) return;
    const CGFloat visibleTop = _offset, visibleBottom = _offset + self.bounds.size.height;
    // Measure what is about to show; real heights replace the estimates.
    size_t first = [self blockAt:std::max<CGFloat>(0, visibleTop - kPreviewInsetY)];
    for (size_t i = first; i < _blocks.size() && _tops[i] < visibleBottom; ++i) {
        if (_blocks[i].measured) continue;
        [self measure:i];
        [self updateTops:i];
    }
    first = [self blockAt:std::max<CGFloat>(0, visibleTop - kPreviewInsetY)];
    if (_frames.size() > 64) _frames.clear();

    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGColorRef color = NSColor.labelColor.CGColor;
    for (size_t i = first; i < _blocks.size() && kPreviewInsetY + _tops[i] - _offset < NSMaxY(dirtyRect); ++i) {
        const CGFloat height = _blocks[i].height;
        if (_blocks[i].length == 0) continue;
        auto it = _frames.find(i);
        if (it == _frames.end()) {
            CTFramesetterRef setter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)[self stringFor:i]);
            CGPathRef path = CGPathCreateWithRect(CGRectMake(0, 0, _textWidth, height + _lineHeight), nullptr);
            it = _frames.emplace(i, CF<CTFrameRef>(CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, nullptr))).first;
            CGPathRelease(path);
            CFRelease(setter);
        }
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, kPreviewInsetX, kPreviewInsetY + _tops[i] - _offset + height + _lineHeight);
        CGContextScaleCTM(ctx, 1, -1);
        CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
        CGContextSetFillColorWithColor(ctx, color);
        CTFrameDraw(it->second.get(), ctx);
        CGContextRestoreGState(ctx);
    }

    const CGFloat total = _tops.back() + 2 * kPreviewInsetY, viewHeight = self.bounds.size.height;
    if (_scrolling && total > viewHeight) {
        const CGFloat knob = std::max<CGFloat>(24, viewHeight * viewHeight / total);
        const CGFloat y = (viewHeight - knob) * _offset / (total - viewHeight);
        [NSColor.tertiaryLabelColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(self.bounds.size.width - 6, y + 3, 3, knob - 6) xRadius:1.5 yRadius:1.5] fill];
    }
}

- (void)scrollWheel:(NSEvent*)event {
    const CGFloat delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * _lineHeight * 3;
    const CGFloat total = _tops.back() + 2 * kPreviewInsetY;
    const CGFloat offset = std::clamp<CGFloat>(_offset - delta, 0, std::max<CGFloat>(0, total - self.bounds.size.height));
    if (offset == _offset) return;
    _offset = offset;
    _scrolling = YES;
    const NSInteger generation = ++_scrollGeneration;
    __weak CRTextPreview* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        CRTextPreview* preview = weakSelf;
        if (!preview || preview->_scrollGeneration != generation) return;
        preview->_scrolling = NO;
        preview.needsDisplay = YES;
    });
    self.needsDisplay = YES;
}

@end

namespace {

// A picture decoded at the size it is shown, upright.
CF<CGImageRef> decodePicture(NSURL* url, CGFloat maxPixels) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    if (!source) return {};
    NSDictionary* options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize : @(maxPixels),
    };
    CF<CGImageRef> picture(CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options));
    CFRelease(source);
    return picture;
}

}  // namespace

// A picture, drawn directly. Once drawn, the decoded picture is let go: the layer holds the pixels.
@interface CRImagePreview : CRView
- (instancetype)initWithPicture:(CF<CGImageRef>)picture url:(NSURL*)url maxPixels:(CGFloat)maxPixels size:(NSSize)size;
@end

@implementation CRImagePreview {
    CF<CGImageRef> _image;
    NSURL* _url;
    CGFloat _maxPixels;
}

- (instancetype)initWithPicture:(CF<CGImageRef>)picture url:(NSURL*)url maxPixels:(CGFloat)maxPixels size:(NSSize)size {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, size.width + 16, size.height + 16)])) {
        _image = std::move(picture);
        _url = url;
        _maxPixels = maxPixels;
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    if (!_image) _image = decodePicture(_url, _maxPixels);  // drawn again, such as on another display
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    const CGRect rect = NSInsetRect(self.bounds, 8, 8);
    CGContextSaveGState(ctx);
    CGPathRef clip = CGPathCreateWithRoundedRect(rect, 6, 6, nullptr);
    CGContextAddPath(ctx, clip);
    CGContextClip(ctx);
    CGPathRelease(clip);
    CGContextTranslateCTM(ctx, rect.origin.x, rect.origin.y + rect.size.height);  // the view is flipped
    CGContextScaleCTM(ctx, 1, -1);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, rect.size.width, rect.size.height), _image.get());
    CGContextRestoreGState(ctx);
    _image = CF<CGImageRef>();
}

@end

#pragma mark - Popup

@implementation CRPopup {
    crumb::Store* _store;
    CRClipboard* _clipboard;
    CRPanel* _panel;
    NSView* _content;
    CRHeaderView* _header;
    CRRule* _topRule;
    CRRule* _bottomRule;
    CRListView* _list;
    CRSettingsPage* _page;
    CRFooterButton* _clear;
    CRFooterButton* _settings;
    CRFooterButton* _quit;
    NSPanel* _preview;
    NSInteger _previewGeneration;
    NSInteger _clearGeneration;
    BOOL _confirmingClear;
    BOOL _open;
    BOOL _settingsMode;
    CGFloat _left, _top;  // where the panel's top-left corner sits while it is open
    std::unordered_map<uint64_t, crumb::Haystack> _haystacks;
}

- (instancetype)initWithStore:(crumb::Store*)store clipboard:(CRClipboard*)clipboard {
    if ((self = [super init])) {
        _store = store;
        _clipboard = clipboard;
    }
    return self;
}

- (BOOL)isOpen {
    return _open;
}

- (BOOL)recording {
    return _page.recording;
}

// The window is built only when it opens and torn down when it closes, so a closed Crumb holds no views.
- (void)build {
    if (_panel) return;
    _panel = (CRPanel*)makePanel(NSMakeRect(0, 0, kWidth, 300), CRPanel.class);
    _panel.popup = self;
    _panel.delegate = self;

    _content = [[CRFlippedView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, 300)];
    _header = [[CRHeaderView alloc] initWithPopup:self];
    [_content addSubview:_header];

    _topRule = [[CRRule alloc] initWithFrame:NSZeroRect];
    _bottomRule = [[CRRule alloc] initWithFrame:NSZeroRect];
    [_content addSubview:_topRule];
    [_content addSubview:_bottomRule];

    _list = [[CRListView alloc] initWithStore:_store popup:self];
    [_content addSubview:_list];

    __weak CRPopup* weakSelf = self;
    _clear = [[CRFooterButton alloc] initWithFrame:NSZeroRect];
    _clear.title = @"Clear History";
    _clear.action = ^{
        [weakSelf clearPressed];
    };
    _settings = [[CRFooterButton alloc] initWithFrame:NSZeroRect];
    _settings.title = @"Settings";
    _settings.icon = CRIconGear;
    _settings.hasIcon = YES;
    _settings.toolTip = @"Settings (⌘,)";
    _settings.action = ^{
        [weakSelf toggleSettings];
    };
    _quit = [[CRFooterButton alloc] initWithFrame:NSZeroRect];
    _quit.title = @"Quit Crumb";
    _quit.icon = CRIconPower;
    _quit.hasIcon = YES;
    _quit.toolTip = @"Quit Crumb (⌘Q)";
    _quit.action = ^{
        [NSApp terminate:nil];
    };
    [_content addSubview:_clear];
    [_content addSubview:_settings];
    [_content addSubview:_quit];

    _panel.contentView = makeBackground(_content, kRadius);
}

- (void)releaseWindow {
    if (_open || !_panel) return;
    _panel.delegate = nil;
    _panel.contentView = nil;
    _panel = nil;
    _content = nil;
    _header = nil;
    _topRule = nil;
    _bottomRule = nil;
    _list = nil;
    _page = nil;
    _clear = nil;
    _settings = nil;
    _quit = nil;
}

#pragma mark Showing

- (void)toggle {
    if (_open)
        [self close];
    else
        [self showAt:NSEvent.mouseLocation settings:NO];
}

- (void)showSettings {
    if (_open) {
        if (!_settingsMode) [self toggleSettings];
        return;
    }
    const NSRect visible = NSScreen.mainScreen.visibleFrame;
    [self showAt:NSMakePoint(NSMidX(visible) - kWidth / 2, NSMidY(visible) + 180) settings:YES];
}

- (void)showAt:(NSPoint)point settings:(BOOL)settings {
    const CFTimeInterval start = CACurrentMediaTime();
    [self build];
    [_clipboard pollNow];
    [_header clear];
    [self resetClear];
    _settingsMode = settings;
    [self filter];

    // The top-left corner goes at the pointer, like a context menu.
    const NSRect visible = screenAt(point).visibleFrame;
    const CGFloat height = std::min(kHeader + [self bodyHeight] + kFooter, visible.size.height - 16);
    _left = point.x + kWidth > NSMaxX(visible) ? point.x - kWidth : point.x;
    _left = std::clamp<CGFloat>(_left, NSMinX(visible) + 4, NSMaxX(visible) - kWidth - 4);
    _top = std::clamp<CGFloat>(point.y, NSMinY(visible) + height + 4, NSMaxY(visible));
    [self applyMode];
    [self layout];

    _open = YES;
    [_panel orderFrontRegardless];
    [_panel makeKeyWindow];
    [_panel makeFirstResponder:_header];
    if (!settings) [self schedulePreview];
    if (trace()) NSLog(@"open %.1f ms (%ld rows)", (CACurrentMediaTime() - start) * 1000, (long)_list.count);
}

- (CGFloat)bodyHeight {
    if (_settingsMode) return _page.preferredHeight;
    return _list.count ? std::min(_list.contentHeight, kMaxList) : kEmptyList;
}

- (void)applyMode {
    if (_settingsMode && !_page) {
        __weak CRPopup* weakSelf = self;
        CRFooterButton* check = nil;
        if (self.updater.available) {
            check = [[CRFooterButton alloc] initWithFrame:NSZeroRect];
            check.title = @"Check for Updates";
            check.action = ^{
                CRPopup* popup = weakSelf;
                [popup->_page checkForUpdates];
            };
        }
        _page = [[CRSettingsPage alloc] initWithUpdater:self.updater checkButton:check];
        _page.returnResponder = _header;
        _page.onLimit = ^(NSInteger limit) {
            CRPopup* popup = weakSelf;
            if (popup.onLimit) popup.onLimit(limit);
        };
        [_content addSubview:_page];
    }
    if (_settingsMode) [_page refresh];
    _page.hidden = !_settingsMode;
    _list.hidden = _settingsMode;
    _clear.hidden = _settingsMode;
    _settings.tint = _settingsMode ? NSColor.controlAccentColor : nil;
    _header.title = _settingsMode ? @"Crumb Settings" : @"Crumb";
}

- (void)toggleSettings {
    [self hidePreview];
    ++_previewGeneration;
    _settingsMode = !_settingsMode;
    [_header clear];
    if (!_settingsMode) [self filter];
    [self applyMode];
    [self layout];
    [_panel makeFirstResponder:_header];
}

- (void)layout {
    const NSRect visible = screenAt(NSMakePoint(_left + 1, _top - 1)).visibleFrame;
    const CGFloat height = std::min(kHeader + [self bodyHeight] + kFooter,
                                    std::max<CGFloat>(kHeader + kFooter + kRow, _top - NSMinY(visible) - 4));
    const CGFloat body = height - kHeader - kFooter;
    [_panel setFrame:NSMakeRect(_left, _top - height, kWidth, height) display:NO animate:NO];
    _content.frame = NSMakeRect(0, 0, kWidth, height);
    _header.frame = NSMakeRect(0, 0, kWidth, kHeader);
    _topRule.frame = NSMakeRect(0, kHeader - 1, kWidth, 1);
    _list.frame = NSMakeRect(0, kHeader, kWidth, body);
    _page.frame = NSMakeRect(0, kHeader, kWidth, body);
    _bottomRule.frame = NSMakeRect(0, height - kFooter, kWidth, 1);

    const CGFloat footerY = height - kFooter + 6, buttonHeight = kFooter - 12;
    _clear.frame = NSMakeRect(6, footerY, [_clear fittingWidth], buttonHeight);
    _quit.frame = NSMakeRect(kWidth - 6 - 32, footerY, 32, buttonHeight);
    _settings.frame = NSMakeRect(NSMinX(_quit.frame) - 2 - 32, footerY, 32, buttonHeight);
    [_panel invalidateShadow];
}

- (void)close {
    if (!_open) return;
    _open = NO;
    ++_previewGeneration;
    [self hidePreview];
    [_panel close];
    [_list clear];
    std::unordered_map<uint64_t, crumb::Haystack>().swap(_haystacks);
    [self resetClear];
    // The window goes once AppKit is done with it, then the freed memory goes back to the system.
    __weak CRPopup* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf releaseWindow];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        CRPopup* popup = weakSelf;
        if (popup && !popup->_open) malloc_zone_pressure_relief(nullptr, 0);
    });
}

- (void)windowDidResignKey:(NSNotification*)notification {
    [self close];
}

- (void)reload {
    if (!_open || _settingsMode) return;
    const uint64_t selected = _list.selected >= 0 ? [_list idAt:_list.selected] : 0;
    [self filter];
    [self layout];
    for (NSInteger row = 0; row < _list.count; ++row) {
        if ([_list idAt:row] == selected) {
            _list.selected = row;
            [_list scrollToSelection];
            break;
        }
    }
}

#pragma mark Search

- (void)filter {
    const auto& items = _store->items();
    const crumb::Query query(_header.query.UTF8String ?: "");
    std::vector<Row> rows;
    if (query.empty()) {
        rows.resize(items.size());
        for (size_t i = 0; i < items.size(); ++i) rows[i].item = i;
    } else {
        struct Hit {
            size_t item;
            int score;
            std::vector<uint32_t> matches;
        };
        std::vector<Hit> hits;
        std::vector<uint32_t> matches;
        for (size_t i = 0; i < items.size(); ++i) {
            const auto& item = items[i];
            if (item.kind == crumb::Kind::Image && !(item.flags & crumb::kHasText)) continue;
            auto it = _haystacks.find(item.id);
            if (it == _haystacks.end()) it = _haystacks.emplace(item.id, crumb::prepare(displayText(item))).first;
            int score = 0;
            if (query.match(it->second, score, matches)) hits.push_back({i, score, matches});
        }
        std::stable_sort(hits.begin(), hits.end(), [](const Hit& a, const Hit& b) { return a.score > b.score; });
        rows.resize(hits.size());
        for (size_t k = 0; k < hits.size(); ++k) {
            rows[k].item = hits[k].item;
            rows[k].matches = std::move(hits[k].matches);
        }
    }
    _list.emptyText = query.empty() ? @"Nothing copied yet" : @"No matches";
    [_list setRows:std::move(rows)];
}

- (void)queryChanged {
    if (trace()) NSLog(@"query: [%@]", _header.query);
    if (_settingsMode) {  // typing on the settings page starts a search in the list
        _settingsMode = NO;
        [self applyMode];
    }
    [self filter];
    [self layout];
    [self schedulePreview];
}

- (void)performCommand:(SEL)command {
    if (command == @selector(cancelOperation:)) {
        if (_settingsMode)
            [self toggleSettings];
        else
            [self close];
        return;
    }
    if (_settingsMode) return;
    if (command == @selector(moveUp:)) [self moveTo:_list.selected - 1];
    else if (command == @selector(moveDown:)) [self moveTo:_list.selected + 1];
    else if (command == @selector(moveToBeginningOfDocument:) || command == @selector(scrollToBeginningOfDocument:)) [self moveTo:0];
    else if (command == @selector(moveToEndOfDocument:) || command == @selector(scrollToEndOfDocument:)) [self moveTo:_list.count - 1];
    else if (command == @selector(pageUp:) || command == @selector(scrollPageUp:)) [self moveTo:std::max<NSInteger>(0, _list.selected - 10)];
    else if (command == @selector(pageDown:) || command == @selector(scrollPageDown:))
        [self moveTo:std::min<NSInteger>(_list.count - 1, _list.selected + 10)];
    else if (command == @selector(insertNewline:) || command == @selector(insertLineBreak:)) [self activate:_list.selected];
    else if (command == @selector(deleteWordBackward:)) [self deleteSelected];  // ⌥⌫ deletes the selected entry
}

- (void)moveTo:(NSInteger)row {
    if (_list.count == 0) return;
    row = std::clamp<NSInteger>(row, 0, _list.count - 1);
    if (row == _list.selected) return;
    _list.selected = row;
    [_list scrollToSelection];
    [self schedulePreview];
}

- (BOOL)handleKeyEquivalent:(NSEvent*)event {
    if (event.type != NSEventTypeKeyDown) return NO;
    const NSEventModifierFlags flags = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift |
                                                              NSEventModifierFlagOption | NSEventModifierFlagControl);
    if (flags != NSEventModifierFlagCommand) return NO;
    static const unsigned short digits[] = {kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                            kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9};
    static const unsigned short keypad[] = {kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3,
                                            kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6,
                                            kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9};
    for (NSInteger i = 0; i < 9; ++i) {
        if (event.keyCode == digits[i] || event.keyCode == keypad[i]) {
            if (!_settingsMode) [self activate:i];
            return YES;
        }
    }
    NSString* key = CRKeyCharacter(event);
    if ([key isEqualToString:@","]) {
        [self toggleSettings];
        return YES;
    }
    if ([key isEqualToString:@"q"]) {
        [NSApp terminate:nil];
        return YES;
    }
    if ([key isEqualToString:@"w"]) {
        [self close];
        return YES;
    }
    if ([key isEqualToString:@"v"]) {
        if (_settingsMode) [self toggleSettings];
        [_header paste];
        return YES;
    }
    return NO;
}

#pragma mark Actions

- (void)listDidHover:(NSInteger)row {
    _list.selected = row;
    [self schedulePreview];
}

- (void)listDidClick:(NSInteger)row {
    [self activate:row];
}

- (void)activate:(NSInteger)row {
    if (row < 0 || row >= _list.count) return;
    const size_t item = [_list itemAt:row];
    [self close];
    [_clipboard copyItemAtIndex:item];
}

- (void)deleteSelected {
    const NSInteger row = _list.selected;
    if (row < 0) return;
    const size_t item = [_list itemAt:row];
    _haystacks.erase(_store->items()[item].id);
    _store->remove(item);
    [self filter];
    [self layout];
    if (_list.count) [self moveTo:std::min(row, _list.count - 1)];
    [self schedulePreview];
}

- (void)clearPressed {
    if (!_confirmingClear) {
        _confirmingClear = YES;
        _clear.title = @"Click Again to Clear";
        _clear.tint = NSColor.systemRedColor;
        _clear.frame = NSMakeRect(NSMinX(_clear.frame), NSMinY(_clear.frame), [_clear fittingWidth], NSHeight(_clear.frame));
        const NSInteger generation = ++_clearGeneration;
        __weak CRPopup* weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            CRPopup* popup = weakSelf;
            if (popup && popup->_clearGeneration == generation) [popup resetClear];
        });
        return;
    }
    [self resetClear];
    [self hidePreview];
    std::unordered_map<uint64_t, crumb::Haystack>().swap(_haystacks);
    [_clipboard clearHistory];  // also drops copies still being saved; the list reloads when it's done
}

- (void)resetClear {
    ++_clearGeneration;
    if (!_confirmingClear) return;
    _confirmingClear = NO;
    _clear.title = @"Clear History";
    _clear.tint = nil;
    _clear.frame = NSMakeRect(NSMinX(_clear.frame), NSMinY(_clear.frame), [_clear fittingWidth], NSHeight(_clear.frame));
}

#pragma mark Preview

- (void)schedulePreview {
    [self hidePreview];
    const NSInteger generation = ++_previewGeneration;
    __weak CRPopup* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(kPreviewDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CRPopup* popup = weakSelf;
        if (popup && popup->_open && !popup->_settingsMode && popup->_previewGeneration == generation) [popup showPreview];
    });
}

- (void)hidePreview {
    if (!_preview) return;
    [_preview close];
    _preview = nil;
}

- (void)showPreview {
    const NSInteger row = _list.selected;
    if (row < 0) return;
    const crumb::Item item = _store->items()[[_list itemAt:row]];
    const NSRect visible = screenAt(NSMakePoint(_left + 1, _top - 1)).visibleFrame;
    const CGFloat maxHeight = std::min(kPreviewMaxHeight, visible.size.height - 16);
    const CGFloat scale = _panel.backingScaleFactor ?: 2;

    NSView* view = nil;
    if (item.kind == crumb::Kind::Image) {
        const CGFloat w = std::max<CGFloat>(1, item.width / 2.0), h = std::max<CGFloat>(1, item.height / 2.0);
        const CGFloat fit = std::min({CGFloat(1), (kPreviewMaxWidth - 16) / w, (maxHeight - 16) / h});
        const NSSize size = NSMakeSize(std::max<CGFloat>(1, std::round(w * fit)), std::max<CGFloat>(1, std::round(h * fit)));
        NSURL* url = [NSURL fileURLWithPath:@(_store->imageFile(item).c_str())];
        const CGFloat maxPixels = std::ceil(std::max(size.width, size.height) * scale);
        CF<CGImageRef> picture = decodePicture(url, maxPixels);
        if (!picture) return;
        view = [[CRImagePreview alloc] initWithPicture:std::move(picture) url:url maxPixels:maxPixels size:size];
    } else {
        // A few spare bytes let the cut fall on a character boundary.
        std::string bytes =
            crumb::readFile(_store->file(item.id, item.kind == crumb::Kind::Files ? "files" : "txt"), kPreviewMaxBytes + 3);
        const bool cut = bytes.size() > kPreviewMaxBytes;
        bytes.resize(crumb::utf8Prefix(bytes, kPreviewMaxBytes).size());
        NSString* text = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding];
        if (!text) text = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSISOLatin1StringEncoding];
        if (cut) text = [text stringByAppendingString:@"\n…"];
        if (text.length == 0) return;
        view = [[CRTextPreview alloc] initWithText:text maxWidth:kPreviewMaxWidth maxHeight:maxHeight];
    }
    const NSSize size = view.frame.size;

    // Beside the list, level with the selected row; on the other side if there is no room.
    const NSRect panel = _panel.frame;
    const NSRect rowRect = [_list rectOfRow:row];
    const CGFloat rowTop = NSMaxY(panel) - kHeader - NSMinY(rowRect);
    CGFloat x = NSMaxX(panel) + 8;
    if (x + size.width > NSMaxX(visible)) x = NSMinX(panel) - 8 - size.width;
    x = std::max(x, NSMinX(visible) + 4);
    const CGFloat y = std::clamp<CGFloat>(rowTop - size.height, NSMinY(visible) + 4, NSMaxY(visible) - size.height);

    _preview = makePanel(NSMakeRect(x, y, size.width, size.height), NSPanel.class);
    _preview.contentView = makeBackground(view, 12);
    [_preview orderFrontRegardless];
}

@end
