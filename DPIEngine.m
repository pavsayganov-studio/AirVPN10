// DPIEngine.m — see DPIEngine.h for the overview.
//
// WHY a sidecar process and not packet tricks: macOS has no divert sockets and
// pf has no divert-packet, so GoodbyeDPI/zapret-style packet interception is
// not possible here. ByeDPI (ciadpi) does the same desync (split / disorder /
// OOB / TLS-record split) in userspace: setsockopt(IP_TTL) between send()
// calls. No root, no TUN — consistent with Raketa's System Proxy architecture.
//
// WHY the ByeByeDPI list is no longer tested (v0.13.4): upstream ciadpi enables the "fake
// packet" family (-f -n -S ...) only on Linux and Windows (FAKE_SUPPORT in params.h; the
// fake is sent with vmsplice/splice on Linux and TransmitFile on Windows, zero-copy tricks
// macOS does not have). 37 of the 60 ByeByeDPI lines need it, and the rest are plain cuts of
// the ClientHello. The search logs of 2026-10-07 and 2026-10-09 show every one of them (and the
// adapted "~" forms cut down to plain cuts) failing exactly like the no-bypass control, and the
// zapret community lists maintained in 2026 contain no plain cut for YouTube any more
// (handoff.md section 15). The candidates are now ten stream-cutting lines, one per mechanism.
//
// WHY the live test copies ByeByeDPI's own success rule: ByeByeDPI (SiteCheckUtils)
// counts a request as passed when an HTTP answer arrives and, if the server
// declared a Content-Length, the whole body arrived. v0.12.x demanded a clean
// curl exit inside a hard 4-5 s total limit instead, which fails any strategy that
// is merely slow (every TTL-based "disorder" waits for one TCP retransmit) even
// though it works.
//
// WHY DoH is only a fallback (v0.13.3, corrected in v0.13.4): v0.13.3 assumed that since
// February 2026 Russian networks stop answering plain DNS for YouTube names, so getaddrinfo()
// hangs (curl exit 28 "Resolving timed out") and every strategy fails before a ClientHello is
// sent. The log of 2026-10-09 disproved that on this network: the system resolver answered
// (www.youtube.com -> a Google address) and the control "direct, DoH addresses" was exactly as
// blocked (3/19) as "direct, system DNS" - the filter is on the wire, not in DNS. DoH stays for
// networks where the system answer really is unusable: the search uses it only then, and at
// runtime sing-box resolves the YouTube names over it (and speaks SOCKS4 to ciadpi, which then
// never resolves anything) only when the last search recorded an unusable system resolver.
// v0.14.2 — WHAT CHANGED AND WHY. Every ciadpi stream-cutting line ("M") is recorded as NOT
// working on macOS: 0 of 68 in the v0.13.3 log, none in the v0.13.4/0.13.5 runs, and ciadpi has
// no fake packets here (FAKE_SUPPORT is Linux/Windows only, dpi-research.md section 2). The M lines
// stay in the list as tripwires and for manual choice; nothing more is added to them.
// What replaces them: sing-box 1.14 ships the fake-ClientHello injection this file's planned
// "lab" was going to write by hand - the route option `tls_spoof` (+ `tls_spoof_method`) and the
// TCP / TLS-record fragmentation options. Read in its source on 2026-10-14: raw sockets with
// IP_HDRINCL, sequence numbers from the kernel's pcblist_n, ROOT required, applied to the direct
// connection after the dial, the fake goes out with the first write of the real ClientHello.
// These are the "S" candidates. They need no ciadpi at all: in YouTube mode the matching rule only
// sets the options and the connection stays `direct`; in the search ONE root sing-box carries an
// inbound per candidate (a password prompt per candidate would be unusable), and the same probes,
// success rule and ranking are applied to it.
// v0.15.3 - WHAT CHANGED AND WHY. The log of 2026-10-25 (v0.15.2) is the first with a candidate that
// opened anything: S3, a fake ClientHello (wrong-sequence) PLUS TCP fragmentation, 6/19 against 3/19
// with no bypass; every other S line (fake alone, fragments alone, fake + TLS records) and every M line
// died at the probe stage. Two things in that log were wrong or missing:
//   * the wire probe asked ONE address (the first the resolver gave) and printed "address or route
//     blocked ... no ClientHello trick can help" - and then S3 did help on other hosts. Google answers
//     with many addresses and they need not behave alike (users report Google/googlevideo addresses cut
//     at the TCP stage on some operators and a name filter elsewhere). The probe now asks up to four
//     addresses; when EVERY system address fails at the TCP stage it asks DoH for others and, if one of
//     those answers, the rest of the run and the runtime use DoH names;
//   * "mean 0.00 s" for six passed hosts is not a real page load, and the log did not say which hosts
//     passed. The controls and every candidate that opens anything now log "passed: host http/bytes/secs".
// The S list is rebuilt around the one combination that worked (see DPISpoofLines).
#import "DPIEngine.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <libproc.h>
#import <signal.h>
#import <unistd.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>

static const int kDPIPort     = 10811;   // runtime ciadpi (system proxy -> sing-box -> here)
static const int kDPITestPort = 10820;   // throw-away ciadpi used by the search
static const NSUInteger kDPIWireMax = 4;   // v0.15.3: addresses of one name the wire probe asks
static const int kDPISBBase   = 10830;   // search: first SOCKS inbound of the root sing-box (one per "S" candidate)
static NSString *const kDPIRepoRaw  = @"https://raw.githubusercontent.com/romanvht/ByeByeDPI/master/app/src/main/assets/";
static NSString *const kDPISelKey   = @"RaketaDPIStrategy";
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

#pragma mark - DNS over HTTPS (v0.13.3)

// Literal-IP DoH endpoints, tried in this order; the first that answers wins. An IP has
// no name for a filter to match, and DoH is TLS on 443, not UDP/53. Order (v0.13.4): 8.8.4.4
// first - it answered in the search log of 2026-10-09 while 1.1.1.1 gave no answer, and it
// kept working when 8.8.8.8 stopped answering over TCP on 2026-07-03. 8.8.8.8 is last for the
// same reason. Only used when the system resolver is unusable.
static NSArray<NSString *> *DPIDoHServers(void) {
    return @[@"https://8.8.4.4/dns-query", @"https://1.0.0.1/dns-query", @"https://9.9.9.9/dns-query",
             @"https://1.1.1.1/dns-query", @"https://8.8.8.8/dns-query"];
}

// The stored endpoint ends up in a sing-box config, so only this exact shape is accepted.
static BOOL DPIValidDoHURL(NSString *u) {
    static NSRegularExpression *re; static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"^https://[0-9]{1,3}(\\.[0-9]{1,3}){3}/dns-query$" options:0 error:nil];
    });
    return [u isKindOfClass:[NSString class]] && u.length < 64
        && [re numberOfMatchesInString:u options:0 range:NSMakeRange(0, u.length)] == 1;
}

