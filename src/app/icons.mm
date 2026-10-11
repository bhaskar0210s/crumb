// Crumb's few icons, drawn with paths (system symbol images would load the whole symbol catalog into memory
// for six glyphs), and the editing shortcuts that a menu bar would otherwise provide.

#import "app.h"

#include <cmath>

namespace {

NSBezierPath* stroked(CGFloat width) {
    NSBezierPath* path = [NSBezierPath bezierPath];
    path.lineWidth = width;
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;
    return path;
}

// A page with a folded corner; (x, y) is its top-left corner in a flipped view.
void page(NSBezierPath* path, CGFloat x, CGFloat y, CGFloat w, CGFloat h, CGFloat fold) {
    [path moveToPoint:NSMakePoint(x, y)];
    [path lineToPoint:NSMakePoint(x + w - fold, y)];
    [path lineToPoint:NSMakePoint(x + w, y + fold)];
    [path lineToPoint:NSMakePoint(x + w, y + h)];
    [path lineToPoint:NSMakePoint(x, y + h)];
    [path closePath];
    [path moveToPoint:NSMakePoint(x + w - fold, y)];
    [path lineToPoint:NSMakePoint(x + w - fold, y + fold)];
    [path lineToPoint:NSMakePoint(x + w, y + fold)];
}

}  // namespace

void CRDrawIcon(CRIcon icon, NSRect box, NSColor* color) {
    const CGFloat s = std::min(box.size.width, box.size.height);
    const CGFloat x0 = NSMinX(box) + (box.size.width - s) / 2, y0 = NSMinY(box) + (box.size.height - s) / 2;
    auto P = [&](CGFloat x, CGFloat y) { return NSMakePoint(x0 + x * s, y0 + y * s); };
    const CGFloat line = std::max<CGFloat>(1.25, s * 0.095);
    NSBezierPath* path = stroked(line);
    [color setStroke];

    switch (icon) {
        case CRIconSearch: {
            [path appendBezierPathWithOvalInRect:NSMakeRect(x0 + 0.14 * s, y0 + 0.14 * s, 0.56 * s, 0.56 * s)];
            [path moveToPoint:P(0.63, 0.63)];
            [path lineToPoint:P(0.88, 0.88)];
            break;
        }
        case CRIconPower: {
            // An open ring with a bar through the gap (the views are flipped: angles run clockwise).
            [path appendBezierPathWithArcWithCenter:P(0.5, 0.54) radius:0.34 * s startAngle:-58 endAngle:238 clockwise:NO];
            [path moveToPoint:P(0.5, 0.1)];
            [path lineToPoint:P(0.5, 0.5)];
            break;
        }
        case CRIconGear: {
            // One outline around eight teeth, and the hole in the middle.
            const NSPoint c = P(0.5, 0.5);
            const CGFloat outer = 0.45 * s, inner = 0.33 * s;
            auto at = [&](CGFloat degrees, CGFloat radius) {
                const CGFloat a = degrees * M_PI / 180;
                return NSMakePoint(c.x + radius * std::cos(a), c.y + radius * std::sin(a));
            };
            for (int i = 0; i < 8; ++i) {
                const CGFloat a = i * 45;
                if (i == 0)
                    [path moveToPoint:at(a - 15, inner)];
                else
                    [path appendBezierPathWithArcWithCenter:c radius:inner startAngle:a - 30 endAngle:a - 15 clockwise:NO];
                [path lineToPoint:at(a - 8, outer)];
                [path appendBezierPathWithArcWithCenter:c radius:outer startAngle:a - 8 endAngle:a + 8 clockwise:NO];
                [path lineToPoint:at(a + 15, inner)];
            }
            [path appendBezierPathWithArcWithCenter:c radius:inner startAngle:315 + 15 endAngle:360 - 15 clockwise:NO];
            [path closePath];
            [path appendBezierPathWithOvalInRect:NSMakeRect(c.x - 0.13 * s, c.y - 0.13 * s, 0.26 * s, 0.26 * s)];
            break;
        }
        case CRIconDocument: {
            page(path, x0 + 0.2 * s, y0 + 0.08 * s, 0.6 * s, 0.84 * s, 0.22 * s);
            break;
        }
        case CRIconDocuments: {
            page(path, x0 + 0.14 * s, y0 + 0.2 * s, 0.56 * s, 0.74 * s, 0.2 * s);
            // The page behind peeks out above and to the right.
            [path moveToPoint:P(0.3, 0.2)];
            [path lineToPoint:P(0.3, 0.06)];
            [path lineToPoint:P(0.86, 0.06)];
            [path lineToPoint:P(0.86, 0.8)];
            [path lineToPoint:P(0.7, 0.8)];
            break;
        }
        case CRIconFolder: {
            [path moveToPoint:P(0.08, 0.22)];
            [path lineToPoint:P(0.38, 0.22)];
            [path lineToPoint:P(0.47, 0.32)];
            [path lineToPoint:P(0.92, 0.32)];
            [path lineToPoint:P(0.92, 0.82)];
            [path lineToPoint:P(0.08, 0.82)];
            [path closePath];
            break;
        }
    }
    [path stroke];
}

BOOL CRHandleEditingKey(NSEvent* event) {
    const NSEventModifierFlags flags = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift |
                                                              NSEventModifierFlagOption | NSEventModifierFlagControl);
    NSString* key = CRKeyCharacter(event);
    SEL action = nullptr;
    if (flags == NSEventModifierFlagCommand) {
        if ([key isEqualToString:@"x"]) action = @selector(cut:);
        if ([key isEqualToString:@"c"]) action = @selector(copy:);
        if ([key isEqualToString:@"v"]) action = @selector(paste:);
        if ([key isEqualToString:@"a"]) action = @selector(selectAll:);
        if ([key isEqualToString:@"z"]) action = NSSelectorFromString(@"undo:");
    } else if (flags == (NSEventModifierFlagCommand | NSEventModifierFlagShift) && [key isEqualToString:@"z"]) {
        action = NSSelectorFromString(@"redo:");
    }
    return action && [NSApp sendAction:action to:nil from:nil];
}
