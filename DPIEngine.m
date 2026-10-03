// DPIEngine.m — see DPIEngine.h for the overview.
//
// WHY a sidecar process and not packet tricks: macOS has no divert sockets and
// pf has no divert-packet, so GoodbyeDPI/zapret-style packet interception is
// not possible here. ByeDPI (ciadpi) does the same desync (split / disorder /
// OOB / TLS-record split) in userspace: setsockopt(IP_TTL) between send()
// calls. No root, no TUN — consistent with Raketa's System Proxy architecture.
//
// WHY every strategy is pre-flighted: upstream ciadpi only enables the "fake
// packet" family (-f, -n, -S, ...) on Linux and Windows (FAKE_SUPPORT in
// params.h). On macOS those flags are *invalid options* and the process exits
// immediately, so strategies that use them cannot run here. They stay in the
// list (the list is the source of truth and may gain macOS support later),
// but are skipped in the search and never offered in the menu.
#import "DPIEngine.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <libproc.h>
#import <signal.h>
#import <unistd.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

static const int kDPIPort     = 10811;   // runtime ciadpi (system proxy -> sing-box -> here)
static const int kDPITestPort = 10820;   // throw-away ciadpi used by the search
static NSString *const kDPIRepoRaw  = @"https://raw.githubusercontent.com/romanvht/ByeByeDPI/master/app/src/main/assets/";
static NSString *const kDPISelKey   = @"RaketaDPIStrategy";
static NSString *const kDPIListName = @"strategies.list";
static NSString *const kDPIYTName   = @"youtube.sites";
static NSString *const kDPIGVName   = @"googlevideo.sites";

#pragma mark - Small helpers

static NSString *DPITrim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Blocking GET with a hard timeout. Used only from background queues.
static NSData *DPIFetch(NSString *urlStr, NSTimeInterval to) {
    NSURL *u = [NSURL URLWithString:urlStr];
    if (!u) return nil;
    NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    c.timeoutIntervalForRequest  = to;
    c.timeoutIntervalForResource = to + 5;
    c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *s = [NSURLSession sessionWithConfiguration:c];
    __block NSData *out = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[s dataTaskWithURL:u completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!e && d && [r isKindOfClass:[NSHTTPURLResponse class]]
            && [(NSHTTPURLResponse *)r statusCode] == 200) out = d;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((to + 6) * NSEC_PER_SEC)));
    [s finishTasksAndInvalidate];
    return out;
}

static BOOL DPIValidHost(NSString *h) {
    if (h.length < 3 || h.length > 120) return NO;
    static NSCharacterSet *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"] invertedSet];
    });
    return [h rangeOfCharacterFromSet:bad].location == NSNotFound && [h containsString:@"."]
        && ![h hasPrefix:@"-"];
}

// TCP connect probe to 127.0.0.1:port. Returns YES once something is listening.
static BOOL DPIPortOpen(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int rc = connect(fd, (struct sockaddr *)&a, sizeof a);
    close(fd);
    return rc == 0;
}

#pragma mark - DPIResult

@implementation DPIResult
@end

#pragma mark - DPIEngine

@interface DPIEngine () {
    NSString *_binary, *_resDir, *_supDir;
    dispatch_queue_t _cbq;
    dispatch_queue_t _q;            // serial: owns the runtime ciadpi process
    NSTask  *_proxyTask;
    NSString *_proxyStrategy;
    NSArray  *_proxyArgs;
    NSDate  *_lastRestart;
    volatile BOOL _proxyUp;
    BOOL _stopRequested;
    volatile BOOL _searching;
    volatile BOOL _cancel;
    NSMutableSet *_testTasks;       // guarded by @synchronized(_testTasks)
    NSArray<DPIResult *> *_results; // best first
    NSString *_resultsSig;
    NSDate   *_resultsDate;
    NSInteger _lastTested, _lastTotal;
}
@end

@implementation DPIEngine