// RFC 8484 GET parameter: a wire-format A query for `name`, base64url without padding.
static NSString *DPIDNSQueryParam(NSString *name) {
    NSMutableData *q = [NSMutableData data];
    static const uint8_t hdr[12] = {0, 0, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0};   // id 0, RD, 1 question
    [q appendBytes:hdr length:sizeof hdr];
    for (NSString *label in [name componentsSeparatedByString:@"."]) {
        NSData *l = [label dataUsingEncoding:NSASCIIStringEncoding];
        if (!l.length || l.length > 63) return nil;
        uint8_t n = (uint8_t)l.length;
        [q appendBytes:&n length:1];
        [q appendData:l];
    }
    static const uint8_t tail[5] = {0, 0, 1, 0, 1};                              // root, A, IN
    [q appendBytes:tail length:sizeof tail];
    NSString *b = [q base64EncodedStringWithOptions:0];
    b = [b stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    b = [b stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [b stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

// Index just past a (possibly compressed) DNS name starting at i, or -1.
static NSInteger DPISkipDNSName(const uint8_t *p, NSUInteger n, NSUInteger i) {
    for (int guard = 0; guard < 128 && i < n; guard++) {
        uint8_t len = p[i];
        if (len == 0) return (NSInteger)i + 1;
        if ((len & 0xC0) == 0xC0) return i + 2 <= n ? (NSInteger)i + 2 : -1;
        if (len & 0xC0) return -1;
        i += 1 + len;
    }
    return -1;
}

// Not loopback, private, link-local, CGNAT or multicast: what a poisoned answer usually is.
static BOOL DPIPublicIPv4(unsigned a, unsigned b) {
    if (a == 0 || a == 10 || a == 127 || a >= 224) return NO;
    if (a == 169 && b == 254) return NO;
    if (a == 172 && b >= 16 && b <= 31) return NO;
    if (a == 192 && b == 168) return NO;
    if (a == 100 && b >= 64 && b <= 127) return NO;
    return YES;
}

// Public IPv4 addresses of the A records in a DNS response; empty on any error or RCODE.
static NSArray<NSString *> *DPIParseDNSA(NSData *d) {
    const uint8_t *p = d.bytes; NSUInteger n = d.length;
    if (n < 12 || (p[3] & 0x0F) != 0) return @[];
    NSUInteger qd = ((NSUInteger)p[4] << 8) | p[5], an = ((NSUInteger)p[6] << 8) | p[7];
    NSInteger i = 12;
    for (NSUInteger q = 0; q < qd; q++) {
        i = DPISkipDNSName(p, n, (NSUInteger)i);
        if (i < 0 || (NSUInteger)i + 4 > n) return @[];
        i += 4;
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger a = 0; a < an; a++) {
        i = DPISkipDNSName(p, n, (NSUInteger)i);
        if (i < 0 || (NSUInteger)i + 10 > n) break;
        unsigned type = ((unsigned)p[i] << 8) | p[i + 1];
        NSUInteger rdlen = ((NSUInteger)p[i + 8] << 8) | p[i + 9];
        i += 10;
        if ((NSUInteger)i + rdlen > n) break;
        if (type == 1 && rdlen == 4 && DPIPublicIPv4(p[i], p[i + 1]))
            [out addObject:[NSString stringWithFormat:@"%u.%u.%u.%u", p[i], p[i + 1], p[i + 2], p[i + 3]]];
        i += (NSInteger)rdlen;
    }
    return out;
}

// What the system resolver says: an IPv4 string, "timeout" or "error N". getaddrinfo()
// cannot be interrupted, so it runs on its own thread and is abandoned on timeout.
// Up to `maxN` public IPv4 addresses the system resolver gives for `host`, in its order (v0.15.3; it used to
// return only the first). nil = no usable answer; *err then says "timeout" or "error <rc>" for the log.
static NSArray<NSString *> *DPISystemResolveAll(NSString *host, NSTimeInterval within, NSUInteger maxN,
                                                NSString **err) {
    __block NSArray<NSString *> *got = nil;
    __block NSString *why = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [NSThread detachNewThreadWithBlock:^{
        struct addrinfo hints; memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
        struct addrinfo *res = NULL;
        int rc = getaddrinfo(host.UTF8String, NULL, &hints, &res);
        NSMutableArray<NSString *> *out = [NSMutableArray array];
        for (struct addrinfo *p = res; rc == 0 && p && out.count < maxN; p = p->ai_next) {
            char buf[INET_ADDRSTRLEN];
            if (!p->ai_addr || !inet_ntop(AF_INET, &((struct sockaddr_in *)p->ai_addr)->sin_addr, buf, sizeof buf))
                continue;
            unsigned a = 0, b = 0, c = 0, d = 0;
            if (sscanf(buf, "%u.%u.%u.%u", &a, &b, &c, &d) != 4 || !DPIPublicIPv4(a, b)) continue;
            NSString *s = [NSString stringWithUTF8String:buf];
            if (s && ![out containsObject:s]) [out addObject:s];
        }
        if (res) freeaddrinfo(res);
        if (out.count) got = out;
        else why = rc != 0 ? [NSString stringWithFormat:@"error %d", rc] : @"no public address";
        dispatch_semaphore_signal(sem);
    }];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(within * NSEC_PER_SEC))) != 0) {
        if (err) *err = @"timeout";
        return nil;
    }
    if (!got && err) *err = why ?: @"error";
    return got;
}

#pragma mark - DPIResult

@implementation DPIResult
@end

// One candidate: `raw` is what is run (and what is the identity of a result), `src` is
// 1000 + its position in DPICuratedLines().
@interface DPIEntry : NSObject
@property (copy)   NSString *raw;
@property (assign) NSInteger src;
@property (copy)   NSString *label;      // "M3"
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
    NSInteger _directOK, _directTotal;     // control run: same hosts, no bypass at all
    NSInteger _passOK, _passTotal;         // control run: same hosts through ciadpi with NO desync
    NSInteger _lastCurated;                // candidates of the last search
    NSString *_dohURL;                     // DoH endpoint the last search used (nil = system DNS)
    BOOL     _dnsSysBad;                   // the system resolver gave no usable answer for YouTube
    BOOL     _sysAddrBlocked;              // v0.15.3: it answered, but none of its addresses completes a TCP handshake while a DoH one does
    NSString *_wireVerdict;                // one-line result of the last wire probe (menu note), nil = none
    BOOL     _wireSNI;                     // the same address completed TLS for another SNI: a name-based filter
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

    NSString *withVal  = @"sdoqftnmeMrOQaALuTgRKW";  // short options that take a value (-W: ms between parts)
    NSString *noVal    = @"SZ";                      // md5sig, wait-send
    NSSet *longWith = [NSSet setWithArray:@[@"split",@"disorder",@"oob",@"disoob",@"fake",@"ttl",
        @"fake-sni",@"fake-offset",@"fake-tls-mod",@"oob-data",@"mod-http",@"tlsrec",@"tlsminor",
        @"udp-fake",@"auto",@"auto-mode",@"cache-ttl",@"timeout",@"round",@"proto",@"def-ttl",
        @"await-int"]];
    NSSet *longNo = [NSSet setWithArray:@[@"md5sig",@"wait-send"]];

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
            if (![t isEqualToString:@"--md5sig"] && ![t isEqualToString:@"--wait-send"] && !hasEq && i + 1 < toks.count) [g addObject:toks[++i]];
        } else if (t.length == 2 && ![t isEqualToString:@"-S"] && ![t isEqualToString:@"-Z"] && i + 1 < toks.count) {
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
                @"--auto-mode": @"-L", @"--def-ttl": @"-g",
                @"--wait-send": @"-Z", @"--await-int": @"-W"};
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

// Candidates for a macOS ciadpi (v0.13.4: the ONLY candidates; the ByeByeDPI list and its
// adapted "~" forms are no longer tested). What a macOS ciadpi can do is cut the stream
// (split / disorder / OOB / TLS-record split); real fake packets exist only in the Linux and
// Windows builds. Evidence, 2026-10-09:
//   * all 68 candidates of v0.13.3 (22 ByeByeDPI lines, 34 adapted, 12 curated) ended at
//     "probe fail 28x2", identical to the no-bypass controls (3/19), with system DNS answering;
//   * every YouTube rule of the zapret community lists maintained in 2026 (Flowseal, 21 rules
//     read on 2026-10-09) uses fake packets, a TCP sequence overlap or a fake host segment; no
//     plain split/disorder rule is left;
//   * FOCI 2025 (Niere et al., ECH in censorship circumvention): TSPU reassembles TCP now;
//     TCP segmentation alone or TLS-record fragmentation alone no longer beat it, the two
//     combined still did against the ECH block. An Iran 2026 report says reassembly also
//     nullifies 10-30 B fragments with 10-20 ms pauses - the Xray-style v0.13.3 lines M4/M5
//     are gone for that reason.
// What is left is one line per mechanism, so a network with a weaker filter still gets its
// chance and a search takes about a minute instead of six:
//   M1  cut at the SNI                          M2  the same, second piece held back 20 ms
//   M3  TLS-record cut + TCP cut at the SNI     M4  the same, paced (the FOCI 2025 combination)
//   M5  cut before the SNI, then 1-byte pieces over it, paced (SpoofDPI "sni" mode; GFW
//       measurements 2026: 1-5 B pieces)
//   M6  upstream's BSD/Windows recipe (--split 1+s --disorder 3+s), paced
//   M7  OOB byte inside the SNI, paced          M8  --disoob 3 --disorder 7 (upstream README), paced
//   M9  alternating TTL=1 pieces over the SNI   M10 a bare OOB byte after the first byte
// On a non-Linux ciadpi sock_has_notsent() is a stub, so nothing waits for a part to leave
// before the TTL is restored or the next part is sent; the hidden -Z (wait after each part)
// with -W <ms> does (v0.13.3). None of these is expected to beat a reassembling filter: they
// are tripwires, ranked by the live test like any other candidate.
static NSArray<NSString *> *DPICuratedLines(void) {
    return @[@"-s1+s",
             @"-s1+s -Z -W 20",
             @"-r1+s -s1+s",
             @"-r1+s -s1+s -Z -W 10",
             @"-s0+s -s1:12:1+s -Z -W 8",
             @"-s1+s -d3+s -Z -W 10",
             @"-o3+s -Z -W 10",
             @"-q3+s -d7+s -Z -W 10",
             @"-d0:6:1+s -Z -W 10",
             @"-o1"];
}

