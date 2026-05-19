#import "AppDelegate.h"

@interface AppDelegate ()
@property (strong) NSStatusItem *statusItem;
@property (strong) NSMenuItem *statusMenuItem;
@property (strong) NSMenuItem *toggleMenuItem;
@property (strong) NSString *currentPID;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"🛡️";
    
    NSMenu *menu = [[NSMenu alloc] init];
    
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Status: Ready" action:nil keyEquivalent:@""];
    [self.statusMenuItem setEnabled:NO];
    [menu addItem:self.statusMenuItem];
    
    [menu addItem:[NSMenuItem separatorItem]];
    
    self.toggleMenuItem = [[NSMenuItem alloc] initWithTitle:@"Connect" action:@selector(toggleConnection) keyEquivalent:@"c"];
    [self.toggleMenuItem setTarget:self];
    [menu addItem:self.toggleMenuItem];
    
    [menu addItem:[NSMenuItem separatorItem]];
    
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quitApp) keyEquivalent:@"q"];
    [quitItem setTarget:self];
    [menu addItem:quitItem];
    
    self.statusItem.menu = menu;
}

- (void)toggleConnection {
    if (self.currentPID != nil) {
        [self stopVPN];
    } else {
        [self startVPN];
    }
}

- (void)startVPN {
    self.statusMenuItem.title = @"Status: Connecting...";
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *appSupport = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    appSupport = [appSupport URLByAppendingPathComponent:@"MiniVPN"];
    [fm createDirectoryAtURL:appSupport withIntermediateDirectories:YES attributes:nil error:nil];
    
    NSString *configPath = [[appSupport URLByAppendingPathComponent:@"config.json"] path];
    NSString *logPath = [[appSupport URLByAppendingPathComponent:@"vpn.log"] path];
    NSString *binaryPath = [[NSBundle mainBundle] pathForResource:@"sing-box" ofType:nil];
    
    NSString *configJSON = @"{\"log\":{\"level\":\"info\"},\"inbounds\":[{\"type\":\"tun\",\"tag\":\"tun-in\",\"interface_name\":\"utun9\",\"inet4_address\":\"172.19.0.1/30\",\"auto_route\":true,\"strict_route\":true}],\"outbounds\":[{\"type\":\"direct\",\"tag\":\"direct\"}]}";
    [configJSON writeToFile:configPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    
    NSString *shellCommand = [NSString stringWithFormat:@"nohup '%@' run -c '%@' > '%@' 2>&1 & echo $!", binaryPath, configPath, logPath];
    NSString *scriptSource = [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", shellCommand];
    
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorInfo = nil;
    NSAppleEventDescriptor *output = [script executeAndReturnError:&errorInfo];
    
    if (output && output.stringValue && output.stringValue.length > 0) {
        self.currentPID = output.stringValue;
        self.statusMenuItem.title = @"Status: Connected";
        self.toggleMenuItem.title = @"Disconnect";
        self.statusItem.button.title = @"🟢";
    } else {
        self.statusMenuItem.title = @"Status: Auth Failed";
    }
}

- (void)stopVPN {
    if (!self.currentPID) return;
    NSString *scriptSource = [NSString stringWithFormat:@"do shell script \"kill -9 %@\" with administrator privileges", self.currentPID];
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    [script executeAndReturnError:nil];
    
    self.currentPID = nil;
    self.statusMenuItem.title = @"Status: Ready";
    self.toggleMenuItem.title = @"Connect";
    self.statusItem.button.title = @"🛡️";
}

- (void)quitApp {
    if (self.currentPID != nil) { [self stopVPN]; }
    [[NSApplication sharedApplication] terminate:self];
}
@end
