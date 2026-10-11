// The settings page, shown inside the list's own panel (the gear in its footer). Everything is drawn by Crumb
// itself: a separate window and the standard controls would cost several megabytes of memory for four options.

#import "app.h"

#import <ServiceManagement/ServiceManagement.h>

#include <algorithm>

namespace {

constexpr CGFloat kRowHeight = 40;
constexpr CGFloat kSide = 16;

NSDictionary* textAttributes(CGFloat size, NSFontWeight weight, NSColor* color) {
    return @{NSFontAttributeName : [NSFont systemFontOfSize:size weight:weight], NSForegroundColorAttributeName : color};
}

void drawText(NSString* text, CGFloat x, CGFloat midY, NSDictionary* attributes) {
    const NSSize size = [text sizeWithAttributes:attributes];
    [text drawAtPoint:NSMakePoint(x, std::round(midY - size.height / 2)) withAttributes:attributes];
}

}  // namespace

#pragma mark - Controls

// An on/off switch. Flips the moment it is clicked.
@interface CRToggle : CRView
@property(nonatomic) BOOL on;
@property(nonatomic, copy) void (^onChange)(BOOL on);
@end

@implementation CRToggle

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    return YES;
}

- (void)setOn:(BOOL)on {
    _on = on;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    const NSRect track = self.bounds;
    const CGFloat radius = track.size.height / 2;
    [(self.on ? NSColor.controlAccentColor : [NSColor.labelColor colorWithAlphaComponent:0.16]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:radius yRadius:radius] fill];
    const CGFloat knob = track.size.height - 4;
    const NSRect circle = NSMakeRect(self.on ? NSMaxX(track) - knob - 2 : 2, 2, knob, knob);
    [[NSColor.blackColor colorWithAlphaComponent:0.12] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSOffsetRect(circle, 0, 0.5)] fill];
    [NSColor.whiteColor setFill];
    [[NSBezierPath bezierPathWithOvalInRect:circle] fill];
}

- (void)mouseDown:(NSEvent*)event {
    self.on = !self.on;
    if (self.onChange) self.onChange(self.on);
}

@end

// − value + : steps of ten.
@interface CRStepper : CRView
@property(nonatomic) NSInteger value;
@property(nonatomic) NSInteger minimum, maximum, step;
@property(nonatomic, copy) void (^onChange)(NSInteger value);
@end

@implementation CRStepper

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    return YES;
}

- (void)setValue:(NSInteger)value {
    _value = value;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    const NSRect box = self.bounds;
    [[NSColor.labelColor colorWithAlphaComponent:0.08] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:box xRadius:7 yRadius:7] fill];
    const CGFloat third = box.size.width / 3;
    NSDictionary* sign = textAttributes(15, NSFontWeightMedium, NSColor.secondaryLabelColor);
    NSDictionary* number = @{
        NSFontAttributeName : [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName : NSColor.labelColor,
    };
    auto centered = [&](NSString* text, CGFloat midX, NSDictionary* attributes) {
        const NSSize size = [text sizeWithAttributes:attributes];
        [text drawAtPoint:NSMakePoint(std::round(midX - size.width / 2), std::round(NSMidY(box) - size.height / 2))
           withAttributes:attributes];
    };
    centered(@"−", third / 2, sign);
    centered([NSString stringWithFormat:@"%ld", (long)self.value], NSMidX(box), number);
    centered(@"+", box.size.width - third / 2, sign);
}

- (void)mouseDown:(NSEvent*)event {
    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    const CGFloat third = self.bounds.size.width / 3;
    NSInteger value = self.value;
    if (point.x < third)
        value -= self.step;
    else if (point.x > 2 * third)
        value += self.step;
    else
        return;
    value = std::clamp(value, self.minimum, self.maximum);
    if (value == self.value) return;
    self.value = value;
    if (self.onChange) self.onChange(value);
}

@end

#pragma mark - Page

@implementation CRSettingsPage {
    CRUpdater* _updater;
    CRShortcutField* _shortcut;
    CRToggle* _login;
    CRToggle* _updates;
    CRStepper* _size;
    NSView* _check;
    NSString* _status;
    NSArray<NSString*>* _labels;
}

