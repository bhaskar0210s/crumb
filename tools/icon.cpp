// Renders Crumb's app icon into an .iconset directory (see `make icon`): a stack of three cards, the history,
// with a crumb on top, on a graphite tile.

#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

#include <cmath>
#include <cstdio>
#include <string>

namespace {

CGColorRef color(int rgb, double alpha = 1) {
    return CGColorCreateSRGB(((rgb >> 16) & 255) / 255.0, ((rgb >> 8) & 255) / 255.0, (rgb & 255) / 255.0, alpha);
}

// A rectangle with continuous ("squircle") corners, the shape of macOS app icons.
CGPathRef squircle(CGRect r, double radius) {
    const double x = r.origin.x, y = r.origin.y, w = r.size.width, h = r.size.height, k = radius;
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, nullptr, x + 1.52866483 * k, y);
    auto corner = [&](double cx, double cy, double dx1, double dy1, double dx2, double dy2) {
        // From the end of one edge to the start of the next, around the corner (cx, cy). (dx1, dy1) points
        // back along the incoming edge, (dx2, dy2) along the outgoing one.
        auto pt = [&](double a, double b) { return CGPointMake(cx + dx1 * a * k + dx2 * b * k, cy + dy1 * a * k + dy2 * b * k); };
        const CGPoint start = pt(1.52866483, 0);
        CGPathAddLineToPoint(p, nullptr, start.x, start.y);
        CGPoint c1 = pt(1.08849296, 0), c2 = pt(0.86840694, 0), e = pt(0.63149399, 0.07491100);
        CGPathAddCurveToPoint(p, nullptr, c1.x, c1.y, c2.x, c2.y, e.x, e.y);
        c1 = pt(0.37282383, 0.16906599), c2 = pt(0.16906599, 0.37282383), e = pt(0.07491100, 0.63149399);
        CGPathAddCurveToPoint(p, nullptr, c1.x, c1.y, c2.x, c2.y, e.x, e.y);
        c1 = pt(0, 0.86840694), c2 = pt(0, 1.08849296), e = pt(0, 1.52866483);
        CGPathAddCurveToPoint(p, nullptr, c1.x, c1.y, c2.x, c2.y, e.x, e.y);
    };
    corner(x + w, y, -1, 0, 0, 1);      // bottom right (y grows upward)
    corner(x + w, y + h, 0, -1, -1, 0); // top right
    corner(x, y + h, 1, 0, 0, -1);      // top left
    corner(x, y, 0, 1, 1, 0);           // bottom left
    CGPathCloseSubpath(p);
    return p;
}

void fillPath(CGContextRef g, CGPathRef path, int rgb, double alpha = 1) {
    CGColorRef c = color(rgb, alpha);
    CGContextAddPath(g, path);
    CGContextSetFillColorWithColor(g, c);
    CGContextFillPath(g);
    CGColorRelease(c);
}

void gradientFill(CGContextRef g, CGPathRef path, int top, int bottom, double y0, double y1) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    const void* colors[] = {color(top), color(bottom)};
    CFArrayRef array = CFArrayCreate(nullptr, colors, 2, &kCFTypeArrayCallBacks);
    CGGradientRef gradient = CGGradientCreateWithColors(space, array, nullptr);
    CGContextSaveGState(g);
    CGContextAddPath(g, path);
    CGContextClip(g);
    CGContextDrawLinearGradient(g, gradient, CGPointMake(0, y1), CGPointMake(0, y0), 0);
    CGContextRestoreGState(g);
    CGGradientRelease(gradient);
    CFRelease(array);
    CFRelease(colors[0]);
    CFRelease(colors[1]);
    CGColorSpaceRelease(space);
}

void card(CGContextRef g, double x, double y, double w, double h, int top, int bottom, double shadow) {
    CGPathRef path = CGPathCreateWithRoundedRect(CGRectMake(x, y, w, h), 56, 56, nullptr);
    CGContextSaveGState(g);
    CGColorRef shade = color(0x000000, shadow);
    CGContextSetShadowWithColor(g, CGSizeMake(0, -10), 28, shade);
    fillPath(g, path, bottom);
    CGContextRestoreGState(g);
    gradientFill(g, path, top, bottom, y, y + h);
    CGColorRelease(shade);
    CGPathRelease(path);
}

void bar(CGContextRef g, double x, double y, double w, int rgb, double alpha) {
    CGPathRef path = CGPathCreateWithRoundedRect(CGRectMake(x, y, w, 30), 15, 15, nullptr);
    fillPath(g, path, rgb, alpha);
    CGPathRelease(path);
}

