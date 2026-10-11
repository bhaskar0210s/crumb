// The global shortcut and the field that records it.

#import "app.h"

#import <Carbon/Carbon.h>

namespace {

EventHotKeyRef gHotKey = nullptr;
EventHandlerRef gHandler = nullptr;
void (^gAction)(void) = nil;

OSStatus onHotKey(EventHandlerCallRef, EventRef, void*) {
    if (gAction) gAction();
    return noErr;
}

NSString* keyName(UInt32 keyCode) {
    switch (keyCode) {
        case kVK_Return: return @"↩";
        case kVK_ANSI_KeypadEnter: return @"⌤";
        case kVK_Tab: return @"⇥";
        case kVK_Space: return @"Space";
        case kVK_Delete: return @"⌫";
        case kVK_ForwardDelete: return @"⌦";
        case kVK_Escape: return @"⎋";
        case kVK_LeftArrow: return @"←";
        case kVK_RightArrow: return @"→";
        case kVK_UpArrow: return @"↑";
        case kVK_DownArrow: return @"↓";
        case kVK_Home: return @"↖";
        case kVK_End: return @"↘";
        case kVK_PageUp: return @"⇞";
        case kVK_PageDown: return @"⇟";
        case kVK_F1: return @"F1";
        case kVK_F2: return @"F2";
        case kVK_F3: return @"F3";
        case kVK_F4: return @"F4";
        case kVK_F5: return @"F5";
        case kVK_F6: return @"F6";
        case kVK_F7: return @"F7";
        case kVK_F8: return @"F8";
        case kVK_F9: return @"F9";
        case kVK_F10: return @"F10";
        case kVK_F11: return @"F11";
        case kVK_F12: return @"F12";
        case kVK_F13: return @"F13";
        case kVK_F14: return @"F14";
        case kVK_F15: return @"F15";
        case kVK_F16: return @"F16";
        case kVK_F17: return @"F17";
        case kVK_F18: return @"F18";
        case kVK_F19: return @"F19";
        case kVK_F20: return @"F20";
        default: break;
    }
    // Everything else: ask the keyboard layout which character the key types.
    NSString* name = nil;
    TISInputSourceRef source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
    auto layout = source ? static_cast<CFDataRef>(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)) : nullptr;
    if (layout) {
        UInt32 deadKeys = 0;
        UniChar chars[4];
        UniCharCount length = 0;
        UCKeyTranslate(reinterpret_cast<const UCKeyboardLayout*>(CFDataGetBytePtr(layout)), static_cast<UInt16>(keyCode),
                       kUCKeyActionDisplay, 0, LMGetKbdType(), kUCKeyTranslateNoDeadKeysBit, &deadKeys, 4, &length, chars);
        if (length) name = [NSString stringWithCharacters:chars length:length].uppercaseString;
    }
    if (source) CFRelease(source);
    return name.length ? name : [NSString stringWithFormat:@"Key %u", keyCode];
}

bool isFunctionKey(UInt32 keyCode) {
    switch (keyCode) {
        case kVK_F1: case kVK_F2: case kVK_F3: case kVK_F4: case kVK_F5: case kVK_F6: case kVK_F7:
        case kVK_F8: case kVK_F9: case kVK_F10: case kVK_F11: case kVK_F12: case kVK_F13: case kVK_F14:
        case kVK_F15: case kVK_F16: case kVK_F17: case kVK_F18: case kVK_F19: case kVK_F20:
            return true;
        default:
            return false;
    }
}

NSString* modifierNames(UInt32 modifiers) {
    NSMutableString* s = [NSMutableString string];
    if (modifiers & controlKey) [s appendString:@"⌃"];
    if (modifiers & optionKey) [s appendString:@"⌥"];
    if (modifiers & shiftKey) [s appendString:@"⇧"];
    if (modifiers & cmdKey) [s appendString:@"⌘"];
    return s;
}

}  // namespace

void CRSetHotKeyAction(void (^action)(void)) {
    gAction = [action copy];
}

BOOL CRRegisterHotKey(UInt32 keyCode, UInt32 modifiers) {
    if (!gHandler) {
        const EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
        InstallEventHandler(GetApplicationEventTarget(), onHotKey, 1, &spec, nullptr, &gHandler);
    }
    CRUnregisterHotKey();
    const EventHotKeyID hotKeyID = {'crmb', 1};
    return RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &gHotKey) == noErr;
}

void CRUnregisterHotKey(void) {
    if (gHotKey) UnregisterEventHotKey(gHotKey);
    gHotKey = nullptr;
}

UInt32 CRCarbonModifiers(NSEventModifierFlags flags) {
    UInt32 modifiers = 0;
    if (flags & NSEventModifierFlagCommand) modifiers |= cmdKey;
    if (flags & NSEventModifierFlagShift) modifiers |= shiftKey;
    if (flags & NSEventModifierFlagOption) modifiers |= optionKey;
    if (flags & NSEventModifierFlagControl) modifiers |= controlKey;
    return modifiers;
}

