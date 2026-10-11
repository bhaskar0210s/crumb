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
constexpr CGFloat kRadius = 16;   // panel corners
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
constexpr NSUInteger kMeasureLimit = 20000;  // longer previews just take the largest size

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

// Liquid Glass where the system has it (macOS 26 and later), the menu material before that. The class is
// looked up at run time so that Crumb also builds with older SDKs.
NSView* makeBackground(NSView* content, CGFloat radius) {
    if (Class glassClass = NSClassFromString(@"NSGlassEffectView")) {
        NSView* glass = [[glassClass alloc] initWithFrame:content.frame];
        [glass setValue:@(radius) forKey:@"cornerRadius"];
        [glass setValue:content forKey:@"contentView"];
        return glass;
    }
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
- (BOOL)handleKeyEquivalent:(NSEvent*)event;
- (void)listDidHover:(NSInteger)row;
- (void)listDidClick:(NSInteger)row;
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
    return [self.popup handleKeyEquivalent:event] || CRHandleEditingKey(event) || [super performKeyEquivalent:event];
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
        self.wantsLayer = YES;
        self.layer.contentsFormat = kCAContentsFormatRGBA8Uint;
        if (@available(macOS 14.0, *)) self.clipsToBounds = YES;  // rows scrolled half out must not spill over
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

- (void)drawRect:(NSRect)dirtyRect {
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

@interface CRFooterButton : NSView
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
        self.wantsLayer = YES;
        self.layer.contentsFormat = kCAContentsFormatRGBA8Uint;
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

@interface CRIconView : NSView
@property(nonatomic) CRIcon icon;
@end

@implementation CRIconView

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    CRDrawIcon(self.icon, self.bounds, NSColor.tertiaryLabelColor);
}

@end

@interface CRRule : NSView
@end

@implementation CRRule

- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.separatorColor setFill];
    NSRectFill(self.bounds);
}

@end

#pragma mark - Popup