- (instancetype)initWithBinary:(NSString *)binaryPath
                   resourceDir:(NSString *)resourceDir
                    supportDir:(NSString *)supportDir {
    if ((self = [super init])) {
        _binary = [binaryPath copy]; _resDir = [resourceDir copy]; _supDir = [supportDir copy];
        _cbq = dispatch_get_main_queue();
        _q   = dispatch_queue_create("com.samurai.raketa.dpi", DISPATCH_QUEUE_SERIAL);
        _testTasks = [NSMutableSet set];
        _results = @[];
        [self loadResultsFromDisk];
    }
    return self;
}

- (void)setCallbackQueue:(dispatch_queue_t)queue { _cbq = queue; }
- (BOOL)available {
    return _binary.length && [[NSFileManager defaultManager] isExecutableFileAtPath:_binary];
}
- (BOOL)searching    { return _searching; }
- (BOOL)proxyRunning { return _proxyUp; }
+ (int)proxyPort     { return kDPIPort; }

- (NSString *)selectedStrategy {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kDPISelKey];
}
- (void)setSelectedStrategy:(NSString *)s {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (s.length) [d setObject:s forKey:kDPISelKey]; else [d removeObjectForKey:kDPISelKey];
}

#pragma mark Strategy parsing and safety filter

// The list is fetched from a third-party repo, so every line is treated as
// untrusted data: it is split into argv tokens (never passed through a shell)
// and each option must be on this whitelist. Options that read/write files,
// daemonize, or change the listen address (-D -w -y -H -j -l -i -p -I -E -P ...)
// are NOT allowed — a compromised list must not be able to touch the disk
// or expose the proxy on the network.
+ (nullable NSArray<NSString *> *)argsForStrategy:(NSString *)raw {
    NSString *s = [raw stringByReplacingOccurrencesOfString:@"{sni}" withString:@"google.com"];
    s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@""];
    if (s.length == 0 || s.length > 500) return nil;
    static NSCharacterSet *okChars;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        okChars = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 \t-:+,._*#?="];
    });
    if ([s rangeOfCharacterFromSet:[okChars invertedSet]].location != NSNotFound) return nil;

    NSMutableArray *toks = [NSMutableArray array];
    for (NSString *t in [s componentsSeparatedByCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]])
        if (t.length) [toks addObject:t];
    if (!toks.count || toks.count > 80) return nil;

    NSString *withVal  = @"sdoqftnmeMrOQaALuTgRK";   // short options that take a value
    NSString *noVal    = @"S";                       // md5sig
    NSSet *longWith = [NSSet setWithArray:@[@"split",@"disorder",@"oob",@"disoob",@"fake",@"ttl",
        @"fake-sni",@"fake-offset",@"fake-tls-mod",@"oob-data",@"mod-http",@"tlsrec",@"tlsminor",
        @"udp-fake",@"auto",@"auto-mode",@"cache-ttl",@"timeout",@"round",@"proto",@"def-ttl"]];
    NSSet *longNo = [NSSet setWithArray:@[@"md5sig"]];

    for (NSUInteger i = 0; i < toks.count; i++) {
        NSString *t = toks[i];
        if ([t hasPrefix:@"--"]) {
            NSString *name = [t substringFromIndex:2];
            NSRange eq = [name rangeOfString:@"="];
            BOOL hasEq = eq.location != NSNotFound;
            if (hasEq) name = [name substringToIndex:eq.location];
            if ([longNo containsObject:name]) { if (hasEq) return nil; continue; }
            if (![longWith containsObject:name]) return nil;
            if (!hasEq) { if (++i >= toks.count) return nil; }     // value is the next token
        } else if ([t hasPrefix:@"-"] && t.length >= 2) {
            NSString *ch = [t substringWithRange:NSMakeRange(1, 1)];
            if ([noVal containsString:ch]) { if (t.length != 2) return nil; continue; }
            if (![withVal containsString:ch]) return nil;
            if (t.length == 2) { if (++i >= toks.count) return nil; }  // detached value
        } else {
            return nil;                                                // stray bare token
        }
    }
    return toks;
}

#pragma mark Lists (bundled snapshot + optional update from the repo)

- (NSString *)effectivePathForList:(NSString *)name {
    NSString *upd = [_supDir stringByAppendingPathComponent:[@"dpi_" stringByAppendingString:name]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:upd]) return upd;
    return [[_resDir stringByAppendingPathComponent:@"dpi"] stringByAppendingPathComponent:name];
}

