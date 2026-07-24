#import "CPFileWatcher.h"
#import <CoreServices/CoreServices.h>

@interface CPFileWatcher ()
@property (nonatomic, copy) NSArray<NSString *> *paths;
@property (nonatomic, copy) CPFileWatcherChangeHandler changeHandler;
@property (nonatomic) FSEventStreamRef stream;
@property (nonatomic, strong) dispatch_queue_t eventQueue;
@property (nonatomic, strong) dispatch_source_t reconciliationTimer;
@property (nonatomic, assign) BOOL notificationPending;
- (void)scheduleChangeNotification;
@end

static void CPFileSystemEventsCallback(ConstFSEventStreamRef streamRef,
                                       void *clientCallBackInfo,
                                       size_t numEvents,
                                       void *eventPaths,
                                       const FSEventStreamEventFlags eventFlags[],
                                       const FSEventStreamEventId eventIds[]) {
    CPFileWatcher *watcher = (__bridge CPFileWatcher *)clientCallBackInfo;
    [watcher scheduleChangeNotification];
}

@implementation CPFileWatcher

- (instancetype)initWithPaths:(NSArray<NSString *> *)paths
                 changeHandler:(CPFileWatcherChangeHandler)changeHandler {
    self = [super init];
    if (!self) { return nil; }
    _paths = [paths copy];
    _changeHandler = [changeHandler copy];
    _eventQueue = dispatch_queue_create("com.codexpulse.file-watcher", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)start {
    if (self.stream || self.paths.count == 0) { return; }

    FSEventStreamContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
    CFArrayRef paths = (__bridge CFArrayRef)self.paths;
    self.stream = FSEventStreamCreate(kCFAllocatorDefault,
                                      &CPFileSystemEventsCallback,
                                      &context,
                                      paths,
                                      kFSEventStreamEventIdSinceNow,
                                      0.35,
                                      kFSEventStreamCreateFlagFileEvents |
                                      kFSEventStreamCreateFlagNoDefer |
                                      kFSEventStreamCreateFlagUseCFTypes);
    if (self.stream) {
        FSEventStreamSetDispatchQueue(self.stream, self.eventQueue);
        FSEventStreamStart(self.stream);
    }

    self.reconciliationTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.eventQueue);
    dispatch_source_set_timer(self.reconciliationTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 5 * 60 * NSEC_PER_SEC),
                              5 * 60 * NSEC_PER_SEC,
                              2 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.reconciliationTimer, ^{
        [weakSelf scheduleChangeNotification];
    });
    dispatch_resume(self.reconciliationTimer);
}

- (void)scheduleChangeNotification {
    if (self.notificationPending) { return; }
    self.notificationPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), self.eventQueue, ^{
        self.notificationPending = NO;
        if (self.changeHandler) { self.changeHandler(); }
    });
}

- (void)stop {
    if (self.reconciliationTimer) {
        dispatch_source_cancel(self.reconciliationTimer);
        self.reconciliationTimer = nil;
    }
    if (self.stream) {
        FSEventStreamStop(self.stream);
        FSEventStreamInvalidate(self.stream);
        FSEventStreamRelease(self.stream);
        self.stream = NULL;
    }
}

- (void)dealloc {
    [self stop];
}

@end
