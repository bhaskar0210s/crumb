// The Settings window: one small pane, built when opened and freed when closed.

#import "app.h"

#import <ServiceManagement/ServiceManagement.h>

#include <algorithm>

namespace {

constexpr CGFloat kWindowWidth = 460;
constexpr CGFloat kMargin = 20;
constexpr CGFloat kRowHeight = 44;
constexpr CGFloat kHeadingHeight = 28;

NSTextField* label(NSString* text, CGFloat size, NSFontWeight weight, NSColor* color) {
    NSTextField* field = [NSTextField labelWithString:text];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = color;
    [field sizeToFit];
    return field;
}

NSColor* groupFill() {
    if (@available(macOS 14.0, *)) return NSColor.quaternarySystemFillColor;
    return [NSColor.labelColor colorWithAlphaComponent:0.04];
}

}  // namespace

@interface CRSettingsWindow : NSWindow
@end

@implementation CRSettingsWindow

- (BOOL)performKeyEquivalent:(NSEvent*)event {
    // Views first: the shortcut field records ⌘W or ⌘Q like any other shortcut.
    if ([super performKeyEquivalent:event]) return YES;
    const NSEventModifierFlags flags = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift |
                                                              NSEventModifierFlagOption | NSEventModifierFlagControl);
    NSString* key = CRKeyCharacter(event);
    if (flags == NSEventModifierFlagCommand && [key isEqualToString:@"w"]) {
        [self performClose:nil];
        return YES;
    }
    if (flags == NSEventModifierFlagCommand && [key isEqualToString:@"q"]) {
        [NSApp terminate:nil];
        return YES;
    }
    return CRHandleEditingKey(event);
}

@end

@interface CRSettingsView : NSView
@end

@implementation CRSettingsView

- (BOOL)isFlipped {
    return YES;
}

@end

// A rounded group of rows with hairlines between them, like System Settings.
@interface CRGroupView : NSView
@property(nonatomic) NSInteger rows;
@end

@implementation CRGroupView

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    [groupFill() setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:10 yRadius:10] fill];
    [NSColor.separatorColor setFill];
    for (NSInteger i = 1; i < self.rows; ++i) NSRectFill(NSMakeRect(12, i * kRowHeight, self.bounds.size.width - 24, 1));
}

@end

@implementation CRSettings {
    CRUpdater* _updater;
    NSWindow* _window;
    CRShortcutField* _shortcut;
    NSSwitch* _login;
    NSSwitch* _updates;
    NSTextField* _size;
    NSStepper* _stepper;
    NSTextField* _status;
    NSButton* _checkButton;
}

- (instancetype)initWithUpdater:(CRUpdater*)updater {
    if ((self = [super init])) _updater = updater;
    return self;
}

- (void)show {
    if (!_window) [self build];
    [self refresh];
    if (@available(macOS 14.0, *))
        [NSApp activate];
    else
        [NSApp activateIgnoringOtherApps:YES];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:nil];  // no field starts out focused
}

