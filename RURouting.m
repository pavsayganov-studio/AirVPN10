// RURouting.m — see RURouting.h for the overview.
#import "RURouting.h"

// ── Rule-set lists ─────────────────────────────────────────────────────────────────────────────────────────
// Names are the roscomvpn-geosite categories (file geosite-<name>.srs after CI copied them) and the one
// roscomvpn-geoip list `direct` (geoip-direct.srs). Kept in sync with the "Fetch RU rule sets" step of build.yml.
static NSArray<NSString *> *RUBlockSites(void)  { return @[@"category-ads", @"win-spy", @"torrent"]; }
static NSArray<NSString *> *RUProxySites(void)  { return @[@"google-play", @"github", @"twitch-ads", @"youtube", @"telegram"]; }
static NSArray<NSString *> *RUDirectSites(void) {
    // NOT "private": the published geosite private.srs holds plain words ("lan", "test", "local", "internal")
    // as substring keywords, so it would send planet.com or speedtest.net direct. RUPrivateSuffixes() below
    // says the same thing as proper suffixes.
    return @[@"category-ru", @"whitelist", @"microsoft", @"apple", @"epicgames", @"riot",
             @"escapefromtarkov", @"steam", @"twitch", @"pinterest", @"faceit"];
}
static NSString *const kRUGeoIPDirect = @"geoip-direct";

// Names that only exist on a local network (RFC 6761 / 6762 / 8375).
static NSArray<NSString *> *RUPrivateSuffixes(void) {
    return @[@"local", @"localhost", @"lan", @"localdomain", @"home.arpa", @"internal", @"invalid", @"test", @"example"];
}

// Big Russian services written by hand. The geosite lists were de-duplicated against the IP ranges (a domain
// whose addresses are already in geoip-direct is not in them), so these are not redundant: they go direct at
// once, without waiting for the address lookup.
static NSArray<NSString *> *RUDirectDomains(void) {
    return @[@"ozon.ru", @"wildberries.ru", @"megamarket.ru", @"avito.ru", @"samokat.ru",
             @"yandex.ru", @"ya.ru", @"kinopoisk.ru", @"dzen.ru",
             @"sberbank.ru", @"tbank.ru", @"tinkoff.ru", @"alfabank.ru", @"vtb.ru", @"mironline.ru",
             @"gazprombank.ru", @"gpb.ru",
             @"vk.com", @"vkvideo.ru", @"vkmusic.ru", @"ok.ru", @"mail.ru",
             @"gosuslugi.ru", @"2gis.ru", @"mts.ru", @"megafon.ru", @"rustore.ru", @"max.ru",
             @"emias.info", @"mos.ru", @"invitro.ru", @"gemotest.ru", @"medsi.ru", @"fdoctor.ru",
             @"dns-shop.ru", @"goldapple.ru", @"detmir.ru", @"5ka.ru", @"perekrestok.ru", @"magnit.ru",
             @"chizhik.club", @"eapteka.ru",
             @"ivi.ru", @"okko.tv", @"wink.ru", @"premier.one", @"kion.ru",
             @"hh.ru", @"aviasales.ru", @"rzd.ru",
             // direct in the plain VPN profile too; the geosite apple list covers only push and update hosts
             @"apple.com", @"icloud.com"];
}

static NSString *const kTagRemote   = @"dns-remote";
static NSString *const kTagDomestic = @"dns-domestic";

static NSString *RUSiteTag(NSString *name) { return [@"geosite-" stringByAppendingString:name]; }
static NSArray<NSString *> *RUSiteTags(NSArray<NSString *> *names) {
    NSMutableArray *t = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *n in names) [t addObject:RUSiteTag(n)];
    return t;
}
static NSArray<NSString *> *RUAllTags(void) {
    NSMutableArray *t = [NSMutableArray array];
    [t addObjectsFromArray:RUSiteTags(RUBlockSites())];
    [t addObjectsFromArray:RUSiteTags(RUProxySites())];
    [t addObjectsFromArray:RUSiteTags(RUDirectSites())];
    [t addObject:kRUGeoIPDirect];
    return t;
}