- (instancetype)initWithUpdater:(CRUpdater*)updater checkButton:(NSView*)checkButton {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _updater = updater;
        NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;

        _shortcut = [[CRShortcutField alloc] initWithFrame:NSZeroRect];
        _shortcut.keyCode = static_cast<UInt32>([defaults integerForKey:CRHotKeyCodeKey]);
        _shortcut.modifiers = static_cast<UInt32>([defaults integerForKey:CRHotKeyModifiersKey]);
        [self addSubview:_shortcut];

        __weak CRSettingsPage* weakSelf = self;
        _login = [[CRToggle alloc] initWithFrame:NSZeroRect];
        _login.onChange = ^(BOOL on) {
            [weakSelf setLaunchAtLogin:on];
        };
        [self addSubview:_login];

        NSMutableArray* labels = [NSMutableArray arrayWithObjects:@"Open Crumb", @"Launch at login", nil];
        if (_updater.available) {
            [labels addObject:@"Check for updates automatically"];
            _updates = [[CRToggle alloc] initWithFrame:NSZeroRect];
            _updates.onChange = ^(BOOL on) {
                [NSUserDefaults.standardUserDefaults setBool:on forKey:CRCheckForUpdatesKey];
            };
            [self addSubview:_updates];
        }
        [labels addObject:@"History size"];
        _labels = labels;

        _size = [[CRStepper alloc] initWithFrame:NSZeroRect];
        _size.minimum = 10;
        _size.maximum = 1000;
        _size.step = 10;
        _size.onChange = ^(NSInteger value) {
            CRSettingsPage* page = weakSelf;
            [NSUserDefaults.standardUserDefaults setInteger:value forKey:CRHistorySizeKey];
            if (page.onLimit) page.onLimit(value);
        };
        [self addSubview:_size];

        _check = checkButton;
        if (_check) [self addSubview:_check];
        [self refresh];
        [self layoutControls];
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (CGFloat)preferredHeight {
    return 8 + _labels.count * kRowHeight + 30 + 36;
}

- (BOOL)recording {
    return _shortcut.recording;
}

- (void)refresh {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    _login.on = SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    _updates.on = [defaults boolForKey:CRCheckForUpdatesKey];
    _size.value = [defaults integerForKey:CRHistorySizeKey];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self layoutControls];
}

- (void)layoutControls {
    const CGFloat width = self.bounds.size.width;
    auto row = [&](NSInteger index, NSView* control, NSSize size) {
        control.frame = NSMakeRect(width - kSide - size.width, 8 + index * kRowHeight + std::round((kRowHeight - size.height) / 2),
                                   size.width, size.height);
    };
    NSInteger index = 0;
    row(index++, _shortcut, NSMakeSize(104, 26));
    row(index++, _login, NSMakeSize(34, 20));
    if (_updates) row(index++, _updates, NSMakeSize(34, 20));
    row(index++, _size, NSMakeSize(104, 26));
    if (_check) {
        const CGFloat y = 8 + _labels.count * kRowHeight + 30;
        _check.frame = NSMakeRect(width - kSide + 10 - 140, y + 4, 140, 28);
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    const CGFloat width = self.bounds.size.width;
    NSDictionary* label = textAttributes(13, NSFontWeightRegular, NSColor.labelColor);
    for (NSUInteger i = 0; i < _labels.count; ++i) {
        const CGFloat top = 8 + i * kRowHeight;
        drawText(_labels[i], kSide, top + kRowHeight / 2, label);
        if (i + 1 < _labels.count) {
            [NSColor.separatorColor setFill];
            NSRectFill(NSMakeRect(kSide, top + kRowHeight - 0.5, width - 2 * kSide, 1));
        }
    }
    const CGFloat hintTop = 8 + _labels.count * kRowHeight;
    drawText(@"In the list: ⌘1–⌘9 copy an entry, ⌥⌫ deletes one, Esc closes.", kSide, hintTop + 15,
             textAttributes(11, NSFontWeightRegular, NSColor.secondaryLabelColor));
    NSString* version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSString* line = [NSString stringWithFormat:@"Crumb %@", version];
    if (_status.length) line = [line stringByAppendingFormat:@"  ·  %@", _status];
    drawText(line, kSide, hintTop + 30 + 18, textAttributes(11, NSFontWeightRegular, NSColor.secondaryLabelColor));
}

- (void)setLaunchAtLogin:(BOOL)on {
    NSError* error = nil;
    SMAppService* service = SMAppService.mainAppService;
    const BOOL ok = on ? [service registerAndReturnError:&error] : [service unregisterAndReturnError:&error];
    if (!ok && service.status == SMAppServiceStatusRequiresApproval) [SMAppService openSystemSettingsLoginItems];
    [self refresh];
}

- (void)checkForUpdates {
    if (!_updater.available) return;
    _status = @"Checking…";
    self.needsDisplay = YES;
    __weak CRSettingsPage* weakSelf = self;
    [_updater checkNow:^(NSString* status) {
        CRSettingsPage* page = weakSelf;
        if (!page) return;
        page->_status = status;
        page.needsDisplay = YES;
    }];
}

@end
