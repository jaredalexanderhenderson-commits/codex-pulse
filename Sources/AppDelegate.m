#import "AppDelegate.h"
#import "CPFileWatcher.h"
#import "CPLogCollector.h"
#import "CPPricingEngine.h"
#import "CPUpdater.h"

static double CPAppDouble(id value) {
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
}

// Height of the dashboard's glass toolbar, in CSS pixels. The web view is
// point-for-point with CSS pixels here, so the same number positions the native
// drag overlay over that toolbar. Keep in sync with `--titlebar-h`.
static const CGFloat CPTitlebarHeight = 52.0;

// Matches the dashboard's `--canvas`, so the window never flashes a colour the
// page is about to contradict. The dashboard is light-only and does not follow the
// system appearance, hence the fixed value rather than a dynamic provider.
static NSColor *CPWindowBackgroundColor(void) {
    return [NSColor colorWithSRGBRed:0.875 green:0.898 blue:0.953 alpha:1.0];
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
@property (nonatomic, strong) NSView *dragView;
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

- (void)windowDidResize:(NSNotification *)notification {
    [self layoutDragView];
}

// Spans the dashboard toolbar horizontally, leaving the traffic lights on the
// left and the toolbar's Live pill, refresh and settings buttons on the right
// clickable. The dashboard centres its toolbar contents in a 1200pt column, so
// the right-hand gutter grows with the window's half-overflow past that column.
- (void)layoutDragView {
    NSView *contentView = self.window.contentView;
    if (!contentView || !self.dragView) { return; }

    CGFloat width = NSWidth(contentView.bounds);
    CGFloat leftGutter = 80.0;
    CGFloat contentColumn = MIN(1200.0, width - 44.0);
    CGFloat rightGutter = 240.0 + MAX(0.0, (width - contentColumn) / 2.0 - 22.0);
    CGFloat dragWidth = MAX(0.0, width - leftGutter - rightGutter);

    self.dragView.frame = NSMakeRect(leftGutter,
                                     NSHeight(contentView.bounds) - CPTitlebarHeight,
                                     dragWidth,
                                     CPTitlebarHeight);
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
    self.window.backgroundColor = CPWindowBackgroundColor();
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
    // cannot make the dashboard's HTML toolbar draggable on its own. Keep a
    // native drag view over that toolbar instead. Its frame is recomputed on
    // resize rather than autoresized, because the reserved right-hand gutter has
    // to stay wide enough to expose the toolbar's own buttons at any width.
    self.dragView = [[CPWindowDragView alloc] initWithFrame:NSZeroRect];
    [contentView addSubview:self.dragView positioned:NSWindowAbove relativeTo:self.webView];
    [self layoutDragView];

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
    // The dashboard shows the running version in its settings drawer. Feeding it
    // from the bundle keeps the two from drifting apart at release time.
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:@[version] options:0 error:NULL];
    NSString *literal = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:@"window.codexPulseSetVersion && window.codexPulseSetVersion(%@[0]);", literal];
    [self.webView evaluateJavaScript:script completionHandler:nil];
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
    alert.informativeText = @"This clears only the app’s local ledger, then re-imports usage from the beginning of June. Codex session files are never changed.";
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
