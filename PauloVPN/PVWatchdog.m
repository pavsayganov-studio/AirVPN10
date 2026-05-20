#import "PVWatchdog.h"
@interface PVWatchdog ()
@property (weak) NSTask *task;
@property (weak) id target;
@property (assign) SEL selector;
@property (strong) NSTimer *timer;
@end
@implementation PVWatchdog
+ (instancetype)shared {
    static PVWatchdog *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}
- (void)startMonitoring:(NSTask *)task startSelector:(SEL)selector target:(id)target {
    self.task = task; self.selector = selector; self.target = target;
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(check) userInfo:nil repeats:YES];
}
- (void)check {
    if (!self.task || ![self.task isRunning]) {
        NSLog(@"[Watchdog] Restarting sing-box...");
        if ([self.target respondsToSelector:self.selector])
            [self.target performSelectorOnMainThread:self.selector withObject:nil waitUntilDone:NO];
    }
}
- (void)stopMonitoring { [self.timer invalidate]; self.timer = nil; }
@end
