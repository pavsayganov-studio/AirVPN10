#import "VPNManager+Watchdog.h"
#import <AppKit/AppKit.h>

// Associated objects key for timer
static const void *kWatchdogTimerKey = &kWatchdogTimerKey;

@implementation VPNManager (Watchdog)

- (NSTimer *)watchdogTimer {
    return objc_getAssociatedObject(self, kWatchdogTimerKey);
}

- (void)setWatchdogTimer:(NSTimer *)timer {
    objc_setAssociatedObject(self, kWatchdogTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)startWatchdog {
    [self stopWatchdog]; // на всякий случай
    self.watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                          target:self
                                                        selector:@selector(checkSingBoxProcess)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (void)stopWatchdog {
    [self.watchdogTimer invalidate];
    self.watchdogTimer = nil;
}

- (void)checkSingBoxProcess {
    // Проверяем, жив ли процесс sing-box
    // Предполагаем, что у основного класса есть свойство singBoxTask типа NSTask
    NSTask *task = [self performSelector:@selector(singBoxTask)]; // если объявлено
    if (task && [task isRunning]) {
        return;
    }
    NSLog(@"[PauloVPN] sing-box упал, перезапускаю...");
    // Вызываем метод запуска из основной реализации
    if ([self respondsToSelector:@selector(startSingBox)]) {
        [self performSelector:@selector(startSingBox)];
    }
}

@end
