#import "CPLogCollector.h"
#import "CPPricingEngine.h"

static long long CPLongLong(id value) {
    return [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : 0;
}

static double CPDouble(id value) {
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
}

static NSString *CPJSONStringValue(NSString *line, NSString *key) {
    NSString *needle = [NSString stringWithFormat:@"\"%@\"", key];
    NSRange keyRange = [line rangeOfString:needle];
    if (keyRange.location == NSNotFound) { return nil; }

    NSUInteger cursor = NSMaxRange(keyRange);
    while (cursor < line.length && [line characterAtIndex:cursor] != ':') { cursor++; }
    if (cursor >= line.length) { return nil; }
    cursor++;
    while (cursor < line.length && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[line characterAtIndex:cursor]]) { cursor++; }
    if (cursor >= line.length || [line characterAtIndex:cursor] != '"') { return nil; }

    NSUInteger start = cursor;
    cursor++;
    BOOL escaped = NO;
    while (cursor < line.length) {
        unichar character = [line characterAtIndex:cursor];
        if (!escaped && character == '"') {
            NSString *quoted = [line substringWithRange:NSMakeRange(start, cursor - start + 1)];
            NSData *data = [quoted dataUsingEncoding:NSUTF8StringEncoding];
            return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
        }
        if (!escaped && character == '\\') {
            escaped = YES;
        } else {
            escaped = NO;
        }
        cursor++;
    }
    return nil;
}

@interface CPLogCollector ()
@property (nonatomic, copy) NSArray<NSURL *> *sessionRoots;
@property (nonatomic, strong) NSURL *stateURL;
@property (nonatomic, strong) CPPricingEngine *pricingEngine;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *events;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *checkpoints;
@property (nonatomic, strong) NSMutableSet<NSString *> *eventKeys;
@property (nonatomic, strong, nullable) NSMutableDictionary *latestLimit;
@property (nonatomic, strong) NSDate *trackingStart;
@property (nonatomic, strong, nullable) NSDate *fixedNow;
@property (nonatomic, strong) NSISO8601DateFormatter *fractionalFormatter;
@property (nonatomic, strong) NSISO8601DateFormatter *plainFormatter;
@property (nonatomic, strong) NSDictionary *cachedSnapshot;
@end

@implementation CPLogCollector

- (instancetype)initWithSessionRoots:(NSArray<NSURL *> *)sessionRoots
                             stateURL:(NSURL *)stateURL
                        pricingEngine:(CPPricingEngine *)pricingEngine
                                  now:(NSDate *)fixedNow {
    self = [super init];
    if (!self) { return nil; }

    _sessionRoots = [sessionRoots copy];
    _stateURL = stateURL;
    _pricingEngine = pricingEngine;
    _fixedNow = fixedNow;
    _queue = dispatch_queue_create("com.codexpulse.collector", DISPATCH_QUEUE_SERIAL);
    _events = [NSMutableArray array];
    _checkpoints = [NSMutableDictionary dictionary];
    _eventKeys = [NSMutableSet set];

    _fractionalFormatter = [NSISO8601DateFormatter new];
    _fractionalFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    _plainFormatter = [NSISO8601DateFormatter new];
    _plainFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;

    [self loadState];
    _cachedSnapshot = [self buildSnapshot];
    return self;
}

- (NSDate *)now {
    return self.fixedNow ?: [NSDate date];
}

- (NSDate *)dateFromISO:(NSString *)value {
    if (![value isKindOfClass:[NSString class]]) { return nil; }
    return [self.fractionalFormatter dateFromString:value] ?: [self.plainFormatter dateFromString:value];
}

- (NSString *)isoFromDate:(NSDate *)date {
    return [self.fractionalFormatter stringFromDate:date];
}

