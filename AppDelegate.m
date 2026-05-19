#import "AppDelegate.h"
#import "ViewController.h"

@interface AppDelegate ()
@property (strong) NSStatusItem *statusItem;
@property (strong) NSPopover *popover;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // 1. Создаем иконку
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"🛡️";
    self.statusItem.button.action = @selector(togglePopover:);
    self.statusItem.button.target = self;
    
    // 2. Создаем всплывающее окно
    self.popover = [[NSPopover alloc] init];
    self.popover.contentViewController = [[ViewController alloc] init];
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
}

- (void)togglePopover:(id)sender {
    if (self.popover.isShown) {
        [self.popover performClose:sender];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
        [self.popover showRelativeToRect:self.statusItem.button.bounds ofView:self.statusItem.button preferredEdge:NSRectEdgeMinY];
    }
}
@end
