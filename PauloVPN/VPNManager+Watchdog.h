#import "VPNManager.h"

@interface VPNManager (Watchdog)
- (void)startWatchdog;
- (void)stopWatchdog;
@end