- (void)build {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    CRSettingsView* view = [[CRSettingsView alloc] initWithFrame:NSZeroRect];
    const CGFloat groupWidth = kWindowWidth - 2 * kMargin;
    CGFloat y = 14;

    auto heading = [&](NSString* text) {
        NSTextField* field = label(text, 13, NSFontWeightSemibold, NSColor.labelColor);
        field.frame = NSMakeRect(kMargin + 4, y + 4, field.frame.size.width, field.frame.size.height);
        [view addSubview:field];
        y += kHeadingHeight;
    };
    auto group = [&](NSInteger rows) {
        CRGroupView* box = [[CRGroupView alloc] initWithFrame:NSMakeRect(kMargin, y, groupWidth, rows * kRowHeight)];
        box.rows = rows;
        [view addSubview:box];
        y += rows * kRowHeight;
        return box;
    };
    auto rowLabel = [&](CRGroupView* box, NSInteger row, NSString* text) {
        NSTextField* field = label(text, 13, NSFontWeightRegular, NSColor.labelColor);
        const NSSize size = field.frame.size;
        field.frame = NSMakeRect(14, row * kRowHeight + std::round((kRowHeight - size.height) / 2), size.width, size.height);
        [box addSubview:field];
    };
    auto place = [&](CRGroupView* box, NSInteger row, NSView* control, NSSize size) {
        control.frame = NSMakeRect(box.bounds.size.width - 14 - size.width,
                                   row * kRowHeight + std::round((kRowHeight - size.height) / 2), size.width, size.height);
        [box addSubview:control];
    };

    heading(@"General");
    const NSInteger generalRows = _updater.available ? 3 : 2;
    CRGroupView* general = group(generalRows);
    rowLabel(general, 0, @"Open Crumb");
    _shortcut = [[CRShortcutField alloc] initWithFrame:NSZeroRect];
    _shortcut.keyCode = static_cast<UInt32>([defaults integerForKey:CRHotKeyCodeKey]);
    _shortcut.modifiers = static_cast<UInt32>([defaults integerForKey:CRHotKeyModifiersKey]);
    place(general, 0, _shortcut, NSMakeSize(112, 26));

    rowLabel(general, 1, @"Launch at login");
    _login = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    _login.controlSize = NSControlSizeSmall;
    _login.target = self;
    _login.action = @selector(toggleLogin:);
    [_login sizeToFit];
    place(general, 1, _login, _login.frame.size);

    if (_updater.available) {
        rowLabel(general, 2, @"Check for updates automatically");
        _updates = [[NSSwitch alloc] initWithFrame:NSZeroRect];
        _updates.controlSize = NSControlSizeSmall;
        _updates.target = self;
        _updates.action = @selector(toggleUpdates:);
        [_updates sizeToFit];
        place(general, 2, _updates, _updates.frame.size);
    }

    NSTextField* hint = label(@"In the list: ⌘1–⌘9 copy an entry, ⌥⌫ deletes one, Esc closes.", 11, NSFontWeightRegular,
                              NSColor.secondaryLabelColor);
    hint.frame = NSMakeRect(kMargin + 4, y + 6, groupWidth - 8, hint.frame.size.height);
    [view addSubview:hint];
    y += 30;

    heading(@"Storage");
    CRGroupView* storage = group(1);
    rowLabel(storage, 0, @"History size");
    _stepper = [[NSStepper alloc] initWithFrame:NSZeroRect];
    _stepper.minValue = 1;
    _stepper.maxValue = 1000;
    _stepper.increment = 10;
    _stepper.valueWraps = NO;
    _stepper.target = self;
    _stepper.action = @selector(stepSize:);
    [_stepper sizeToFit];
    place(storage, 0, _stepper, _stepper.frame.size);

    NSNumberFormatter* formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterNoStyle;
    formatter.minimum = @1;
    formatter.maximum = @1000;
    formatter.allowsFloats = NO;
    _size = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _size.formatter = formatter;
    _size.alignment = NSTextAlignmentRight;
    _size.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    _size.target = self;
    _size.action = @selector(typeSize:);
    _size.cell.sendsActionOnEndEditing = YES;
    _size.bezelStyle = NSTextFieldRoundedBezel;
    const NSRect stepper = _stepper.frame;
    _size.frame = NSMakeRect(NSMinX(stepper) - 4 - 64, std::round((kRowHeight - 24) / 2), 64, 24);
    [storage addSubview:_size];

    y += 18;
    NSString* version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSTextField* about = label([NSString stringWithFormat:@"Crumb %@", version], 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    about.frame = NSMakeRect(kMargin + 4, y + 6, about.frame.size.width, about.frame.size.height);
    [view addSubview:about];
    if (_updater.available) {
        _checkButton = [NSButton buttonWithTitle:@"Check for Updates" target:self action:@selector(checkNow:)];
        _checkButton.controlSize = NSControlSizeSmall;
        _checkButton.font = [NSFont systemFontOfSize:11];
        [_checkButton sizeToFit];
        const NSSize size = _checkButton.frame.size;
        _checkButton.frame = NSMakeRect(kWindowWidth - kMargin - size.width, y + 2, size.width, size.height);
        [view addSubview:_checkButton];
        _status = label(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
        _status.frame = NSMakeRect(NSMaxX(about.frame) + 10, y + 6, NSMinX(_checkButton.frame) - NSMaxX(about.frame) - 20,
                                   about.frame.size.height);
        _status.lineBreakMode = NSLineBreakByTruncatingTail;
        [view addSubview:_status];
    }
    y += 36;

    view.frame = NSMakeRect(0, 0, kWindowWidth, y);
    _window = [[CRSettingsWindow alloc] initWithContentRect:view.frame
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                            backing:NSBackingStoreBuffered
                                              defer:YES];
    _window.title = @"Crumb Settings";
    _window.contentView = view;
    _window.releasedWhenClosed = NO;
    _window.animationBehavior = NSWindowAnimationBehaviorNone;
    _window.delegate = self;
    [_window center];
}

- (void)refresh {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    _login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    _updates.state = [defaults boolForKey:CRCheckForUpdatesKey] ? NSControlStateValueOn : NSControlStateValueOff;
    const NSInteger size = [defaults integerForKey:CRHistorySizeKey];
    _size.integerValue = size;
    _stepper.integerValue = size;
}

// Leaving the window ends a shortcut recording (restoring the shortcut) and commits a typed history size.
- (void)windowDidResignKey:(NSNotification*)notification {
    [_window makeFirstResponder:nil];
}

- (void)windowWillClose:(NSNotification*)notification {
    [_window makeFirstResponder:nil];
    // Settings are rarely open: let the whole window go and give the focus back.
    _window.delegate = nil;
    _window = nil;
    _shortcut = nil;
    _login = nil;
    _updates = nil;
    _size = nil;
    _stepper = nil;
    _status = nil;
    _checkButton = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp hide:nil];
    });
}

- (void)toggleLogin:(NSSwitch*)sender {
    NSError* error = nil;
    SMAppService* service = SMAppService.mainAppService;
    const BOOL on = sender.state == NSControlStateValueOn;
    const BOOL ok = on ? [service registerAndReturnError:&error] : [service unregisterAndReturnError:&error];
    if (!ok && service.status == SMAppServiceStatusRequiresApproval) [SMAppService openSystemSettingsLoginItems];
    [self refresh];
}

- (void)toggleUpdates:(NSSwitch*)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn forKey:CRCheckForUpdatesKey];
}

- (void)applySize:(NSInteger)size {
    size = std::clamp<NSInteger>(size, 1, 1000);
    [NSUserDefaults.standardUserDefaults setInteger:size forKey:CRHistorySizeKey];
    _size.integerValue = size;
    _stepper.integerValue = size;
    if (self.onLimit) self.onLimit(size);
}

- (void)stepSize:(NSStepper*)sender {
    [self applySize:sender.integerValue];
}

- (void)typeSize:(NSTextField*)sender {
    [self applySize:sender.integerValue];
}

- (void)checkNow:(id)sender {
    _checkButton.enabled = NO;
    _status.stringValue = @"Checking…";
    __weak CRSettings* weakSelf = self;
    [_updater checkNow:^(NSString* status) {
        CRSettings* settings = weakSelf;
        if (!settings) return;
        settings->_status.stringValue = status;
        settings->_checkButton.enabled = YES;
    }];
}

@end