@implementation RURouting

+ (NSString *)bundledRulesDirectory {
    return [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"ru"];
}

+ (NSString *)missingRuleFileInDirectory:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *tag in RUAllTags()) {
        NSString *f = [tag stringByAppendingString:@".srs"];
        if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:f]]) return f;
    }
    return nil;
}

+ (NSDictionary *)routeForProxyTag:(NSString *)proxyTag rulesDirectory:(NSString *)dir {
    NSMutableArray *sets = [NSMutableArray array];
    for (NSString *tag in RUAllTags())
        [sets addObject:@{@"type": @"local", @"tag": tag, @"format": @"binary",
                          @"path": [dir stringByAppendingPathComponent:[tag stringByAppendingString:@".srs"]]}];

    // Local and private ranges: always direct (the same list the plain VPN profile uses).
    NSArray *privateRanges = @[@"127.0.0.0/8", @"192.168.0.0/16", @"10.0.0.0/8", @"172.16.0.0/12"];

    NSArray *rules = @[
        // 1. block
        @{@"rule_set": RUSiteTags(RUBlockSites()), @"action": @"reject"},
        // 2. proxy: before direct, so a service listed on both sides (Twitch ads vs Twitch) goes through the VPN
        @{@"rule_set": RUSiteTags(RUProxySites()), @"action": @"route", @"outbound": proxyTag},
        // 3. direct, by name
        @{@"domain_suffix": RUPrivateSuffixes(),    @"action": @"route", @"outbound": @"direct"},
        @{@"rule_set": RUSiteTags(RUDirectSites()), @"action": @"route", @"outbound": @"direct"},
        @{@"domain_suffix": RUDirectDomains(),      @"action": @"route", @"outbound": @"direct"},
        // 4. by address: look the name up through the tunnel; a Russian address goes direct, any other
        //    falls to `final` (the VPN). A destination that is already an address skips the lookup.
        @{@"action": @"resolve", @"server": kTagRemote, @"strategy": @"prefer_ipv4"},
        @{@"ip_cidr": privateRanges,                @"action": @"route", @"outbound": @"direct"},
        @{@"rule_set": @[kRUGeoIPDirect],           @"action": @"route", @"outbound": @"direct"}
    ];

    return @{@"rule_set": sets,
             @"rules": rules,
             @"final": proxyTag,
             // sing-box 1.14 has no implicit resolver for the `direct` outbound: the domestic one
             @"default_domain_resolver": kTagDomestic};
}

+ (NSDictionary *)dnsForProxyTag:(NSString *)proxyTag yandex:(BOOL)yandex {
    NSDictionary *domestic = yandex
        // Yandex's own DoH endpoint: IP 77.88.8.8:443, certificate name common.dot.dns.yandex.net
        // (yandex.ru/support/dns). The name is set explicitly so the certificate is checked
        // without a lookup of the name itself.
        ? @{@"type": @"https", @"tag": kTagDomestic, @"server": @"77.88.8.8",
            @"tls": @{@"server_name": @"common.dot.dns.yandex.net"}}
        : @{@"type": @"local", @"tag": kTagDomestic};

    // No `dns.rules`: every lookup in this profile names its server (the `resolve` rule and
    // default_domain_resolver in the route), and a lookup that names its server skips the DNS rules.
    return @{@"servers": @[
                // Names outside the lists are asked through the tunnel, so the provider never sees them.
                // 8.8.8.8 is blocked on the provider's side since 2026-07, but a query inside the tunnel
                // does not touch it (dpi-research.md section 4).
                @{@"type": @"https", @"tag": kTagRemote, @"server": @"8.8.8.8", @"detour": proxyTag},
                domestic],
             @"final": kTagRemote,
             @"strategy": @"prefer_ipv4"};
}

@end
