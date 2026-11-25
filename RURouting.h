// RURouting — the «RU» routing profile of the VPN (v0.17.0).
//
// Foundation-only on purpose (like DPIEngine): it only builds the `route` and `dns` parts of the sing-box
// config, so it can be compiled and its output checked with `sing-box check` outside the app.
//
// What the profile does (the RoscomVPN "DEFAULT" profile, translated to sing-box 1.14 rule sets):
//   * block   : ads, Windows telemetry, torrent trackers/DHT
//   * proxy   : YouTube, Telegram, GitHub, Google Play, Twitch ads
//   * direct  : Russian banks and services, Apple/Microsoft, game stores, private ranges, plus a short list
//               of big Russian services written by hand
//   * the rest: resolved through the tunnel; an address inside the Russian ranges goes direct, any other
//               address goes through the VPN (Xray's "IPIfNonMatch")
//   * DNS     : DoH 8.8.8.8 through the tunnel for names outside the lists; the VPN server's own name and
//               the names that go direct are resolved outside the tunnel by the system resolver, or by
//               Yandex DNS (DoH, direct) when the person ticks «Яндекс DNS».
//
// The rule sets are .srs files compiled by the roscomvpn-geosite / roscomvpn-geoip projects. CI downloads
// them (pinned commits, see build.yml) into Resources/ru; sing-box reads them from disk, so connecting
// needs no network beyond the VPN itself.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RURouting : NSObject

// <app>.app/Contents/Resources/ru
+ (NSString *)bundledRulesDirectory;

// Name of the first rule-set file missing in `dir`, nil when all of them are there.
+ (nullable NSString *)missingRuleFileInDirectory:(NSString *)dir;

// The `route` object: rule sets read from `dir`, rules in the order block -> proxy -> direct, final = proxy.
+ (NSDictionary *)routeForProxyTag:(NSString *)proxyTag rulesDirectory:(NSString *)dir;

// The `dns` object. yandex = YES: domestic names go to Yandex DNS over DoH (direct); NO: to the system resolver.
+ (NSDictionary *)dnsForProxyTag:(NSString *)proxyTag yandex:(BOOL)yandex;

@end

NS_ASSUME_NONNULL_END
