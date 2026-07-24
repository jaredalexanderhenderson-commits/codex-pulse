#import <Foundation/Foundation.h>
#import "CPLogCollector.h"
#import "CPPricingEngine.h"
#import "CPUpdater.h"

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
        Assert([CPUpdater isVersion:@"1.4" newerThanVersion:@"1.3"], @"Updater recognizes a newer minor version");
        Assert([CPUpdater isVersion:@"1.10" newerThanVersion:@"1.9"], @"Updater compares numeric version components");
        Assert(![CPUpdater isVersion:@"1.4" newerThanVersion:@"1.4"], @"Updater ignores the installed version");
        Assert(![CPUpdater isVersion:@"1.3.9" newerThanVersion:@"1.4"], @"Updater rejects an older version");

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

        NSURL *boundedStateURL = [stateRoot URLByAppendingPathComponent:@"bounded-usage-store.json"];
        NSISO8601DateFormatter *eventFormatter = [NSISO8601DateFormatter new];
        eventFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        NSDate *eventStart = ISODate(@"2026-07-19T00:00:00.000Z");
        NSMutableArray *storedEvents = [NSMutableArray array];
        for (NSInteger index = 0; index < 25001; index++) {
            NSDate *timestamp = [eventStart dateByAddingTimeInterval:index];
            [storedEvents addObject:@{
                @"key": [NSString stringWithFormat:@"event-%ld", (long)index],
                @"timestamp": [eventFormatter stringFromDate:timestamp],
                @"sessionId": @"bounded-session",
                @"originator": @"Codex",
                @"model": @"gpt-5.6-terra",
                @"serviceTier": @"standard",
                @"tierLabel": @"standard",
                @"input": @1,
                @"cached": @0,
                @"output": @0,
                @"reasoning": @0,
                @"total": @1,
                @"credits": @0,
                @"apiCost": @0,
                @"pricingKnown": @YES
            }];
        }
        NSDictionary *oversizedState = @{
            @"version": @1,
            @"trackingStart": @"2026-07-01T00:00:00.000Z",
            @"events": storedEvents,
            @"checkpoints": @{},
            @"latestLimit": @{}
        };
        [[NSFileManager defaultManager] createDirectoryAtURL:stateRoot withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *oversizedData = [NSJSONSerialization dataWithJSONObject:oversizedState options:0 error:nil];
        [oversizedData writeToURL:boundedStateURL options:NSDataWritingAtomic error:nil];
        CPLogCollector *boundedCollector = [[CPLogCollector alloc] initWithSessionRoots:@[]
                                                                                stateURL:boundedStateURL
                                                                           pricingEngine:pricing
                                                                                     now:ISODate(@"2026-07-20T12:00:00.000Z")];
        NSDictionary *boundedSnapshot = RefreshSynchronously(boundedCollector);
        Assert([boundedSnapshot[@"health"][@"eventsTracked"] longLongValue] == 25000, @"Collector caps retained event history");
        NSDictionary *savedBoundedState = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:boundedStateURL] options:0 error:nil];
        Assert([savedBoundedState[@"events"] count] == 25000, @"Collector persists the compacted event history");

        [[NSFileManager defaultManager] removeItemAtURL:stateRoot error:nil];
        NSLog(@"%d failure(s)", failures);
    }
    return failures == 0 ? 0 : 1;
}
