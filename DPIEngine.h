// DPIEngine — YouTube DPI-bypass engine for Raketa (v0.12.0).
//
// Foundation-only on purpose (no AppKit): all UI lives in ViewController.m,
// and this class can be compiled and tested outside the app.
//
// What it does:
//   * runs the bundled `ciadpi` (ByeDPI, MIT) as a *user-level* local SOCKS5
//     proxy on 127.0.0.1:10811 — no root, no TUN, no pf rules;
//   * tests a short list of stream-cutting strategies (v0.13.4, see DPIEngine.m) on
//     the current network by test-fetching YouTube/googlevideo hosts through a
//     throw-away ciadpi per strategy, after a wire probe that says where the
//     filter acts (the host lists still come from the ByeByeDPI repo);
//   * builds the sing-box config used by "Смотреть YouTube" mode.
//
// CPU discipline: no timers, no polling. Everything below runs only when the
// person clicks a button; ciadpi itself sleeps in poll() while idle.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DPIResult : NSObject
@property (copy)   NSString *strategy;   // raw strategy line (its identity)
@property (assign) NSInteger number;     // 1000 + position in the candidate list ("M" + position)
@property (copy)   NSString *label;      // what the UI shows after "№": "M3"
@property (assign) NSInteger ok;         // hosts reachable through this strategy
@property (assign) NSInteger total;      // hosts tested
@property (assign) double    avgTime;    // mean seconds of the successful requests
@end

// stage: @"update" (checking the repo) or @"search"; done/total count strategies
typedef void (^DPIProgressBlock)(NSString *stage, NSInteger done, NSInteger total, NSInteger best);
typedef void (^DPIDoneBlock)(BOOL ok, NSString *summary);
typedef void (^DPIStartBlock)(BOOL ok, NSString * _Nullable error);
// v0.14.2: root launch of a sing-box for the "S" strategies' search; supplied by the app (the engine
// has no UI). done(pid, nil) on success, done(0, reason) otherwise. Called off the main queue.
typedef void (^DPIPrivStartBlock)(NSString *binary, NSString *config, NSString *log,
                                  void (^done)(int pid, NSString * _Nullable error));
typedef void (^DPIPrivStopBlock)(int pid);

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
// v0.14.2 - strategies run by sing-box itself ("S": tls_spoof / tls_fragment route options)
@property (copy, nullable) NSString * _Nullable (^coreBinary)(void);   // the sing-box to run
@property (copy, nullable) DPIPrivStartBlock privStart;
@property (copy, nullable) DPIPrivStopBlock  privStop;
+ (BOOL)isSingBoxStrategy:(NSString *)raw;                  // "sb:..." line (S1...S8)

- (NSInteger)strategyCount;                                  // valid strategies in the list
- (NSInteger)numberForStrategy:(NSString *)raw;              // 1-based, 0 if not in list
- (NSArray<DPIResult *> *)topResults:(NSUInteger)n;          // best first, ok > 0 only
- (nullable DPIResult *)resultForStrategy:(NSString *)raw;   // also for candidates that failed the search
- (NSString *)labelForStrategy:(NSString *)raw;              // "M3"; @"" if not a candidate
// Every candidate in test order with the last measurement (total == 0: not tested), so the
// person can pick any of them by hand even when the search found none.
- (NSArray<DPIResult *> *)allCandidates;
- (NSString *)diagnosisNote;                                 // wire probe + DNS check + control runs: what they say about the last failure
- (NSString *)searchLogPath;                                 // dpi_search.log (may not exist yet)
- (NSString *)resultsSummary;                                // one line for the menu header
- (NSString *)coverageNote;                                  // "checked N: stream cutting only"
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
// An instance method since v0.13.3: when the last search found the system resolver unusable
// (v0.13.4: only then) the YouTube names are resolved by sing-box over DoH and ciadpi is fed
// IPv4 addresses over SOCKS4.
- (NSDictionary *)youtubeOnlyConfigWithInbounds:(NSArray *)inbounds;
+ (int)proxyPort;

@end

NS_ASSUME_NONNULL_END
