// RKSubscription.m — see the header
#import "RKSubscription.h"
#import <sys/sysctl.h>

static NSString *const kHWIDKey = @"RaketaHWID";

@implementation RKSubscription

+ (NSString *)hwid {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *h = [d stringForKey:kHWIDKey];
    if (h.length < 8) {
        h = [[[NSUUID UUID] UUIDString] lowercaseString];
        [d setObject:h forKey:kHWIDKey];
    }
    return h;
}

+ (NSString *)deviceModel {
    char buf[64] = {0};
    size_t len = sizeof buf;
    if (sysctlbyname("hw.model", buf, &len, NULL, 0) != 0) return @"Mac";
    return [NSString stringWithUTF8String:buf] ?: @"Mac";
}

+ (void)decorateRequest:(NSMutableURLRequest *)req appVersion:(NSString *)app coreVersion:(NSString *)core {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    NSString *os = [NSString stringWithFormat:@"%ld.%ld.%ld",
                    (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
    // The "sing-box" token is deliberate: panels pick the response format by User-Agent, and a
    // client that names itself sing-box gets links/JSON that sing-box can run (panels leave out
    // the nodes sing-box has no transport for, e.g. XHTTP) instead of a Xray-only dump.
    NSString *ua = core.length
        ? [NSString stringWithFormat:@"Raketa/%@ sing-box/%@ (macOS %@)", app ?: @"0", core, os]
        : [NSString stringWithFormat:@"Raketa/%@ sing-box (macOS %@)", app ?: @"0", os];
    [req setValue:ua                  forHTTPHeaderField:@"User-Agent"];
    [req setValue:[self hwid]         forHTTPHeaderField:@"x-hwid"];
    [req setValue:@"macOS"            forHTTPHeaderField:@"x-device-os"];
    [req setValue:os                  forHTTPHeaderField:@"x-ver-os"];
    [req setValue:[self deviceModel]  forHTTPHeaderField:@"x-device-model"];
}

+ (NSString *)headerNamed:(NSString *)name in:(NSDictionary *)headers {
    for (id k in headers)
        if ([k isKindOfClass:[NSString class]] &&
            [(NSString *)k caseInsensitiveCompare:name] == NSOrderedSame) {
            id v = headers[k];
            return [v isKindOfClass:[NSString class]] ? v : [v description];
        }
    return nil;
}

+ (NSString *)userinfoSummary:(NSString *)header {
    if (!header.length) return nil;
    long long up = 0, down = 0, total = 0, expire = 0;
    for (NSString *part in [header componentsSeparatedByString:@";"]) {
        NSArray *kv = [part componentsSeparatedByString:@"="];
        if (kv.count != 2) continue;
        NSString *k = [[kv[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
        long long v = [kv[1] longLongValue];
        if      ([k isEqualToString:@"upload"])   up = v;
        else if ([k isEqualToString:@"download"]) down = v;
        else if ([k isEqualToString:@"total"])    total = v;
        else if ([k isEqualToString:@"expire"])   expire = v;
    }
    NSMutableArray *bits = [NSMutableArray array];
    if (total > 0) {
        NSByteCountFormatter *f = [[NSByteCountFormatter alloc] init];
        f.countStyle = NSByteCountFormatterCountStyleDecimal;
        [bits addObject:[NSString stringWithFormat:@"%@ / %@",
                         [f stringFromByteCount:up + down], [f stringFromByteCount:total]]];
    }
    // 0 = unlimited; a far-future value is a panel's way of saying the same.
    if (expire > 0 && expire < 4102444800LL) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.dateFormat = @"dd.MM.yyyy";
        [bits addObject:[@"до " stringByAppendingString:
                         [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)expire]]]];
    }
    return bits.count ? [bits componentsJoinedByString:@" · "] : nil;
}

+ (NSString *)problemForStatus:(NSInteger)status headers:(NSDictionary *)headers {
    NSString *lim = [self headerNamed:@"x-hwid-limit" in:headers];
    if ([lim caseInsensitiveCompare:@"true"] == NSOrderedSame)
        return @"⚠  Лимит устройств исчерпан — удалите старое устройство у провайдера";
    if (status == 401 || status == 403)
        return [NSString stringWithFormat:@"⚠  Доступ запрещён (HTTP %ld) — проверьте ссылку или лимит устройств", (long)status];
    if (status == 404) return @"⚠  Подписка не найдена — проверьте ссылку";
    if (status == 429) return @"⚠  Слишком много запросов — повторите через минуту";
    if (status >= 500) return [NSString stringWithFormat:@"⚠  Сервер подписки недоступен (HTTP %ld)", (long)status];
    if (status >= 400) return [NSString stringWithFormat:@"⚠  Ошибка загрузки подписки (HTTP %ld)", (long)status];
    return nil;
}

+ (NSString *)unsupportedReasonForVless:(NSString *)link {
    NSURLComponents *c = [NSURLComponents componentsWithString:
        [link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    NSString *type = nil, *enc = nil;
    for (NSURLQueryItem *q in c.queryItems) {
        if ([q.name isEqualToString:@"type"])       type = q.value.lowercaseString;
        if ([q.name isEqualToString:@"encryption"]) enc  = q.value.lowercaseString;
    }
    // sing-box 1.14 has no XHTTP transport and no VLESS Encryption (checked with `sing-box check`).
    if ([type isEqualToString:@"xhttp"] || [type isEqualToString:@"splithttp"]) return @"XHTTP";
    if (enc.length && ![enc isEqualToString:@"none"]) return @"VLESS Encryption";
    return nil;
}

@end
