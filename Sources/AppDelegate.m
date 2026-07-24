#import "AppDelegate.h"
#import "CPFileWatcher.h"
#import "CPLogCollector.h"
#import "CPPricingEngine.h"
#import "CPUpdater.h"

static double CPAppDouble(id value) {
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
}

@interface CPWindowDragView : NSView
@end

@implementation CPWindowDragView

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (BOOL)mouseDownCanMoveWindow {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    [self.window performWindowDragWithEvent:event];
}

@end

@interface AppDelegate ()
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem *menuLimitItem;
@property (nonatomic, strong) NSMenuItem *menuTokenItem;
@property (nonatomic, strong) NSMenuItem *menuCreditItem;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) CPLogCollector *collector;
@property (nonatomic, strong) CPFileWatcher *watcher;
@property (nonatomic, strong) NSDictionary *latestSnapshot;
@property (nonatomic, strong) NSURL *dataDirectoryURL;
@property (nonatomic, assign) BOOL webViewReady;
@property (nonatomic, strong) CPUpdater *updater;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Regular activation keeps Codex Pulse visible in the Dock while the
    // status item continues to provide the compact menu-bar experience.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self configureCollector];
    self.updater = [CPUpdater new];
    [self configureStatusItem];
    [self showDashboard:nil];

    __weak typeof(self) weakSelf = self;
    [self.collector refreshWithCompletion:^(NSDictionary<NSString *,id> *snapshot) {
        [weakSelf consumeSnapshot:snapshot];
    }];

    NSArray *watchPaths = [[self sessionRoots] valueForKey:@"path"];
    self.watcher = [[CPFileWatcher alloc] initWithPaths:watchPaths changeHandler:^{
        [weakSelf.collector refreshWithCompletion:^(NSDictionary<NSString *,id> *snapshot) {
            [weakSelf consumeSnapshot:snapshot];
        }];
    }];
    [self.watcher start];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf.updater checkForUpdatesUserInitiated:NO];
    });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self showDashboard:nil];
    return YES;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [sender orderOut:nil];
    return NO;
}

- (NSArray<NSURL *> *)sessionRoots {
    NSString *override = NSProcessInfo.processInfo.environment[@"CODEX_PULSE_SESSION_ROOTS"];
    if (override.length) {
        NSMutableArray *urls = [NSMutableArray array];
        for (NSString *path in [override componentsSeparatedByString:@":"]) {
            if (path.length) { [urls addObject:[NSURL fileURLWithPath:path isDirectory:YES]]; }
        }
        return urls;
    }
    NSString *codexHome = [NSHomeDirectory() stringByAppendingPathComponent:@".codex"];
    return @[
        [NSURL fileURLWithPath:[codexHome stringByAppendingPathComponent:@"sessions"] isDirectory:YES],
        [NSURL fileURLWithPath:[codexHome stringByAppendingPathComponent:@"archived_sessions"] isDirectory:YES]
    ];
}

- (void)configureCollector {
    NSURL *pricingURL = [NSBundle.mainBundle URLForResource:@"pricing" withExtension:@"json"];
    NSError *pricingError = nil;
    CPPricingEngine *pricingEngine = [[CPPricingEngine alloc] initWithPricingFileURL:pricingURL error:&pricingError];
    if (!pricingEngine) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Codex Pulse could not load its pricing table.";
        alert.informativeText = pricingError.localizedDescription ?: @"The pricing resource is missing.";
        [alert runModal];
        [NSApp terminate:nil];
        return;
    }

    NSString *override = NSProcessInfo.processInfo.environment[@"CODEX_PULSE_DATA_DIR"];
    if (override.length) {
        self.dataDirectoryURL = [NSURL fileURLWithPath:override isDirectory:YES];
    } else {
        NSURL *applicationSupport = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                            inDomains:NSUserDomainMask].firstObject;
        self.dataDirectoryURL = [applicationSupport URLByAppendingPathComponent:@"Codex Pulse" isDirectory:YES];
    }
    NSURL *stateURL = [self.dataDirectoryURL URLByAppendingPathComponent:@"usage-store.json"];
    self.collector = [[CPLogCollector alloc] initWithSessionRoots:[self sessionRoots]
                                                         stateURL:stateURL
                                                    pricingEngine:pricingEngine
                                                              now:nil];
}

