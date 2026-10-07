// DPIEngine.m — see DPIEngine.h for the overview.
//
// WHY a sidecar process and not packet tricks: macOS has no divert sockets and
// pf has no divert-packet, so GoodbyeDPI/zapret-style packet interception is
// not possible here. ByeDPI (ciadpi) does the same desync (split / disorder /
// OOB / TLS-record split) in userspace: setsockopt(IP_TTL) between send()
// calls. No root, no TUN — consistent with Raketa's System Proxy architecture.
//
// WHY strategies are ADAPTED and not just filtered: upstream ciadpi enables the
// "fake packet" family (-f -n -S ...) only on Linux and Windows (FAKE_SUPPORT in
// params.h). On macOS those flags are invalid options and the process exits at
// once, and 37 of the 60 ByeByeDPI lines use them. Dropping those lines (what
// v0.12.x did) left 23 candidates and, on a strict network, often none. Now the
// options this ciadpi build lacks are cut out of such a line and the rest of it
// (split / disorder / OOB / TLS-record parts) becomes an extra candidate, marked
// "~" in the menu. Nothing is assumed about whether an adapted line works: it
// goes through the same live test as every original one.
//
// WHY the live test copies ByeByeDPI's own success rule: ByeByeDPI (SiteCheckUtils)
// counts a request as passed when an HTTP answer arrives and, if the server
// declared a Content-Length, the whole body arrived. v0.12.x demanded a clean
// curl exit inside a hard 4-5 s total limit instead, which fails any strategy that
// is merely slow (every TTL-based "disorder" waits for one TCP retransmit) even
// though it works.
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

// Result of one curl request, parsed from `-D -` (headers) + `-w` (trailer).
// Pure function so it can be unit-tested without a network.
//   http     - final HTTP status, 0 when no answer arrived
//   size     - body bytes received
//   declared - Content-Length of the FINAL response, -1 when absent or chunked
static void DPIParseCurlOutput(NSString *out, int *http, long long *size,
                               double *secs, long long *declared) {
    *http = 0; *size = 0; *secs = 0; *declared = -1;
    for (NSString *raw in [out componentsSeparatedByString:@"\n"]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!l.length) continue;
        NSString *lc = [l lowercaseString];
        if ([l hasPrefix:@"HTTP/"]) {
            *declared = -1;                       // a new response block (redirect hop)
        } else if ([lc hasPrefix:@"content-length:"]) {
            *declared = [[l substringFromIndex:15] longLongValue];
        } else if ([lc hasPrefix:@"transfer-encoding:"] && [lc containsString:@"chunked"]) {
            *declared = -1;                       // length unknown by design
        } else if ([l hasPrefix:@"@@RK "]) {
            NSArray *p = [[l substringFromIndex:5] componentsSeparatedByString:@" "];
            if (p.count >= 3) {
                *http = [p[0] intValue]; *size = [p[1] longLongValue]; *secs = [p[2] doubleValue];
            }
        }
    }
}

// ByeByeDPI's rule (see the header comment), plus one guard of ours: when the
// length is unknown (chunked page) the body must either finish or at least get
// past 32 KB, because the classic DPI stall freezes a connection at ~16 KB.
static BOOL DPIRequestPassed(int http, long long size, long long declared, int curlStatus) {
    if (http <= 0) return NO;
    if (declared > 0) return size >= declared;
    return curlStatus == 0 || size >= 32768;
}

#pragma mark - DPIResult

@implementation DPIResult
@end

// One usable line of the strategy list: `raw` is what is run (and what is the
// identity of a result), `src` is the line's position in the ByeByeDPI file.
@interface DPIEntry : NSObject
@property (copy)   NSString *raw;
@property (assign) NSInteger src;
@property (assign) BOOL      adapted;
@property (assign) BOOL      curated;    // from DPICuratedLines(), not from the ByeByeDPI file
@property (copy)   NSString *label;      // "12", "12~" (adapted), "M3" (curated)
@end
@implementation DPIEntry
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
    NSInteger _lastNative, _lastAdapted;   // composition of the list at the last search
    NSInteger _directOK, _directTotal;     // control run: same hosts, no bypass at all
    NSInteger _passOK, _passTotal;         // control run: same hosts through ciadpi with NO desync
    NSInteger _lastCurated;
    NSDictionary<NSString *, DPIResult *> *_tested;   // every candidate tested at the last search, failures included
    NSSet   *_caps;                        // options this ciadpi lists in --help (nil = unknown)
    BOOL     _capsDone;
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

#pragma mark macOS capability probe and strategy adaptation