@implementation CRPopup {
    crumb::Store* _store;
    CRClipboard* _clipboard;
    CRPanel* _panel;
    NSView* _content;
    NSTextField* _title;
    CRIconView* _magnifier;
    NSTextField* _search;
    CRRule* _topRule;
    CRRule* _bottomRule;
    CRListView* _list;
    CRFooterButton* _clear;
    CRFooterButton* _settings;
    CRFooterButton* _quit;
    NSTextView* _editor;
    NSPanel* _preview;
    NSInteger _previewGeneration;
    NSInteger _clearGeneration;
    BOOL _confirmingClear;
    BOOL _open;
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

- (void)prepare {
    if (_panel) return;
    _panel = (CRPanel*)makePanel(NSMakeRect(0, 0, kWidth, 300), CRPanel.class);
    _panel.popup = self;
    _panel.delegate = self;

    _content = [[CRFlippedView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, 300)];

    _title = [NSTextField labelWithString:@"Crumb"];
    _title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _title.textColor = NSColor.labelColor;
    [_title sizeToFit];
    [_content addSubview:_title];

    _magnifier = [[CRIconView alloc] initWithFrame:NSZeroRect];
    _magnifier.icon = CRIconSearch;
    [_content addSubview:_magnifier];

    _search = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _search.bezeled = NO;
    _search.bordered = NO;
    _search.drawsBackground = NO;
    _search.focusRingType = NSFocusRingTypeNone;
    _search.font = [NSFont systemFontOfSize:14];
    _search.cell.scrollable = YES;
    _search.cell.wraps = NO;
    _search.cell.usesSingleLineMode = YES;
    _search.delegate = self;
    [_content addSubview:_search];

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
        [weakSelf openSettings];
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

#pragma mark Showing

- (void)toggle {
    if (_open)
        [self close];
    else
        [self show];
}

- (void)show {
    const CFTimeInterval start = CACurrentMediaTime();
    [self prepare];
    [_clipboard pollNow];
    _search.stringValue = @"";
    [self resetClear];
    [self filter];

    // The top-left corner goes at the pointer, like a context menu.
    const NSPoint pointer = NSEvent.mouseLocation;
    const NSRect visible = screenAt(pointer).visibleFrame;
    const CGFloat height = std::min(kHeader + [self listHeight] + kFooter, visible.size.height - 16);
    _left = pointer.x + kWidth > NSMaxX(visible) ? pointer.x - kWidth : pointer.x;
    _left = std::clamp<CGFloat>(_left, NSMinX(visible) + 4, NSMaxX(visible) - kWidth - 4);
    _top = std::clamp<CGFloat>(pointer.y, NSMinY(visible) + height + 4, NSMaxY(visible));
    [self layout];

    _open = YES;
    [_panel orderFrontRegardless];
    [_panel makeKeyWindow];
    [_panel makeFirstResponder:_search];
    [self updateSearchField];
    [self schedulePreview];
    if (trace()) NSLog(@"open %.1f ms (%ld rows)", (CACurrentMediaTime() - start) * 1000, (long)_list.count);
}

- (CGFloat)listHeight {
    return _list.count ? std::min(_list.contentHeight, kMaxList) : kEmptyList;
}

- (void)layout {
    const NSRect visible = screenAt(NSMakePoint(_left + 1, _top - 1)).visibleFrame;
    const CGFloat height = std::min(kHeader + [self listHeight] + kFooter, std::max<CGFloat>(kHeader + kFooter + kRow, _top - NSMinY(visible) - 4));
    const CGFloat listHeight = height - kHeader - kFooter;
    [_panel setFrame:NSMakeRect(_left, _top - height, kWidth, height) display:NO animate:NO];
    _content.frame = NSMakeRect(0, 0, kWidth, height);

    const NSSize title = _title.frame.size;
    _title.frame = NSMakeRect(16, std::round((kHeader - title.height) / 2), title.width, title.height);
    const CGFloat glassX = NSMaxX(_title.frame) + 14;
    _magnifier.frame = NSMakeRect(glassX, std::round((kHeader - 15) / 2), 15, 15);
    const CGFloat fieldX = NSMaxX(_magnifier.frame) + 6;
    _search.frame = NSMakeRect(fieldX, std::round((kHeader - 20) / 2), kWidth - fieldX - 16, 20);

    _topRule.frame = NSMakeRect(0, kHeader - 1, kWidth, 1);
    _list.frame = NSMakeRect(0, kHeader, kWidth, listHeight);
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
    // The whole window goes once AppKit is done with it (rebuilding it takes a few milliseconds), so a closed
    // popup holds no layers or buffers. Then the freed memory goes back to the system.
    __weak CRPopup* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf teardown];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        CRPopup* popup = weakSelf;
        if (popup && !popup->_open) malloc_zone_pressure_relief(nullptr, 0);
    });
}

- (void)teardown {
    if (_open || !_panel) return;
    [self releaseWindow];
    // Build the next one now: views that have never been drawn hold no buffers, and opening stays instant.
    [self prepare];
}

- (void)releaseWindow {
    _panel.delegate = nil;
    _panel.contentView = nil;
    _panel = nil;
    _content = nil;
    _title = nil;
    _magnifier = nil;
    _search = nil;
    _topRule = nil;
    _bottomRule = nil;
    _list = nil;
    _clear = nil;
    _settings = nil;
    _quit = nil;
    _editor = nil;
}

// A plain editor for the search field: no spell checking, autocorrection or substitutions (checking also
// loads language models that would stay in memory).
- (id)windowWillReturnFieldEditor:(NSWindow*)window toObject:(id)client {
    if (client != _search) return nil;
    if (!_editor) {
        _editor = [[NSTextView alloc] initWithFrame:NSZeroRect];
        _editor.fieldEditor = YES;
        _editor.richText = NO;
        _editor.importsGraphics = NO;
        _editor.enabledTextCheckingTypes = 0;
        _editor.continuousSpellCheckingEnabled = NO;
        _editor.grammarCheckingEnabled = NO;
        _editor.automaticSpellingCorrectionEnabled = NO;
        _editor.automaticTextCompletionEnabled = NO;
        _editor.automaticTextReplacementEnabled = NO;
        _editor.automaticQuoteSubstitutionEnabled = NO;
        _editor.automaticDashSubstitutionEnabled = NO;
        _editor.automaticDataDetectionEnabled = NO;
        _editor.automaticLinkDetectionEnabled = NO;
        _editor.smartInsertDeleteEnabled = NO;
        _editor.allowsUndo = YES;
        if (@available(macOS 15.0, *)) _editor.writingToolsBehavior = NSWritingToolsBehaviorNone;
    }
    return _editor;
}

