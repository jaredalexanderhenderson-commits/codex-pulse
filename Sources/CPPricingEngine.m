#import "CPPricingEngine.h"

@interface CPPricingEngine ()
@property (nonatomic, copy) NSDictionary<NSString *, NSDictionary *> *models;
@property (nonatomic, readwrite, copy) NSString *publishedDate;
@property (nonatomic, readwrite, copy) NSString *sourceURL;
@end

@implementation CPPricingEngine

- (instancetype)initWithPricingFileURL:(NSURL *)url error:(NSError **)error {
    self = [super init];
    if (!self) { return nil; }

    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) { return nil; }

    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![root isKindOfClass:[NSDictionary class]]) { return nil; }

    _models = [root[@"models"] isKindOfClass:[NSDictionary class]] ? root[@"models"] : @{};
    _publishedDate = [root[@"published"] isKindOfClass:[NSString class]] ? root[@"published"] : @"Unknown";
    _sourceURL = [root[@"source"] isKindOfClass:[NSString class]] ? root[@"source"] : @"";
    return self;
}

- (NSString *)normalizedModel:(NSString *)model {
    NSString *normalized = model.lowercaseString;
    NSDictionary *aliases = @{
        @"gpt-5.6": @"gpt-5.6-sol",
        @"gpt-5.4-mini": @"gpt-5.4-mini",
        @"gpt-5.3-codex-spark": @"gpt-5.3-codex-spark"
    };
    return aliases[normalized] ?: normalized;
}

- (NSDictionary<NSString *, id> *)estimateForModel:(NSString *)model
                                        serviceTier:(NSString *)serviceTier
                                        inputTokens:(long long)inputTokens
                                       cachedTokens:(long long)cachedTokens
                                       outputTokens:(long long)outputTokens {
    NSString *normalized = model.length ? [self normalizedModel:model] : @"";
    NSDictionary *rate = self.models[normalized];
    if (![rate isKindOfClass:[NSDictionary class]]) {
        return @{
            @"known": @NO,
            @"credits": @0.0,
            @"apiCost": @0.0,
            @"displayModel": model ?: @"Unknown model",
            @"tierLabel": serviceTier ?: @"standard",
            @"creditMultiplier": @1.0,
            @"apiMultiplier": @1.0
        };
    }

    NSDictionary *creditRates = rate[@"credits"];
    NSDictionary *apiRates = rate[@"apiUSD"];
    long long safeInput = MAX(0, inputTokens);
    long long safeCached = MIN(MAX(0, cachedTokens), safeInput);
    long long uncached = safeInput - safeCached;
    long long safeOutput = MAX(0, outputTokens);

    double creditMultiplier = 1.0;
    double apiMultiplier = 1.0;
    NSString *tier = serviceTier.lowercaseString ?: @"standard";
    NSString *tierLabel = tier.length ? tier : @"standard";

    if ([tier isEqualToString:@"fast"]) {
        if ([normalized hasPrefix:@"gpt-5.6"] || [normalized hasPrefix:@"gpt-5.5"]) {
            creditMultiplier = 2.5;
        } else if ([normalized hasPrefix:@"gpt-5.4"]) {
            creditMultiplier = 2.0;
        }
        apiMultiplier = creditMultiplier;
        tierLabel = [NSString stringWithFormat:@"Fast x%.1f", creditMultiplier];
    } else if ([tier isEqualToString:@"priority"]) {
        // Codex records the selected priority tier. Official API-equivalent pricing
        // for GPT-5.6 Priority processing is 2x Standard. Credit rates remain the
        // published base estimate because Priority and ChatGPT Fast are not identical.
        apiMultiplier = [normalized hasPrefix:@"gpt-5.6"] ? 2.0 : 1.0;
        tierLabel = apiMultiplier > 1.0 ? @"Priority · API x2" : @"Priority";
    }

    double credits = (((double)uncached / 1000000.0) * [creditRates[@"input"] doubleValue]
                    + ((double)safeCached / 1000000.0) * [creditRates[@"cachedInput"] doubleValue]
                    + ((double)safeOutput / 1000000.0) * [creditRates[@"output"] doubleValue])
                    * creditMultiplier;

    BOOL hasAPIPrice = [apiRates isKindOfClass:[NSDictionary class]];
    double apiCost = hasAPIPrice
        ? (((double)uncached / 1000000.0) * [apiRates[@"input"] doubleValue]
          + ((double)safeCached / 1000000.0) * [apiRates[@"cachedInput"] doubleValue]
          + ((double)safeOutput / 1000000.0) * [apiRates[@"output"] doubleValue]) * apiMultiplier
        : 0.0;

    return @{
        @"known": @YES,
        @"hasAPIPrice": @(hasAPIPrice),
        @"credits": @(credits),
        @"apiCost": @(apiCost),
        @"displayModel": rate[@"displayName"] ?: model ?: normalized,
        @"tierLabel": tierLabel,
        @"creditMultiplier": @(creditMultiplier),
        @"apiMultiplier": @(apiMultiplier)
    };
}

@end