- (void)loadState {
    NSData *data = [NSData dataWithContentsOfURL:self.stateURL];
    NSDictionary *state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;

    NSString *trackingStartString = [state[@"trackingStart"] isKindOfClass:[NSString class]] ? state[@"trackingStart"] : nil;
    self.trackingStart = [self dateFromISO:trackingStartString] ?: [[self now] dateByAddingTimeInterval:-(7.0 * 24.0 * 60.0 * 60.0)];

    NSArray *storedEvents = [state[@"events"] isKindOfClass:[NSArray class]] ? state[@"events"] : @[];
    for (NSDictionary *event in storedEvents) {
        if (![event isKindOfClass:[NSDictionary class]]) { continue; }
        NSMutableDictionary *mutableEvent = [event mutableCopy];
        [self.events addObject:mutableEvent];
        NSString *key = mutableEvent[@"key"];
        if (key.length) { [self.eventKeys addObject:key]; }
    }

    NSDictionary *storedCheckpoints = [state[@"checkpoints"] isKindOfClass:[NSDictionary class]] ? state[@"checkpoints"] : @{};
    [storedCheckpoints enumerateKeysAndObjectsUsingBlock:^(NSString *path, NSDictionary *checkpoint, BOOL *stop) {
        if ([path isKindOfClass:[NSString class]] && [checkpoint isKindOfClass:[NSDictionary class]]) {
            self.checkpoints[path] = [checkpoint mutableCopy];
        }
    }];

    if ([state[@"latestLimit"] isKindOfClass:[NSDictionary class]]) {
        self.latestLimit = [state[@"latestLimit"] mutableCopy];
    }
}

- (void)saveState {
    NSDictionary *state = @{
        @"version": @1,
        @"trackingStart": [self isoFromDate:self.trackingStart],
        @"events": self.events,
        @"checkpoints": self.checkpoints,
        @"latestLimit": self.latestLimit ?: @{}
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    if (!data) { return; }
    [[NSFileManager defaultManager] createDirectoryAtURL:self.stateURL.URLByDeletingLastPathComponent
                             withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToURL:self.stateURL options:NSDataWritingAtomic error:nil];
}

- (BOOL)isEligibleOriginator:(NSString *)originator {
    NSString *normalized = originator.lowercaseString;
    if (![normalized containsString:@"codex"]) { return NO; }
    if ([normalized containsString:@"daemon"] || [normalized containsString:@"zilix"]) { return NO; }
    return YES;
}

- (void)refreshWithCompletion:(CPCollectorCompletion)completion {
    dispatch_async(self.queue, ^{
        [self scanRoots];
        [self saveState];
        self.cachedSnapshot = [self buildSnapshot];
        NSDictionary *snapshot = self.cachedSnapshot;
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(snapshot); });
        }
    });
}

- (void)resetAndReimportWithCompletion:(CPCollectorCompletion)completion {
    dispatch_async(self.queue, ^{
        [self.events removeAllObjects];
        [self.checkpoints removeAllObjects];
        [self.eventKeys removeAllObjects];
        self.latestLimit = nil;
        self.trackingStart = [[self now] dateByAddingTimeInterval:-(7.0 * 24.0 * 60.0 * 60.0)];
        [self scanRoots];
        [self saveState];
        self.cachedSnapshot = [self buildSnapshot];
        NSDictionary *snapshot = self.cachedSnapshot;
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(snapshot); });
        }
    });
}

- (NSDictionary<NSString *,id> *)currentSnapshot {
    __block NSDictionary *snapshot;
    dispatch_sync(self.queue, ^{ snapshot = self.cachedSnapshot ?: [self buildSnapshot]; });
    return snapshot;
}

- (void)scanRoots {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *keys = @[NSURLContentModificationDateKey, NSURLFileSizeKey, NSURLIsRegularFileKey];

    for (NSURL *root in self.sessionRoots) {
        NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtURL:root
                                              includingPropertiesForKeys:keys
                                                                 options:NSDirectoryEnumerationSkipsHiddenFiles
                                                            errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
        for (NSURL *fileURL in enumerator) {
            if (![fileURL.pathExtension.lowercaseString isEqualToString:@"jsonl"]) { continue; }
            NSDictionary *values = [fileURL resourceValuesForKeys:keys error:nil];
            if (![values[NSURLIsRegularFileKey] boolValue]) { continue; }

            NSString *path = fileURL.path;
            unsigned long long fileSize = [values[NSURLFileSizeKey] unsignedLongLongValue];
            NSDate *modified = values[NSURLContentModificationDateKey];
            NSMutableDictionary *checkpoint = [self.checkpoints[path] mutableCopy];

            if (!checkpoint && modified && [modified compare:self.trackingStart] == NSOrderedAscending) { continue; }
            if (checkpoint && [checkpoint[@"offset"] unsignedLongLongValue] == fileSize) { continue; }

            [self processFileURL:fileURL size:fileSize checkpoint:checkpoint ?: [NSMutableDictionary dictionary]];
        }
    }
}

