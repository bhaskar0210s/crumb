// Updates from the project's GitHub releases: checks once a day; a newer release is downloaded, checked
// against the release key's signature, unpacked, swapped in and restarted. curl, ditto and codesign do the
// heavy lifting in their own processes, so no networking code ever loads into Crumb itself.

#import "app.h"

#include <cerrno>
#include <cstdio>
#include <stdio.h>

#include "../core/version.hpp"

namespace {

NSString* const kLastCheckKey = @"lastUpdateCheck";
NSString* const kAsset = @"Crumb.zip";
constexpr NSTimeInterval kCheckInterval = 24 * 60 * 60;

enum class Result { UpToDate, Installed, Failed };

// Whether this Mac's macOS is new enough for a bundle (its LSMinimumSystemVersion).
bool runsHere(NSDictionary* info) {
    NSString* minimum = info[@"LSMinimumSystemVersion"];
    if (![minimum isKindOfClass:NSString.class]) return true;
    NSArray<NSString*>* parts = [minimum componentsSeparatedByString:@"."];
    const NSOperatingSystemVersion version = {
        parts.count > 0 ? parts[0].integerValue : 0,
        parts.count > 1 ? parts[1].integerValue : 0,
        parts.count > 2 ? parts[2].integerValue : 0,
    };
    return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:version];
}

NSData* run(NSString* tool, NSArray<NSString*>* arguments, int* status) {
    NSTask* task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = arguments;
    NSPipe* output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    *status = -1;
    if (![task launchAndReturnError:nil]) return nil;
    NSData* data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    *status = task.terminationStatus;
    return data;
}

// True when `signature` is the release key's ECDSA P-256 signature (DER, SHA-256) of `data`.
bool signedByRelease(NSData* data, NSData* signature, NSString* publicKey) {
    NSData* raw = publicKey ? [[NSData alloc] initWithBase64EncodedString:publicKey options:0] : nil;
    if (raw.length != 65 || signature.length == 0) return false;
    NSDictionary* attributes = @{
        (id)kSecAttrKeyType : (id)kSecAttrKeyTypeECSECPrimeRandom,
        (id)kSecAttrKeyClass : (id)kSecAttrKeyClassPublic,
        (id)kSecAttrKeySizeInBits : @256,
    };
    SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)raw, (__bridge CFDictionaryRef)attributes, nullptr);
    if (!key) return false;
    const bool ok = SecKeyVerifySignature(key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, (__bridge CFDataRef)data,
                                          (__bridge CFDataRef)signature, nullptr);
    CFRelease(key);
    return ok;
}

struct Source {
    NSString* api;           // the latest-release URL
    NSString* publicKey;     // base64 of the release key
    bool httpsOnly = true;   // tests point Crumb at local files
};

Result update(const Source& source, NSString* current, NSString* bundlePath, NSString* identifier, NSString** message) {
    NSArray<NSString*>* secure = source.httpsOnly ? @[ @"--proto", @"=https", @"--proto-redir", @"=https" ] : @[];
    int status = 0;
    NSData* json = run(@"/usr/bin/curl",
                       [secure arrayByAddingObjectsFromArray:@[ @"-fsSL", @"--max-time", @"20", @"-H",
                                                                @"Accept: application/vnd.github+json", @"-A", @"Crumb", source.api ]],
                       &status);
    NSDictionary* release = status == 0 && json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    NSString* tag = [release isKindOfClass:NSDictionary.class] ? release[@"tag_name"] : nil;
    if (![tag isKindOfClass:NSString.class]) {
        *message = @"Couldn't check for updates.";
        return Result::Failed;
    }
    if (!crumb::isNewerVersion(tag.UTF8String, current.UTF8String)) {
        *message = @"Crumb is up to date.";
        return Result::UpToDate;
    }
    NSString *download = nil, *signatureURL = nil;
    NSArray* assets = release[@"assets"];
    if ([assets isKindOfClass:NSArray.class]) {
        for (NSDictionary* asset in assets) {
            if (![asset isKindOfClass:NSDictionary.class]) continue;
            if ([asset[@"name"] isEqual:kAsset]) download = asset[@"browser_download_url"];
            if ([asset[@"name"] isEqual:[kAsset stringByAppendingString:@".sig"]]) signatureURL = asset[@"browser_download_url"];
        }
    }
    if (![download isKindOfClass:NSString.class] || ![signatureURL isKindOfClass:NSString.class]) {
        *message = @"The new version has no download yet.";
        return Result::Failed;
    }

    // Work in a private folder on the app's own volume, so the final swap is a single rename.
    NSFileManager* files = NSFileManager.defaultManager;
    NSURL* scratch = [files URLForDirectory:NSItemReplacementDirectory
                                   inDomain:NSUserDomainMask
                          appropriateForURL:[NSURL fileURLWithPath:bundlePath]
                                     create:YES
                                      error:nil];
    if (!scratch) {
        *message = @"Crumb can't update itself in this folder.";
        return Result::Failed;
    }
    NSString* folder = scratch.path;
    auto fail = [&](NSString* text) {
        [files removeItemAtPath:folder error:nil];
        *message = text;
        return Result::Failed;
    };
    NSString* zip = [folder stringByAppendingPathComponent:@"Crumb.zip"];
    NSString* signature = [folder stringByAppendingPathComponent:@"Crumb.zip.sig"];
    NSString* unpacked = [folder stringByAppendingPathComponent:@"new"];
    NSArray* fetch = [secure arrayByAddingObjectsFromArray:@[ @"-fsSL", @"--max-time", @"600", @"-A", @"Crumb", @"-o" ]];
    run(@"/usr/bin/curl", [fetch arrayByAddingObjectsFromArray:@[ zip, download ]], &status);
    if (status != 0) return fail(@"Couldn't download the update.");
    run(@"/usr/bin/curl", [fetch arrayByAddingObjectsFromArray:@[ signature, signatureURL ]], &status);
    NSData* archive = [NSData dataWithContentsOfFile:zip options:NSDataReadingMappedIfSafe error:nil];
    if (status != 0 || !signedByRelease(archive, [NSData dataWithContentsOfFile:signature], source.publicKey))
        return fail(@"The download isn't signed by Crumb's release key.");

    run(@"/usr/bin/ditto", @[ @"-x", @"-k", zip, unpacked ], &status);
    NSString* app = [unpacked stringByAppendingPathComponent:@"Crumb.app"];
    NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString* version = info[@"CFBundleShortVersionString"];
    if (status != 0 || ![info[@"CFBundleIdentifier"] isEqual:identifier] || ![version isKindOfClass:NSString.class] ||
        !crumb::isNewerVersion(version.UTF8String, current.UTF8String))
        return fail(@"The download isn't a newer Crumb.");
    if (!runsHere(info)) return fail([NSString stringWithFormat:@"Crumb %@ needs a newer version of macOS.", version]);
    run(@"/usr/bin/codesign", @[ @"--verify", @"--deep", @"--strict", app ], &status);
    if (status != 0) return fail(@"The download is damaged.");

    // Swap the old and new bundles in one step; the running copy keeps working from memory until the restart.
    if (renamex_np(app.fileSystemRepresentation, bundlePath.fileSystemRepresentation, RENAME_SWAP) != 0)
        return fail(@"Crumb can't replace itself in this folder.");
    [files removeItemAtPath:folder error:nil];
    *message = [NSString stringWithFormat:@"Updated to %@. Restarting…", version];
    return Result::Installed;
}

}  // namespace

