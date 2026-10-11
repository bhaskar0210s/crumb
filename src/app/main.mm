// Crumb: a tiny clipboard history for macOS. Press ⇧⌘C anywhere to see everything you copied.

#import "app.h"

#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>
#import <ServiceManagement/ServiceManagement.h>

#include <algorithm>
#include <memory>

NSString* const CRHotKeyCodeKey = @"hotKeyCode";
NSString* const CRHotKeyModifiersKey = @"hotKeyModifiers";
NSString* const CRHistorySizeKey = @"historySize";
NSString* const CRCheckForUpdatesKey = @"checkForUpdates";

namespace {

NSString* const kLaunchedBeforeKey = @"launchedBefore";

NSString* dataDirectory() {
    NSString* custom = NSProcessInfo.processInfo.environment[@"CRUMB_DATA"];
    if (custom.length) return custom;
    NSString* support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [support stringByAppendingPathComponent:@"Crumb"];
}

bool installedInApplications() {
    NSString* path = NSBundle.mainBundle.bundlePath;
    return [path hasPrefix:@"/Applications/"] ||
           [path hasPrefix:[NSHomeDirectory() stringByAppendingPathComponent:@"Applications/"]];
}

}  // namespace

@interface CRAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation CRAppDelegate {
    std::unique_ptr<crumb::Store> _store;
    CRClipboard* _clipboard;
    CRPopup* _popup;
    CRUpdater* _updater;
    CRSettings* _settings;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{
        CRHotKeyCodeKey : @(kVK_ANSI_C),
        CRHotKeyModifiersKey : @(cmdKey | shiftKey),
        CRHistorySizeKey : @100,
        CRCheckForUpdatesKey : @YES,
    }];

    _store = std::make_unique<crumb::Store>(dataDirectory().fileSystemRepresentation);
    _store->setLimit(static_cast<size_t>(std::max<NSInteger>(1, [defaults integerForKey:CRHistorySizeKey])));
    _store->load();

    _clipboard = [[CRClipboard alloc] initWithStore:_store.get()];
    _popup = [[CRPopup alloc] initWithStore:_store.get() clipboard:_clipboard];
    _updater = [[CRUpdater alloc] initWithPopup:_popup];

    __weak CRAppDelegate* weakSelf = self;
    __weak CRPopup* weakPopup = _popup;
    _clipboard.onChange = ^{
        [weakPopup reload];
    };
    _popup.onSettings = ^{
        [weakSelf showSettings];
    };
    CRSetHotKeyAction(^{
        [weakPopup toggle];
    });
    CRRegisterHotKey(static_cast<UInt32>([defaults integerForKey:CRHotKeyCodeKey]),
                     static_cast<UInt32>([defaults integerForKey:CRHotKeyModifiersKey]));

    [_clipboard start];
    [_updater start];

    if (![defaults boolForKey:kLaunchedBeforeKey]) {
        [defaults setBool:YES forKey:kLaunchedBeforeKey];
        if (installedInApplications()) [SMAppService.mainAppService registerAndReturnError:nil];
        [self showSettings];  // there is no menu bar icon, so say hello once
    }
    // Build the list window ahead of time so that even the first open is instant.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        [weakPopup prepare];
    });
}

// Quitting waits (up to ten seconds) for copies that are still being saved.
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
    if (!_clipboard.busy) return NSTerminateNow;
    [self finishSaving:CACurrentMediaTime()];
    return NSTerminateLater;
}

- (void)finishSaving:(CFTimeInterval)since {
    if (!_clipboard.busy || CACurrentMediaTime() - since > 10) {
        [NSApp replyToApplicationShouldTerminate:YES];
        return;
    }
    __weak CRAppDelegate* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 20), dispatch_get_main_queue(), ^{
        [weakSelf finishSaving:since];
    });
}

// Opening Crumb again (from Finder or Spotlight) shows its settings.
- (BOOL)applicationShouldHandleReopen:(NSApplication*)sender hasVisibleWindows:(BOOL)flag {
    [self showSettings];
    return NO;
}

- (void)showSettings {
    if (!_settings) {
        _settings = [[CRSettings alloc] initWithUpdater:_updater];
        crumb::Store* store = _store.get();
        __weak CRPopup* weakPopup = _popup;
        _settings.onLimit = ^(NSInteger limit) {
            store->setLimit(static_cast<size_t>(limit));
            [weakPopup reload];
        };
    }
    [_settings show];
}

@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSApplication* app = NSApplication.sharedApplication;
        CRAppDelegate* delegate = [CRAppDelegate new];
        app.delegate = delegate;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        [app run];
    }
    return 0;
}