- (void)processFileURL:(NSURL *)fileURL
                  size:(unsigned long long)fileSize
            checkpoint:(NSMutableDictionary *)checkpoint {
    unsigned long long offset = [checkpoint[@"offset"] unsignedLongLongValue];
    if (offset > fileSize) { offset = 0; }

    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:fileURL error:nil];
    if (!handle) { return; }
    @try { [handle seekToFileOffset:offset]; } @catch (__unused NSException *exception) { [handle closeFile]; return; }

    NSMutableData *buffer = [NSMutableData data];
    NSData *newline = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
    unsigned long long processedOffset = offset;

    while (YES) {
        NSData *chunk = [handle readDataOfLength:64 * 1024];
        if (chunk.length == 0) { break; }
        [buffer appendData:chunk];

        NSUInteger consumed = 0;
        while (consumed < buffer.length) {
            NSRange searchRange = NSMakeRange(consumed, buffer.length - consumed);
            NSRange lineBreak = [buffer rangeOfData:newline options:0 range:searchRange];
            if (lineBreak.location == NSNotFound) { break; }
            NSRange lineRange = NSMakeRange(consumed, lineBreak.location - consumed);
            NSData *lineData = [buffer subdataWithRange:lineRange];
            [self processLineData:lineData checkpoint:checkpoint sourcePath:fileURL.path];
            NSUInteger lineBytes = lineRange.length + 1;
            processedOffset += lineBytes;
            consumed = lineBreak.location + 1;
        }

        if (consumed > 0) {
            NSData *remainder = [buffer subdataWithRange:NSMakeRange(consumed, buffer.length - consumed)];
            buffer = [remainder mutableCopy];
        }
    }

    [handle closeFile];
    checkpoint[@"offset"] = @(processedOffset);
    self.checkpoints[fileURL.path] = checkpoint;
}