// Options that exist only in some ciadpi builds (upstream: FAKE_SUPPORT /
// TIMEOUT_SUPPORT / __linux__). The probe can only REMOVE support for these;
// every other option is taken as available, so a --help that hides an option
// can never silently shrink the list.
static NSSet *DPIGatedOptions(void) {
    static NSSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@"-f", @"--fake", @"-n", @"--fake-sni", @"-S", @"--md5sig",
                                  @"-T", @"--timeout", @"-Y", @"--drop-sack"]];
    });
    return s;
}

// Modifiers that only tune fake packets; without `-f` they do nothing.
static NSSet *DPIFakeOnlyOptions(void) {
    static NSSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@"-t", @"--ttl", @"-Q", @"--fake-tls-mod", @"-O", @"--fake-offset",
                                  @"-l", @"--fake-data"]];
    });
    return s;
}

// Parts that actually change how the first packets are cut up.
static NSSet *DPIDesyncOptions(void) {
    static NSSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@"-s", @"--split", @"-d", @"--disorder", @"-o", @"--oob",
                                  @"-q", @"--disoob", @"-r", @"--tlsrec"]];
    });
    return s;
}

// "-d1" -> "-d", "--split=3" -> "--split", "-S" -> "-S".
static NSString *DPIOptKey(NSString *tok) {
    if ([tok hasPrefix:@"--"]) {
        NSRange eq = [tok rangeOfString:@"="];
        return eq.location == NSNotFound ? tok : [tok substringToIndex:eq.location];
    }
    return tok.length >= 2 ? [tok substringToIndex:2] : tok;
}

// Groups an (already validated) token list into options with their detached
// values: @[@[@"-d", @"1"], @[@"-s1+s"], @[@"-S"], @[@"--split", @"1+s"]].
// Same grammar as +argsForStrategy:.
static NSArray<NSArray<NSString *> *> *DPIOptionGroups(NSArray<NSString *> *toks) {
    NSMutableArray *groups = [NSMutableArray array];
    for (NSUInteger i = 0; i < toks.count; i++) {
        NSString *t = toks[i];
        NSMutableArray *g = [NSMutableArray arrayWithObject:t];
        if ([t hasPrefix:@"--"]) {
            BOOL hasEq = [t rangeOfString:@"="].location != NSNotFound;
            if (![t isEqualToString:@"--md5sig"] && !hasEq && i + 1 < toks.count) [g addObject:toks[++i]];
        } else if (t.length == 2 && ![t isEqualToString:@"-S"] && i + 1 < toks.count) {
            [g addObject:toks[++i]];
        }
        [groups addObject:g];
    }
    return groups;
}

// What this ciadpi build prints in `--help` ("-f, --fake <pos_t> ..."), as a set
// of "-f" and "--fake" strings. The binary is the source of truth: if a later
// build gains fake-packet support on macOS, those strategies become original
// (not adapted) with no code change. nil when the binary cannot be asked.
- (NSSet *)probedOptions {
    @synchronized (self) {
        if (_capsDone) return _caps;
        _capsDone = YES;
        if (!self.available) return nil;
        NSTask *t = [[NSTask alloc] init];
        NSPipe *p = [NSPipe pipe];
        t.launchPath = _binary;
        t.arguments = @[@"--help"];
        t.standardOutput = p; t.standardError = p;
        t.standardInput = [NSFileHandle fileHandleWithNullDevice];
        @try { [t launch]; } @catch (NSException *e) { return nil; }
        // --help prints ~3 KB (fits the pipe buffer) and exits; never wait longer than 1.5 s.
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:1.5];
        while (t.isRunning && [end timeIntervalSinceNow] > 0) usleep(5000);
        if (t.isRunning) { [t terminate]; return nil; }
        NSData *d = [[p fileHandleForReading] readDataToEndOfFile];
        NSString *txt = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
        if (!txt.length) return nil;
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"^\\s*-([A-Za-z#/]),\\s*--([A-Za-z0-9-]+)"
                                 options:NSRegularExpressionAnchorsMatchLines error:nil];
        NSMutableSet *set = [NSMutableSet set];
        for (NSTextCheckingResult *r in [re matchesInString:txt options:0 range:NSMakeRange(0, txt.length)]) {
            [set addObject:[@"-" stringByAppendingString:[txt substringWithRange:[r rangeAtIndex:1]]]];
            [set addObject:[@"--" stringByAppendingString:[txt substringWithRange:[r rangeAtIndex:2]]]];
        }
        _caps = set.count >= 10 ? set : nil;     // a tiny set means the output was not a help text
        return _caps;
    }
}

- (BOOL)optionMissing:(NSString *)key {
    if (![DPIGatedOptions() containsObject:key]) return NO;
    NSSet *caps = [self probedOptions];
    return !(caps && [caps containsObject:key]);
}

