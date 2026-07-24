#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

static AppDelegate *CPApplicationDelegate;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        // NSApplication does not own its delegate. Keep the delegate alive for the
        // complete event loop so status-menu targets can never point at freed memory.
        CPApplicationDelegate = [AppDelegate new];
        application.delegate = CPApplicationDelegate;
        [application run];
        application.delegate = nil;
        CPApplicationDelegate = nil;
    }
    return 0;
}