- (void)processLineData:(NSData *)lineData
             checkpoint:(NSMutableDictionary *)checkpoint
              sourcePath:(NSString *)sourcePath {
    if (lineData.length < 8) { return; }
    NSUInteger prefixLength = MIN((NSUInteger)4096, lineData.length);
    NSString *prefix = [[NSString alloc] initWithData:[lineData subdataWithRange:NSMakeRange(0, prefixLength)]
                                            encoding:NSUTF8StringEncoding];
    if (!prefix.length) { return; }

    BOOL sessionMeta = [prefix containsString:@"session_meta"];
    BOOL turnContext = [prefix containsString:@"turn_context"];
    BOOL tokenCount = [prefix containsString:@"token_count"];
    BOOL threadSettings = [prefix containsString:@"thread_settings_applied"];
    if (!sessionMeta && !turnContext && !tokenCount && !threadSettings) { return; }

    if (sessionMeta || turnContext || threadSettings) {
        NSString *line = lineData.length == prefixLength
            ? prefix
            : [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (!line.length) { return; }

        if (sessionMeta) {
            NSString *sessionID = CPJSONStringValue(line, @"id");
            NSString *originator = CPJSONStringValue(line, @"originator");
            NSString *cwd = CPJSONStringValue(line, @"cwd");
            if (sessionID.length) { checkpoint[@"sessionId"] = sessionID; }
            if (originator.length) {
                checkpoint[@"originator"] = originator;
                checkpoint[@"eligible"] = @([self isEligibleOriginator:originator]);
            }
            if (cwd.length) { checkpoint[@"cwd"] = cwd; }
        }
        if (turnContext || threadSettings) {
            NSString *model = CPJSONStringValue(line, @"model");
            NSString *cwd = CPJSONStringValue(line, @"cwd");
            NSString *tier = threadSettings ? CPJSONStringValue(line, @"service_tier") : nil;
            if (model.length) { checkpoint[@"model"] = model; }
            if (cwd.length) { checkpoint[@"cwd"] = cwd; }
            if (tier.length) { checkpoint[@"serviceTier"] = tier; }
        }
        if (!tokenCount) { return; }
    }

    if (!tokenCount) { return; }
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) { return; }
    NSDictionary *payload = [root[@"payload"] isKindOfClass:[NSDictionary class]] ? root[@"payload"] : @{};
    if (![payload[@"type"] isEqual:@"token_count"]) { return; }

    NSString *timestamp = [root[@"timestamp"] isKindOfClass:[NSString class]] ? root[@"timestamp"] : @"";
    NSDate *eventDate = [self dateFromISO:timestamp];
    NSDictionary *info = [payload[@"info"] isKindOfClass:[NSDictionary class]] ? payload[@"info"] : @{};
    NSDictionary *total = [info[@"total_token_usage"] isKindOfClass:[NSDictionary class]] ? info[@"total_token_usage"] : @{};
    NSDictionary *last = [info[@"last_token_usage"] isKindOfClass:[NSDictionary class]] ? info[@"last_token_usage"] : @{};

    long long currentInput = CPLongLong(total[@"input_tokens"]);
    long long currentCached = CPLongLong(total[@"cached_input_tokens"]);
    long long currentOutput = CPLongLong(total[@"output_tokens"]);
    long long currentReasoning = CPLongLong(total[@"reasoning_output_tokens"]);
    long long currentTotal = CPLongLong(total[@"total_tokens"]);

    BOOL hasPrevious = checkpoint[@"lastTotal"] != nil;
    long long previousInput = CPLongLong(checkpoint[@"lastInput"]);
    long long previousCached = CPLongLong(checkpoint[@"lastCached"]);
    long long previousOutput = CPLongLong(checkpoint[@"lastOutput"]);
    long long previousReasoning = CPLongLong(checkpoint[@"lastReasoning"]);
    long long previousTotal = CPLongLong(checkpoint[@"lastTotal"]);
    BOOL monotonic = hasPrevious
        && currentInput >= previousInput
        && currentCached >= previousCached
        && currentOutput >= previousOutput
        && currentReasoning >= previousReasoning
        && currentTotal >= previousTotal;

    long long deltaInput = monotonic ? currentInput - previousInput : CPLongLong(last[@"input_tokens"]);
    long long deltaCached = monotonic ? currentCached - previousCached : CPLongLong(last[@"cached_input_tokens"]);
    long long deltaOutput = monotonic ? currentOutput - previousOutput : CPLongLong(last[@"output_tokens"]);
    long long deltaReasoning = monotonic ? currentReasoning - previousReasoning : CPLongLong(last[@"reasoning_output_tokens"]);
    long long deltaTotal = monotonic ? currentTotal - previousTotal : CPLongLong(last[@"total_tokens"]);

    checkpoint[@"lastInput"] = @(currentInput);
    checkpoint[@"lastCached"] = @(currentCached);
    checkpoint[@"lastOutput"] = @(currentOutput);
    checkpoint[@"lastReasoning"] = @(currentReasoning);
    checkpoint[@"lastTotal"] = @(currentTotal);

    BOOL eligible = [checkpoint[@"eligible"] boolValue];
    if (eligible) { [self captureLatestLimitFromPayload:payload timestamp:timestamp]; }
    if (!eligible || !eventDate || [eventDate compare:self.trackingStart] == NSOrderedAscending || deltaTotal <= 0) { return; }

    NSString *sessionID = checkpoint[@"sessionId"] ?: sourcePath.lastPathComponent;
    NSString *eventKey = [NSString stringWithFormat:@"%@|%@|%lld", sessionID, timestamp, currentTotal];
    if ([self.eventKeys containsObject:eventKey]) { return; }

    NSString *model = checkpoint[@"model"] ?: @"Unknown model";
    NSString *serviceTier = checkpoint[@"serviceTier"] ?: @"standard";
    NSDictionary *estimate = [self.pricingEngine estimateForModel:model
                                                       serviceTier:serviceTier
                                                       inputTokens:deltaInput
                                                      cachedTokens:deltaCached
                                                      outputTokens:deltaOutput];
    NSMutableDictionary *event = [@{
        @"key": eventKey,
        @"timestamp": timestamp,
        @"sessionId": sessionID,
        @"originator": checkpoint[@"originator"] ?: @"Codex",
        @"cwd": checkpoint[@"cwd"] ?: @"",
        @"model": model,
        @"serviceTier": serviceTier,
        @"tierLabel": estimate[@"tierLabel"] ?: serviceTier,
        @"input": @(MAX(0, deltaInput)),
        @"cached": @(MAX(0, deltaCached)),
        @"output": @(MAX(0, deltaOutput)),
        @"reasoning": @(MAX(0, deltaReasoning)),
        @"total": @(MAX(0, deltaTotal)),
        @"credits": estimate[@"credits"] ?: @0,
        @"apiCost": estimate[@"apiCost"] ?: @0,
        @"pricingKnown": estimate[@"known"] ?: @NO
    } mutableCopy];

    [self.events addObject:event];
    [self.eventKeys addObject:eventKey];
}