- (void)configureStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = self.statusItem.button;
    button.image = [NSImage imageWithSystemSymbolName:@"sparkles" accessibilityDescription:@"Codex Pulse"];
    button.title = @" --";
    button.toolTip = @"Codex Pulse";

    NSMenu *menu = [NSMenu new];
    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"Open Codex Pulse" action:@selector(showDashboard:) keyEquivalent:@""];
    openItem.target = self;
    [menu addItem:openItem];
    [menu addItem:NSMenuItem.separatorItem];

    self.menuLimitItem = [[NSMenuItem alloc] initWithTitle:@"Weekly remaining · waiting" action:@selector(showDashboard:) keyEquivalent:@""];
    self.menuTokenItem = [[NSMenuItem alloc] initWithTitle:@"Tracked tokens · waiting" action:@selector(showDashboard:) keyEquivalent:@""];
    self.menuCreditItem = [[NSMenuItem alloc] initWithTitle:@"Estimated credits · waiting" action:@selector(showDashboard:) keyEquivalent:@""];
    self.menuLimitItem.target = self;
    self.menuTokenItem.target = self;
    self.menuCreditItem.target = self;
    [menu addItem:self.menuLimitItem];
    [menu addItem:self.menuTokenItem];
    [menu addItem:self.menuCreditItem];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"Refresh Now" action:@selector(refreshNow:) keyEquivalent:@"r"];
    refreshItem.target = self;
    [menu addItem:refreshItem];
    NSMenuItem *updateItem = [[NSMenuItem alloc] initWithTitle:@"Check for Updates…" action:@selector(checkForUpdates:) keyEquivalent:@""];
    updateItem.target = self;
    [menu addItem:updateItem];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Codex Pulse" action:@selector(quitApp:) keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];
    self.statusItem.menu = menu;
}

