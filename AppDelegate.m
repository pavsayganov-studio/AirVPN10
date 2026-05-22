#import "AppDelegate.h"
#import "ViewController.h"

@interface AppDelegate ()
@property (strong) NSStatusItem *statusItem;
@property (strong) NSPopover    *popover;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSMenu *main = [[NSMenu alloc] init];
    NSMenuItem *ei = [[NSMenuItem alloc] init];
    NSMenu *em = [[NSMenu alloc] initWithTitle:@"Edit"];
    [em addItemWithTitle:@"Cut"        action:@selector(cut:)       keyEquivalent:@"x"];
    [em addItemWithTitle:@"Copy"       action:@selector(copy:)      keyEquivalent:@"c"];
    [em addItemWithTitle:@"Paste"      action:@selector(paste:)     keyEquivalent:@"v"];
    [em addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [ei setSubmenu:em]; [main addItem:ei]; [NSApp setMainMenu:main];

    self.statusItem = [[NSStatusBar systemStatusBar]
                       statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title  = @"🚀 Raketa";
    self.statusItem.button.action = @selector(togglePopover:);
    self.statusItem.button.target = self;

    self.popover = [[NSPopover alloc] init];
    self.popover.contentViewController = [[ViewController alloc] init];
    self.popover.behavior = NSPopoverBehaviorTransient;
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
@end