- (void)captureLatestLimitFromPayload:(NSDictionary *)payload timestamp:(NSString *)timestamp {
    NSDictionary *limits = [payload[@"rate_limits"] isKindOfClass:[NSDictionary class]] ? payload[@"rate_limits"] : nil;
    NSDictionary *primary = [limits[@"primary"] isKindOfClass:[NSDictionary class]] ? limits[@"primary"] : nil;
    if (!limits || !primary) { return; }

    NSDate *candidate = [self dateFromISO:timestamp];
    NSDate *existing = [self dateFromISO:self.latestLimit[@"timestamp"]];
    if (existing && candidate && [candidate compare:existing] != NSOrderedDescending) { return; }

    NSDictionary *credits = [limits[@"credits"] isKindOfClass:[NSDictionary class]] ? limits[@"credits"] : @{};
    self.latestLimit = [@{
        @"timestamp": timestamp ?: @"",
        @"usedPercent": primary[@"used_percent"] ?: @0,
        @"windowMinutes": primary[@"window_minutes"] ?: @0,
        @"resetsAt": primary[@"resets_at"] ?: @0,
        @"planType": limits[@"plan_type"] ?: @"unknown",
        @"hasCredits": credits[@"has_credits"] ?: @NO,
        @"creditBalance": credits[@"balance"] ?: @"0"
    } mutableCopy];
}

- (NSMutableDictionary *)emptyAggregate {
    return [@{
        @"input": @0LL, @"cached": @0LL, @"output": @0LL, @"reasoning": @0LL,
        @"total": @0LL, @"credits": @0.0, @"apiCost": @0.0,
        @"knownTokens": @0LL, @"eventCount": @0LL
    } mutableCopy];
}

- (void)addEvent:(NSDictionary *)event toAggregate:(NSMutableDictionary *)aggregate {
    for (NSString *key in @[@"input", @"cached", @"output", @"reasoning", @"total"]) {
        aggregate[key] = @(CPLongLong(aggregate[key]) + CPLongLong(event[key]));
    }
    aggregate[@"credits"] = @(CPDouble(aggregate[@"credits"]) + CPDouble(event[@"credits"]));
    aggregate[@"apiCost"] = @(CPDouble(aggregate[@"apiCost"]) + CPDouble(event[@"apiCost"]));
    aggregate[@"eventCount"] = @(CPLongLong(aggregate[@"eventCount"]) + 1);
    if ([event[@"pricingKnown"] boolValue]) {
        aggregate[@"knownTokens"] = @(CPLongLong(aggregate[@"knownTokens"]) + CPLongLong(event[@"total"]));
    }
}

- (NSDictionary *)aggregateSince:(NSDate *)cutoff {
    NSMutableDictionary *aggregate = [self emptyAggregate];
    NSMutableSet *sessions = [NSMutableSet set];
    for (NSDictionary *event in self.events) {
        NSDate *date = [self dateFromISO:event[@"timestamp"]];
        if (cutoff && (!date || [date compare:cutoff] == NSOrderedAscending)) { continue; }
        [self addEvent:event toAggregate:aggregate];
        if (event[@"sessionId"]) { [sessions addObject:event[@"sessionId"]]; }
    }
    long long total = CPLongLong(aggregate[@"total"]);
    aggregate[@"sessionCount"] = @(sessions.count);
    aggregate[@"pricingCoverage"] = @(total > 0 ? (100.0 * CPLongLong(aggregate[@"knownTokens"]) / (double)total) : 100.0);
    return aggregate;
}