@implementation CRUpdater {
    __weak CRPopup* _popup;
    NSString* _api;
    NSString* _publicKey;
    BOOL _localTest;
    NSTimer* _timer;
    BOOL _busy;
}

- (instancetype)initWithPopup:(CRPopup*)popup {
    if ((self = [super init])) {
        _popup = popup;
        NSBundle* bundle = NSBundle.mainBundle;
        NSString* override = NSProcessInfo.processInfo.environment[@"CRUMB_UPDATE_URL"];
        NSString* repository = [bundle objectForInfoDictionaryKey:@"CrumbRepository"];
        NSString* key = [bundle objectForInfoDictionaryKey:@"CrumbUpdateKey"];
        _publicKey = [key isKindOfClass:NSString.class] && key.length ? key : nil;
        if (override.length) {
            _api = override;  // for tests: a local release, still checked against the release key
            _localTest = YES;
        } else if ([repository isKindOfClass:NSString.class] && [repository componentsSeparatedByString:@"/"].count == 2) {
            _api = [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", repository];
        }
        if (!_publicKey) _api = nil;  // a build without the release key can't trust any download
    }
    return self;
}

- (BOOL)available {
    return _api != nil;
}

- (void)start {
    if (!_api) return;
    __weak CRUpdater* weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:6 * 60 * 60
                                             repeats:YES
                                               block:^(NSTimer* timer) {
                                                   [weakSelf checkIfDue];
                                               }];
    _timer.tolerance = 15 * 60;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [weakSelf checkIfDue];
    });
}

- (void)checkIfDue {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:CRCheckForUpdatesKey]) return;
    if (NSDate.date.timeIntervalSince1970 - [defaults doubleForKey:kLastCheckKey] < kCheckInterval) return;
    [self check:nil];
}

- (void)checkNow:(void (^)(NSString* status))report {
    [self check:report];
}

- (void)check:(void (^)(NSString* status))report {
    if (!_api || _busy) {
        if (report) report(_api ? @"Already checking…" : @"Updates aren't available for this build.");
        return;
    }
    _busy = YES;
    Source source;
    source.api = _api;
    source.publicKey = _publicKey;
    source.httpsOnly = !_localTest;
    NSBundle* bundle = NSBundle.mainBundle;
    NSString* current = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0";
    NSString* path = bundle.bundlePath;
    NSString* identifier = bundle.bundleIdentifier ?: @"";
    __weak CRUpdater* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString* message = nil;
        const Result result = update(source, current, path, identifier, &message);
        dispatch_async(dispatch_get_main_queue(), ^{
            CRUpdater* updater = weakSelf;
            if (!updater) return;
            updater->_busy = NO;
            // Automatic checks wait a day even after a failure, so a broken release isn't fetched over and over.
            if (result != Result::Failed || !report)
                [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970 forKey:kLastCheckKey];
            if (report) report(message);
            if (result == Result::Installed) [updater restart];
        });
    });
}

// Starts the new version once this one has quit, waiting until the list isn't open.
- (void)restart {
    if (_popup.isOpen) {
        __weak CRUpdater* weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakSelf restart];
        });
        return;
    }
    NSTask* task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[
        @"-c", [NSString stringWithFormat:@"while kill -0 %d 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"", getpid()],
        NSBundle.mainBundle.bundlePath
    ];
    if ([task launchAndReturnError:nil]) [NSApp terminate:nil];
}

@end