// The form of `raw` this ciadpi can run. Same string when every option is
// supported (*adapted = NO). Otherwise the missing options (and, because they
// are meaningless without fake packets, the fake-only modifiers) are cut out and
// *adapted = YES. nil when no split/disorder/OOB/tlsrec part would be left.
- (NSString *)runnableForm:(NSString *)raw adapted:(BOOL *)adapted {
    *adapted = NO;
    NSMutableArray *toks = [NSMutableArray array];
    for (NSString *t in [raw componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]])
        if (t.length) [toks addObject:t];
    NSArray *groups = DPIOptionGroups(toks);
    BOOL anyMissing = NO;
    for (NSArray *g in groups) if ([self optionMissing:DPIOptKey(g[0])]) { anyMissing = YES; break; }
    if (!anyMissing) return raw;

    BOOL fakeGone = [self optionMissing:@"-f"];
    NSMutableArray *kept = [NSMutableArray array];
    BOOL hasPart = NO;
    for (NSArray *g in groups) {
        NSString *k = DPIOptKey(g[0]);
        if ([self optionMissing:k]) continue;
        if (fakeGone && [DPIFakeOnlyOptions() containsObject:k]) continue;
        if ([DPIDesyncOptions() containsObject:k]) hasPart = YES;
        [kept addObjectsFromArray:g];
    }
    if (!hasPart) return nil;
    *adapted = YES;
    return [kept componentsJoinedByString:@" "];
}

// "--split 1+s" and "-s1+s" are the same option; so are -s1+s and -s 1+s.
static NSString *DPICanonOpt(NSString *key) {
    static NSDictionary *map; static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{@"--split": @"-s", @"--disorder": @"-d", @"--oob": @"-o", @"--disoob": @"-q",
                @"--tlsrec": @"-r", @"--fake": @"-f", @"--ttl": @"-t", @"--auto": @"-A",
                @"--mod-http": @"-M", @"--tlsminor": @"-m", @"--oob-data": @"-e",
                @"--fake-sni": @"-n", @"--fake-tls-mod": @"-Q", @"--fake-offset": @"-O",
                @"--fake-data": @"-l", @"--udp-fake": @"-a", @"--md5sig": @"-S",
                @"--timeout": @"-T", @"--drop-sack": @"-Y", @"--cache-ttl": @"-u",
                @"--auto-mode": @"-L", @"--def-ttl": @"-g"};
    });
    return map[key] ?: key;
}

// Two lines that behave identically in the search get the same key: fake-only
// modifiers do nothing without fake packets, `-aN` (UDP fakes) never touches the TCP
// test, and the long/short spelling of an option is irrelevant.
- (NSString *)dedupeKey:(NSString *)line {
    NSMutableArray *toks = [NSMutableArray array];
    for (NSString *t in [line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]])
        if (t.length) [toks addObject:t];
    BOOL fakeGone = [self optionMissing:@"-f"];
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *g in DPIOptionGroups(toks)) {
        NSString *k = DPICanonOpt(DPIOptKey(g[0]));
        if ([k isEqualToString:@"-a"]) continue;
        if (fakeGone && [DPIFakeOnlyOptions() containsObject:DPIOptKey(g[0])]) continue;
        NSString *first = g[0], *val = @"";
        if ([first hasPrefix:@"--"]) {
            NSRange eq = [first rangeOfString:@"="];
            val = eq.location != NSNotFound ? [first substringFromIndex:eq.location + 1] : (g.count > 1 ? g[1] : @"");
        } else {
            val = first.length > 2 ? [first substringFromIndex:2] : (g.count > 1 ? g[1] : @"");
        }
        [out addObject:[k stringByAppendingString:val]];
    }
    return [out componentsJoinedByString:@" "];
}

// Candidates for a macOS ciadpi, tried FIRST. The ByeByeDPI list is tuned for Android
// (Linux): its best lines lean on fake packets and on Linux's selective retransmit
// after a TTL=1 "disorder". Upstream's README says a BSD/Windows-style stack
// retransmits from the lost position instead and recommends `--split 1+s --disorder 3+s`
// there; it also recommends putting an OOB byte inside the SNI (`--oob 3+s`) and shows
// `--disoob 3 --disorder 7`. These lines follow that advice and add TLS-record splitting
// at the SNI, which does not depend on the OS at all. They are guesses ranked by the
// live test like every other candidate, nothing more. Lines identical to an entry of
// the ByeByeDPI list are skipped (the ByeByeDPI number wins).
static NSArray<NSString *> *DPICuratedLines(void) {
    return @[@"-s1+s -d3+s",
             @"-s1+s -d3+s -r1+s",
             @"-r1+s -s1+s",
             @"-r3+s -s3+s",
             @"-o3+s",
             @"-o3+s -r1+s",
             @"-q3+s -d7+s",
             @"-s1 -o3+s",
             @"-s1+s -s1+sm -s1+se",
             @"-r1+s -r1+sm -s1+s",
             @"-d1 -s1+s -d3+s",
             @"-s1+s -r1+sm -o3+se"];
}