void render(int pixels, const std::string& file) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef g = CGBitmapContextCreate(nullptr, pixels, pixels, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGContextScaleCTM(g, pixels / 1024.0, pixels / 1024.0);

    // The tile: the macOS icon grid's 824-point square, with a soft shadow below it.
    CGPathRef tile = squircle(CGRectMake(100, 100, 824, 824), 120);
    CGContextSaveGState(g);
    CGColorRef shade = color(0x000000, 0.32);
    CGContextSetShadowWithColor(g, CGSizeMake(0, -12), 30, shade);
    fillPath(g, tile, 0x1C1C1E);
    CGContextRestoreGState(g);
    CGColorRelease(shade);
    gradientFill(g, tile, 0x48484C, 0x1C1C1E, 100, 924);

    // The history: three cards, the newest in front.
    card(g, 322, 404, 380, 300, 0x5E5E63, 0x48484D, 0.25);
    card(g, 287, 334, 450, 300, 0x9E9EA4, 0x84848A, 0.3);
    card(g, 252, 236, 520, 330, 0xFFFFFF, 0xE7E7EC, 0.35);
    bar(g, 312, 470, 300, 0x3A3A3C, 0.85);
    bar(g, 312, 410, 380, 0x3A3A3C, 0.55);
    bar(g, 312, 350, 240, 0x3A3A3C, 0.55);

    // The crumb: a toasted, slightly angular morsel resting on the front card.
    const double cx = 672, cy = 296, r = 58;
    const double corners[][2] = {{-1.00, 0.10}, {-0.72, 0.74}, {-0.05, 0.98}, {0.62, 0.80}, {1.02, 0.18},
                                 {0.80, -0.62}, {0.10, -0.92}, {-0.62, -0.70}};
    CGMutablePathRef crumb = CGPathCreateMutable();
    const int n = sizeof(corners) / sizeof(corners[0]);
    for (int i = 0; i <= n; ++i) {
        // Rounded corners: each corner is a quadratic curve between the midpoints of its two edges.
        const double* a = corners[(i + n - 1) % n];
        const double* b = corners[i % n];
        const double* c = corners[(i + 1) % n];
        const double mx1 = cx + r * (a[0] + b[0]) / 2, my1 = cy + r * (a[1] + b[1]) / 2;
        const double mx2 = cx + r * (b[0] + c[0]) / 2, my2 = cy + r * (b[1] + c[1]) / 2;
        if (i == 0)
            CGPathMoveToPoint(crumb, nullptr, mx1, my1);
        CGPathAddQuadCurveToPoint(crumb, nullptr, cx + r * b[0], cy + r * b[1], mx2, my2);
    }
    CGPathCloseSubpath(crumb);
    CGContextSaveGState(g);
    shade = color(0x4A2600, 0.45);
    CGContextSetShadowWithColor(g, CGSizeMake(0, -8), 16, shade);
    fillPath(g, crumb, 0xC27A2C);
    CGContextRestoreGState(g);
    CGColorRelease(shade);
    gradientFill(g, crumb, 0xF6C978, 0xC27A2C, cy - r, cy + r);
    // A few pores.
    const double pores[][3] = {{-0.38, 0.30, 0.13}, {0.30, 0.38, 0.10}, {0.05, -0.30, 0.12}, {0.52, -0.18, 0.08}};
    for (const auto& p : pores) {
        CGPathRef pore = CGPathCreateWithEllipseInRect(
            CGRectMake(cx + r * p[0] - r * p[2], cy + r * p[1] - r * p[2], 2 * r * p[2], 2 * r * p[2]), nullptr);
        fillPath(g, pore, 0x9A5A1C, 0.55);
        CGPathRelease(pore);
    }
    CGPathRelease(crumb);

    CGImageRef image = CGBitmapContextCreateImage(g);
    CFStringRef path = CFStringCreateWithCString(nullptr, file.c_str(), kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(nullptr, path, kCFURLPOSIXPathStyle, false);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
    CGImageDestinationAddImage(dest, image, nullptr);
    CGImageDestinationFinalize(dest);

    CFRelease(dest);
    CFRelease(url);
    CFRelease(path);
    CGImageRelease(image);
    CGPathRelease(tile);
    CGContextRelease(g);
    CGColorSpaceRelease(space);
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: icon <dir.iconset> [preview.png]\n");
        return 1;
    }
    const std::string dir = argv[1];
    // Sizes above 256pt@2x are left out on purpose: Finder scales up, and the app stays small.
    const struct { int points, scale; } sizes[] = {{16, 1}, {16, 2}, {32, 1}, {32, 2}, {128, 1}, {128, 2}, {256, 1}, {256, 2}};
    for (const auto& size : sizes) {
        char name[64];
        std::snprintf(name, sizeof(name), "/icon_%dx%d%s.png", size.points, size.points, size.scale == 2 ? "@2x" : "");
        render(size.points * size.scale, dir + name);
    }
    if (argc > 2) render(512, argv[2]);
    return 0;
}