- (NSArray<NSString *> *)linesOf:(NSString *)text {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *l in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = DPITrim(l);
        if (t.length && ![t hasPrefix:@"#"]) [a addObject:t];
    }
    return a;
}

- (NSArray<NSString *> *)strategies {
    NSString *txt = [NSString stringWithContentsOfFile:[self effectivePathForList:kDPIListName]
                                              encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *l in [self linesOf:txt ?: @""])
        if ([DPIEngine argsForStrategy:l] && ![seen containsObject:l]) { [seen addObject:l]; [out addObject:l]; }
    return out;
}

- (NSArray<NSString *> *)hostsFromList:(NSString *)name {
    NSString *txt = [NSString stringWithContentsOfFile:[self effectivePathForList:name]
                                              encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *l in [self linesOf:txt ?: @""]) if (DPIValidHost(l)) [out addObject:l];
    return out;
}

- (NSInteger)strategyCount { return (NSInteger)[self strategies].count; }
- (NSInteger)numberForStrategy:(NSString *)raw {
    NSUInteger i = [[self strategies] indexOfObject:raw];
    return i == NSNotFound ? 0 : (NSInteger)i + 1;
}

// Returns a human-readable note. Never throws away a good local list on failure.
- (NSString *)updateListsSync {
    NSString *oldTxt = [NSString stringWithContentsOfFile:[self effectivePathForList:kDPIListName]
                                                 encoding:NSUTF8StringEncoding error:nil];
    NSInteger before = (NSInteger)[self strategies].count;
    NSData *sd = DPIFetch([kDPIRepoRaw stringByAppendingString:@"proxytest_strategies.list"], 10);
    if (!sd) return @"репозиторий недоступен";
    NSString *st = [[NSString alloc] initWithData:sd encoding:NSUTF8StringEncoding];
    NSInteger valid = 0;
    for (NSString *l in [self linesOf:st ?: @""]) if ([DPIEngine argsForStrategy:l]) valid++;
    if (valid < 5) return @"список не изменён";

    BOOL changed = ![DPITrim(st) isEqualToString:DPITrim(oldTxt ?: @"")];
    if (changed) [sd writeToFile:[_supDir stringByAppendingPathComponent:@"dpi_strategies.list"] atomically:YES];

    // Host lists: small, refreshed together; a failed fetch keeps the old one.
    NSDictionary *hl = @{@"proxytest_youtube.sites": kDPIYTName,
                         @"proxytest_googlevideo.sites": kDPIGVName};
    for (NSString *remote in hl) {
        NSData *d = DPIFetch([kDPIRepoRaw stringByAppendingString:remote], 10);
        NSString *t = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
        NSInteger good = 0;
        for (NSString *l in [self linesOf:t ?: @""]) if (DPIValidHost(l)) good++;
        if (good >= 3)
            [d writeToFile:[_supDir stringByAppendingPathComponent:
                            [@"dpi_" stringByAppendingString:hl[remote]]] atomically:YES];
    }
    if (!changed) return @"список актуален";
    return [NSString stringWithFormat:@"список обновлён %ld→%ld", (long)before, (long)valid];
}

#pragma mark Results (persisted)

+ (NSString *)networkSignature {
    SCDynamicStoreRef st = SCDynamicStoreCreate(NULL, CFSTR("raketa.dpi"), NULL, NULL);
    NSString *sig = @"unknown";
    if (st) {
        NSDictionary *d = (__bridge_transfer NSDictionary *)
            SCDynamicStoreCopyValue(st, CFSTR("State:/Network/Global/IPv4"));
        if ([d isKindOfClass:[NSDictionary class]])
            sig = [NSString stringWithFormat:@"%@|%@", d[@"PrimaryInterface"] ?: @"?", d[@"Router"] ?: @"?"];
        CFRelease(st);
    }
    return sig;
}

- (NSString *)resultsPath { return [_supDir stringByAppendingPathComponent:@"dpi_results.json"]; }

