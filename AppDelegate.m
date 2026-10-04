#import "AppDelegate.h"
#import "ViewController.h"

@interface AppDelegate () <NSMenuDelegate>
@property (strong) NSStatusItem   *statusItem;
@property (strong) NSPopover      *popover;
@property (strong) ViewController *vc;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    // Edit menu — enables Cut/Copy/Paste in the URL text field
    NSMenu *main = [[NSMenu alloc] init];
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    for (NSArray *a in @[@[@"Cut",@"cut:",@"x"],@[@"Copy",@"copy:",@"c"],
                          @[@"Paste",@"paste:",@"v"],@[@"Select All",@"selectAll:",@"a"]])
        [editMenu addItemWithTitle:a[0] action:NSSelectorFromString(a[1]) keyEquivalent:a[2]];
    [editItem setSubmenu:editMenu];
    [main addItem:editItem];
    [NSApp setMainMenu:main];

    self.statusItem = [[NSStatusBar systemStatusBar]
                        statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title  = @"🚀 Raketa";
    self.statusItem.button.action = @selector(statusItemClicked:);
    self.statusItem.button.target = self;
    // v0.13.0: react on mouse-up of BOTH buttons so a right-click can open the
    // quick-actions menu while a left-click still opens the window.
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];

    self.vc = [[ViewController alloc] init];
    self.popover = [[NSPopover alloc] init];
    self.popover.contentViewController = self.vc;
    self.popover.behavior = NSPopoverBehaviorTransient;
    [self syncPopoverAppearance];

    // Event-driven (no polling): the popover frame/arrow follows the system theme.
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self
        selector:@selector(themeChanged:)
            name:@"AppleInterfaceThemeChangedNotification" object:nil];
}

- (void)themeChanged:(NSNotification *)n {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self syncPopoverAppearance]; });
}

- (void)syncPopoverAppearance {
    self.popover.appearance = [ViewController appearanceForDark:[ViewController systemIsDark]];
}

- (void)statusItemClicked:(id)sender {
    NSEvent *e = [NSApp currentEvent];
    BOOL right = e.type == NSEventTypeRightMouseUp
              || (e.type == NSEventTypeLeftMouseUp && (e.modifierFlags & NSEventModifierFlagControl));
    if (right) [self showQuickMenu]; else [self togglePopover:sender];
}

- (void)togglePopover:(id)sender {
    if (self.popover.isShown) {
        [self.popover performClose:sender];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
        [self.popover showRelativeToRect:self.statusItem.button.bounds
                                  ofView:self.statusItem.button
                           preferredEdge:NSRectEdgeMinY];
    }
}

#pragma mark - Quick actions menu (right-click)

- (NSMenuItem *)quickItem:(NSString *)title action:(SEL)a enabled:(BOOL)en state:(NSInteger)st {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:a keyEquivalent:@""];
    it.target  = self;
    it.enabled = en;
    it.state   = st;
    return it;
}

- (void)showQuickMenu {
    if (self.popover.isShown) [self.popover performClose:nil];
    ViewController *vc = self.vc;
    BOOL vpn = vc.vpnOn, yt = vc.youtubeOn, busy = vc.quickBusy;
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    m.autoenablesItems = NO;            // enabled/disabled is decided here, from live state
    [m addItem:[self quickItem:@"Подключить VPN"  action:@selector(quickConnect)
                       enabled:(!vpn && !busy)    state:NSOffState]];
    [m addItem:[self quickItem:@"Отключить VPN"   action:@selector(quickDisconnect)
                       enabled:vpn               state:NSOffState]];
    [m addItem:[NSMenuItem separatorItem]];
    // YouTube mode and VPN are mutually exclusive (see handoff.md), so the item is
    // off while the VPN is on, exactly like the button in the window.
    [m addItem:[self quickItem:@"Обход YouTube (DPI)" action:@selector(quickYouTube)
                       enabled:(vc.youtubeAvailable && !vpn && !busy)
                         state:(yt ? NSOnState : NSOffState)]];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:[self quickItem:@"Выйти" action:@selector(quickQuit) enabled:YES state:NSOffState]];

    // Attach, click, detach: the documented way to show a menu for a status
    // item that normally uses a custom action.
    self.statusItem.menu = m;
    [self.statusItem.button performClick:nil];
    self.statusItem.menu = nil;
}

- (void)quickConnect {
    [self.vc quickConnectVPNWithFallback:^{ [self togglePopover:nil]; }];   // no keys yet: show the window
}
- (void)quickDisconnect { [self.vc quickDisconnectVPN]; }
- (void)quickYouTube    { [self.vc quickToggleYouTube]; }
- (void)quickQuit       { [self.vc quickQuit]; }

@end
