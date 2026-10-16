// RKSubscription.h — how Raketa talks to a subscription server (v0.14.0)
//
// What the Xray-based clients (INCY, Happ) do that Raketa did not: they say who and what they
// are (User-Agent, device headers incl. a stable device id), they read the traffic/expiry the
// panel reports, and they tell the user WHY a subscription did not load instead of "no servers".
// Foundation only; no state except one random device id kept in NSUserDefaults.
#import <Foundation/Foundation.h>

@interface RKSubscription : NSObject

// Random per-install device id (HWID). Panels with a device limit (Remnawave "HWID device
// limit") refuse a client that sends none. It is NOT derived from the hardware.
+ (NSString *)hwid;

// User-Agent + x-hwid / x-device-os / x-ver-os / x-device-model. `coreVersion` may be @"".
+ (void)decorateRequest:(NSMutableURLRequest *)req appVersion:(NSString *)app coreVersion:(NSString *)core;

// Case-insensitive header lookup (allHeaderFields keys keep the server's capitalisation).
+ (NSString *)headerNamed:(NSString *)name in:(NSDictionary *)headers;

// "Subscription-Userinfo: upload=0; download=1; total=2; expire=3" -> "1 КБ / 2 КБ · до 01.01.2027".
// nil when the header carries nothing worth showing.
+ (NSString *)userinfoSummary:(NSString *)header;

// A Russian, actionable message for a failed or refused subscription request; nil = nothing wrong.
+ (NSString *)problemForStatus:(NSInteger)status headers:(NSDictionary *)headers;

// Why sing-box cannot use a vless:// link ("XHTTP", "VLESS Encryption"), nil when it can.
+ (NSString *)unsupportedReasonForVless:(NSString *)link;

@end