- (void)loadResultsFromDisk {
    NSData *d = [NSData dataWithContentsOfFile:[self resultsPath]];
    if (!d) return;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![j isKindOfClass:[NSDictionary class]]) return;
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *r in j[@"results"]) {
        if (![r isKindOfClass:[NSDictionary class]] || ![r[@"s"] isKindOfClass:[NSString class]]) continue;
        DPIResult *x = [DPIResult new];
        x.strategy = r[@"s"]; x.ok = [r[@"ok"] integerValue];
        x.total = [r[@"n"] integerValue]; x.avgTime = [r[@"t"] doubleValue];
        [a addObject:x];
    }
    _results = a;
    _resultsSig = j[@"sig"];
    NSNumber *ts = j[@"date"];
    _resultsDate = ts ? [NSDate dateWithTimeIntervalSince1970:ts.doubleValue] : nil;
    _lastTested = [j[@"tested"] integerValue]; _lastTotal = [j[@"listed"] integerValue];
}

- (void)saveResults {
    NSMutableArray *a = [NSMutableArray array];
    for (DPIResult *r in _results)
        [a addObject:@{@"s": r.strategy, @"ok": @(r.ok), @"n": @(r.total), @"t": @(r.avgTime)}];
    NSDictionary *j = @{@"sig": _resultsSig ?: @"", @"date": @([_resultsDate timeIntervalSince1970]),
                        @"tested": @(_lastTested), @"listed": @(_lastTotal), @"results": a};
    NSData *d = [NSJSONSerialization dataWithJSONObject:j options:0 error:nil];
    if (d) [d writeToFile:[self resultsPath] atomically:YES];
}

- (NSArray<DPIResult *> *)topResults:(NSUInteger)n {
    NSArray *list = [self strategies];
    NSMutableArray *a = [NSMutableArray array];
    for (DPIResult *r in _results) {
        NSUInteger idx = [list indexOfObject:r.strategy];
        if (r.ok > 0 && idx != NSNotFound) { r.number = (NSInteger)idx + 1; [a addObject:r]; }
        if (a.count >= n) break;
    }
    return a;
}
- (DPIResult *)resultForStrategy:(NSString *)raw {
    for (DPIResult *r in _results) if ([r.strategy isEqualToString:raw]) {
        r.number = [self numberForStrategy:raw]; return r;
    }
    return nil;
}
- (NSString *)coverageNote {
    if (!_lastTotal) return @"";
    if (_lastTested >= _lastTotal) return [NSString stringWithFormat:@"Проверено стратегий: %ld", (long)_lastTested];
    return [NSString stringWithFormat:@"Проверено %ld из %ld (остальные используют fake-пакеты — недоступны в macOS-сборке)",
            (long)_lastTested, (long)_lastTotal];
}
- (BOOL)resultsMatchCurrentNetwork {
    return _resultsSig.length && [_resultsSig isEqualToString:[DPIEngine networkSignature]];
}
- (NSString *)resultsSummary {
    if (!_resultsDate) return @"Поиск ещё не выполнялся";
    NSInteger mins = (NSInteger)(-[_resultsDate timeIntervalSinceNow] / 60);
    NSString *age = mins < 1 ? @"только что" : mins < 90
        ? [NSString stringWithFormat:@"%ld мин назад", (long)mins]
        : [NSString stringWithFormat:@"%ld ч назад", (long)(mins / 60)];
    NSString *net = [self resultsMatchCurrentNetwork] ? @"для этой сети" : @"для ДРУГОЙ сети — запустите поиск";
    return [NSString stringWithFormat:@"Лучшие %@ · %@", net, age];
}

#pragma mark Process plumbing

- (NSTask *)launchCiadpiPort:(int)port strategyArgs:(NSArray *)sargs {
    // -X: IPv4 only. Many networks have no working IPv6 route; a v6 attempt that
    // hangs would look like "strategy doesn't work".
    NSMutableArray *args = [NSMutableArray arrayWithObjects:
        @"-i", @"127.0.0.1", @"-p", [NSString stringWithFormat:@"%d", port], @"-X", nil];
    [args addObjectsFromArray:sargs];
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = _binary;
    t.arguments = args;
    t.standardInput  = [NSFileHandle fileHandleWithNullDevice];
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError  = [NSFileHandle fileHandleWithNullDevice];
    @try { [t launch]; } @catch (NSException *e) { return nil; }
    return t;
}

