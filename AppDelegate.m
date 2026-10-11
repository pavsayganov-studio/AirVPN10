#import "AppDelegate.h"
#import "ViewController.h"

// Menu-bar glyph (v0.13.5): the rocket of AppIcon.svg as a TEMPLATE image - black on a
// transparent background; macOS tints it for the light/dark menu bar like every other status
// icon, so no colour is chosen here. The shapes are those of AppIcon.svg (viewBox 100, nose up);
// the matrix below is the SVG transform "translate(9 9) scale(16/75.1) translate(-45.75 -55.25)
// rotate(45 50 51)" written out, so the order of operations cannot be misread: rocket 16 of the
// 18 pt canvas, nose to the upper right. A drawing handler, not a bitmap: sharp on every scale
// factor, drawn only when the menu bar repaints. Flipped (y down) so the numbers are the SVG's.
// The porthole is cut with the even-odd rule (windingRule 1 == NSEvenOddWindingRule; the raw
// value avoids the enum's renamed constant).
static NSImage *RKRocketGlyph(void) {
    NSImage *img = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:YES
                          drawingHandler:^BOOL(NSRect dst) {
        NSAffineTransformStruct m = {0.150649, 0.150649, -0.150649, 0.150649, 10.056108, -7.120966};
        NSAffineTransform *t = [NSAffineTransform transform];
        [t setTransformStruct:m];
        [t concat];
        [[NSColor blackColor] set];
        {
            NSBezierPath *hull = [NSBezierPath bezierPath];
            [hull moveToPoint:NSMakePoint(50, 4)];
            [hull curveToPoint:NSMakePoint(65, 62) controlPoint1:NSMakePoint(63, 16) controlPoint2:NSMakePoint(67, 34)];
            [hull lineToPoint:NSMakePoint(35, 62)];
            [hull curveToPoint:NSMakePoint(50, 4) controlPoint1:NSMakePoint(33, 34) controlPoint2:NSMakePoint(37, 16)];
            [hull closePath];
            [hull appendBezierPathWithOvalInRect:NSMakeRect(42, 28, 16, 16)];
            hull.windingRule = (NSWindingRule)1;
            [hull fill];
        }
        {
            NSBezierPath *p = [NSBezierPath bezierPath];
            [p moveToPoint:NSMakePoint(62, 44)];
            [p curveToPoint:NSMakePoint(80, 80) controlPoint1:NSMakePoint(72, 52) controlPoint2:NSMakePoint(79, 62)];
            [p lineToPoint:NSMakePoint(62, 70)];
            [p closePath];
            [p fill];
        }
        {
            NSBezierPath *p = [NSBezierPath bezierPath];
            [p moveToPoint:NSMakePoint(38, 44)];
            [p curveToPoint:NSMakePoint(20, 80) controlPoint1:NSMakePoint(28, 52) controlPoint2:NSMakePoint(21, 62)];
            [p lineToPoint:NSMakePoint(38, 70)];
            [p closePath];
            [p fill];
        }
        {
            NSBezierPath *p = [NSBezierPath bezierPath];
            [p moveToPoint:NSMakePoint(40, 59)];
            [p lineToPoint:NSMakePoint(60, 59)];
            [p lineToPoint:NSMakePoint(57, 70)];
            [p lineToPoint:NSMakePoint(43, 70)];
            [p closePath];
            [p fill];
        }
        {
            NSBezierPath *p = [NSBezierPath bezierPath];
            [p moveToPoint:NSMakePoint(43, 73)];
            [p curveToPoint:NSMakePoint(50, 98) controlPoint1:NSMakePoint(42, 83) controlPoint2:NSMakePoint(47, 92)];
            [p curveToPoint:NSMakePoint(57, 73) controlPoint1:NSMakePoint(53, 92) controlPoint2:NSMakePoint(58, 83)];
            [p closePath];
            [p fill];
        }
        return YES;
    }];
    [img setTemplate:YES];
    return img;
}

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
    // v0.13.5: only a monochrome rocket (template image) - same look as the other status icons,
    // no text taking menu-bar space. The tooltip is the only label left, so keep it.
    self.statusItem.button.image         = RKRocketGlyph();
    self.statusItem.button.imagePosition = NSImageOnly;
    self.statusItem.button.toolTip       = @"Raketa";
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