// Every runnable candidate, in TEST order: the macOS-first lines (M1..), then the
// original ByeByeDPI lines, then the adapted ones. A ByeByeDPI line that fails the
// safety filter is skipped but still occupies its number, so "№N" always equals the
// line's position in the ByeByeDPI file.
- (NSArray<DPIEntry *> *)entries {
    NSString *txt = [NSString stringWithContentsOfFile:[self effectivePathForList:kDPIListName]
                                              encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray<DPIEntry *> *originals = [NSMutableArray array], *adapted = [NSMutableArray array];
    NSMutableSet *seenRaw = [NSMutableSet set], *seenKey = [NSMutableSet set];
    NSInteger src = 0;
    for (NSString *l in [self linesOf:txt ?: @""]) {
        src++;
        if (![DPIEngine argsForStrategy:l] || [seenRaw containsObject:l]) continue;
        [seenRaw addObject:l];
        BOOL ad = NO;
        NSString *run = [self runnableForm:l adapted:&ad];
        if (!run) continue;
        DPIEntry *e = [DPIEntry new];
        e.raw = run; e.src = src; e.adapted = ad;
        e.label = [NSString stringWithFormat:@"%ld%@", (long)src, ad ? @"~" : @""];
        if (ad) { [adapted addObject:e]; }
        else    { [originals addObject:e]; [seenKey addObject:[self dedupeKey:run]]; }
    }
    NSMutableArray<DPIEntry *> *rest = [NSMutableArray arrayWithArray:originals];
    for (DPIEntry *e in adapted) {
        NSString *k = [self dedupeKey:e.raw];
        if ([seenKey containsObject:k] || ![DPIEngine argsForStrategy:e.raw]) continue;
        [seenKey addObject:k];
        [rest addObject:e];
    }
    NSMutableArray<DPIEntry *> *out = [NSMutableArray array];
    NSInteger k = 0;
    for (NSString *l in DPICuratedLines()) {
        k++;
        BOOL ad = NO;
        NSString *run = [DPIEngine argsForStrategy:l] ? [self runnableForm:l adapted:&ad] : nil;
        if (!run) continue;
        NSString *key = [self dedupeKey:run];
        if ([seenKey containsObject:key]) continue;      // already in the list under its own number
        [seenKey addObject:key];
        DPIEntry *e = [DPIEntry new];
        e.raw = run; e.src = 1000 + k; e.adapted = NO; e.curated = YES;
        e.label = [NSString stringWithFormat:@"M%ld", (long)k];
        [out addObject:e];
    }
    [out addObjectsFromArray:rest];
    return out;
}

- (NSArray<NSString *> *)strategies {
    NSMutableArray *a = [NSMutableArray array];
    for (DPIEntry *e in [self entries]) [a addObject:e.raw];
    return a;
}

- (NSArray<NSString *> *)hostsFromList:(NSString *)name {
    NSString *txt = [NSString stringWithContentsOfFile:[self effectivePathForList:name]
                                              encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *l in [self linesOf:txt ?: @""]) if (DPIValidHost(l)) [out addObject:l];
    return out;
}

- (NSInteger)strategyCount { return (NSInteger)[self entries].count; }
- (NSInteger)numberForStrategy:(NSString *)raw {
    for (DPIEntry *e in [self entries]) if ([e.raw isEqualToString:raw]) return e.src;
    return 0;
}
// "12", "12~" or "M3"; @"" when the line is not a candidate any more.
- (NSString *)labelForStrategy:(NSString *)raw {
    for (DPIEntry *e in [self entries]) if ([e.raw isEqualToString:raw]) return e.label;
    return @"";
}
// Every candidate in test order with whatever the last search measured for it
// (total == 0: not tested). Lets the menu offer ALL of them for manual choice, so a
// network where the search finds nothing is not a dead end.
- (NSArray<DPIResult *> *)allCandidates {
    NSMutableArray *out = [NSMutableArray array];
    for (DPIEntry *e in [self entries]) {
        DPIResult *t = _tested[e.raw];
        DPIResult *r = [DPIResult new];
        r.strategy = e.raw; r.number = e.src; r.adapted = e.adapted; r.label = e.label;
        if (t) { r.ok = t.ok; r.total = t.total; r.avgTime = t.avgTime; }
        [out addObject:r];
    }
    return out;
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
    NSMutableDictionary *all = [NSMutableDictionary dictionary];
    // "results" = working ones, best first; "all" (v0.13.2) = every candidate tested.
    for (NSString *key in @[@"all", @"results"]) {
        id arr = j[key];
        if (![arr isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *r in arr) {
            if (![r isKindOfClass:[NSDictionary class]] || ![r[@"s"] isKindOfClass:[NSString class]]) continue;
            DPIResult *x = [DPIResult new];
            x.strategy = r[@"s"]; x.ok = [r[@"ok"] integerValue];
            x.total = [r[@"n"] integerValue]; x.avgTime = [r[@"t"] doubleValue];
            all[x.strategy] = x;
            if ([key isEqualToString:@"results"]) [a addObject:x];
        }
    }
    _results = a;
    _tested = all;
    _resultsSig = j[@"sig"];
    NSNumber *ts = j[@"date"];
    _resultsDate = ts ? [NSDate dateWithTimeIntervalSince1970:ts.doubleValue] : nil;
    _lastTested = [j[@"tested"] integerValue]; _lastTotal = [j[@"listed"] integerValue];
    _lastNative = [j[@"native"] integerValue]; _lastAdapted = [j[@"adapted"] integerValue];
    _lastCurated = [j[@"curated"] integerValue];
    _directOK = [j[@"direct_ok"] integerValue]; _directTotal = [j[@"direct_n"] integerValue];
    _passOK = [j[@"pass_ok"] integerValue]; _passTotal = [j[@"pass_n"] integerValue];
}

- (void)saveResults {
    NSMutableArray *a = [NSMutableArray array], *all = [NSMutableArray array];
    for (DPIResult *r in _results)
        [a addObject:@{@"s": r.strategy, @"ok": @(r.ok), @"n": @(r.total), @"t": @(r.avgTime)}];
    for (DPIResult *r in [_tested allValues])
        [all addObject:@{@"s": r.strategy, @"ok": @(r.ok), @"n": @(r.total), @"t": @(r.avgTime)}];
    NSDictionary *j = @{@"sig": _resultsSig ?: @"", @"date": @([_resultsDate timeIntervalSince1970]),
                        @"tested": @(_lastTested), @"listed": @(_lastTotal),
                        @"native": @(_lastNative), @"adapted": @(_lastAdapted), @"curated": @(_lastCurated),
                        @"direct_ok": @(_directOK), @"direct_n": @(_directTotal),
                        @"pass_ok": @(_passOK), @"pass_n": @(_passTotal),
                        @"results": a, @"all": all};
    NSData *d = [NSJSONSerialization dataWithJSONObject:j options:0 error:nil];
    if (d) [d writeToFile:[self resultsPath] atomically:YES];
}

- (NSArray<DPIResult *> *)topResults:(NSUInteger)n {
    NSMutableDictionary<NSString *, DPIEntry *> *byRaw = [NSMutableDictionary dictionary];
    for (DPIEntry *e in [self entries]) byRaw[e.raw] = e;
    NSMutableArray *a = [NSMutableArray array];
    for (DPIResult *r in _results) {
        DPIEntry *e = byRaw[r.strategy];
        if (r.ok > 0 && e) { r.number = e.src; r.adapted = e.adapted; r.label = e.label; [a addObject:r]; }
        if (a.count >= n) break;
    }
    return a;
}
// Includes candidates that FAILED the search: a hand-picked one still shows its "0/19".
- (DPIResult *)resultForStrategy:(NSString *)raw {
    DPIResult *r = _tested[raw];
    if (!r) for (DPIResult *x in _results) if ([x.strategy isEqualToString:raw]) { r = x; break; }
    if (!r) return nil;
    for (DPIEntry *e in [self entries]) if ([e.raw isEqualToString:raw]) {
        r.number = e.src; r.adapted = e.adapted; r.label = e.label;
    }
    return r;
}
- (NSString *)coverageNote {
    if (!_lastTotal) return @"";
    if (_lastNative + _lastAdapted == 0)        // saved by v0.12.x: different list semantics
        return @"Результаты старого формата — повторите поиск 🔍";
    NSMutableString *s = [NSMutableString stringWithFormat:@"Проверено %ld: %ld ориг.",
                          (long)_lastTested, (long)_lastNative];
    if (_lastAdapted) [s appendFormat:@" + %ld адапт. (~)", (long)_lastAdapted];
    if (_lastCurated) [s appendFormat:@" + %ld для macOS (M)", (long)_lastCurated];
    return s;
}
// One line that says WHICH kind of failure the last search saw, from the two control
// runs (same hosts: directly, and through ciadpi with no desync at all):
//   direct fine, proxy broken  -> our proxy chain is at fault, not the strategies
//   both blocked               -> the network blocks; only a better strategy helps
//   direct fine, proxy fine    -> nothing visible to bypass
- (NSString *)diagnosisNote {
    if (!_directTotal) return @"";
    NSString *d = [NSString stringWithFormat:@"%ld/%ld", (long)_directOK, (long)_directTotal];
    BOOL directFine = _directOK * 10 >= _directTotal * 7;
    if (!_passTotal) return [NSString stringWithFormat:@"Без обхода напрямую: %@", d];
    NSString *p = [NSString stringWithFormat:@"%ld/%ld", (long)_passOK, (long)_passTotal];
    if (directFine && _passOK * 2 < _directOK)
        return [NSString stringWithFormat:@"⚠ напрямую %@, через ciadpi без обхода %@ — сбой прокси", d, p];
    if (directFine)
        return [NSString stringWithFormat:@"Без обхода открывается %@ — блокировки не видно", d];
    if (_passOK * 10 >= _passTotal * 7)      // plain proxy already works where direct does not
        return [NSString stringWithFormat:@"Через ciadpi без обхода открывается %@ (напрямую %@)", p, d];
    return [NSString stringWithFormat:@"Сеть блокирует: напрямую %@, через прокси %@", d, p];
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

// One HTTPS request. port > 0: through the SOCKS5 proxy there; port == 0: direct
// (the control run). YES when it passes ByeByeDPI's rule (DPIRequestPassed).
// *code is 0 on success, else curl's exit status, or 1 when curl was content but
// the body fell short (declared length not reached / stalled under 32 KB).
//
// Timeouts: --connect-timeout covers TCP + SOCKS + TLS handshake; -Y/-y aborts a
// transfer that stalls (the DPI freeze), -m is only a backstop for huge pages.
// None of them punishes a strategy for being slow but alive.
- (BOOL)curlHost:(NSString *)host port:(int)port timeout:(int)to
         seconds:(double *)secs code:(int *)code {
    NSMutableArray *args = [NSMutableArray arrayWithObjects:
        @"-q", @"-sS", @"-o", @"/dev/null", @"-D", @"-", @"--http1.1",
        @"-L", @"--max-redirs", @"3",
        @"--connect-timeout", [NSString stringWithFormat:@"%d", to],
        @"-m", [NSString stringWithFormat:@"%d", to * 3],
        @"-Y", @"1", @"-y", [NSString stringWithFormat:@"%d", to], nil];
    if (port > 0)
        [args addObjectsFromArray:@[@"--socks5-hostname", [NSString stringWithFormat:@"127.0.0.1:%d", port]]];
    [args addObjectsFromArray:@[@"-w", @"\n@@RK %{http_code} %{size_download} %{time_total}\n",
                                [NSString stringWithFormat:@"https://%@/", host]]];
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/curl";
    t.arguments = args;
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    t.standardError  = [NSFileHandle fileHandleWithNullDevice];
    t.standardInput  = [NSFileHandle fileHandleWithNullDevice];
    @synchronized (_testTasks) { [_testTasks addObject:t]; }
    BOOL ok = NO; int status = -1;
    @try {
        [t launch];
        NSData *out = [[p fileHandleForReading] readDataToEndOfFile];   // headers + one line; ends at exit
        [t waitUntilExit];
        status = t.terminationStatus;
        // Latin-1 never fails to decode, unlike UTF-8 on an odd header byte.
        NSString *txt = [[NSString alloc] initWithData:out encoding:NSISOLatin1StringEncoding] ?: @"";
        int http; long long size, declared; double s;
        DPIParseCurlOutput(txt, &http, &size, &s, &declared);
        ok = DPIRequestPassed(http, size, declared, status);
        if (ok && secs) *secs = s;
    } @catch (NSException *e) { ok = NO; status = -1; }
    @synchronized (_testTasks) { [_testTasks removeObject:t]; }
    if (code) *code = ok ? 0 : (status != 0 ? status : 1);
    return ok;
}

// Runs `hosts` concurrently; returns the success count, sums the times of the
// successful ones and counts failure reasons (curl exit status -> count) into
// `fails` for the search log.
// One short-lived NSThread per host (not a GCD global queue): the workers
// block on the child process, and GCD may throttle blocked workers on small
// (old) Macs, which would serialize the battery and stretch the search.
- (NSInteger)batteryHosts:(NSArray<NSString *> *)hosts port:(int)port timeout:(int)to
                totalTime:(double *)sum failures:(NSMutableDictionary *)fails {
    __block NSInteger okc = 0; __block double tsum = 0;
    dispatch_group_t g = dispatch_group_create();
    NSObject *lock = [NSObject new];
    for (NSString *h in hosts) {
        dispatch_group_enter(g);
        [NSThread detachNewThreadWithBlock:^{
            if (!self->_cancel) {
                double secs = 0; int code = 0;
                BOOL ok = [self curlHost:h port:port timeout:to seconds:&secs code:&code];
                @synchronized (lock) {
                    if (ok) { okc++; tsum += secs; }
                    else if (fails) {
                        NSNumber *k = @(code);
                        fails[k] = @([fails[k] integerValue] + 1);
                    }
                }
            }
            dispatch_group_leave(g);
        }];
    }
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    if (sum) *sum = tsum;
    return okc;
}

// "28x12 35x2" - failure histogram for the log line.
static NSString *DPIFailText(NSDictionary *f) {
    if (!f.count) return @"-";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSNumber *k in [[f allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [parts addObject:[NSString stringWithFormat:@"%@x%@", k, f[k]]];
    return [parts componentsJoinedByString:@" "];
}

// nil = this ciadpi build rejected the strategy (not counted as "tested").
// *diag gets a short note for the search log.
- (DPIResult *)testStrategy:(NSString *)raw hosts:(NSArray *)hosts probes:(NSArray *)probes
                       diag:(NSString **)diag {
    NSArray *sargs = [DPIEngine argsForStrategy:raw];
    NSTask *t = sargs ? [self launchCiadpiPort:kDPITestPort strategyArgs:sargs] : nil;
    if (!t) { if (diag) *diag = @"launch failed"; return nil; }
    DPIResult *r = nil;
    if ([self waitReady:t port:kDPITestPort timeout:1.0]) {
        r = [DPIResult new];
        r.strategy = raw; r.total = (NSInteger)hosts.count;
        // Stage 1: two always-up hosts. A strategy that cannot even get these
        // through is dead; skip the full battery (saves ~5 s and a pile of curls).
        NSMutableDictionary *f1 = [NSMutableDictionary dictionary];
        double s1 = 0;
        NSInteger p1 = [self batteryHosts:probes port:kDPITestPort timeout:5 totalTime:&s1 failures:f1];
        if (p1 > 0 && !_cancel) {
            NSMutableDictionary *f2 = [NSMutableDictionary dictionary];
            double sum = 0;
            r.ok = [self batteryHosts:hosts port:kDPITestPort timeout:5 totalTime:&sum failures:f2];
            r.avgTime = r.ok ? sum / r.ok : 0;
            if (diag) *diag = [NSString stringWithFormat:@"fail %@", DPIFailText(f2)];
        } else if (diag) {
            *diag = [NSString stringWithFormat:@"probe fail %@", DPIFailText(f1)];
        }
    } else if (diag) {
        *diag = t.isRunning ? @"proxy did not listen" : @"ciadpi exited at start";
    }
    if (t.isRunning) { [t terminate]; [t waitUntilExit]; }
    return r;
}

- (NSString *)searchLogPath { return [_supDir stringByAppendingPathComponent:@"dpi_search.log"]; }

- (void)searchWithProgress:(DPIProgressBlock)progress done:(DPIDoneBlock)done {
    if (_searching) return;
    dispatch_queue_t cbq = _cbq;
    if (!self.available) { dispatch_async(cbq, ^{ done(NO, @"DPI-движок не найден"); }); return; }
    _searching = YES; _cancel = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        dispatch_async(cbq, ^{ progress(@"update", 0, 0, 0); });
        NSString *updNote = [self updateListsSync];

        NSArray<DPIEntry *> *ents = [self entries];
        NSMutableArray *hosts = [NSMutableArray arrayWithArray:[self hostsFromList:kDPIYTName]];
        NSArray *gv = [self hostsFromList:kDPIGVName];
        [hosts addObjectsFromArray:[gv subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)6, gv.count))]];
        NSArray *probes = @[@"www.youtube.com", @"i.ytimg.com"];
        if (hosts.count < 3 || !ents.count) {
            self->_searching = NO;
            dispatch_async(cbq, ^{ done(NO, @"нет данных для проверки"); });
            return;
        }
        NSInteger nNative = 0, nAdapted = 0, nCurated = 0;
        for (DPIEntry *e in ents) { if (e.curated) nCurated++; else if (e.adapted) nAdapted++; else nNative++; }
        NSInteger total = (NSInteger)ents.count;

        // The log is the way to see WHY a network gave no result: it is the only
        // evidence available when the search runs on a machine we cannot reach.
        NSMutableString *log = [NSMutableString string];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        // No network signature here on purpose: the person may paste this log into a chat
        // and the signature contains the router address.
        [log appendFormat:@"# Raketa DPI search %@\n# ciadpi options: %@\n"
                          @"# list: %ld originals + %ld adapted (~) + %ld macOS-first (M) = %ld candidates; %lu hosts per strategy; lists: %@\n"
                          @"# columns: №  ok/total  mean-s  failures(curl-exit x count; 1 = short body)  line\n",
                          [df stringFromDate:[NSDate date]],
                          [self probedOptions] ? @"probed" : @"probe failed (macOS defaults)",
                          (long)nNative, (long)nAdapted, (long)nCurated, (long)total, (unsigned long)hosts.count, updNote];

        // Control run: the same hosts with NO bypass. Tells "network is open /
        // blocked" apart from "strategy breaks the connection" in the log.
        dispatch_async(cbq, ^{ progress(@"search", 0, total, 0); });
        NSMutableDictionary *dfail = [NSMutableDictionary dictionary];
        double dsum = 0;
        NSInteger dOK = [self batteryHosts:hosts port:0 timeout:5 totalTime:&dsum failures:dfail];
        [log appendFormat:@"direct (no bypass)  %ld/%lu  failures %@\n", (long)dOK,
                          (unsigned long)hosts.count, DPIFailText(dfail)];

        // Second control: the SAME hosts through ciadpi with no desync option at all. If
        // "direct" is fine but this is not, the proxy chain itself is broken (not the
        // strategies); if both are blocked, the network blocks and only a strategy helps.
        NSInteger pOK = 0;
        {
            NSMutableDictionary *pfail = [NSMutableDictionary dictionary];
            double psum = 0;
            NSTask *pt = [self launchCiadpiPort:kDPITestPort strategyArgs:@[]];
            if (pt && !self->_cancel && [self waitReady:pt port:kDPITestPort timeout:1.0]) {
                pOK = [self batteryHosts:hosts port:kDPITestPort timeout:5 totalTime:&psum failures:pfail];
                [log appendFormat:@"proxy, no desync    %ld/%lu  failures %@\n", (long)pOK,
                                  (unsigned long)hosts.count, DPIFailText(pfail)];
            } else {
                [log appendString:@"proxy, no desync    could not start ciadpi\n"];
            }
            if (pt.isRunning) { [pt terminate]; [pt waitUntilExit]; }
        }

        NSMutableArray<DPIResult *> *found = [NSMutableArray array];
        NSMutableDictionary<NSString *, DPIResult *> *allTested = [NSMutableDictionary dictionary];
        NSInteger tested = 0, best = 0;
        for (NSInteger i = 0; i < total && !self->_cancel; i++) {
            NSInteger doneN = i, bestN = best, tot = total;
            dispatch_async(cbq, ^{ progress(@"search", doneN, tot, bestN); });
            DPIEntry *e = ents[(NSUInteger)i];
            NSString *diag = nil;
            DPIResult *r = [self testStrategy:e.raw hosts:hosts probes:probes diag:&diag];
            if (!r) {                          // unsupported by this build
                [log appendFormat:@"#%@  REJECTED (%@)  %@\n", e.label, diag ?: @"", e.raw];
                continue;
            }
            tested++;
            allTested[e.raw] = r;
            [log appendFormat:@"#%@  %ld/%ld  %.2f  %@  %@\n", e.label,
                              (long)r.ok, (long)r.total, r.avgTime, r.ok == r.total ? @"-" : (diag ?: @"-"), e.raw];
            if (r.ok > 0) { [found addObject:r]; if (r.ok > best) best = r.ok; }
            usleep(400000);                   // be gentle between strategies
        }
        BOOL cancelled = self->_cancel;
        self->_searching = NO;
        if (cancelled) {
            [log appendString:@"# cancelled\n"];
            [log writeToFile:[self searchLogPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            dispatch_async(cbq, ^{ done(NO, @"поиск остановлен"); });
            return;
        }

        [found sortUsingComparator:^NSComparisonResult(DPIResult *a, DPIResult *b) {
            if (a.ok != b.ok) return a.ok > b.ok ? NSOrderedAscending : NSOrderedDescending;
            if (a.avgTime != b.avgTime) return a.avgTime < b.avgTime ? NSOrderedAscending : NSOrderedDescending;
            return NSOrderedSame;
        }];
        self->_results = found;
        self->_resultsSig = [DPIEngine networkSignature];
        self->_resultsDate = [NSDate date];
        self->_lastTested = tested; self->_lastTotal = total;
        self->_lastNative = nNative; self->_lastAdapted = nAdapted; self->_lastCurated = nCurated;
        self->_directOK = dOK; self->_directTotal = (NSInteger)hosts.count;
        self->_passOK = pOK; self->_passTotal = (NSInteger)hosts.count;
        self->_tested = allTested;
        [self saveResults];
        [log appendFormat:@"# done: %lu working of %ld tested\n", (unsigned long)found.count, (long)tested];
        [log writeToFile:[self searchLogPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSString *sum = found.count
            ? [NSString stringWithFormat:@"Найдено %lu из %ld · %@",
               (unsigned long)found.count, (long)tested, updNote]
            : @"Рабочих не найдено · выберите вручную (▾)";
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
