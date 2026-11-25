// RKNet — what the VPN leaves on the machine, and how it fails (v0.18.0).
//
// Foundation-only, like RURouting and CoreUpdater, so it can be built and tested outside the app.
//
//   1. Local listener ports. The ports of a local proxy (10808, 10809, ...) are the first thing a scan of
//      127.0.0.1 looks for; Russian regulators' VPN-detection guidance names local proxy ports
//      (habr.com/ru/articles/1023352, publish.obsidian.md/zapret/VLESS-SOCKS5-vulnerability: both
//      secondary sources, about Android; nothing macOS-specific was found). A sweep of all 65535 ports
//      still finds a listener; a check of the well-known ones no longer does. So the ports are picked once per
//      install, at random, and kept (Telegram's proxy setting then stays valid).
//   2. «Авто»: one urltest group over the subscription's servers (Hiddify's "delay based node selection").
//   3. Preflight: `sing-box check` on the generated config before root is asked for.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RKNet : NSObject

// Random-per-install local ports: SOCKS, mixed (HTTP + SOCKS system proxy), Telegram. Written to the
// three out-parameters. `defaults write com.samurai.raketa RaketaFixedPorts -bool YES` brings back
// 10808 / 10809 / 10810; `defaults delete com.samurai.raketa RaketaLocalPorts` picks new ones.
+ (void)loadPortsSocks:(NSInteger *)socks mixed:(NSInteger *)mixed tg:(NSInteger *)tg;
// Port of the YouTube mode's ciadpi (same persistence; 10811 when ports are pinned).
+ (int)dpiPort;

// Tag of the «Авто» group.
+ (NSString *)autoGroupTag;

// The `outbounds` array for «Авто»: the chosen server first (it carries the first connections until the first
// delay test is done), then other servers of the subscription, at most `limit` in all; then the urltest group and
// `direct`. nil when fewer than two usable servers (the group would be pointless).
+ (nullable NSArray *)autoOutboundsFromServers:(NSArray<NSDictionary *> *)servers
                                   selectedTag:(NSString *)selectedTag
                                         limit:(NSUInteger)limit;

// `sing-box check -c path` run as the current user. nil = the config is fine (or the check could not run);
// otherwise the last line of its complaint, short enough for the status line.
+ (nullable NSString *)preflightConfigAtPath:(NSString *)path core:(NSString *)corePath;

@end

NS_ASSUME_NONNULL_END
