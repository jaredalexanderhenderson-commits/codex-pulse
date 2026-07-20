#import <Foundation/Foundation.h>

@class CPPricingEngine;

NS_ASSUME_NONNULL_BEGIN

typedef void (^CPCollectorCompletion)(NSDictionary<NSString *, id> *snapshot);

@interface CPLogCollector : NSObject

- (instancetype)initWithSessionRoots:(NSArray<NSURL *> *)sessionRoots
                             stateURL:(NSURL *)stateURL
                        pricingEngine:(CPPricingEngine *)pricingEngine
                                  now:(nullable NSDate *)fixedNow;

- (void)refreshWithCompletion:(nullable CPCollectorCompletion)completion;
- (void)resetAndReimportWithCompletion:(nullable CPCollectorCompletion)completion;
- (NSDictionary<NSString *, id> *)currentSnapshot;

@end

NS_ASSUME_NONNULL_END
