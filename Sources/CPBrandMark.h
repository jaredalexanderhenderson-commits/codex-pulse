#import <Cocoa/Cocoa.h>

// The Codex Pulse mark: a rising pulse trace with a detached node at its leading
// end. The trace reads both as a heartbeat and as usage accumulating over time;
// the node echoes the dashboard's chart cursor and its Live indicator, and gives
// the mark a direction the old orbit-and-core icon lacked.
//
// The geometry is defined once here, in a 32x32 box with y pointing up (AppKit
// convention), and scaled into whatever box the caller needs. Both the app icon
// generator and the menu-bar template image draw from these coordinates so they
// cannot drift apart. The inline SVG in dashboard.html mirrors the same numbers
// with y flipped, since SVG's y points down.

static const CGFloat CPBrandMarkGrid = 32.0;

// Trace vertices, in grid units. Deliberately asymmetric: evenly sized zigzags
// read as a monogram rather than a signal. One tall narrow spike over an otherwise
// gently rising line keeps it legible as a chart with a beat in it.
static const NSPoint CPBrandMarkTraceVertices[] = {
    { 4.0, 9.2 },    // low left
    { 9.6, 12.2 },   // gentle rise
    { 13.0, 10.0 },  // dip before the beat
    { 16.2, 22.6 },  // the beat: tall and narrow
    { 19.0, 13.6 },  // fall back
    { 25.4, 21.4 }   // rise out, terminating at the node
};
static const NSUInteger CPBrandMarkTraceVertexCount =
    sizeof(CPBrandMarkTraceVertices) / sizeof(CPBrandMarkTraceVertices[0]);

// The node sits on the trace's final vertex, not detached from it — floating free
// it reads as a stray bullet. Roughly twice the stroke width, so it terminates the
// line the way the dashboard's chart cursor sits on the token-flow line.
static const NSPoint CPBrandMarkNodeCentre = { 25.4, 21.4 };
static const CGFloat CPBrandMarkNodeRadius = 2.6;

static inline NSPoint CPBrandMarkPoint(NSPoint unit, NSRect box) {
    return NSMakePoint(NSMinX(box) + unit.x / CPBrandMarkGrid * NSWidth(box),
                       NSMinY(box) + unit.y / CPBrandMarkGrid * NSHeight(box));
}

// Round caps and joins keep the trace feeling like a drawn stroke at every size.
static inline CGFloat CPBrandMarkStrokeWidth(NSRect box) {
    return 2.7 / CPBrandMarkGrid * MIN(NSWidth(box), NSHeight(box));
}

static inline NSBezierPath *CPBrandMarkTrace(NSRect box) {
    NSBezierPath *path = [NSBezierPath bezierPath];
    for (NSUInteger index = 0; index < CPBrandMarkTraceVertexCount; index++) {
        NSPoint point = CPBrandMarkPoint(CPBrandMarkTraceVertices[index], box);
        if (index == 0) { [path moveToPoint:point]; } else { [path lineToPoint:point]; }
    }
    path.lineWidth = CPBrandMarkStrokeWidth(box);
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;
    return path;
}

static inline NSBezierPath *CPBrandMarkNode(NSRect box) {
    NSPoint centre = CPBrandMarkPoint(CPBrandMarkNodeCentre, box);
    CGFloat radius = CPBrandMarkNodeRadius / CPBrandMarkGrid * MIN(NSWidth(box), NSHeight(box));
    return [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(centre.x - radius, centre.y - radius, radius * 2.0, radius * 2.0)];
}
