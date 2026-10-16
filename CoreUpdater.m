// CoreUpdater.m — in-app update of the sing-box core (v0.14.0)
//
// WHY the updated core lives in ~/Library/Application Support/Raketa/cores/ and not inside
// Raketa.app: the bundle is ad-hoc code-signed with --deep in CI, rewriting its Resources
// would break the seal. The bundled core is never modified and is always the fallback.
//
// WHY only the official "darwin-amd64-legacy-macos-10.13" release asset: SagerNet builds it
// with a patched Go toolchain and MACOSX_DEPLOYMENT_TARGET=10.13 (Mach-O LC_VERSION_MIN 10.13),
// so one x86_64 binary runs on every macOS Raketa supports (arm64 Macs run it under Rosetta,
// like the app itself). The standard darwin-amd64 asset needs a newer macOS and is never used.
//
// Trust model (same as the rest of the app): the file is fetched over HTTPS from github.com,
// its SHA-256 is compared with the digest GitHub publishes for the asset when there is one,
// and it must run and accept the app's own configs before it is installed. The installed core
// is a user-writable file, like the app bundle itself when it is dragged into /Applications.
#import "CoreUpdater.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *const kReleaseBase = @"https://github.com/SagerNet/sing-box/releases/download/";
static NSString *const kLatestAPI   = @"https://api.github.com/repos/SagerNet/sing-box/releases/latest";

// ── helpers ──────────────────────────────────────────────────────────────────────────────

// Runs a tool and returns its exit status (-1: could not start, -2: killed by the timeout).
static int RKRun(NSString *path, NSArray<NSString *> *args, NSTimeInterval timeout, NSString **out) {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = path;
    t.arguments = args;
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    t.standardError = p;
    @try { [t launch]; }
    @catch (NSException *e) { if (out) *out = e.reason ?: @""; return -1; }
    __block BOOL killed = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (t.isRunning) { killed = YES; [t terminate]; }
    });
    NSData *d = [[p fileHandleForReading] readDataToEndOfFile];
    [t waitUntilExit];
    if (out) *out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
    return killed ? -2 : t.terminationStatus;
}

// First non-empty line of a tool's output, colour codes removed, shortened for a status line.
static NSString *RKFirstLine(NSString *s) {
    NSString *c = [s stringByReplacingOccurrencesOfString:@"\\x1b\\[[0-9;]*m" withString:@""
                                                  options:NSRegularExpressionSearch
                                                    range:NSMakeRange(0, s.length)];
    for (NSString *l in [c componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) return t.length > 150 ? [[t substringToIndex:150] stringByAppendingString:@"…"] : t;
    }
    return @"";
}

static NSString *RKSHA256(NSString *path) {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!h) return nil;
    CC_SHA256_CTX c;
    CC_SHA256_Init(&c);
    for (;;) {
        @autoreleasepool {
            NSData *d = [h readDataOfLength:1 << 20];
            if (!d.length) break;
            CC_SHA256_Update(&c, d.bytes, (CC_LONG)d.length);
        }
    }
    [h closeFile];
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(md, &c);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", md[i]];
    return s;
}