// YES once the proxy accepts connections; NO if it exited (invalid options) or timed out.
- (BOOL)waitReady:(NSTask *)t port:(int)port timeout:(NSTimeInterval)to {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:to];
    while ([end timeIntervalSinceNow] > 0) {
        if (!t.isRunning) return NO;
        if (DPIPortOpen(port)) return YES;
        usleep(30000);
    }
    return NO;
}

- (NSString *)pidPath { return [_supDir stringByAppendingPathComponent:@"dpi.pid"]; }

- (void)startProxyWithStrategy:(NSString *)raw completion:(DPIStartBlock)completion {
    NSArray *sargs = [DPIEngine argsForStrategy:raw];
    dispatch_queue_t cbq = _cbq;
    if (!self.available) { dispatch_async(cbq, ^{ completion(NO, @"DPI-движок не найден"); }); return; }
    if (!sargs)          { dispatch_async(cbq, ^{ completion(NO, @"стратегия отклонена"); }); return; }
    dispatch_async(_q, ^{
        [self killProxyOnQueue];
        NSTask *t = [self launchCiadpiPort:kDPIPort strategyArgs:sargs];
        BOOL ready = t && [self waitReady:t port:kDPIPort timeout:1.5];
        if (!ready) {
            if (t.isRunning) [t terminate];
            dispatch_async(cbq, ^{
                completion(NO, @"движок не запустился");
            });
            return;
        }
        self->_stopRequested = NO;
        self->_proxyTask = t; self->_proxyStrategy = raw; self->_proxyArgs = sargs;
        self->_proxyUp = YES; self->_lastRestart = nil;
        [[NSString stringWithFormat:@"%d", t.processIdentifier]
            writeToFile:[self pidPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        __weak DPIEngine *ws = self;
        t.terminationHandler = ^(NSTask *dead) { [ws proxyDied:dead]; };
        dispatch_async(cbq, ^{ completion(YES, nil); });
    });
}

- (void)killProxyOnQueue {
    _stopRequested = YES;
    _proxyUp = NO;
    NSTask *t = _proxyTask; _proxyTask = nil;
    if (t) { t.terminationHandler = nil; if (t.isRunning) [t terminate]; }
    [[NSFileManager defaultManager] removeItemAtPath:[self pidPath] error:nil];
}

- (void)stopProxy { dispatch_async(_q, ^{ [self killProxyOnQueue]; }); }

// ciadpi died on its own. One automatic restart; a second death within 15 s
// means something is structurally wrong, so give up and tell the UI.
- (void)proxyDied:(NSTask *)dead {
    dispatch_async(_q, ^{
        if (dead != self->_proxyTask || self->_stopRequested) return;
        self->_proxyUp = NO;
        BOOL recent = self->_lastRestart && -[self->_lastRestart timeIntervalSinceNow] < 15;
        if (!recent && self->_proxyArgs) {
            self->_lastRestart = [NSDate date];
            NSTask *t = [self launchCiadpiPort:kDPIPort strategyArgs:self->_proxyArgs];
            if (t && [self waitReady:t port:kDPIPort timeout:1.5]) {
                self->_proxyTask = t; self->_proxyUp = YES;
                __weak DPIEngine *ws = self;
                t.terminationHandler = ^(NSTask *d2) { [ws proxyDied:d2]; };
                return;
            }
            if (t.isRunning) [t terminate];
        }
        self->_proxyTask = nil;
        [[NSFileManager defaultManager] removeItemAtPath:[self pidPath] error:nil];
        void (^gaveUp)(void) = self.onProxyGaveUp;
        if (gaveUp) dispatch_async(self->_cbq, gaveUp);
    });
}

// A previous Raketa session may have been killed with ciadpi still running.
- (void)cleanupStaleProxy {
    NSString *s = [NSString stringWithContentsOfFile:[self pidPath] encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[self pidPath] error:nil];
    pid_t pid = (pid_t)[s intValue];
    if (pid <= 1) return;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof path) > 0
        && [[[NSString stringWithUTF8String:path] lastPathComponent] isEqualToString:@"ciadpi"])
        kill(pid, SIGTERM);
}