// ── Strategies run by sing-box itself ("S", v0.14.2; list rebuilt in v0.15.3) ─────────────────
// raw = "sb:key=value;key=value": spoof=<fake SNI> method=<wrong-sequence|wrong-checksum|wrong-ack|
// wrong-md5> frag=1 (TCP fragmentation at the SNI) rec=1 (TLS record fragmentation) delay=<ms>
// (tls_fragment_fallback_delay, needs frag=1). The two fragmentation options are mutually exclusive in
// sing-box ("sing-box check" refuses both together). The strategy is stored in NSUserDefaults and ends up
// in a config, so DPISBOptions() is a whitelist: anything else is nil.
//
// WHAT THE 2026-10-25 LOG SAID [measured]: of the eight v0.14.2 lines only "fake ClientHello
// (wrong-sequence) + TCP fragments" opened anything (6/19 against 3/19 with no bypass); the fake alone
// (four methods, two fake names), the fragments alone and fake + TLS records all died at the probe stage.
// That is the shape of every rule in the maintained zapret list - a fake AND a split in one rule
// (dpi-research.md section 2) - so the list is now built around that one combination and varies the two
// things never varied: HOW the real server rejects the fake, and WHICH name the fake carries. The old S1,
// S2, S4-S8 are gone as measured dead; the old S3 is S1 now (the strategy line is unchanged, so a saved
// choice stays valid). Labels are positions, as always.
//   S1 fake google.com, badseq + TCP fragments      (measured 6/19)
//   S2 the same, bad checksum     S3 the same, md5sig option     S4 the same, bad ack
//   S5 fake name ya.ru            S6 fake name max.ru (the name the zapret lists use for non-Google rules)
//   S7 S1 with the pause between fragments 40 ms instead of sing-box's 500 ms [inferred]: on macOS
//      sing-box waits for the ACK of each piece (SO_NWRITE) and uses the fixed pause only when the ACK
//      came within 20 ms - a near cache or a transparent proxy [source: common/tlsfragment/wait_darwin.go]
static NSArray<NSString *> *DPISpoofLines(void) {
    return @[@"sb:spoof=www.google.com;method=wrong-sequence;frag=1",
             @"sb:spoof=www.google.com;method=wrong-checksum;frag=1",
             @"sb:spoof=www.google.com;method=wrong-md5;frag=1",
             @"sb:spoof=www.google.com;method=wrong-ack;frag=1",
             @"sb:spoof=ya.ru;method=wrong-sequence;frag=1",
             @"sb:spoof=max.ru;method=wrong-sequence;frag=1",
             @"sb:spoof=www.google.com;method=wrong-sequence;frag=1;delay=40"];
}

// The route-options fields for an "sb:" line; nil when the line is not a valid one.
static NSDictionary *DPISBOptions(NSString *raw) {
    if (![raw isKindOfClass:[NSString class]] || ![raw hasPrefix:@"sb:"]) return nil;
    NSSet *methods = [NSSet setWithObjects:@"wrong-sequence", @"wrong-checksum", @"wrong-ack", @"wrong-md5", nil];
    NSMutableDictionary *o = [NSMutableDictionary dictionary];
    for (NSString *kv in [[raw substringFromIndex:3] componentsSeparatedByString:@";"]) {
        NSArray *p = [kv componentsSeparatedByString:@"="];
        if (p.count != 2) return nil;
        NSString *k = p[0], *v = p[1];
        if ([k isEqualToString:@"spoof"])       { if (!DPIValidHost(v)) return nil; o[@"tls_spoof"] = v; }
        else if ([k isEqualToString:@"method"]) { if (![methods containsObject:v]) return nil; o[@"tls_spoof_method"] = v; }
        else if ([k isEqualToString:@"rec"])    { if (![v isEqualToString:@"1"]) return nil; o[@"tls_record_fragment"] = [NSNumber numberWithBool:YES]; }
        else if ([k isEqualToString:@"frag"])   { if (![v isEqualToString:@"1"]) return nil; o[@"tls_fragment"] = [NSNumber numberWithBool:YES]; }
        else if ([k isEqualToString:@"delay"]) {          // pause between the pieces, whole ms, 5...2000
            NSInteger ms = v.integerValue;
            if (ms < 5 || ms > 2000 || ![[@(ms) stringValue] isEqualToString:v]) return nil;
            o[@"tls_fragment_fallback_delay"] = [NSString stringWithFormat:@"%ldms", (long)ms];
        }
        else return nil;
    }
    if (o[@"tls_spoof_method"] && !o[@"tls_spoof"]) return nil;
    if (o[@"tls_record_fragment"] && o[@"tls_fragment"]) return nil;
    if (o[@"tls_fragment_fallback_delay"] && !o[@"tls_fragment"]) return nil;
    return o.count ? o : nil;
}

+ (BOOL)isSingBoxStrategy:(NSString *)raw { return DPISBOptions(raw) != nil; }

// Every runnable candidate, in TEST order (v0.13.4: DPICuratedLines() only). A line the
// safety filter rejects, or that this ciadpi cannot run even after cutting the options it
// lacks, is skipped but keeps its number, so "M3" is always the third line of the list.
- (NSArray<DPIEntry *> *)entries {
    NSMutableArray<DPIEntry *> *out = [NSMutableArray array];
    NSMutableSet *seenKey = [NSMutableSet set];
    NSInteger k = 0;
    // v0.14.2: the sing-box-run strategies come first (S1...), the stream-cutting lines after them.
    NSInteger sk = 0;
    for (NSString *l in DPISpoofLines()) {
        sk++;
        if (!DPISBOptions(l)) continue;
        DPIEntry *se = [DPIEntry new];
        se.raw = l; se.src = 2000 + sk;
        se.label = [NSString stringWithFormat:@"S%ld", (long)sk];
        [out addObject:se];
    }
    for (NSString *l in DPICuratedLines()) {
        k++;
        BOOL ad = NO;
        NSString *run = [DPIEngine argsForStrategy:l] ? [self runnableForm:l adapted:&ad] : nil;
        if (!run) continue;
        NSString *key = [self dedupeKey:run];
        if ([seenKey containsObject:key]) continue;
        [seenKey addObject:key];
        DPIEntry *e = [DPIEntry new];
        e.raw = run; e.src = 1000 + k;
        e.label = [NSString stringWithFormat:@"M%ld", (long)k];
        [out addObject:e];
    }
    return out;
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
        r.strategy = e.raw; r.number = e.src; r.label = e.label;
        if (t) { r.ok = t.ok; r.total = t.total; r.avgTime = t.avgTime; }
        [out addObject:r];
    }
    return out;
}