// "1.14.3" / "1.14.3-rc.1" -> numeric parts; anything after '-' is ignored.
static NSComparisonResult RKVerCompare(NSString *a, NSString *b) {
    NSArray *pa = [[[a componentsSeparatedByString:@"-"] firstObject] componentsSeparatedByString:@"."];
    NSArray *pb = [[[b componentsSeparatedByString:@"-"] firstObject] componentsSeparatedByString:@"."];
    NSUInteger n = MAX(pa.count, pb.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger x = i < pa.count ? [pa[i] integerValue] : 0;
        NSInteger y = i < pb.count ? [pb[i] integerValue] : 0;
        if (x != y) return x < y ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
}

static NSData *RKHTTPGet(NSString *urlString, NSInteger *status) {
    NSURL *u = [NSURL URLWithString:urlString];
    if (!u) return nil;
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:u];
    rq.timeoutInterval = 20.0;
    [rq setValue:@"Raketa" forHTTPHeaderField:@"User-Agent"];
    [rq setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    __block NSData *out = nil;
    __block NSInteger code = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        code = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        if (!e) out = d;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (status) *status = code;
    return out;
}

// Downloads to `dest`. An ephemeral session: a 26 MB archive must not end up in a URL cache.
static BOOL RKDownload(NSURL *url, NSString *dest) {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest  = 30.0;
    cfg.timeoutIntervalForResource = 300.0;
    NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg];
    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[s downloadTaskWithURL:url completionHandler:^(NSURL *loc, NSURLResponse *r, NSError *e) {
        NSInteger code = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        if (loc && !e && code == 200)
            ok = [[NSFileManager defaultManager] moveItemAtURL:loc
                                                         toURL:[NSURL fileURLWithPath:dest] error:NULL];
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    [s finishTasksAndInvalidate];
    return ok;
}

// ── CoreUpdater ──────────────────────────────────────────────────────────────────────────

@interface CoreUpdater ()
@property (nonatomic, copy)   NSString *supportDir;
@property (nonatomic, copy)   NSString *bundled;
@property (nonatomic, assign) BOOL      busy;
@end

@implementation CoreUpdater

- (instancetype)initWithSupportDir:(NSString *)supportDir bundledPath:(NSString *)bundledPath {
    if ((self = [super init])) {
        _supportDir = [supportDir copy];
        _bundled    = [bundledPath copy] ?: @"";
    }
    return self;
}

- (NSString *)coresDir   { return [self.supportDir stringByAppendingPathComponent:@"cores"]; }
- (NSString *)recordPath { return [[self coresDir] stringByAppendingPathComponent:@"cores.json"]; }

- (NSDictionary *)record {
    NSData *d = [NSData dataWithContentsOfFile:[self recordPath]];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [j isKindOfClass:[NSDictionary class]] ? j : @{};
}

- (NSString *)activeCorePath {
    id p = [self record][@"path"];
    if ([p isKindOfClass:[NSString class]]) {
        // Only files this class installed are honoured: a hand-edited record cannot point the
        // privileged launch at an arbitrary binary.
        NSString *std = [(NSString *)p stringByStandardizingPath];
        if ([std hasPrefix:[[self coresDir] stringByAppendingString:@"/"]] &&
            [[NSFileManager defaultManager] isExecutableFileAtPath:std])
            return std;
    }
    return self.bundled;
}

- (BOOL)usingUpdatedCore { return ![[self activeCorePath] isEqualToString:self.bundled]; }

- (NSString *)activeVersion {
    id v = [self record][@"version"];
    if (self.usingUpdatedCore && [v isKindOfClass:[NSString class]]) return v;
    id h = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"RaketaCoreVersion"];
    return [h isKindOfClass:[NSString class]] ? h : @"";
}

- (void)pruneKeeping:(NSArray<NSString *> *)keep {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *n in [fm contentsOfDirectoryAtPath:[self coresDir] error:NULL])
        if ([n hasPrefix:@"sing-box-"] && ![keep containsObject:n])
            [fm removeItemAtPath:[[self coresDir] stringByAppendingPathComponent:n] error:NULL];
}

- (void)resetToBundled {
    [[NSFileManager defaultManager] removeItemAtPath:[self recordPath] error:NULL];
    [self pruneKeeping:@[]];
}

- (void)checkAndUpdateWithConfigPaths:(NSArray<NSString *> *)configPaths
                               status:(void (^)(NSString *))status
                           completion:(void (^)(BOOL, NSString *))completion {
    if (self.busy) { completion(NO, @"Обновление ядра уже идёт"); return; }
    self.busy = YES;
    NSArray *paths = [configPaths copy] ?: @[];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *msg = nil;
        BOOL ok = [self runUpdateWithConfigPaths:paths status:status message:&msg];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            completion(ok, msg ?: @"");
        });
    });
}