#pragma mark Search

- (void)cancelSearch {
    _cancel = YES;
    @synchronized (_testTasks) {
        for (NSTask *t in _testTasks) if (t.isRunning) [t terminate];
    }
}

// One curl request through the proxy. YES = transport worked end to end
// (any HTTP status counts: DPI blocking shows up as reset/timeout, not as 4xx).
- (BOOL)curlHost:(NSString *)host port:(int)port timeout:(int)to seconds:(double *)secs {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/curl";
    t.arguments = @[@"-q", @"-sS", @"-o", @"/dev/null", @"-L", @"--max-redirs", @"3",
                    @"-m", [NSString stringWithFormat:@"%d", to],
                    @"--connect-timeout", [NSString stringWithFormat:@"%d", to],
                    @"--socks5-hostname", [NSString stringWithFormat:@"127.0.0.1:%d", port],
                    @"-w", @"%{time_total}",
                    [NSString stringWithFormat:@"https://%@/", host]];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    t.standardError  = [NSFileHandle fileHandleWithNullDevice];
    t.standardInput  = [NSFileHandle fileHandleWithNullDevice];
    @synchronized (_testTasks) { [_testTasks addObject:t]; }
    BOOL ok = NO;
    @try {
        [t launch];
        NSData *out = [[p fileHandleForReading] readDataToEndOfFile];   // tiny, ends at exit
        [t waitUntilExit];
        ok = (t.terminationStatus == 0);
        if (ok && secs) *secs = [[[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] doubleValue];
    } @catch (NSException *e) { ok = NO; }
    @synchronized (_testTasks) { [_testTasks removeObject:t]; }
    return ok;
}

// Runs `hosts` concurrently; returns the success count and sums times.
// One short-lived NSThread per host (not a GCD global queue): the workers
// block on the child process, and GCD may throttle blocked workers on small
// (old) Macs, which would serialize the battery and stretch the search.
- (NSInteger)batteryHosts:(NSArray<NSString *> *)hosts port:(int)port timeout:(int)to totalTime:(double *)sum {
    __block NSInteger okc = 0; __block double tsum = 0;
    dispatch_group_t g = dispatch_group_create();
    NSObject *lock = [NSObject new];
    for (NSString *h in hosts) {
        dispatch_group_enter(g);
        [NSThread detachNewThreadWithBlock:^{
            if (!self->_cancel) {
                double secs = 0;
                BOOL ok = [self curlHost:h port:port timeout:to seconds:&secs];
                if (ok) @synchronized (lock) { okc++; tsum += secs; }
            }
            dispatch_group_leave(g);
        }];
    }
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    if (sum) *sum = tsum;
    return okc;
}

// nil = this ciadpi build rejected the strategy (not counted as "tested").
- (DPIResult *)testStrategy:(NSString *)raw hosts:(NSArray *)hosts probes:(NSArray *)probes {
    NSArray *sargs = [DPIEngine argsForStrategy:raw];
    NSTask *t = sargs ? [self launchCiadpiPort:kDPITestPort strategyArgs:sargs] : nil;
    if (!t) return nil;
    DPIResult *r = nil;
    if ([self waitReady:t port:kDPITestPort timeout:1.0]) {
        r = [DPIResult new];
        r.strategy = raw; r.total = (NSInteger)hosts.count;
        // Stage 1: two always-up hosts. A strategy that cannot even get these
        // through is dead; skip the full battery (saves ~5 s and a pile of curls).
        double s1 = 0;
        if ([self batteryHosts:probes port:kDPITestPort timeout:4 totalTime:&s1] > 0 && !_cancel) {
            double sum = 0;
            r.ok = [self batteryHosts:hosts port:kDPITestPort timeout:5 totalTime:&sum];
            r.avgTime = r.ok ? sum / r.ok : 0;
        }
    }
    if (t.isRunning) { [t terminate]; [t waitUntilExit]; }
    return r;
}

- (void)searchWithProgress:(DPIProgressBlock)progress done:(DPIDoneBlock)done {
    if (_searching) return;
    dispatch_queue_t cbq = _cbq;
    if (!self.available) { dispatch_async(cbq, ^{ done(NO, @"DPI-движок не найден"); }); return; }
    _searching = YES; _cancel = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        dispatch_async(cbq, ^{ progress(@"update", 0, 0, 0); });
        NSString *updNote = [self updateListsSync];

        NSArray *strats = [self strategies];
        NSMutableArray *hosts = [NSMutableArray arrayWithArray:[self hostsFromList:kDPIYTName]];
        NSArray *gv = [self hostsFromList:kDPIGVName];
        [hosts addObjectsFromArray:[gv subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)6, gv.count))]];
        NSArray *probes = @[@"www.youtube.com", @"i.ytimg.com"];
        if (hosts.count < 3 || !strats.count) {
            self->_searching = NO;
            dispatch_async(cbq, ^{ done(NO, @"нет данных для проверки"); });
            return;
        }
        NSMutableArray<DPIResult *> *found = [NSMutableArray array];
        NSInteger tested = 0, best = 0, total = (NSInteger)strats.count;
        for (NSInteger i = 0; i < total && !self->_cancel; i++) {
            NSInteger doneN = i, bestN = best, tot = total;
            dispatch_async(cbq, ^{ progress(@"search", doneN, tot, bestN); });
            DPIResult *r = [self testStrategy:strats[(NSUInteger)i] hosts:hosts probes:probes];
            if (!r) continue;                 // unsupported by this build
            tested++;
            if (r.ok > 0) { [found addObject:r]; if (r.ok > best) best = r.ok; }
            usleep(400000);                   // be gentle between strategies
        }
        BOOL cancelled = self->_cancel;
        self->_searching = NO;
        if (cancelled) { dispatch_async(cbq, ^{ done(NO, @"поиск остановлен"); }); return; }

        [found sortUsingComparator:^NSComparisonResult(DPIResult *a, DPIResult *b) {
            if (a.ok != b.ok) return a.ok > b.ok ? NSOrderedAscending : NSOrderedDescending;
            if (a.avgTime != b.avgTime) return a.avgTime < b.avgTime ? NSOrderedAscending : NSOrderedDescending;
            return NSOrderedSame;
        }];
        self->_results = found;
        self->_resultsSig = [DPIEngine networkSignature];
        self->_resultsDate = [NSDate date];
        self->_lastTested = tested; self->_lastTotal = total;
        [self saveResults];

        NSString *sum = found.count
            ? [NSString stringWithFormat:@"Найдено %lu из %ld · %@",
               (unsigned long)found.count, (long)tested, updNote]
            : [NSString stringWithFormat:@"Рабочих не найдено · %@", updNote];
        BOOL okAny = found.count > 0;
        dispatch_async(cbq, ^{ done(okAny, sum); });
    });
}

