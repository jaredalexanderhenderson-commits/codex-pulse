#import "CPUpdater.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *const CPReleaseAPIURL = @"https://api.github.com/repos/jaredalexanderhenderson-commits/codex-pulse/releases/latest";

@interface CPUpdater ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, assign) BOOL checking;
@end

@implementation CPUpdater

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 20.0;
        configuration.timeoutIntervalForResource = 180.0;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

+ (BOOL)isVersion:(NSString *)candidate newerThanVersion:(NSString *)current {
    if (!candidate.length || !current.length) { return NO; }
    return [candidate compare:current options:NSNumericSearch] == NSOrderedDescending;
}

- (void)checkForUpdatesUserInitiated:(BOOL)userInitiated {
    if (self.checking) { return; }
    self.checking = YES;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:CPReleaseAPIURL]];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [request setValue:@"Codex-Pulse-Updater" forHTTPHeaderField:@"User-Agent"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.checking = NO;
            [weakSelf handleReleaseData:data response:response error:error userInitiated:userInitiated];
        });
    }];
    [task resume];
}

- (void)handleReleaseData:(NSData *)data
                  response:(NSURLResponse *)response
                     error:(NSError *)error
             userInitiated:(BOOL)userInitiated {
    NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
    if (error || statusCode != 200 || !data.length) {
        if (userInitiated) {
            NSString *detail = statusCode == 404
                ? @"No Codex Pulse releases have been published yet."
                : (error.localizedDescription ?: @"GitHub did not return a valid release.");
            [self showMessage:@"Unable to check for updates" detail:detail];
        }
        return;
    }

    NSError *jsonError = nil;
    NSDictionary *release = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![release isKindOfClass:NSDictionary.class]) {
        if (userInitiated) { [self showMessage:@"Unable to check for updates" detail:jsonError.localizedDescription ?: @"The release response was invalid."]; }
        return;
    }

    NSString *tag = release[@"tag_name"];
    NSString *latestVersion = [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag;
    NSString *currentVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0";
    if (![CPUpdater isVersion:latestVersion newerThanVersion:currentVersion]) {
        if (userInitiated) {
            [self showMessage:@"Codex Pulse is up to date"
                       detail:[NSString stringWithFormat:@"You are running version %@.", currentVersion]];
        }
        return;
    }

    NSDictionary *archiveAsset = nil;
    for (NSDictionary *asset in release[@"assets"]) {
        NSString *name = asset[@"name"];
        if ([name isEqualToString:@"Codex-Pulse.zip"] ||
            [name isEqualToString:@"Codex Pulse.zip"] ||
            [name isEqualToString:@"Codex.Pulse.zip"]) {
            archiveAsset = asset;
            break;
        }
    }
    NSString *downloadString = archiveAsset[@"browser_download_url"];
    NSString *digest = archiveAsset[@"digest"];
    if (!downloadString.length || ![digest hasPrefix:@"sha256:"]) {
        [self showMessage:@"Update is not installable"
                   detail:@"The GitHub release is missing its signed archive or SHA-256 digest."];
        return;
    }

    NSString *notes = release[@"body"];
    if (notes.length > 1200) { notes = [[notes substringToIndex:1200] stringByAppendingString:@"\n…"]; }
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Codex Pulse %@ is available", latestVersion];
    alert.informativeText = notes.length ? notes : @"A new version is ready to install.";
    [alert addButtonWithTitle:@"Install Update"];
    [alert addButtonWithTitle:@"Later"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) { return; }

    [self downloadUpdate:[NSURL URLWithString:downloadString]
          expectedDigest:[digest substringFromIndex:@"sha256:".length]
                 version:latestVersion];
}

- (void)downloadUpdate:(NSURL *)downloadURL expectedDigest:(NSString *)expectedDigest version:(NSString *)version {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:downloadURL];
    [request setValue:@"Codex-Pulse-Updater" forHTTPHeaderField:@"User-Agent"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithRequest:request
                                                         completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error || !location) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf showMessage:@"Update download failed" detail:error.localizedDescription ?: @"The release archive could not be downloaded."];
            });
            return;
        }
        [weakSelf prepareDownloadedArchive:location expectedDigest:expectedDigest version:version];
    }];
    [task resume];
}

