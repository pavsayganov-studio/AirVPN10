// CoreUpdater.h — in-app update of the sing-box core (v0.14.0)
//
// Foundation only, no AppKit: it can never touch the UI, and the VPN code only asks it for a
// path (-activeCorePath). Everything slow (network, tar, `sing-box check`) runs on a background
// queue and is started by an explicit click - there is no timer and no polling.
#import <Foundation/Foundation.h>

@interface CoreUpdater : NSObject

// supportDir: ~/Library/Application Support/Raketa. bundledPath: the core inside Raketa.app.
- (instancetype)initWithSupportDir:(NSString *)supportDir bundledPath:(NSString *)bundledPath;

// The core to run: the updated one when it is installed and executable, else the bundled one.
@property (nonatomic, readonly, copy) NSString *activeCorePath;
@property (nonatomic, readonly) BOOL usingUpdatedCore;
@property (nonatomic, readonly) BOOL busy;

// Version of the active core without starting a process: the installed record, or the value
// CI wrote into Info.plist (RaketaCoreVersion) for the bundled one. @"" when unknown.
- (NSString *)activeVersion;

// Check GitHub for a newer stable sing-box and install it. `status` reports progress text,
// `completion` the result; both are called on the main queue. A new core replaces the old one
// only after it started (`version`) and accepted every config file in `configPaths`
// (`sing-box check`) - a release that dropped a field the app still writes is refused.
- (void)checkAndUpdateWithConfigPaths:(NSArray<NSString *> *)configPaths
                               status:(void (^)(NSString *text))status
                           completion:(void (^)(BOOL ok, NSString *summary))completion;

// Forget the updated core and delete its files; the bundled core is used again.
- (void)resetToBundled;

@end
