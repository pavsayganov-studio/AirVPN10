// RKNet.m — see RKNet.h.
#import "RKNet.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <stdlib.h>

static NSString *const kPortsKey = @"RaketaLocalPorts";   // @[socks, mixed, tg, dpi]
static NSString *const kFixedKey = @"RaketaFixedPorts";   // YES: 10808 / 10809 / 10810 / 10811
// Below macOS's ephemeral range (49152...), above the well-known and default-proxy ports.
static const unsigned kPortLo = 20000, kPortSpan = 29000;
static const NSUInteger kPortCount = 4;

// Nothing listens on 127.0.0.1:port right now (a bind attempt; no connection is made).
static BOOL RKPortFree(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons((uint16_t)port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL ok = bind(fd, (struct sockaddr *)&a, sizeof a) == 0;
    close(fd);
    return ok;
}

static BOOL RKPortsValid(NSArray *p) {
    if (![p isKindOfClass:[NSArray class]] || p.count != kPortCount) return NO;
    NSMutableSet *seen = [NSMutableSet set];
    for (id n in p) {
        if (![n isKindOfClass:[NSNumber class]]) return NO;
        NSInteger v = [n integerValue];
        if (v < (NSInteger)kPortLo || v >= (NSInteger)(kPortLo + kPortSpan) || [seen containsObject:n]) return NO;
        [seen addObject:n];
    }
    return YES;
}

static NSArray<NSNumber *> *RKPorts(void) {
    static NSArray<NSNumber *> *ports;
    @synchronized([RKNet class]) {
        if (ports) return ports;
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSArray *pinned = @[@10808, @10809, @10810, @10811];
        if ([ud boolForKey:kFixedKey]) { ports = pinned; return ports; }
        NSArray *saved = [ud arrayForKey:kPortsKey];
        if (RKPortsValid(saved)) { ports = saved; return ports; }
        NSMutableArray *fresh = [NSMutableArray array];
        for (int tries = 0; fresh.count < kPortCount && tries < 500; tries++) {
            NSNumber *n = [NSNumber numberWithUnsignedInt:kPortLo + arc4random_uniform(kPortSpan)];
            if (![fresh containsObject:n] && RKPortFree(n.intValue)) [fresh addObject:n];
        }
        if (fresh.count < kPortCount) { ports = pinned; return ports; }   // cannot happen in practice
        [ud setObject:fresh forKey:kPortsKey];
        [ud synchronize];
        ports = fresh;
    }
    return ports;
}

// A server entry sing-box can dial: a real protocol, a host and a port. (The same test startVPN applies to the
// chosen server; here it keeps one broken entry of a big subscription out of the group.)
static BOOL RKServerUsable(NSDictionary *o) {
    id type = [o objectForKey:@"type"], tag = [o objectForKey:@"tag"];
    id srv = [o objectForKey:@"server"], prt = [o objectForKey:@"server_port"];
    if (![type isKindOfClass:[NSString class]] || ![tag isKindOfClass:[NSString class]] || ![(NSString *)tag length]) return NO;
    if ([@[@"selector", @"urltest", @"direct", @"block", @"dns"] containsObject:type]) return NO;
    if (![srv isKindOfClass:[NSString class]] || ![(NSString *)srv length]) return NO;
    if (![prt isKindOfClass:[NSNumber class]] && ![prt isKindOfClass:[NSString class]]) return NO;
    NSInteger port = [prt integerValue];
    return port >= 1 && port <= 65535;
}

@implementation RKNet

+ (void)loadPortsSocks:(NSInteger *)socks mixed:(NSInteger *)mixed tg:(NSInteger *)tg {
    NSArray<NSNumber *> *p = RKPorts();
    *socks = [[p objectAtIndex:0] integerValue];
    *mixed = [[p objectAtIndex:1] integerValue];
    *tg    = [[p objectAtIndex:2] integerValue];
}

+ (int)dpiPort { return [[RKPorts() objectAtIndex:3] intValue]; }

+ (NSString *)autoGroupTag { return @"raketa-auto"; }

+ (NSArray *)autoOutboundsFromServers:(NSArray<NSDictionary *> *)servers
                          selectedTag:(NSString *)selectedTag
                                limit:(NSUInteger)limit {
    NSString *groupTag = [self autoGroupTag];
    NSMutableArray<NSDictionary *> *picked = [NSMutableArray array];
    NSMutableSet<NSString *> *tags = [NSMutableSet setWithObjects:@"direct", groupTag, nil];

    // The chosen server first, then the others in subscription order.
    NSMutableArray<NSDictionary *> *order = [NSMutableArray array];
    for (NSDictionary *o in servers)
        if ([[o objectForKey:@"tag"] isEqual:selectedTag]) { [order addObject:o]; break; }
    [order addObjectsFromArray:servers];

    for (NSDictionary *o in order) {
        if (picked.count >= limit) break;
        if (!RKServerUsable(o) || [tags containsObject:[o objectForKey:@"tag"]]) continue;
        [tags addObject:[o objectForKey:@"tag"]];
        [picked addObject:o];
    }
    if (picked.count < 2) return nil;

    NSMutableArray *names = [NSMutableArray arrayWithCapacity:picked.count];
    for (NSDictionary *o in picked) [names addObject:[o objectForKey:@"tag"]];
    NSMutableArray *out = [NSMutableArray arrayWithArray:picked];
    // interval 5 min and idle_timeout 30 min: every test is a connection to every listed server, which is
    // traffic a watcher can count and CPU the app is to spare; tolerance 50 ms: no hopping between near-equal
    // servers; interrupt_exist_connections: when the group does switch, old connections die and are re-made at once.
    [out addObject:@{@"type": @"urltest", @"tag": groupTag, @"outbounds": names,
                     @"interval": @"5m", @"idle_timeout": @"30m", @"tolerance": @50,
                     @"interrupt_exist_connections": [NSNumber numberWithBool:YES]}];
    [out addObject:@{@"type": @"direct", @"tag": @"direct"}];
    return out;
}

+ (NSString *)preflightConfigAtPath:(NSString *)path core:(NSString *)corePath {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:corePath]) return nil;
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = corePath;
    t.arguments = @[@"check", @"-c", path];
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe; t.standardError = pipe;
    @try { [t launch]; } @catch (NSException *e) { return nil; }
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];   // returns when the check exits
    [t waitUntilExit];
    if (t.terminationStatus == 0) return nil;

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSRegularExpression *ansi = [NSRegularExpression regularExpressionWithPattern:@"\x1b\\[[0-9;]*m" options:0 error:nil];
    text = [ansi stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
    // The first ERROR / FATAL line says what is wrong (a later FATAL line often only repeats "stopped");
    // a core that prints something else gets its last line.
    NSString *last = @"", *first = nil;
    for (NSString *l in [text componentsSeparatedByString:@"\n"]) {
        NSString *s = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!s.length) continue;
        last = s;
        if (!first && ([s hasPrefix:@"ERROR"] || [s hasPrefix:@"FATAL"])) first = s;
    }
    if (first) last = first;
    if (!last.length) last = [NSString stringWithFormat:@"код %d", t.terminationStatus];
    if ([last hasPrefix:@"FATAL"] || [last hasPrefix:@"ERROR"]) {
        NSRange r = [last rangeOfString:@"] "];
        if (r.location != NSNotFound) last = [last substringFromIndex:NSMaxRange(r)];
    }
    if (last.length > 110) last = [[last substringToIndex:107] stringByAppendingString:@"..."];
    return last;
}

@end
