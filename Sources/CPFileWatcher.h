#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^CPFileWatcherChangeHandler)(void);

@interface CPFileWatcher : NSObject

- (instancetype)initWithPaths:(NSArray<NSString *> *)paths
                 changeHandler:(CPFileWatcherChangeHandler)changeHandler;
- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