// Returns a human-readable note. Never throws away a good local list on failure.
// v0.13.4: only the two host lists are refreshed; the strategy list is not used any more.
- (NSString *)updateListsSync {
    NSDictionary *hl = @{@"proxytest_youtube.sites": kDPIYTName,
                         @"proxytest_googlevideo.sites": kDPIGVName};
    NSInteger fetched = 0;
    BOOL changed = NO;
    for (NSString *remote in hl) {
        NSData *d = DPIFetch([kDPIRepoRaw stringByAppendingString:remote], 10);
        NSString *t = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
        NSInteger good = 0;
        for (NSString *l in [self linesOf:t ?: @""]) if (DPIValidHost(l)) good++;
        if (good < 3) continue;                      // a failed or odd fetch keeps the old list
        fetched++;
        NSString *old = [NSString stringWithContentsOfFile:[self effectivePathForList:hl[remote]]
                                                  encoding:NSUTF8StringEncoding error:nil];
        if (![DPITrim(t) isEqualToString:DPITrim(old ?: @"")]) changed = YES;
        [d writeToFile:[_supDir stringByAppendingPathComponent:
                        [@"dpi_" stringByAppendingString:hl[remote]]] atomically:YES];
    }
    if (!fetched) return @"репозиторий недоступен";
    return changed ? @"списки сайтов обновлены" : @"списки сайтов актуальны";
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
    _lastCurated = [j[@"curated"] integerValue];
    _directOK = [j[@"direct_ok"] integerValue]; _directTotal = [j[@"direct_n"] integerValue];
    _passOK = [j[@"pass_ok"] integerValue]; _passTotal = [j[@"pass_n"] integerValue];
    _dohURL = DPIValidDoHURL(j[@"doh"]) ? j[@"doh"] : nil;      // validated: it goes into a config
    _dnsSysBad = [j[@"dns_bad"] boolValue];
    _sysAddrBlocked = [j[@"addr_blocked"] boolValue];
    NSString *wv = j[@"wire"];
    _wireVerdict = ([wv isKindOfClass:[NSString class]] && wv.length) ? wv : nil;
    _wireSNI = [j[@"wire_sni"] boolValue];
}