- (void)windowDidResignKey:(NSNotification*)notification {
    [self close];
}

- (void)reload {
    if (!_open) return;
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
    const crumb::Query query(_search.stringValue.UTF8String ?: "");
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

- (void)controlTextDidChange:(NSNotification*)notification {
    [self updateSearchField];
    [self filter];
    [self layout];
    [self schedulePreview];
}

// The search field only shows while searching: until then the header is just the title, and typing anywhere
// in the list starts a search.
- (void)updateSearchField {
    const BOOL searching = _search.stringValue.length > 0;
    _magnifier.hidden = !searching;
    _editor.insertionPointColor = searching ? NSColor.controlAccentColor : NSColor.clearColor;
}

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    if (command == @selector(moveUp:)) return [self moveTo:_list.selected - 1];
    if (command == @selector(moveDown:)) return [self moveTo:_list.selected + 1];
    if (command == @selector(moveToBeginningOfDocument:) || command == @selector(scrollToBeginningOfDocument:))
        return [self moveTo:0];
    if (command == @selector(moveToEndOfDocument:) || command == @selector(scrollToEndOfDocument:))
        return [self moveTo:_list.count - 1];
    if (command == @selector(pageUp:) || command == @selector(scrollPageUp:))
        return [self moveTo:std::max<NSInteger>(0, _list.selected - 10)];
    if (command == @selector(pageDown:) || command == @selector(scrollPageDown:))
        return [self moveTo:std::min<NSInteger>(_list.count - 1, _list.selected + 10)];
    if (command == @selector(insertNewline:) || command == @selector(insertLineBreak:)) {
        [self activate:_list.selected];
        return YES;
    }
    if (command == @selector(cancelOperation:)) {
        [self close];
        return YES;
    }
    if (command == @selector(deleteWordBackward:)) {  // ⌥⌫ deletes the selected entry
        [self deleteSelected];
        return YES;
    }
    return NO;
}

