#import <AppKit/AppKit.h>

@interface CPUpdater : NSObject

- (void)checkForUpdatesUserInitiated:(BOOL)userInitiated;
+ (BOOL)isVersion:(NSString *)candidate newerThanVersion:(NSString *)current;

@end
