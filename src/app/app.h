// Declarations shared by the AppKit side of Crumb.

#pragma once

#import <AppKit/AppKit.h>

#include "../core/store.hpp"

NS_ASSUME_NONNULL_BEGIN

// User defaults
extern NSString* const CRHotKeyCodeKey;
extern NSString* const CRHotKeyModifiersKey;
extern NSString* const CRHistorySizeKey;
extern NSString* const CRCheckForUpdatesKey;

// Renders a view's drawing on the CPU into an 8-bit image used as its layer's contents. The system's own
// drawing path moves larger views onto the GPU, which loads a couple of megabytes of shaders for good.
void CRRenderIntoLayer(NSView* view, void (^draw)(NSRect bounds));

// A flipped view drawn through CRRenderIntoLayer: subclasses just implement drawRect:.
@interface CRView : NSView
@end

// Watches the general pasteboard and puts entries back on it.
@interface CRClipboard : NSObject
- (instancetype)initWithStore:(crumb::Store*)store;
@property(nonatomic, copy, nullable) void (^onChange)(void);
- (void)start;
- (void)poll;
// Looks for a new copy right away, without waiting for it to settle.
- (void)pollNow;
// Puts an entry back on the pasteboard and moves it to the top of the history.
- (BOOL)copyItemAtIndex:(size_t)index;
- (void)clearHistory;
@property(nonatomic, readonly) BOOL busy;  // copies are still being saved
@end

@class CRUpdater;

// The history list that opens at the pointer. Its gear turns it into the settings page.
@interface CRPopup : NSObject <NSWindowDelegate>
- (instancetype)initWithStore:(crumb::Store*)store clipboard:(CRClipboard*)clipboard;
@property(nonatomic, weak, nullable) CRUpdater* updater;
@property(nonatomic, copy, nullable) void (^onLimit)(NSInteger limit);
@property(nonatomic, readonly) BOOL isOpen;
- (void)toggle;
- (void)showSettings;  // the settings page, in the middle of the screen
- (void)close;
- (void)reload;
@end

@interface CRUpdater : NSObject
- (instancetype)initWithPopup:(CRPopup*)popup;
@property(nonatomic, readonly) BOOL available;  // false when the build can't verify updates
- (void)start;
- (void)checkNow:(void (^)(NSString* status))report;
@end

// Shortcut, launch at login, automatic updates and history size, drawn inside the list's panel.
@interface CRSettingsPage : CRView
- (instancetype)initWithUpdater:(nullable CRUpdater*)updater checkButton:(nullable NSView*)checkButton;
@property(nonatomic, copy, nullable) void (^onLimit)(NSInteger limit);
@property(nonatomic, readonly) CGFloat preferredHeight;
@property(nonatomic, readonly) BOOL recording;  // the shortcut field is waiting for keys
- (void)refresh;
- (void)checkForUpdates;
@end

// The global shortcut, a Carbon hot key: it needs no special permission.
BOOL CRRegisterHotKey(UInt32 keyCode, UInt32 modifiers);
void CRUnregisterHotKey(void);
void CRSetHotKeyAction(void (^action)(void));
UInt32 CRCarbonModifiers(NSEventModifierFlags flags);
NSString* CRShortcutName(UInt32 keyCode, UInt32 modifiers);
// The key an event's shortcut refers to, such as @"c" for ⌘C, also on non-Latin keyboard layouts.
NSString* CRKeyCharacter(NSEvent* event);

typedef NS_ENUM(NSInteger, CRIcon) { CRIconSearch, CRIconGear, CRIconPower, CRIconDocument, CRIconDocuments, CRIconFolder };

// Draws one of Crumb's icons into a square in a flipped view.
void CRDrawIcon(CRIcon icon, NSRect box, NSColor* color);

// Cut, copy, paste, select all, undo and redo for text fields. Crumb has no menu bar, so its windows route
// these shortcuts themselves.
BOOL CRHandleEditingKey(NSEvent* event);

// A field that records a new shortcut when clicked.
@interface CRShortcutField : NSControl
@property(nonatomic) UInt32 keyCode;
@property(nonatomic) UInt32 modifiers;
@property(nonatomic, readonly) BOOL recording;
@property(nonatomic, weak, nullable) NSResponder* returnResponder;  // gets the keyboard back after recording
@end

NS_ASSUME_NONNULL_END