- (void)prepareDownloadedArchive:(NSURL *)location expectedDigest:(NSString *)expectedDigest version:(NSString *)version {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSURL *updateRoot = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:[NSString stringWithFormat:@"codex-pulse-update-%@", NSUUID.UUID.UUIDString]
                         isDirectory:YES];
    NSError *fileError = nil;
    [fileManager createDirectoryAtURL:updateRoot withIntermediateDirectories:YES attributes:nil error:&fileError];
    NSURL *archiveURL = [updateRoot URLByAppendingPathComponent:@"Codex-Pulse.zip"];
    if (!fileError && ![fileManager copyItemAtURL:location toURL:archiveURL error:&fileError]) { }
    if (fileError) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showMessage:@"Update preparation failed" detail:fileError.localizedDescription]; });
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *validationError = nil;
        NSString *actualDigest = [self SHA256ForFile:archiveURL error:&validationError];
        if (!actualDigest || [actualDigest caseInsensitiveCompare:expectedDigest] != NSOrderedSame) {
            validationError = [NSError errorWithDomain:@"CodexPulseUpdater" code:1
                                               userInfo:@{NSLocalizedDescriptionKey: @"The downloaded archive failed its SHA-256 integrity check."}];
        }

        NSURL *stagingURL = [updateRoot URLByAppendingPathComponent:@"staging" isDirectory:YES];
        if (!validationError) {
            [fileManager createDirectoryAtURL:stagingURL withIntermediateDirectories:YES attributes:nil error:&validationError];
        }
        if (!validationError && ![self runTool:@"/usr/bin/ditto" arguments:@[@"-x", @"-k", archiveURL.path, stagingURL.path]]) {
            validationError = [NSError errorWithDomain:@"CodexPulseUpdater" code:2
                                               userInfo:@{NSLocalizedDescriptionKey: @"The update archive could not be unpacked."}];
        }

        NSURL *stagedApp = [stagingURL URLByAppendingPathComponent:@"Codex Pulse.app" isDirectory:YES];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[stagedApp URLByAppendingPathComponent:@"Contents/Info.plist"]];
        if (!validationError && (![info[@"CFBundleIdentifier"] isEqualToString:@"com.jaredhenderson.codexpulse"] ||
                                 ![info[@"CFBundleShortVersionString"] isEqualToString:version])) {
            validationError = [NSError errorWithDomain:@"CodexPulseUpdater" code:3
                                               userInfo:@{NSLocalizedDescriptionKey: @"The downloaded app identity or version did not match the release."}];
        }
        if (!validationError && ![self runTool:@"/usr/bin/codesign" arguments:@[@"--verify", @"--deep", @"--strict", stagedApp.path]]) {
            validationError = [NSError errorWithDomain:@"CodexPulseUpdater" code:4
                                               userInfo:@{NSLocalizedDescriptionKey: @"The downloaded app failed code-signature verification."}];
        }

        if (validationError) {
            [fileManager removeItemAtURL:updateRoot error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ [self showMessage:@"Update verification failed" detail:validationError.localizedDescription]; });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self launchInstallerForApp:stagedApp updateRoot:updateRoot]; });
    });
}

- (NSString *)SHA256ForFile:(NSURL *)fileURL error:(NSError **)error {
    NSInputStream *stream = [NSInputStream inputStreamWithURL:fileURL];
    [stream open];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[64 * 1024];
    while (YES) {
        NSInteger count = [stream read:buffer maxLength:sizeof(buffer)];
        if (count < 0) {
            if (error) { *error = stream.streamError; }
            [stream close];
            return nil;
        }
        if (count == 0) { break; }
        if (count > 0) { CC_SHA256_Update(&context, buffer, (CC_LONG)count); }
    }
    [stream close];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) { [hex appendFormat:@"%02x", digest[index]]; }
    return hex;
}

- (BOOL)runTool:(NSString *)path arguments:(NSArray<NSString *> *)arguments {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) { return NO; }
    [task waitUntilExit];
    return task.terminationStatus == 0;
}

- (void)launchInstallerForApp:(NSURL *)stagedApp updateRoot:(NSURL *)updateRoot {
    NSURL *installerURL = [NSBundle.mainBundle URLForResource:@"install_update" withExtension:@"sh"];
    if (!installerURL) {
        [self showMessage:@"Update installation failed" detail:@"The installer helper is missing from this build."];
        return;
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/zsh"];
    task.arguments = @[installerURL.path, stagedApp.path, NSBundle.mainBundle.bundlePath,
                       [NSString stringWithFormat:@"%d", NSProcessInfo.processInfo.processIdentifier], updateRoot.path];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        [self showMessage:@"Update installation failed" detail:error.localizedDescription];
        return;
    }
    [NSApp terminate:nil];
}

- (void)showMessage:(NSString *)message detail:(NSString *)detail {
    NSAlert *alert = [NSAlert new];
    alert.messageText = message;
    alert.informativeText = detail ?: @"";
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

@end
