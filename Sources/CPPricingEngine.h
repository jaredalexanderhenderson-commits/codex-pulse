#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CPPricingEngine : NSObject

@property (nonatomic, readonly, copy) NSString *publishedDate;
@property (nonatomic, readonly, copy) NSString *sourceURL;

- (instancetype)initWithPricingFileURL:(NSURL *)url error:(NSError **)error;
- (NSDictionary<NSString *, id> *)estimateForModel:(nullable NSString *)model
                                        serviceTier:(nullable NSString *)serviceTier
                                        inputTokens:(long long)inputTokens
                                       cachedTokens:(long long)cachedTokens
                                        outputTokens:(long long)outputTokens;

@end

NS_ASSUME_NONNULL_END