- (void)saveResults {
    NSMutableArray *a = [NSMutableArray array], *all = [NSMutableArray array];
    for (DPIResult *r in _results)
        [a addObject:@{@"s": r.strategy, @"ok": @(r.ok), @"n": @(r.total), @"t": @(r.avgTime)}];
    for (DPIResult *r in [_tested allValues])
        [all addObject:@{@"s": r.strategy, @"ok": @(r.ok), @"n": @(r.total), @"t": @(r.avgTime)}];
    NSDictionary *j = @{@"sig": _resultsSig ?: @"", @"date": @([_resultsDate timeIntervalSince1970]),
                        @"tested": @(_lastTested), @"listed": @(_lastTotal),
                        @"curated": @(_lastCurated),
                        @"direct_ok": @(_directOK), @"direct_n": @(_directTotal),
                        @"pass_ok": @(_passOK), @"pass_n": @(_passTotal),
                        @"doh": _dohURL ?: @"", @"dns_bad": @(_dnsSysBad), @"addr_blocked": @(_sysAddrBlocked),
                        @"wire": _wireVerdict ?: @"", @"wire_sni": @(_wireSNI),
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
        if (r.ok > 0 && e) { r.number = e.src; r.label = e.label; [a addObject:r]; }
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
        r.number = e.src; r.label = e.label;
    }
    return r;
}
- (NSString *)coverageNote {
    if (!_lastTotal) return @"";
    // Results saved by v0.13.3 or older cover another candidate set (68 lines).
    if (!_lastCurated || _lastTotal != (NSInteger)[self entries].count)
        return @"Результаты старого формата — повторите поиск 🔍";
    return [NSString stringWithFormat:@"Проверено %ld · подделка ClientHello (sing-box, S) и разрезание потока (ciadpi, M)",
            (long)_lastTested];
}
// DNS first (v0.13.3), then the two control runs.
- (NSString *)diagnosisNote {
    NSString *ctl = [self controlNote] ?: @"";
    NSString *wire = _wireVerdict.length ? [_wireVerdict stringByAppendingString:@" "] : @"";
    if (_sysAddrBlocked && _dohURL.length)
        return [NSString stringWithFormat:@"%@Адреса YouTube от DNS провайдера не отвечают — имена через DoH %@. %@",
                wire, [[NSURL URLWithString:_dohURL] host] ?: @"", ctl];
    if (_dnsSysBad && _dohURL.length)
        return [NSString stringWithFormat:@"%@DNS провайдера не отдаёт YouTube — имена через DoH %@. %@",
                wire, [[NSURL URLWithString:_dohURL] host] ?: @"", ctl];
    if (_dnsSysBad && _directTotal)
        return [NSString stringWithFormat:@"%@⚠ DNS провайдера не отвечает, DoH недоступен. %@", wire, ctl];
    return [wire stringByAppendingString:ctl];
}
// One line that says WHICH kind of failure the last search saw, from the two control
// runs (same hosts: directly, and through ciadpi with no desync at all):
//   direct fine, proxy broken  -> our proxy chain is at fault, not the strategies
//   both blocked               -> the network blocks; only a better strategy helps
//   direct fine, proxy fine    -> nothing visible to bypass
- (NSString *)controlNote {
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
    if (DPISBOptions(raw)) {                       // v0.14.2: sing-box does the desync, no ciadpi at all
        dispatch_queue_t cbq0 = _cbq;
        dispatch_async(_q, ^{
            [self killProxyOnQueue];
            self->_proxyStrategy = raw;
            dispatch_async(cbq0, ^{ completion(YES, nil); });
        });
        return;
    }
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

// One DoH A lookup through curl (same binary and network stack as the rest of the search,
// and it ignores the system proxy). Empty array = no usable answer.
- (NSArray<NSString *> *)dohLookup:(NSString *)host server:(NSString *)base seconds:(double *)secs {
    NSString *param = DPIDNSQueryParam(host);
    if (!param) return @[];
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/curl";
    t.arguments = @[@"-q", @"-sS", @"--http1.1", @"-m", @"4", @"-H", @"accept: application/dns-message",
                    [NSString stringWithFormat:@"%@?dns=%@", base, param]];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    t.standardError  = [NSFileHandle fileHandleWithNullDevice];
    t.standardInput  = [NSFileHandle fileHandleWithNullDevice];
    @synchronized (_testTasks) { [_testTasks addObject:t]; }
    NSDate *t0 = [NSDate date];
    NSArray *ips = @[];
    @try {
        [t launch];
        NSData *out = [[p fileHandleForReading] readDataToEndOfFile];
        [t waitUntilExit];
        ips = DPIParseDNSA(out);
    } @catch (NSException *e) { ips = @[]; }
    @synchronized (_testTasks) { [_testTasks removeObject:t]; }
    if (secs) *secs = -[t0 timeIntervalSinceNow];
    return ips;
}

// name -> first public IPv4 over DoH, all names concurrently (one short-lived thread each,
// for the same reason as batteryHosts). Names without an answer are left out.
- (NSDictionary<NSString *, NSString *> *)dohResolveNames:(NSArray<NSString *> *)names server:(NSString *)base {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    dispatch_group_t g = dispatch_group_create();
    NSObject *lock = [NSObject new];
    for (NSString *n in names) {
        dispatch_group_enter(g);
        [NSThread detachNewThreadWithBlock:^{
            if (!self->_cancel) {
                NSArray *a = [self dohLookup:n server:base seconds:NULL];
                if (a.count) @synchronized (lock) { out[n] = a[0]; }
            }
            dispatch_group_leave(g);
        }];
    }
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    return out;
}

// One HTTPS request. port > 0: through the proxy there (SOCKS5 with the host name, or
// SOCKS4 with the DoH address when `ips` is given); port == 0: direct
// (the control run). YES when it passes ByeByeDPI's rule (DPIRequestPassed).
// *code is 0 on success, else curl's exit status, or 1 when curl was content but
// the body fell short (declared length not reached / stalled under 32 KB).
//
// Timeouts: --connect-timeout covers TCP + SOCKS + TLS handshake; -Y/-y aborts a
// transfer that stalls (the DPI freeze), -m is only a backstop for huge pages.
// None of them punishes a strategy for being slow but alive.
- (BOOL)curlHost:(NSString *)host port:(int)port ips:(NSDictionary<NSString *, NSString *> *)ips
          timeout:(int)to seconds:(double *)secs code:(int *)code
             http:(int *)httpOut size:(long long *)sizeOut {
    NSMutableArray *args = [NSMutableArray arrayWithObjects:
        @"-q", @"-sS", @"-o", @"/dev/null", @"-D", @"-", @"--http1.1",
        @"-L", @"--max-redirs", @"3",
        @"--connect-timeout", [NSString stringWithFormat:@"%d", to],
        @"-m", [NSString stringWithFormat:@"%d", to * 3],
        @"-Y", @"1", @"-y", [NSString stringWithFormat:@"%d", to], nil];
    // DoH addresses (v0.13.3): curl connects to the IP it is given for every name this run
    // knows (redirects between them included), so the system resolver is never asked; the
    // proxy request then carries the IPv4 address, as sing-box's SOCKS4 outbound does.
    for (NSString *n in ips)
        [args addObjectsFromArray:@[@"--resolve", [NSString stringWithFormat:@"%@:443:%@", n, ips[n]]]];
    if (port > 0)
        [args addObjectsFromArray:@[ips.count ? @"--socks4" : @"--socks5-hostname",
                                    [NSString stringWithFormat:@"127.0.0.1:%d", port]]];
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
    if (httpOut) *httpOut = 0;
    if (sizeOut) *sizeOut = 0;
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
        if (httpOut) *httpOut = http;
        if (sizeOut) *sizeOut = size;
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
- (NSInteger)batteryHosts:(NSArray<NSString *> *)hosts port:(int)port
                      ips:(NSDictionary<NSString *, NSString *> *)ips timeout:(int)to
                totalTime:(double *)sum failures:(NSMutableDictionary *)fails
                   passed:(NSMutableArray<NSString *> *)passed {
    __block NSInteger okc = 0; __block double tsum = 0;
    dispatch_group_t g = dispatch_group_create();
    NSObject *lock = [NSObject new];
    for (NSString *h in hosts) {
        dispatch_group_enter(g);
        [NSThread detachNewThreadWithBlock:^{
            if (!self->_cancel) {
                double secs = 0; int code = 0, http = 0; long long size = 0; BOOL ok = NO;
                if (ips.count && !ips[h]) code = 6;      // DoH had no address: counted, no curl
                else ok = [self curlHost:h port:port ips:ips timeout:to seconds:&secs code:&code
                                    http:&http size:&size];
                @synchronized (lock) {
                    if (ok) {
                        okc++; tsum += secs;
                        // v0.15.3: what really came back (messages to a nil `passed` do nothing)
                        [passed addObject:[NSString stringWithFormat:@"%@ %d/%lldB/%.2fs", h, http, size, secs]];
                    } else if (fails) {
                        NSNumber *k = @(code);
                        fails[k] = @([fails[k] integerValue] + 1);
                    }
                }
            }
            dispatch_group_leave(g);
        }];
    }
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    [passed sortUsingSelector:@selector(compare:)];
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

// "    passed: host http/bytes/secs; ..." for the log (v0.15.3): which hosts a run really opened and with
// what - the only way to tell a real page load from an accident of the success rule.
static NSString *DPIPassText(NSArray<NSString *> *p) {
    if (!p.count) return @"";
    return [NSString stringWithFormat:@"    passed: %@\n", [p componentsJoinedByString:@"; "]];
}

// nil = this ciadpi build rejected the strategy (not counted as "tested").
// *diag gets a short note for the search log.
- (DPIResult *)testStrategy:(NSString *)raw hosts:(NSArray *)hosts probes:(NSArray *)probes
                       ips:(NSDictionary<NSString *, NSString *> *)ips diag:(NSString **)diag {
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
        NSInteger p1 = [self batteryHosts:probes port:kDPITestPort ips:ips timeout:5 totalTime:&s1 failures:f1 passed:nil];
        if (p1 > 0 && !_cancel) {
            NSMutableDictionary *f2 = [NSMutableDictionary dictionary];
            NSMutableArray<NSString *> *pl = [NSMutableArray array];
            double sum = 0;
            r.ok = [self batteryHosts:hosts port:kDPITestPort ips:ips timeout:5 totalTime:&sum failures:f2 passed:pl];
            r.passed = pl;
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

// ── "S" candidates (v0.14.2) ────────────────────────────────────────────────────────────────
// Starts ONE root sing-box with a SOCKS inbound per "S" entry (ports kDPISBBase...), each inbound
// carrying its own route-options rule. `ports` gets raw -> port. NO when there is nothing to start
// or it did not come up; *why says so for the log. The password prompt is the app's (privStart).
- (BOOL)startSBSearchFor:(NSArray<DPIEntry *> *)ents ports:(NSMutableDictionary<NSString *, NSNumber *> *)ports
                     pid:(int *)pidOut why:(NSString **)why log:(NSMutableString *)log {
    NSMutableArray *inb = [NSMutableArray array], *rules = [NSMutableArray array];
    NSInteger i = 0;
    for (DPIEntry *e in ents) {
        NSDictionary *o = DPISBOptions(e.raw);
        if (!o) continue;
        NSString *tag = [NSString stringWithFormat:@"s%ld", (long)i];
        [inb addObject:@{@"type": @"socks", @"tag": tag, @"listen": @"127.0.0.1",
                         @"listen_port": @(kDPISBBase + i)}];
        NSMutableDictionary *r = [@{@"inbound": @[tag], @"action": @"route-options"} mutableCopy];
        [r addEntriesFromDictionary:o];
        [rules addObject:r];
        ports[e.raw] = @(kDPISBBase + i);
        i++;
    }
    if (!inb.count) return NO;
    NSString *bin = self.coreBinary ? self.coreBinary() : nil;
    if (!self.privStart || !bin.length || ![[NSFileManager defaultManager] isExecutableFileAtPath:bin]) {
        if (why) *why = @"no root launcher or sing-box";
        [log appendString:@"sb: S candidates skipped (no root launcher or no sing-box)\n"];
        return NO;
    }
    NSDictionary *cfg = @{@"log": @{@"level": @"warn"}, @"inbounds": inb,
                          @"outbounds": @[@{@"type": @"direct", @"tag": @"direct"}],
                          @"route": @{@"rules": rules, @"final": @"direct"}};
    NSString *cfgPath = [_supDir stringByAppendingPathComponent:@"dpi_sb_search.json"];
    NSString *logPath = [_supDir stringByAppendingPathComponent:@"dpi_sb_search.log"];
    NSData *cd = [NSJSONSerialization dataWithJSONObject:cfg options:0 error:nil];
    if (!cd || ![cd writeToFile:cfgPath atomically:YES]) {
        if (why) *why = @"could not write the sing-box config";
        [log appendString:@"sb: could not write the config\n"];
        return NO;
    }
    __block int pid = 0;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    self.privStart(bin, cfgPath, logPath, ^(int p, NSString *e) { pid = p; err = e; dispatch_semaphore_signal(sem); });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC))) != 0)
        err = @"no answer to the password prompt";
    if (pid <= 0) {
        if (why) *why = err ?: @"root start failed";
        [log appendFormat:@"sb: not started (%@)\n", err ?: @"?"];
        return NO;
    }
    *pidOut = pid;
    BOOL up = NO;
    for (int w = 0; w < 40 && !_cancel; w++) {
        if (DPIPortOpen(kDPISBBase)) { up = YES; break; }
        usleep(100000);
    }
    if (!up) {
        if (why) *why = @"sing-box did not listen";
        [log appendString:@"sb: started but not listening\n"];
        return NO;                       // the caller stops *pidOut
    }
    [log appendFormat:@"sb: root sing-box up, %lu candidates on 127.0.0.1:%d-%d\n",
                      (unsigned long)inb.count, kDPISBBase, kDPISBBase + (int)inb.count - 1];
    return YES;
}

- (void)stopSB:(int)pid {
    if (pid > 0 && self.privStop) self.privStop(pid);
}

// The few lines of the throw-away sing-box's own log that explain a failure (a tls_spoof problem
// on this macOS shows up here and nowhere else).
- (NSString *)sbLogExcerpt {
    NSString *txt = [NSString stringWithContentsOfFile:[_supDir stringByAppendingPathComponent:@"dpi_sb_search.log"]
                                              encoding:NSUTF8StringEncoding error:nil];
    if (!txt.length) return @"sb log: (empty)\n";
    NSMutableString *out = [NSMutableString stringWithString:@"sb log:\n"];
    NSInteger n = 0;
    for (NSString *l in [txt componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *low = l.lowercaseString;
        if (!l.length || !([low containsString:@"spoof"] || [low containsString:@"fatal"] ||
                           [low containsString:@"error"] || [low containsString:@"permission"])) continue;
        NSString *clean = [l stringByReplacingOccurrencesOfString:@"\\x1b\\[[0-9;]*m" withString:@""
                                                          options:NSRegularExpressionSearch
                                                            range:NSMakeRange(0, l.length)];
        [out appendFormat:@"  %@\n", clean.length > 200 ? [clean substringToIndex:200] : clean];
        if (++n >= 12) { [out appendString:@"  ...\n"]; break; }
    }
    if (!n) [out appendString:@"  (no spoof/error lines)\n"];
    return out;
}

// Same probes and success rule as testStrategy:, through the "S" inbound on `port` (no process of
// its own: the root sing-box is already up).
- (DPIResult *)testSB:(NSString *)raw port:(int)port hosts:(NSArray *)hosts probes:(NSArray *)probes
                  ips:(NSDictionary<NSString *, NSString *> *)ips diag:(NSString **)diag {
    DPIResult *r = [DPIResult new];
    r.strategy = raw; r.total = (NSInteger)hosts.count;
    NSMutableDictionary *f1 = [NSMutableDictionary dictionary];
    double s1 = 0;
    NSInteger p1 = [self batteryHosts:probes port:port ips:ips timeout:5 totalTime:&s1 failures:f1 passed:nil];
    if (p1 > 0 && !_cancel) {
        NSMutableDictionary *f2 = [NSMutableDictionary dictionary];
        NSMutableArray<NSString *> *pl = [NSMutableArray array];
        double sum = 0;
        r.ok = [self batteryHosts:hosts port:port ips:ips timeout:5 totalTime:&sum failures:f2 passed:pl];
        r.passed = pl;
        r.avgTime = r.ok ? sum / r.ok : 0;
        if (diag) *diag = [NSString stringWithFormat:@"fail %@", DPIFailText(f2)];
    } else if (diag) {
        *diag = [NSString stringWithFormat:@"probe fail %@", DPIFailText(f1)];
    }
    return r;
}

// One direct HTTPS request to a literal address with a chosen name (SNI and Host), classified
// by how far it got (v0.13.4). Direct on purpose: through the proxy curl cannot tell "TCP never
// connected" from "TLS never finished" (the SOCKS reply hides the first). *kind:
//   0 TLS completed   1 no TCP handshake   2 TCP up, TLS never finished (stall)
//   3 reset/closed during TLS   4 anything else
// The two calls the search makes use the SAME address and differ only in the name: if the
// YouTube name dies and the Google name completes TLS, the filter reads the name (SNI); if
// both die at the TCP stage, the address or the route is blocked and no ClientHello trick
// can help.
- (NSString *)wireProbeName:(NSString *)name ip:(NSString *)ip kind:(NSInteger *)kind {
    NSArray *args = @[@"-q", @"-sS", @"-o", @"/dev/null", @"--http1.1",
                      @"--connect-timeout", @"5", @"-m", @"8",
                      @"--resolve", [NSString stringWithFormat:@"%@:443:%@", name, ip],
                      @"-w", @"\n@@W %{http_code} %{time_connect} %{time_appconnect}\n",
                      [NSString stringWithFormat:@"https://%@/", name]];
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/curl";
    t.arguments = args;
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    t.standardError  = [NSFileHandle fileHandleWithNullDevice];
    t.standardInput  = [NSFileHandle fileHandleWithNullDevice];
    @synchronized (_testTasks) { [_testTasks addObject:t]; }
    int status = -1, http = 0;
    double tConn = 0, tApp = 0;
    @try {
        [t launch];
        NSData *out = [[p fileHandleForReading] readDataToEndOfFile];
        [t waitUntilExit];
        status = t.terminationStatus;
        NSString *txt = [[NSString alloc] initWithData:out encoding:NSISOLatin1StringEncoding] ?: @"";
        for (NSString *l in [txt componentsSeparatedByString:@"\n"]) {
            if (![l hasPrefix:@"@@W "]) continue;
            NSArray *f = [[l substringFromIndex:4] componentsSeparatedByString:@" "];
            if (f.count >= 3) { http = [f[0] intValue]; tConn = [f[1] doubleValue]; tApp = [f[2] doubleValue]; }
        }
    } @catch (NSException *e) { status = -1; }
    @synchronized (_testTasks) { [_testTasks removeObject:t]; }
    NSInteger k; NSString *what;
    if (tApp > 0) {
        k = 0; what = http ? [NSString stringWithFormat:@"TLS completed (HTTP %d)", http] : @"TLS completed";
    } else if (tConn <= 0) {
        k = 1; what = status == 7 ? @"TCP refused (curl 7)" : @"no TCP handshake (timeout)";
    } else if (status == 28) {
        k = 2; what = @"TCP up, TLS never finished (stall)";
    } else if (status == 35 || status == 52 || status == 55 || status == 56) {
        k = 3; what = [NSString stringWithFormat:@"TCP up, reset or closed during TLS (curl %d)", status];
    } else {
        k = 4; what = [NSString stringWithFormat:@"curl %d", status];
    }
    if (kind) *kind = k;
    return what;
}

// The wire probe over several addresses (v0.15.3): every address is asked twice (the YouTube name and a
// Google name nobody filters), all of it concurrently - at most kDPIWireMax x 2 short-lived curls. Logs
// two lines per address; the rows carry ip / ky / kg (the `kind` values of wireProbeName:).
- (NSArray<NSDictionary *> *)wireProbeAddresses:(NSArray<NSString *> *)ips log:(NSMutableString *)log {
    NSString *nameY = @"www.youtube.com", *nameG = @"www.google.com";
    NSArray<NSString *> *names = @[nameY, nameG];
    NSMutableDictionary<NSString *, NSDictionary *> *res = [NSMutableDictionary dictionary];
    NSObject *lock = [NSObject new];
    dispatch_group_t g = dispatch_group_create();
    for (NSString *ip in ips) {
        for (NSString *nm in names) {
            dispatch_group_enter(g);
            [NSThread detachNewThreadWithBlock:^{
                NSInteger k = 4;
                NSString *t = @"not tested";
                if (!self->_cancel) t = [self wireProbeName:nm ip:ip kind:&k];
                @synchronized (lock) {
                    res[[NSString stringWithFormat:@"%@|%@", ip, nm]] = @{@"k": @(k), @"t": t};
                }
                dispatch_group_leave(g);
            }];
        }
    }
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NSString *ip in ips) {
        NSDictionary *y = res[[NSString stringWithFormat:@"%@|%@", ip, nameY]];
        NSDictionary *gg = res[[NSString stringWithFormat:@"%@|%@", ip, nameG]];
        if (!y || !gg) continue;
        [log appendFormat:@"wire: %@  SNI %@ -> %@\n", ip, nameY, y[@"t"]];
        [log appendFormat:@"wire: %@  SNI %@  -> %@\n", ip, nameG, gg[@"t"]];
        [rows addObject:@{@"ip": ip, @"ky": y[@"k"], @"kg": gg[@"k"]}];
    }
    return rows;
}

// YES when no probed address completes a TCP handshake for either name.
static BOOL DPIWireAllNoTCP(NSArray<NSDictionary *> *rows) {
    if (!rows.count) return NO;
    for (NSDictionary *r in rows)
        if (!([r[@"ky"] integerValue] == 1 && [r[@"kg"] integerValue] == 1)) return NO;
    return YES;
}

// One verdict over every probed address: the log gets it in English, the return value is the menu note.
// *sni = YES when some address completes TLS for the Google name but not for the YouTube one.
static NSString *DPIWireVerdict(NSArray<NSDictionary *> *rows, BOOL *sni, NSMutableString *log) {
    NSUInteger n = rows.count, ok = 0, byName = 0, noTCP = 0;
    for (NSDictionary *r in rows) {
        NSInteger ky = [r[@"ky"] integerValue], kg = [r[@"kg"] integerValue];
        if (ky == 0) ok++;
        else if (kg == 0) byName++;
        else if (ky == 1 && kg == 1) noTCP++;
    }
    if (sni) *sni = byName > 0;
    NSString *drop = noTCP ? [NSString stringWithFormat:@" (%lu dropped at the TCP stage: address or route block)",
                              (unsigned long)noTCP] : @"";
    if (ok == n) {
        [log appendString:@"wire verdict: every probed address completes TLS for the YouTube name - no filter seen on it\n"];
        return @"Адрес YouTube отвечает — блокировки на проводе не видно.";
    }
    if (byName > 0) {
        [log appendFormat:@"wire verdict: SNI filter - %lu of %lu address(es) complete TLS for another name only%@\n",
                          (unsigned long)byName, (unsigned long)n, drop];
        return noTCP ? @"Фильтр по имени (SNI): часть адресов отвечает на другое имя, часть отброшена по IP."
                     : @"Фильтр по имени (SNI): тот же адрес отвечает на другое имя.";
    }
    if (ok > 0) {
        [log appendFormat:@"wire verdict: %lu of %lu address(es) answer for the YouTube name, the rest do not%@\n",
                          (unsigned long)ok, (unsigned long)n, drop];
        return @"Часть адресов YouTube отвечает, остальные отброшены.";
    }
    if (noTCP == n) {
        [log appendFormat:@"wire verdict: no TCP handshake on any of the %lu probed address(es) for either name - "
                          @"THESE addresses are blocked by IP or route (no ClientHello matters before the "
                          @"handshake); other addresses of the same service may differ\n", (unsigned long)n];
        return @"Эти адреса не отвечают даже с другим именем — блок по IP или маршруту.";
    }
    [log appendString:@"wire verdict: the addresses fail for both names, so the filter is not (only) name-based\n"];
    return @"Адрес режется независимо от имени — разрезание потока вряд ли поможет.";
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
        NSInteger nCurated = (NSInteger)ents.count;
        NSInteger total = (NSInteger)ents.count;

        // The log is the way to see WHY a network gave no result: it is the only
        // evidence available when the search runs on a machine we cannot reach.
        NSMutableString *log = [NSMutableString string];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        // No network signature here on purpose: the person may paste this log into a chat
        // and the signature contains the router address.
        [log appendFormat:@"# Raketa DPI search %@\n# ciadpi options: %@\n"
                          @"# list: %ld candidates (S = sing-box fake ClientHello + fragments, needs root; M = ciadpi stream cutting, no fakes on macOS); %lu hosts per strategy; lists: %@\n"
                          @"# columns: №  ok/total  mean-s  failures(curl-exit x count; 1 = short body)  line\n",
                          [df stringFromDate:[NSDate date]],
                          [self probedOptions] ? @"probed" : @"probe failed (macOS defaults)",
                          (long)total, (unsigned long)hosts.count, updNote];

        // DNS stage (v0.13.3). Everything below depends on names resolving, and on a network
        // that filters YouTube they often do not: see the header comment.
        dispatch_async(cbq, ^{ progress(@"search", 0, total, 0); });
        NSMutableArray<NSString *> *names = [NSMutableArray arrayWithArray:hosts];
        [names addObjectsFromArray:probes];
        NSString *sysErr = nil;
        NSArray<NSString *> *sysAll = DPISystemResolveAll(@"www.youtube.com", 4, kDPIWireMax, &sysErr);
        NSString *sysAns = sysAll.count ? [sysAll componentsJoinedByString:@" "] : (sysErr ?: @"error");
        BOOL sysOK = sysAll.count > 0;
        [log appendFormat:@"dns: system resolver  www.youtube.com -> %@%@\n", sysAns, sysOK ? @"" : @"  (unusable)"];
        NSString *doh = nil;
        NSDictionary<NSString *, NSString *> *ips = nil;
        if (sysOK) {
            // v0.13.4: the log of 2026-10-09 showed the system resolver answering while every
            // request still died on the wire, so DoH changes nothing there and is not used.
            [log appendString:@"dns: system resolver answers - DoH is not used\n"];
        } else {
            for (NSString *base in DPIDoHServers()) {
                if (self->_cancel) break;
                double ds = 0;
                NSArray *a = [self dohLookup:@"www.youtube.com" server:base seconds:&ds];
                [log appendFormat:@"dns: DoH %@  %@  %.1fs\n", base, a.count ? a[0] : @"no answer", ds];
                if (a.count) { doh = base; break; }
            }
            if (doh) {
                NSDictionary *got = [self dohResolveNames:names server:doh];
                NSMutableArray *miss = [NSMutableArray array];
                for (NSString *n in names) if (!got[n]) [miss addObject:n];
                NSString *missNote = miss.count
                    ? [@"; no answer: " stringByAppendingString:[[miss subarrayWithRange:
                          NSMakeRange(0, MIN((NSUInteger)4, miss.count))] componentsJoinedByString:@" "]]
                    : @"";
                [log appendFormat:@"dns: DoH resolved %lu/%lu names%@\n",
                                  (unsigned long)got.count, (unsigned long)names.count, missNote];
                if (got.count) ips = got;
            } else {
                [log appendString:@"dns: no DoH server answered; names go through the proxy as before\n"];
            }
            if (!ips) doh = nil;
        }

        // Where does the filter act? (v0.13.4; v0.15.3: over SEVERAL addresses.) Each address is asked twice,
        // once with the YouTube name and once with a Google name nobody filters. The 2026-10-25 log asked
        // only the first address, called it blocked and said no trick can help - and S3 then opened hosts the
        // control could not, so the verdict is made over every address the resolver gave (see wireProbeAddresses:).
        NSString *wireText = nil;
        BOOL wireSNI = NO, sysAddrBlocked = NO;
        NSArray<NSString *> *wireIPs = sysOK ? sysAll
                                             : (ips[@"www.youtube.com"] ? @[ips[@"www.youtube.com"]] : @[]);
        if (wireIPs.count && !self->_cancel) {
            NSArray<NSDictionary *> *rows = [self wireProbeAddresses:wireIPs log:log];
            wireText = DPIWireVerdict(rows, &wireSNI, log);
            if (sysOK && DPIWireAllNoTCP(rows) && !self->_cancel) {
                // Every system address is dropped before the handshake: ask DoH for OTHER addresses of the
                // same name. If one of them answers, the run (and the YouTube mode, via _dnsSysBad) uses DoH.
                for (NSString *base in DPIDoHServers()) {
                    if (self->_cancel) break;
                    double ds = 0;
                    NSArray<NSString *> *a = [self dohLookup:@"www.youtube.com" server:base seconds:&ds];
                    [log appendFormat:@"dns: DoH %@  %@  %.1fs\n", base,
                                      a.count ? [a componentsJoinedByString:@" "] : @"no answer", ds];
                    if (!a.count) continue;
                    NSMutableArray<NSString *> *fresh = [NSMutableArray array];
                    for (NSString *x in a)
                        if (![wireIPs containsObject:x] && fresh.count < kDPIWireMax) [fresh addObject:x];
                    if (!fresh.count) { [log appendString:@"dns: DoH gives the same addresses\n"]; break; }
                    NSArray<NSDictionary *> *rows2 = [self wireProbeAddresses:fresh log:log];
                    NSString *up = nil;
                    for (NSDictionary *r in rows2)
                        if (!([r[@"ky"] integerValue] == 1 && [r[@"kg"] integerValue] == 1)) { up = r[@"ip"]; break; }
                    if (up) {
                        BOOL s2 = NO;
                        wireText = DPIWireVerdict(rows2, &s2, log);
                        wireSNI = s2;
                        NSMutableDictionary<NSString *, NSString *> *m2 =
                            [[self dohResolveNames:names server:base] mutableCopy];
                        m2[@"www.youtube.com"] = up;          // the address that answered, not just the first
                        doh = base; ips = m2; sysAddrBlocked = YES;
                        [log appendFormat:@"dns: the system addresses do not answer, DoH %@ gives one that does (%@) - "
                                          @"names go through DoH\n", base, up];
                    }
                    break;
                }
            }
        } else if (!wireIPs.count) {
            [log appendString:@"wire: no address to test\n"];
        }

        // Control runs: the same hosts with NO bypass. They tell "network is open / blocked"
        // apart from "strategy breaks the connection" in the log. With DoH addresses the
        // second one isolates DPI from DNS: if it still fails, the filter is on the wire.
        NSMutableDictionary *dfail = [NSMutableDictionary dictionary];
        double dsum = 0;
        NSMutableArray<NSString *> *dPass = [NSMutableArray array];
        NSInteger dOK = [self batteryHosts:hosts port:0 ips:nil timeout:5 totalTime:&dsum failures:dfail passed:dPass];
        [log appendFormat:@"direct, system DNS    %ld/%lu  failures %@\n", (long)dOK,
                          (unsigned long)hosts.count, DPIFailText(dfail)];
        [log appendString:DPIPassText(dPass)];
        if (ips) {
            NSMutableDictionary *dfail2 = [NSMutableDictionary dictionary];
            NSMutableArray<NSString *> *dPass2 = [NSMutableArray array];
            dOK = [self batteryHosts:hosts port:0 ips:ips timeout:5 totalTime:&dsum failures:dfail2 passed:dPass2];
            [log appendFormat:@"direct, DoH addresses %ld/%lu  failures %@\n", (long)dOK,
                              (unsigned long)hosts.count, DPIFailText(dfail2)];
            [log appendString:DPIPassText(dPass2)];
        }

        // Third control: the SAME hosts through ciadpi with no desync option at all. If
        // "direct" is fine but this is not, the proxy chain itself is broken (not the
        // strategies); if both are blocked, the network blocks and only a strategy helps.
        NSInteger pOK = 0;
        {
            NSMutableDictionary *pfail = [NSMutableDictionary dictionary];
            double psum = 0;
            NSTask *pt = [self launchCiadpiPort:kDPITestPort strategyArgs:@[]];
            if (pt && !self->_cancel && [self waitReady:pt port:kDPITestPort timeout:1.0]) {
                NSMutableArray<NSString *> *pPass = [NSMutableArray array];
                pOK = [self batteryHosts:hosts port:kDPITestPort ips:ips timeout:5 totalTime:&psum failures:pfail passed:pPass];
                [log appendFormat:@"proxy, no desync    %ld/%lu  failures %@\n", (long)pOK,
                                  (unsigned long)hosts.count, DPIFailText(pfail)];
                [log appendString:DPIPassText(pPass)];
            } else {
                [log appendString:@"proxy, no desync    could not start ciadpi\n"];
            }
            if (pt.isRunning) { [pt terminate]; [pt waitUntilExit]; }
        }

        // v0.14.2: ONE root sing-box with an inbound per "S" candidate (see the file header).
        NSMutableDictionary<NSString *, NSNumber *> *sbPort = [NSMutableDictionary dictionary];
        int sbPid = 0;
        NSString *sbWhy = nil;
        BOOL sbUp = [self startSBSearchFor:ents ports:sbPort pid:&sbPid why:&sbWhy log:log];

        NSMutableArray<DPIResult *> *found = [NSMutableArray array];
        NSMutableDictionary<NSString *, DPIResult *> *allTested = [NSMutableDictionary dictionary];
        NSInteger tested = 0, best = 0;
        for (NSInteger i = 0; i < total && !self->_cancel; i++) {
            NSInteger doneN = i, bestN = best, tot = total;
            dispatch_async(cbq, ^{ progress(@"search", doneN, tot, bestN); });
            DPIEntry *e = ents[(NSUInteger)i];
            NSString *diag = nil;
            DPIResult *r = nil;
            if (DPISBOptions(e.raw)) {
                if (sbUp && sbPort[e.raw])
                    r = [self testSB:e.raw port:sbPort[e.raw].intValue hosts:hosts probes:probes ips:ips diag:&diag];
                else
                    diag = sbWhy ?: @"sing-box unavailable";
            } else {
                r = [self testStrategy:e.raw hosts:hosts probes:probes ips:ips diag:&diag];
            }
            if (!r) {                          // unsupported by this build
                [log appendFormat:@"#%@  REJECTED (%@)  %@\n", e.label, diag ?: @"", e.raw];
                continue;
            }
            tested++;
            allTested[e.raw] = r;
            [log appendFormat:@"#%@  %ld/%ld  %.2f  %@  %@\n", e.label,
                              (long)r.ok, (long)r.total, r.avgTime, r.ok == r.total ? @"-" : (diag ?: @"-"), e.raw];
            if (r.ok > 0) {                   // v0.15.3: the evidence, not just the count
                [log appendFormat:@"    vs no bypass: %+ld hosts\n", (long)(r.ok - dOK)];
                [log appendString:DPIPassText(r.passed)];
            }
            if (r.ok > 0) { [found addObject:r]; if (r.ok > best) best = r.ok; }
            usleep(400000);                   // be gentle between strategies
        }
        if (sbPid > 0) {                      // stop the root sing-box; its own log explains a failure
            [self stopSB:sbPid];
            if (sbPort.count) [log appendString:[self sbLogExcerpt]];
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
        self->_lastCurated = nCurated;
        self->_directOK = dOK; self->_directTotal = (NSInteger)hosts.count;
        self->_passOK = pOK; self->_passTotal = (NSInteger)hosts.count;
        self->_dohURL = doh; self->_dnsSysBad = !sysOK || sysAddrBlocked;
        self->_sysAddrBlocked = sysAddrBlocked;
        self->_wireVerdict = wireText; self->_wireSNI = wireSNI;
        self->_tested = allTested;
        [self saveResults];
        [log appendFormat:@"# done: %lu working of %ld tested\n", (unsigned long)found.count, (long)tested];
        [log writeToFile:[self searchLogPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSString *sum = found.count
            ? [NSString stringWithFormat:@"Найдено %lu из %ld · %@",
               (unsigned long)found.count, (long)tested, updNote]
            : (wireSNI ? @"Рабочих не найдено: фильтр по имени, разрезание потока не помогло (журнал — в меню ▾)"
                       : @"Рабочих не найдено · выберите вручную (▾)");
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
//
// With a DoH endpoint from the last search (v0.13.3) the YouTube names are resolved by
// sing-box over DoH and the `dpi` outbound speaks SOCKS4: sing-box's SOCKS4 client
// resolves the destination itself and sends ciadpi an IPv4 address, so ciadpi never calls
// getaddrinfo() (the call that hangs on a network that filters DNS). Everything that is
// not a YouTube name keeps using the system resolver (`final: local`), so local names and
// the rest of the browsing behave exactly as before. Without an endpoint the config is the
// old one (SOCKS5, no dns section).
- (NSDictionary *)youtubeOnlyConfigWithInbounds:(NSArray *)inbounds {
    NSArray *suffixes = @[@"youtube.com", @"youtu.be", @"youtube-nocookie.com",
                          @"googlevideo.com", @"ytimg.com", @"ggpht.com",
                          @"googleusercontent.com",
                          @"youtubei.googleapis.com", @"jnn-pa.googleapis.com"];
    // v0.13.4: only when the last search found the system resolver unusable; otherwise the
    // old, plain config (SOCKS5, system DNS) - DoH would add a dependency for nothing.
    NSString *doh = (_dnsSysBad && DPIValidDoHURL(_dohURL)) ? _dohURL : nil;
    // v0.14.2: an "S" strategy is a route option of the direct connection itself (sing-box injects
    // the fake ClientHello before the real one), so there is no ciadpi hop: the matching rule only
    // sets the options and the traffic stays `direct`. sing-box must run as root for it - it does.
    NSDictionary *sbo = DPISBOptions(self.selectedStrategy);
    NSMutableDictionary *rule = [@{@"domain_suffix": suffixes} mutableCopy];
    NSMutableArray *outs = [@[@{@"type": @"direct", @"tag": @"direct"}] mutableCopy];
    if (sbo) {
        rule[@"action"] = @"route-options";
        [rule addEntriesFromDictionary:sbo];
    } else {
        rule[@"outbound"] = @"dpi";
        [outs addObject:@{@"type": @"socks", @"tag": @"dpi", @"version": doh ? @"4" : @"5",
                          @"server": @"127.0.0.1", @"server_port": @(kDPIPort)}];
    }
    NSMutableDictionary *cfg = [@{
        @"log": @{@"level": @"warn"},
        @"inbounds": inbounds,
        @"outbounds": outs,
        @"route": @{
            @"rules": @[rule],
            @"final": @"direct"
        }
    } mutableCopy];
    if (doh) {
        // sing-box 1.14 removed the legacy DNS server format (`address` URLs, deprecated in
        // 1.12): servers are typed now and the strategy moved into the rule. `sing-box check`
        // 1.14.3 rejects the old shape, and also asks for default_domain_resolver as soon as
        // there is a DNS section. Same behaviour as before: DoH only for the YouTube names.
        NSURL *du = [NSURL URLWithString:doh];
        cfg[@"dns"] = @{
            @"servers": @[@{@"tag": @"doh", @"type": @"https", @"server": du.host ?: @"",
                            @"server_port": du.port ?: @443,
                            @"path": du.path.length ? du.path : @"/dns-query"},
                          @{@"tag": @"local", @"type": @"local"}],
            @"rules": @[@{@"domain_suffix": suffixes, @"server": @"doh", @"strategy": @"ipv4_only"}],
            @"final": @"local"
        };
        NSMutableDictionary *rt = [cfg[@"route"] mutableCopy];
        rt[@"default_domain_resolver"] = @"local";
        cfg[@"route"] = rt;
    }
    return cfg;
}

@end
