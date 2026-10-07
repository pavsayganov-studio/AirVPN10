// DPIEngine — YouTube DPI-bypass engine for Raketa (v0.12.0).
//
// Foundation-only on purpose (no AppKit): all UI lives in ViewController.m,
// and this class can be compiled and tested outside the app.
//
// What it does:
//   * runs the bundled `ciadpi` (ByeDPI, MIT) as a *user-level* local SOCKS5
//     proxy on 127.0.0.1:10811 — no root, no TUN, no pf rules;
//   * keeps the ByeByeDPI strategy list (bundled snapshot + optional update
//     from the ByeByeDPI repo) and finds the strategies that work on the
//     current network by test-fetching YouTube/googlevideo hosts through
//     a throw-away ciadpi per strategy (lines that need options this ciadpi
//     lacks are adapted, see DPIEngine.m);
//   * builds the sing-box config used by "Смотреть YouTube" mode.
//
// CPU discipline: no timers, no polling. Everything below runs only when the
// person clicks a button; ciadpi itself sleeps in poll() while idle.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DPIResult : NSObject
@property (copy)   NSString *strategy;   // raw strategy line (its identity)
@property (assign) NSInteger number;     // position of the line in the ByeByeDPI list ("№N")
@property (assign) BOOL      adapted;    // fake-packet options cut out for macOS (shown as "~")
@property (copy)   NSString *label;      // what the UI shows after "№": "12", "12~" (adapted), "M3" (macOS-first)
@property (assign) NSInteger ok;         // hosts reachable through this strategy
@property (assign) NSInteger total;      // hosts tested
@property (assign) double    avgTime;    // mean seconds of the successful requests
@end

// stage: @"update" (checking the repo) or @"search"; done/total count strategies
typedef void (^DPIProgressBlock)(NSString *stage, NSInteger done, NSInteger total, NSInteger best);
typedef void (^DPIDoneBlock)(BOOL ok, NSString *summary);
typedef void (^DPIStartBlock)(BOOL ok, NSString * _Nullable error);

@interface DPIEngine : NSObject

- (instancetype)initWithBinary:(nullable NSString *)binaryPath
                   resourceDir:(nullable NSString *)resourceDir
                    supportDir:(NSString *)supportDir;

// Where callbacks are delivered. Default: main queue.
- (void)setCallbackQueue:(dispatch_queue_t)queue;

@property (readonly) BOOL available;      // bundled ciadpi exists and is executable
@property (readonly) BOOL searching;
@property (readonly) BOOL proxyRunning;
@property (copy, nullable) NSString *selectedStrategy;   // persisted in NSUserDefaults
// Called (callback queue) when ciadpi died and auto-restart gave up.
@property (copy, nullable) void (^onProxyGaveUp)(void);

- (NSInteger)strategyCount;                                  // valid strategies in the list
- (NSInteger)numberForStrategy:(NSString *)raw;              // 1-based, 0 if not in list
- (NSArray<DPIResult *> *)topResults:(NSUInteger)n;          // best first, ok > 0 only
- (nullable DPIResult *)resultForStrategy:(NSString *)raw;   // also for candidates that failed the search
- (NSString *)labelForStrategy:(NSString *)raw;              // "12", "12~", "M3"; @"" if not a candidate
// Every candidate in test order with the last measurement (total == 0: not tested), so the
// person can pick any of them by hand even when the search found none.
- (NSArray<DPIResult *> *)allCandidates;
- (NSString *)diagnosisNote;                                 // what the two control runs say about the last failure
- (NSString *)searchLogPath;                                 // dpi_search.log (may not exist yet)
- (NSString *)resultsSummary;                                // one line for the menu header
- (NSString *)coverageNote;                                  // "checked X: N original + M adapted + K macOS-first"
- (BOOL)resultsMatchCurrentNetwork;

// Runtime proxy (user-level child process).
- (void)startProxyWithStrategy:(NSString *)raw completion:(DPIStartBlock)completion;
- (void)stopProxy;
- (void)cleanupStaleProxy;                                   // orphan from a crashed session

// Update lists from the repo, then test every strategy on this network.
- (void)searchWithProgress:(DPIProgressBlock)progress done:(DPIDoneBlock)done;
- (void)cancelSearch;

// App is quitting: stop the proxy and any test processes.
- (void)shutdown;

// sing-box config for YouTube-only mode: YouTube domains -> ciadpi, all else direct.
+ (NSDictionary *)youtubeOnlyConfigWithInbounds:(NSArray *)inbounds;
+ (int)proxyPort;

@end

NS_ASSUME_NONNULL_END