NSString* CRKeyCharacter(NSEvent* event) {
    NSString* characters = event.charactersIgnoringModifiers.lowercaseString;
    if (characters.length == 1 && [characters characterAtIndex:0] < 0x80) return characters;
    // Non-Latin layouts: use the key's letter in the ASCII-capable layout, as menus do.
    return keyName(event.keyCode).lowercaseString;
}

NSString* CRShortcutName(UInt32 keyCode, UInt32 modifiers) {
    return [modifierNames(modifiers) stringByAppendingString:keyName(keyCode)];
}

@implementation CRShortcutField {
    UInt32 _live;  // modifiers held while recording
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    return YES;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    CRRenderIntoLayer(self, ^(NSRect bounds) {
        [self drawRect:bounds];
    });
}

- (void)setKeyCode:(UInt32)keyCode {
    _keyCode = keyCode;
    self.needsDisplay = YES;
}

- (void)setModifiers:(UInt32)modifiers {
    _modifiers = modifiers;
    self.needsDisplay = YES;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    const NSRect box = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:box xRadius:7 yRadius:7];
    [(_recording ? [NSColor.controlAccentColor colorWithAlphaComponent:0.14] : [NSColor.labelColor colorWithAlphaComponent:0.08])
        setFill];
    [path fill];
    if (_recording) {
        [NSColor.controlAccentColor setStroke];
        path.lineWidth = 1;
        [path stroke];
    }

    NSString* text;
    NSColor* color = NSColor.labelColor;
    if (_recording) {
        text = _live ? modifierNames(_live) : @"Type shortcut";
        color = NSColor.secondaryLabelColor;
    } else {
        text = CRShortcutName(_keyCode, _modifiers);
    }
    NSDictionary* attributes = @{
        NSFontAttributeName : [NSFont systemFontOfSize:13 weight:_recording ? NSFontWeightRegular : NSFontWeightMedium],
        NSForegroundColorAttributeName : color,
    };
    const NSSize size = [text sizeWithAttributes:attributes];
    [text drawAtPoint:NSMakePoint(NSMidX(self.bounds) - size.width / 2, NSMidY(self.bounds) - size.height / 2)
        withAttributes:attributes];
}

- (void)mouseDown:(NSEvent*)event {
    if (_recording) {
        [self stopRecording];
        return;
    }
    [self.window makeFirstResponder:self];
    _recording = YES;
    _live = 0;
    CRUnregisterHotKey();  // so pressing the current shortcut records it instead of opening Crumb
    self.needsDisplay = YES;
}

- (void)stopRecording {
    if (!_recording) return;
    _recording = NO;
    _live = 0;
    CRRegisterHotKey(_keyCode, _modifiers);
    self.needsDisplay = YES;
    [self handBack];
}

- (void)handBack {
    if (self.window.firstResponder == self) [self.window makeFirstResponder:self.returnResponder];
}

- (BOOL)resignFirstResponder {
    [self stopRecording];
    return YES;
}

- (void)flagsChanged:(NSEvent*)event {
    if (!_recording) return [super flagsChanged:event];
    _live = CRCarbonModifiers(event.modifierFlags);
    self.needsDisplay = YES;
}

- (BOOL)performKeyEquivalent:(NSEvent*)event {
    if (!_recording || self.window.firstResponder != self) return [super performKeyEquivalent:event];
    [self record:event];
    return YES;
}

- (void)keyDown:(NSEvent*)event {
    if (!_recording) return [super keyDown:event];
    [self record:event];
}

- (void)record:(NSEvent*)event {
    const UInt32 modifiers = CRCarbonModifiers(event.modifierFlags);
    const UInt32 keyCode = event.keyCode;
    if (modifiers == 0 && (keyCode == kVK_Escape || keyCode == kVK_Delete)) {
        [self stopRecording];
        return;
    }
    // A global shortcut must not take over ordinary typing or other apps' shortcuts: plain keys, ⌥ or ⇧⌥
    // combinations (they type characters like ç) and ⌘ with a single key (⌘C, ⌘W…) are refused.
    const UInt32 strong = modifiers & (cmdKey | controlKey | optionKey);
    const bool typing = !(modifiers & (cmdKey | controlKey));
    const bool appShortcut = modifiers == cmdKey;
    if (!isFunctionKey(keyCode) && (!strong || typing || appShortcut)) {
        NSBeep();
        return;
    }
    if (!CRRegisterHotKey(keyCode, modifiers)) {
        NSBeep();
        [self stopRecording];
        return;
    }
    _recording = NO;
    _live = 0;
    _keyCode = keyCode;
    _modifiers = modifiers;
    [NSUserDefaults.standardUserDefaults setInteger:keyCode forKey:CRHotKeyCodeKey];
    [NSUserDefaults.standardUserDefaults setInteger:modifiers forKey:CRHotKeyModifiersKey];
    self.needsDisplay = YES;
    [self handBack];
}

@end
