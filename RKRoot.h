#import <Foundation/Foundation.h>

// One administrator password per app session (v0.15.0).
//
// Before: every privileged step (start / stop / switch mode / DPI search) was its own
// `do shell script ... with administrator privileges`, so the person typed the password at every
// switch. Now the FIRST privileged step starts a small root helper (the bundled rkhelper.sh) through
// one prompt; every later step is a line on a FIFO to that helper. The helper understands a fixed list
// of verbs only (core-start / core-stop / proxy-off / search-start / search-stop) and exits when the
// app quits or dies. If the helper cannot be used for any reason the caller falls back to the old
// per-step prompt, so the worst case is the behaviour of v0.14.2.
//
// Foundation only. Main thread only (the callers are the same synchronous call sites as before).
typedef NS_ENUM(NSInteger, RKRootStatus) {
    RKRootOK,            // the verb ran; `reply` holds the helper's value (a pid for the *-start verbs)
    RKRootCancelled,     // the person cancelled the one password prompt: nothing ran
    RKRootUnavailable    // no session (disabled, helper missing/failed): use the legacy per-step prompt
};

@interface RKRoot : NSObject
// scriptPath: bundled rkhelper.sh. supportDir / resourcesDir: the only places the helper will accept
// a config, a log or a sing-box binary from.
- (instancetype)initWithHelperScript:(NSString *)scriptPath
                          supportDir:(NSString *)supportDir
                        resourcesDir:(NSString *)resourcesDir;
@property (nonatomic, readonly) BOOL active;      // a helper is running for this app session
// verbAndArgs: @[@"core-start", iface, ...]. Starts the session first if there is none.
- (RKRootStatus)run:(NSArray<NSString *> *)verbAndArgs reply:(NSString **)reply;
- (void)shutdown;                                 // tells the helper to quit; safe to call twice
@end