#pragma mark Lifecycle / config

- (void)shutdown {
    [self cancelSearch];
    dispatch_sync(_q, ^{ [self killProxyOnQueue]; });
}

// YouTube-only mode: only YouTube/Google-video domains go to ciadpi; everything
// else is `direct`, so ordinary browsing never touches the desync proxy.
// (Suffix match covers subdomains: "youtube.com" matches www.youtube.com.)
+ (NSDictionary *)youtubeOnlyConfigWithInbounds:(NSArray *)inbounds {
    return @{
        @"log": @{@"level": @"warn"},
        @"inbounds": inbounds,
        @"outbounds": @[
            @{@"type": @"direct", @"tag": @"direct"},
            @{@"type": @"socks", @"tag": @"dpi", @"version": @"5",
              @"server": @"127.0.0.1", @"server_port": @(kDPIPort)}
        ],
        @"route": @{
            @"rules": @[
                @{@"domain_suffix": @[@"youtube.com", @"youtu.be", @"youtube-nocookie.com",
                                      @"googlevideo.com", @"ytimg.com", @"ggpht.com",
                                      @"googleusercontent.com",
                                      @"youtubei.googleapis.com", @"jnn-pa.googleapis.com"],
                  @"outbound": @"dpi"}
            ],
            @"final": @"direct"
        }
    };
}

@end
