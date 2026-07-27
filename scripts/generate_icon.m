#import <Cocoa/Cocoa.h>
#import "CPBrandMark.h"

static NSBezierPath *Squircle(NSRect rect, CGFloat radius) {
    return [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
}

// Draws the app icon: the brand mark in white on a squircle carrying the same
// accent-to-violet gradient and glass treatment as the dashboard. The previous
// icon was a near-black purple tile inherited from the old dark theme, which no
// longer matched anything in the app.
static void DrawIcon(CGFloat size, NSString *path) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:(NSInteger)size
                      pixelsHigh:(NSInteger)size
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];

    NSRect canvas = NSMakeRect(0, 0, size, size);
    [[NSColor clearColor] setFill];
    NSRectFill(canvas);

    // macOS leaves roughly a tenth of the canvas as breathing room, and Big Sur
    // onwards uses a squircle radius of about 0.2237 of the icon's edge.
    NSRect tile = NSInsetRect(canvas, size * 0.085, size * 0.085);
    CGFloat radius = size * 0.2237;
    NSBezierPath *tilePath = Squircle(tile, radius);

    // The dashboard's own pairing: --accent #3b5ce0 through to --violet #7c5cf0.
    NSGradient *tileGradient = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor colorWithSRGBRed:0.353 green:0.451 blue:0.980 alpha:1.0], 0.0,
        [NSColor colorWithSRGBRed:0.278 green:0.376 blue:0.929 alpha:1.0], 0.48,
        [NSColor colorWithSRGBRed:0.486 green:0.361 blue:0.941 alpha:1.0], 1.0, nil];
    [tileGradient drawInBezierPath:tilePath angle:-62];

    // Glass highlights, clipped to the squircle. Linear rather than radial: a
    // radial gradient fades out at its own bounding ellipse, which leaves a visible
    // curved seam across the tile.
    [NSGraphicsContext saveGraphicsState];
    [tilePath addClip];

    // Broad specular sweep in from the top-left, mirroring --glass-sheen.
    NSGradient *sheen = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor colorWithWhite:1 alpha:0.34], 0.0,
        [NSColor colorWithWhite:1 alpha:0.06], 0.34,
        [NSColor colorWithWhite:1 alpha:0.0], 0.58, nil];
    [sheen drawInRect:tile angle:-58];

    // A faint lift off the bottom edge so the lower half is lit, not just darker.
    NSGradient *bounce = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor colorWithWhite:1 alpha:0.13], 0.0,
        [NSColor colorWithWhite:1 alpha:0.0], 0.26, nil];
    [bounce drawInRect:tile angle:90];

    [NSGraphicsContext restoreGraphicsState];

    // Bevel rim, kept inside the tile's antialiased edge so it reads as a lit lip
    // rather than an outline. Clipping to the ring between two squircles lets one
    // vertical gradient run through it: bright at the crown, gone at the sides.
    CGFloat lipWidth = MAX(1.0, size * 0.009);
    NSRect lipRect = NSInsetRect(tile, lipWidth * 0.5, lipWidth * 0.5);
    NSBezierPath *ring = [NSBezierPath bezierPath];
    [ring appendBezierPath:Squircle(lipRect, radius - lipWidth * 0.5)];
    [ring appendBezierPath:Squircle(NSInsetRect(lipRect, lipWidth, lipWidth), radius - lipWidth * 1.5)];
    ring.windingRule = NSWindingRuleEvenOdd;

    [NSGraphicsContext saveGraphicsState];
    [ring addClip];
    // angle:90 runs bottom-to-top, so location 0 is the bottom of the tile.
    NSGradient *lipGradient = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor colorWithWhite:1 alpha:0.16], 0.0,
        [NSColor colorWithWhite:1 alpha:0.02], 0.42,
        [NSColor colorWithWhite:1 alpha:0.52], 1.0, nil];
    [lipGradient drawInRect:lipRect angle:90];
    [NSGraphicsContext restoreGraphicsState];

    // The mark, inset so it never crowds the squircle's corners, with a soft drop
    // shadow to lift it off the glass.
    NSRect markBox = NSInsetRect(tile, NSWidth(tile) * 0.185, NSHeight(tile) * 0.185);
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(cg);
    CGContextSetShadowWithColor(cg, CGSizeMake(0, -size * 0.010), size * 0.026,
                                [NSColor colorWithSRGBRed:0.05 green:0.08 blue:0.26 alpha:0.34].CGColor);
    [[NSColor whiteColor] setStroke];
    [CPBrandMarkTrace(markBox) stroke];
    [[NSColor whiteColor] setFill];
    [CPBrandMarkNode(markBox) fill];
    CGContextRestoreGState(cg);

    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:path atomically:YES];
}

static void AppendBigEndianUInt32(NSMutableData *data, uint32_t value) {
    uint32_t bigEndian = CFSwapInt32HostToBig(value);
    [data appendBytes:&bigEndian length:sizeof(bigEndian)];
}

static BOOL BuildICNS(NSString *directory, NSString *outputPath) {
    NSArray<NSArray<NSString *> *> *elements = @[
        @[@"icp4", @"icon_16x16.png"],
        @[@"icp5", @"icon_32x32.png"],
        @[@"icp6", @"icon_32x32@2x.png"],
        @[@"ic07", @"icon_128x128.png"],
        @[@"ic08", @"icon_256x256.png"],
        @[@"ic09", @"icon_512x512.png"],
        @[@"ic10", @"icon_512x512@2x.png"]
    ];
    NSMutableArray<NSDictionary *> *payloads = [NSMutableArray array];
    uint32_t totalLength = 8;
    for (NSArray<NSString *> *element in elements) {
        NSData *payload = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:element[1]]];
        if (!payload) { return NO; }
        [payloads addObject:@{ @"type": element[0], @"data": payload }];
        totalLength += (uint32_t)payload.length + 8;
    }

    NSMutableData *icns = [NSMutableData data];
    [icns appendBytes:"icns" length:4];
    AppendBigEndianUInt32(icns, totalLength);
    for (NSDictionary *element in payloads) {
        [icns appendData:[element[@"type"] dataUsingEncoding:NSASCIIStringEncoding]];
        NSData *payload = element[@"data"];
        AppendBigEndianUInt32(icns, (uint32_t)payload.length + 8);
        [icns appendData:payload];
    }
    return [icns writeToFile:outputPath atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) { return 2; }
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        NSString *outputPath = [NSString stringWithUTF8String:argv[2]];
        NSDictionary<NSString *, NSNumber *> *files = @{
            @"icon_16x16.png": @16,
            @"icon_16x16@2x.png": @32,
            @"icon_32x32.png": @32,
            @"icon_32x32@2x.png": @64,
            @"icon_128x128.png": @128,
            @"icon_128x128@2x.png": @256,
            @"icon_256x256.png": @256,
            @"icon_256x256@2x.png": @512,
            @"icon_512x512.png": @512,
            @"icon_512x512@2x.png": @1024
        };
        [files enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSNumber *pixels, BOOL *stop) {
            DrawIcon(pixels.doubleValue, [directory stringByAppendingPathComponent:name]);
        }];
        if (!BuildICNS(directory, outputPath)) { return 3; }
    }
    return 0;
}