- (BOOL)moveTo:(NSInteger)row {
    if (_list.count == 0) return YES;
    row = std::clamp<NSInteger>(row, 0, _list.count - 1);
    if (row != _list.selected) {
        _list.selected = row;
        [_list scrollToSelection];
        [self schedulePreview];
    }
    return YES;
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
            [self activate:i];
            return YES;
        }
    }
    NSString* key = CRKeyCharacter(event);
    if ([key isEqualToString:@","]) {
        [self openSettings];
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

- (void)openSettings {
    [self close];
    if (self.onSettings) self.onSettings();
}

#pragma mark Preview

- (void)schedulePreview {
    [self hidePreview];
    const NSInteger generation = ++_previewGeneration;
    __weak CRPopup* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(kPreviewDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CRPopup* popup = weakSelf;
        if (popup && popup->_open && popup->_previewGeneration == generation) [popup showPreview];
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
    NSSize size;
    if (item.kind == crumb::Kind::Image) {
        const CGFloat w = std::max<CGFloat>(1, item.width / 2.0), h = std::max<CGFloat>(1, item.height / 2.0);
        const CGFloat fit = std::min({CGFloat(1), (kPreviewMaxWidth - 16) / w, (maxHeight - 16) / h});
        const NSSize image = NSMakeSize(std::max<CGFloat>(1, std::round(w * fit)), std::max<CGFloat>(1, std::round(h * fit)));
        CGImageRef picture = nullptr;
        NSURL* url = [NSURL fileURLWithPath:@(_store->imageFile(item).c_str())];
        if (CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr)) {
            NSDictionary* options = @{
                (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
                (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
                (id)kCGImageSourceThumbnailMaxPixelSize : @(std::ceil(std::max(image.width, image.height) * scale)),
            };
            picture = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
            CFRelease(source);
        }
        if (!picture) return;
        NSImageView* imageView = [NSImageView imageViewWithImage:[[NSImage alloc] initWithCGImage:picture size:image]];
        CGImageRelease(picture);
        imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        imageView.frame = NSMakeRect(8, 8, image.width, image.height);
        imageView.wantsLayer = YES;
        imageView.layer.cornerRadius = 6;
        imageView.layer.masksToBounds = YES;
        size = NSMakeSize(image.width + 16, image.height + 16);
        view = [[CRFlippedView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
        [view addSubview:imageView];
    } else {
        std::string bytes;
        // A few spare bytes let the cut fall on a character boundary.
        bytes = crumb::readFile(_store->file(item.id, item.kind == crumb::Kind::Files ? "files" : "txt"), kPreviewMaxBytes + 3);
        const bool cut = bytes.size() > kPreviewMaxBytes;
        bytes.resize(crumb::utf8Prefix(bytes, kPreviewMaxBytes).size());
        NSString* text = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding];
        if (!text) text = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSISOLatin1StringEncoding];
        if (cut) text = [text stringByAppendingString:@"\n…"];
        if (text.length == 0) return;

        NSFont* font = [NSFont systemFontOfSize:13];
        const CGFloat insetX = 14, insetY = 12;
        CGFloat width = kPreviewMaxWidth, height = maxHeight;
        if (text.length <= kMeasureLimit) {
            NSMutableParagraphStyle* style = [NSMutableParagraphStyle new];
            style.lineBreakMode = NSLineBreakByWordWrapping;
            const NSRect bounds = [text boundingRectWithSize:NSMakeSize(kPreviewMaxWidth - 2 * insetX, CGFLOAT_MAX)
                                                     options:NSStringDrawingUsesLineFragmentOrigin
                                                  attributes:@{NSFontAttributeName : font, NSParagraphStyleAttributeName : style}];
            width = std::min(kPreviewMaxWidth, std::ceil(bounds.size.width) + 2 * insetX + 2);
            height = std::min(maxHeight, std::ceil(bounds.size.height) + 2 * insetY + 2);
        }
        size = NSMakeSize(std::max<CGFloat>(width, 120), std::max<CGFloat>(height, 36));
        NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
        scroll.drawsBackground = NO;
        scroll.hasVerticalScroller = YES;
        scroll.autohidesScrollers = YES;
        scroll.scrollerStyle = NSScrollerStyleOverlay;
        NSTextView* textView = [[NSTextView alloc] initWithFrame:scroll.bounds];
        textView.editable = NO;
        textView.selectable = NO;
        textView.drawsBackground = NO;
        textView.textContainerInset = NSMakeSize(insetX, insetY);
        textView.textContainer.lineFragmentPadding = 0;
        textView.textContainer.widthTracksTextView = YES;
        textView.verticallyResizable = YES;
        textView.horizontallyResizable = NO;
        textView.autoresizingMask = NSViewWidthSizable;
        textView.font = font;
        textView.textColor = NSColor.labelColor;
        textView.string = text;
        scroll.documentView = textView;
        view = scroll;
    }

    // Beside the list, level with the selected row; on the other side if there is no room.
    const NSRect panel = _panel.frame;
    const NSRect rowRect = [_list rectOfRow:row];
    const CGFloat rowTop = NSMaxY(panel) - kHeader - NSMinY(rowRect);
    CGFloat x = NSMaxX(panel) + 8;
    if (x + size.width > NSMaxX(visible)) x = NSMinX(panel) - 8 - size.width;
    x = std::max(x, NSMinX(visible) + 4);
    const CGFloat y = std::clamp<CGFloat>(rowTop - size.height, NSMinY(visible) + 4, NSMaxY(visible) - size.height);

    _preview = makePanel(NSMakeRect(x, y, size.width, size.height), NSPanel.class);
    view.frame = NSMakeRect(0, 0, size.width, size.height);
    _preview.contentView = makeBackground(view, 12);
    [_preview orderFrontRegardless];
}

@end
