#import <Foundation/Foundation.h>
@interface PVWatchdog : NSObject
+ (instancetype)shared;
- (void)startMonitoring:(NSTask *)task startSelector:(SEL)selector target:(id)target;
- (void)stopMonitoring;
@end