// Background queue. Returns YES when the state is consistent (updated, or already current),
// NO when the update was refused or failed; `msg` is the Russian status line either way.
- (BOOL)runUpdateWithConfigPaths:(NSArray<NSString *> *)paths
                          status:(void (^)(NSString *))status
                         message:(NSString **)msg {
    void (^say)(NSString *) = ^(NSString *t) {
        if (status) dispatch_async(dispatch_get_main_queue(), ^{ status(t); });
    };
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *current = [self activeVersion];

    say(@"Проверка версии ядра…");
    NSInteger code = 0;
    NSData *rd = RKHTTPGet(kLatestAPI, &code);
    id rel = (rd && code == 200) ? [NSJSONSerialization JSONObjectWithData:rd options:0 error:nil] : nil;
    NSString *tag = [rel isKindOfClass:[NSDictionary class]] ? rel[@"tag_name"] : nil;
    // Strict shape: the tag ends up in a download URL and a directory name.
    if (![tag isKindOfClass:[NSString class]] ||
        [tag rangeOfString:@"^v[0-9]+\\.[0-9]+\\.[0-9]+$" options:NSRegularExpressionSearch].location == NSNotFound) {
        *msg = code ? [NSString stringWithFormat:@"GitHub не вернул версию ядра (HTTP %ld)", (long)code]
                    : @"GitHub недоступен — версию ядра проверить не удалось";
        return NO;
    }
    NSString *ver = [tag substringFromIndex:1];
    if (current.length && RKVerCompare(ver, current) != NSOrderedDescending) {
        *msg = [NSString stringWithFormat:@"sing-box %@ — это последняя версия", current];
        return YES;
    }

    NSString *asset = [NSString stringWithFormat:@"sing-box-%@-darwin-amd64-legacy-macos-10.13.tar.gz", ver];
    NSString *digest = nil;       // "sha256:<hex>" as published by GitHub; absent on old releases
    for (id a in ([rel[@"assets"] isKindOfClass:[NSArray class]] ? rel[@"assets"] : @[]))
        if ([a isKindOfClass:[NSDictionary class]] && [a[@"name"] isEqual:asset] &&
            [a[@"digest"] isKindOfClass:[NSString class]])
            digest = a[@"digest"];

    NSString *stage = [[self coresDir] stringByAppendingPathComponent:@".staging"];
    [fm removeItemAtPath:stage error:NULL];
    [fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *tgz = [stage stringByAppendingPathComponent:@"core.tar.gz"];

    say([NSString stringWithFormat:@"Загрузка sing-box %@…", ver]);
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@/%@", kReleaseBase, tag, asset]];
    if (!url || !RKDownload(url, tgz)) {
        [fm removeItemAtPath:stage error:NULL];
        *msg = [NSString stringWithFormat:@"Не удалось скачать sing-box %@ — проверьте сеть", ver];
        return NO;
    }
    NSString *sha = RKSHA256(tgz);
    if (digest.length && ![digest isEqualToString:[@"sha256:" stringByAppendingString:sha ?: @""]]) {
        [fm removeItemAtPath:stage error:NULL];
        *msg = @"Контрольная сумма ядра не совпала — обновление отменено";
        return NO;
    }

    say(@"Проверка нового ядра…");
    NSString *out = nil;
    if (RKRun(@"/usr/bin/tar", @[@"-xzf", tgz, @"-C", stage], 120, &out) != 0) {
        [fm removeItemAtPath:stage error:NULL];
        *msg = @"Не удалось распаковать архив ядра";
        return NO;
    }
    NSString *bin = nil;
    for (NSString *rel2 in [fm enumeratorAtPath:stage])
        if ([[rel2 lastPathComponent] isEqualToString:@"sing-box"]) {
            BOOL isDir = NO;
            NSString *full = [stage stringByAppendingPathComponent:rel2];
            if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir) { bin = full; break; }
        }
    if (!bin) {
        [fm removeItemAtPath:stage error:NULL];
        *msg = @"В архиве нет файла sing-box";
        return NO;
    }
    [fm setAttributes:@{NSFilePosixPermissions: @(0755)} ofItemAtPath:bin error:NULL];

    // 1. It must start on THIS macOS (a dyld error on 10.13 shows up here, not at connect time).
    NSString *want = [@"sing-box version " stringByAppendingString:ver];
    int rc = RKRun(bin, @[@"version"], 15, &out);
    if (rc != 0 || [out rangeOfString:want].location == NSNotFound) {
        [fm removeItemAtPath:stage error:NULL];
        *msg = [NSString stringWithFormat:@"Ядро %@ не запускается на этой macOS: %@", ver, RKFirstLine(out)];
        return NO;
    }
    // 2. It must accept the configs the app writes. A trivial config always; the real ones
    //    (config.json / config-yt.json) when they exist. This is what stops a future release
    //    that removed a field the app still emits - the 1.14 DNS format was such a case.
    NSString *mini = [stage stringByAppendingPathComponent:@"min.json"];
    NSString *miniJSON = @"{\"log\":{\"level\":\"error\"},\"inbounds\":[{\"type\":\"mixed\","
                         @"\"listen\":\"127.0.0.1\",\"listen_port\":18999}],"
                         @"\"outbounds\":[{\"type\":\"direct\",\"tag\":\"direct\"}]}";
    [miniJSON writeToFile:mini atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    NSMutableArray *toCheck = [NSMutableArray arrayWithObject:mini];
    for (NSString *p in paths) if ([fm fileExistsAtPath:p]) [toCheck addObject:p];
    for (NSString *p in toCheck) {
        rc = RKRun(bin, @[@"check", @"-c", p], 30, &out);
        if (rc != 0) {
            [fm removeItemAtPath:stage error:NULL];
            *msg = [NSString stringWithFormat:@"Ядро %@ отклонило конфиг: %@", ver, RKFirstLine(out)];
            return NO;
        }
    }

    // 3. Install: versioned directory, then flip the record (atomic write).
    NSString *dirName = [@"sing-box-" stringByAppendingString:ver];
    NSString *dest = [[self coresDir] stringByAppendingPathComponent:dirName];
    NSString *prevDir = [[[self activeCorePath] stringByDeletingLastPathComponent] lastPathComponent];
    [fm removeItemAtPath:dest error:NULL];
    NSString *destBin = [dest stringByAppendingPathComponent:@"sing-box"];
    NSError *err = nil;
    if (![fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:&err] ||
        ![fm moveItemAtPath:bin toPath:destBin error:&err]) {
        [fm removeItemAtPath:stage error:NULL];
        *msg = @"Не удалось установить ядро в Application Support";
        return NO;
    }
    NSDictionary *rec = @{@"version": ver, @"path": destBin, @"sha256": sha ?: @"",
                          @"asset": asset, @"installed": @((long long)[[NSDate date] timeIntervalSince1970])};
    NSData *rj = [NSJSONSerialization dataWithJSONObject:rec options:0 error:nil];
    if (![rj writeToFile:[self recordPath] atomically:YES]) {
        [fm removeItemAtPath:dest error:NULL];
        [fm removeItemAtPath:stage error:NULL];
        *msg = @"Не удалось записать запись об установленном ядре";
        return NO;
    }
    [fm removeItemAtPath:stage error:NULL];
    [self pruneKeeping:@[dirName, prevDir ?: @""]];          // keep one previous version on disk
    *msg = [NSString stringWithFormat:@"sing-box %@ → %@ установлен",
            current.length ? current : @"?", ver];
    return YES;
}

@end