- (void)createWindowIfNeeded {
    if (self.window) { return; }

    NSRect frame = NSMakeRect(0, 0, 1120, 760);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                              NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                              NSWindowStyleMaskFullSizeContentView;
    self.window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Codex Pulse";
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.titlebarAppearsTransparent = YES;
    self.window.movableByWindowBackground = YES;
    self.window.minSize = NSMakeSize(900, 640);
    self.window.backgroundColor = NSColor.blackColor;
    self.window.delegate = self;
    [self.window center];

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    [configuration.userContentController addScriptMessageHandler:self name:@"codexPulse"];
    NSView *contentView = [[NSView alloc] initWithFrame:frame];
    contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.window.contentView = contentView;

    self.webView = [[WKWebView alloc] initWithFrame:contentView.bounds configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.webView.allowsMagnification = NO;
    [contentView addSubview:self.webView];

    // WKWebView consumes background mouse events, so movableByWindowBackground
    // cannot make the custom HTML header draggable on its own. Keep the native
    // drag view alongside the flipped web view so its AppKit coordinates remain
    // anchored to the visible title area.
    CGFloat dragLeftMargin = 80.0;
    CGFloat dragRightMargin = 360.0;
    CGFloat dragHeight = 98.0;
    NSRect dragFrame = NSMakeRect(dragLeftMargin,
                                  NSHeight(contentView.bounds) - 122.0,
                                  NSWidth(contentView.bounds) - dragLeftMargin - dragRightMargin,
                                  dragHeight);
    CPWindowDragView *dragView = [[CPWindowDragView alloc] initWithFrame:dragFrame];
    dragView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [contentView addSubview:dragView positioned:NSWindowAbove relativeTo:self.webView];

    NSURL *dashboardURL = [NSBundle.mainBundle URLForResource:@"dashboard" withExtension:@"html"];
    NSURL *resourcesURL = NSBundle.mainBundle.resourceURL;
    if (dashboardURL && resourcesURL) {
        [self.webView loadFileURL:dashboardURL allowingReadAccessToURL:resourcesURL];
    }
}

- (void)showDashboard:(id)sender {
    [self createWindowIfNeeded];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)refreshNow:(id)sender {
    __weak typeof(self) weakSelf = self;
    [self.collector refreshWithCompletion:^(NSDictionary<NSString *,id> *snapshot) {
        [weakSelf consumeSnapshot:snapshot];
    }];
}

- (void)quitApp:(id)sender {
    [NSApp terminate:nil];
}

- (void)checkForUpdates:(id)sender {
    [self.updater checkForUpdatesUserInitiated:YES];
}

- (void)consumeSnapshot:(NSDictionary *)snapshot {
    self.latestSnapshot = snapshot;
    [self updateStatusMenu:snapshot];
    [self pushSnapshotToDashboard];
}

- (NSString *)compactNumber:(double)value {
    if (value >= 1000000000.0) { return [NSString stringWithFormat:@"%.2fB", value / 1000000000.0]; }
    if (value >= 1000000.0) { return [NSString stringWithFormat:@"%.2fM", value / 1000000.0]; }
    if (value >= 1000.0) { return [NSString stringWithFormat:@"%.1fK", value / 1000.0]; }
    return [NSString stringWithFormat:@"%.0f", value];
}

- (void)updateStatusMenu:(NSDictionary *)snapshot {
    NSDictionary *tracked = snapshot[@"periods"][@"tracked"];
    NSDictionary *limit = snapshot[@"limit"];
    double usedPercent = CPAppDouble(limit[@"usedPercent"]);
    double remainingPercent = 100.0 - MIN(100.0, MAX(0.0, usedPercent));
    self.statusItem.button.title = limit.count ? [NSString stringWithFormat:@" %.0f%%", remainingPercent] : @" --";
    self.statusItem.button.toolTip = limit.count ? @"Codex weekly limit remaining" : @"Codex Pulse";
    self.menuLimitItem.title = limit.count
        ? [NSString stringWithFormat:@"Weekly remaining · %.0f%%", remainingPercent]
        : @"Weekly remaining · unavailable";
    self.menuTokenItem.title = [NSString stringWithFormat:@"Tracked tokens · %@", [self compactNumber:CPAppDouble(tracked[@"total"])]];
    self.menuCreditItem.title = [NSString stringWithFormat:@"Estimated credits · %.1f", CPAppDouble(tracked[@"credits"])];
}

- (void)pushSnapshotToDashboard {
    if (!self.webViewReady || !self.latestSnapshot) { return; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.latestSnapshot options:0 error:nil];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
    NSString *script = [NSString stringWithFormat:@"window.codexPulseUpdate(%@);", json];
    [self.webView evaluateJavaScript:script completionHandler:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.webViewReady = YES;
    [self pushSnapshotToDashboard];
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    NSString *action = nil;
    if ([message.body isKindOfClass:[NSString class]]) {
        action = message.body;
    } else if ([message.body isKindOfClass:[NSDictionary class]]) {
        action = message.body[@"action"];
    }
    if ([action isEqualToString:@"refresh"]) {
        [self refreshNow:nil];
    } else if ([action isEqualToString:@"reset"]) {
        [self confirmReset];
    } else if ([action isEqualToString:@"revealData"]) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[self.dataDirectoryURL]];
    } else if ([action isEqualToString:@"openPricing"]) {
        NSURL *url = [NSURL URLWithString:@"https://help.openai.com/en/articles/20001106-codex-rate-card"];
        if (url) { [[NSWorkspace sharedWorkspace] openURL:url]; }
    }
}

- (void)confirmReset {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Reset Codex Pulse data?";
    alert.informativeText = @"This clears only the app’s local ledger, then re-imports the latest seven days. Codex session files are never changed.";
    [alert addButtonWithTitle:@"Reset & Re-import"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode != NSAlertFirstButtonReturn) { return; }
        __weak typeof(self) weakSelf = self;
        [self.collector resetAndReimportWithCompletion:^(NSDictionary<NSString *,id> *snapshot) {
            [weakSelf consumeSnapshot:snapshot];
        }];
    }];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.watcher stop];
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"codexPulse"];
}

@end
