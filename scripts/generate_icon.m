#import <Cocoa/Cocoa.h>

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

    CGFloat inset = size * 0.055;
    NSRect tile = NSInsetRect(canvas, inset, inset);
    NSBezierPath *tilePath = [NSBezierPath bezierPathWithRoundedRect:tile xRadius:size * 0.225 yRadius:size * 0.225];
    NSGradient *tileGradient = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor colorWithRed:0.08 green:0.055 blue:0.13 alpha:1.0], 0.0,
        [NSColor colorWithRed:0.23 green:0.09 blue:0.42 alpha:1.0], 0.52,
        [NSColor colorWithRed:0.48 green:0.18 blue:0.75 alpha:1.0], 1.0, nil];
    [tileGradient drawInBezierPath:tilePath angle:55];

    [[NSColor colorWithWhite:1 alpha:0.16] setStroke];
    tilePath.lineWidth = MAX(1, size * 0.008);
    [tilePath stroke];

    NSRect glowRect = NSMakeRect(size * 0.19, size * 0.19, size * 0.62, size * 0.62);
    NSBezierPath *glowPath = [NSBezierPath bezierPathWithOvalInRect:glowRect];
    NSGradient *glowGradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithRed:0.73 green:0.40 blue:1 alpha:0.40]
                                                               endingColor:[NSColor colorWithRed:0.44 green:0.16 blue:0.78 alpha:0.01]];
    [glowGradient drawInBezierPath:glowPath relativeCenterPosition:NSMakePoint(0, 0)];

    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:size * 0.5 yBy:size * 0.5];
    [transform rotateByDegrees:-26];
    [transform translateXBy:-size * 0.5 yBy:-size * 0.5];
    [transform concat];
    NSRect orbitRect = NSMakeRect(size * 0.18, size * 0.31, size * 0.64, size * 0.38);
    NSBezierPath *orbit = [NSBezierPath bezierPathWithOvalInRect:orbitRect];
    [[NSColor colorWithRed:0.83 green:0.64 blue:1 alpha:0.9] setStroke];
    orbit.lineWidth = MAX(1.2, size * 0.025);
    [orbit stroke];
    [NSGraphicsContext restoreGraphicsState];

    CGFloat coreSize = size * 0.19;
    NSRect coreRect = NSMakeRect((size - coreSize) / 2, (size - coreSize) / 2, coreSize, coreSize);
    NSBezierPath *core = [NSBezierPath bezierPathWithOvalInRect:coreRect];
    NSGradient *coreGradient = [[NSGradient alloc] initWithStartingColor:[NSColor whiteColor]
                                                               endingColor:[NSColor colorWithRed:0.74 green:0.48 blue:1 alpha:1]];
    [coreGradient drawInBezierPath:core angle:-45];

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
