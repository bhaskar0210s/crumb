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

// The history list that opens at the pointer.
@interface CRPopup : NSObject <NSWindowDelegate, NSTextFieldDelegate>
- (instancetype)initWithStore:(crumb::Store*)store clipboard:(CRClipboard*)clipboard;
@property(nonatomic, copy, nullable) void (^onSettings)(void);
@property(nonatomic, readonly) BOOL isOpen;
- (void)prepare;
- (void)toggle;
- (void)close;
- (void)reload;
@end

@interface CRUpdater : NSObject
- (instancetype)initWithPopup:(CRPopup*)popup;
@property(nonatomic, readonly) BOOL available;  // false when the build doesn't know its repository
- (void)start;
- (void)checkNow:(void (^)(NSString* status))report;
@end

@interface CRSettings : NSObject <NSWindowDelegate>
- (instancetype)initWithUpdater:(CRUpdater*)updater;
@property(nonatomic, copy, nullable) void (^onLimit)(NSInteger limit);
- (void)show;
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
@end

NS_ASSUME_NONNULL_END
