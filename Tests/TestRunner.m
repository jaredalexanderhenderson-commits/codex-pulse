#import <Foundation/Foundation.h>
#import "CPLogCollector.h"
#import "CPPricingEngine.h"

static int failures = 0;

static void Assert(BOOL condition, NSString *message) {
    if (condition) {
        NSLog(@"PASS: %@", message);
    } else {
        NSLog(@"FAIL: %@", message);
        failures++;
    }
}

static void AssertNear(double actual, double expected, double tolerance, NSString *message) {
    Assert(fabs(actual - expected) <= tolerance,
           [NSString stringWithFormat:@"%@ (actual %.8f, expected %.8f)", message, actual, expected]);
}

static NSDate *ISODate(NSString *value) {
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    return [formatter dateFromString:value];
}

static NSDictionary *RefreshSynchronously(CPLogCollector *collector) {
    __block NSDictionary *result = nil;
    [collector refreshWithCompletion:^(NSDictionary<NSString *,id> *snapshot) { result = snapshot; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
    while (!result && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return result;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            NSLog(@"Usage: TestRunner fixture-root pricing.json");
            return 2;
        }

        NSURL *fixtureRoot = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
        NSURL *pricingURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
        NSError *error = nil;
        CPPricingEngine *pricing = [[CPPricingEngine alloc] initWithPricingFileURL:pricingURL error:&error];
        Assert(pricing != nil && error == nil, @"Pricing table loads");

        NSDictionary *estimate = [pricing estimateForModel:@"gpt-5.6-sol"
                                               serviceTier:@"standard"
                                               inputTokens:1000000
                                              cachedTokens:500000
                                              outputTokens:100000];
        Assert([estimate[@"known"] boolValue], @"Known model is priced");
        AssertNear([estimate[@"credits"] doubleValue], 143.75, 0.000001, @"Credits exclude cached input from uncached input");
        AssertNear([estimate[@"apiCost"] doubleValue], 5.75, 0.000001, @"API-equivalent cost uses token-type rates");

        NSDictionary *unknown = [pricing estimateForModel:@"future-model"
                                              serviceTier:@"standard"
                                              inputTokens:1000
                                             cachedTokens:0
                                             outputTokens:100];
        Assert(![unknown[@"known"] boolValue], @"Unknown model remains unpriced");

        NSString *tempName = [NSString stringWithFormat:@"codex-pulse-tests-%@", NSUUID.UUID.UUIDString];
        NSURL *stateRoot = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:tempName isDirectory:YES];
        NSURL *stateURL = [stateRoot URLByAppendingPathComponent:@"usage-store.json"];
        CPLogCollector *collector = [[CPLogCollector alloc] initWithSessionRoots:@[fixtureRoot]
                                                                        stateURL:stateURL
                                                                   pricingEngine:pricing
                                                                             now:ISODate(@"2026-07-20T12:00:00.000Z")];
        NSDictionary *snapshot = RefreshSynchronously(collector);
        Assert(snapshot != nil, @"Collector refresh completes");
        NSDictionary *tracked = snapshot[@"periods"][@"tracked"];
        Assert([tracked[@"input"] longLongValue] == 1100, @"Seven-day import uses cumulative input deltas");
        Assert([tracked[@"cached"] longLongValue] == 300, @"Cached input deltas are preserved");
        Assert([tracked[@"output"] longLongValue] == 150, @"Output deltas are preserved");
        Assert([tracked[@"reasoning"] longLongValue] == 25, @"Reasoning remains an output subset");
        Assert([tracked[@"total"] longLongValue] == 1250, @"Pre-cutoff usage is excluded");
        Assert([tracked[@"eventCount"] longLongValue] == 2, @"Only post-cutoff model calls are counted");
        Assert([tracked[@"sessionCount"] longLongValue] == 1, @"Session aggregation is stable");
        AssertNear([tracked[@"credits"] doubleValue], 0.21625, 0.000001, @"Imported credit estimate is correct");
        AssertNear([tracked[@"apiCost"] doubleValue], 0.00865, 0.000001, @"Imported API-equivalent estimate is correct");
        AssertNear([snapshot[@"limit"][@"usedPercent"] doubleValue], 42.0, 0.000001, @"Latest weekly-limit value wins");

        NSDictionary *secondSnapshot = RefreshSynchronously(collector);
        NSDictionary *secondTracked = secondSnapshot[@"periods"][@"tracked"];
        Assert([secondTracked[@"eventCount"] longLongValue] == 2, @"A second refresh does not duplicate events");
        Assert([secondTracked[@"total"] longLongValue] == 1250, @"Checkpoint refresh preserves totals");

        [[NSFileManager defaultManager] removeItemAtURL:stateRoot error:nil];
        NSLog(@"%d failure(s)", failures);
    }
    return failures == 0 ? 0 : 1;
}