- (NSArray *)dailySeriesFrom:(NSDate *)start now:(NSDate *)now {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd";

    NSMutableDictionary<NSString *, NSMutableDictionary *> *buckets = [NSMutableDictionary dictionary];
    for (NSInteger day = 0; day < 7; day++) {
        NSDate *date = [calendar dateByAddingUnit:NSCalendarUnitDay value:day toDate:start options:0];
        NSString *key = [formatter stringFromDate:date];
        NSMutableDictionary *bucket = [self emptyAggregate];
        bucket[@"date"] = key;
        buckets[key] = bucket;
    }

    for (NSDictionary *event in self.events) {
        NSDate *date = [self dateFromISO:event[@"timestamp"]];
        if (!date || [date compare:start] == NSOrderedAscending) { continue; }
        NSString *key = [formatter stringFromDate:date];
        NSMutableDictionary *bucket = buckets[key];
        if (bucket) { [self addEvent:event toAggregate:bucket]; }
    }

    NSArray *keys = [[buckets allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *key in keys) { [result addObject:buckets[key]]; }
    return result;
}

- (NSArray *)groupedTotalsForKey:(NSString *)groupKey limit:(NSUInteger)limit {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    for (NSDictionary *event in self.events) {
        NSString *name = [event[groupKey] isKindOfClass:[NSString class]] && [event[groupKey] length] ? event[groupKey] : @"Unknown";
        NSMutableDictionary *aggregate = groups[name];
        if (!aggregate) {
            aggregate = [self emptyAggregate];
            aggregate[@"name"] = name;
            groups[name] = aggregate;
        }
        [self addEvent:event toAggregate:aggregate];
    }
    NSArray *sorted = [[groups allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [right[@"total"] compare:left[@"total"]];
    }];
    return sorted.count > limit ? [sorted subarrayWithRange:NSMakeRange(0, limit)] : sorted;
}

- (NSArray *)recentSessions {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *sessions = [NSMutableDictionary dictionary];
    for (NSDictionary *event in self.events) {
        NSString *sessionID = event[@"sessionId"] ?: @"unknown";
        NSMutableDictionary *entry = sessions[sessionID];
        if (!entry) {
            NSString *cwd = event[@"cwd"] ?: @"";
            NSString *project = cwd.length ? cwd.lastPathComponent : @"Codex session";
            entry = [@{
                @"sessionId": sessionID,
                @"project": project.length ? project : @"Codex session",
                @"originator": event[@"originator"] ?: @"Codex",
                @"model": event[@"model"] ?: @"Unknown model",
                @"tierLabel": event[@"tierLabel"] ?: event[@"serviceTier"] ?: @"standard",
                @"total": @0LL,
                @"credits": @0.0,
                @"lastTimestamp": event[@"timestamp"] ?: @""
            } mutableCopy];
            sessions[sessionID] = entry;
        }
        entry[@"total"] = @(CPLongLong(entry[@"total"]) + CPLongLong(event[@"total"]));
        entry[@"credits"] = @(CPDouble(entry[@"credits"]) + CPDouble(event[@"credits"]));
        NSString *timestamp = event[@"timestamp"] ?: @"";
        if ([timestamp compare:entry[@"lastTimestamp"]] == NSOrderedDescending) {
            entry[@"lastTimestamp"] = timestamp;
            entry[@"model"] = event[@"model"] ?: entry[@"model"];
            entry[@"tierLabel"] = event[@"tierLabel"] ?: entry[@"tierLabel"];
        }
    }
    NSArray *sorted = [[sessions allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [right[@"lastTimestamp"] compare:left[@"lastTimestamp"]];
    }];
    return sorted.count > 8 ? [sorted subarrayWithRange:NSMakeRange(0, 8)] : sorted;
}

- (NSDictionary *)buildSnapshot {
    NSDate *now = [self now];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *todayStart = [calendar startOfDayForDate:now];
    NSDate *weekStart = [now dateByAddingTimeInterval:-(7.0 * 24.0 * 60.0 * 60.0)];
    NSDate *chartStart = [calendar dateByAddingUnit:NSCalendarUnitDay value:-6 toDate:todayStart options:0];

    NSDictionary *tracked = [self aggregateSince:self.trackingStart];
    NSDictionary *week = [self aggregateSince:weekStart];
    NSDictionary *today = [self aggregateSince:todayStart];

    NSString *lastEvent = @"";
    for (NSDictionary *event in self.events) {
        NSString *timestamp = event[@"timestamp"] ?: @"";
        if ([timestamp compare:lastEvent] == NSOrderedDescending) { lastEvent = timestamp; }
    }

    return @{
        @"generatedAt": [self isoFromDate:now],
        @"trackingStart": [self isoFromDate:self.trackingStart],
        @"periods": @{ @"tracked": tracked, @"week": week, @"today": today },
        @"daily": [self dailySeriesFrom:chartStart now:now],
        @"models": [self groupedTotalsForKey:@"model" limit:6],
        @"origins": [self groupedTotalsForKey:@"originator" limit:6],
        @"sessions": [self recentSessions],
        @"limit": self.latestLimit ?: @{},
        @"health": @{
            @"filesTracked": @(self.checkpoints.count),
            @"eventsTracked": @(self.events.count),
            @"lastEventAt": lastEvent,
            @"pricingPublished": self.pricingEngine.publishedDate ?: @"Unknown",
            @"pricingSource": self.pricingEngine.sourceURL ?: @"",
            @"privacyMode": @"metadata-only"
        }
    };
}

@end
