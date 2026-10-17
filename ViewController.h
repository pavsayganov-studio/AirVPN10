#import <Cocoa/Cocoa.h>
@interface ViewController : NSViewController

// Theme (used by AppDelegate for the popover chrome)
+ (BOOL)systemIsDark;
+ (NSAppearance *)appearanceForDark:(BOOL)dark;

// Quick actions + state for the right-click menu of the menu-bar item (v0.13.0).
// The state getters never load the UI, so building the menu is free.
@property (readonly) BOOL vpnOn, youtubeOn, quickBusy, youtubeAvailable, hasServers;
- (void)quickConnectVPNWithFallback:(void (^)(void))needsPerson;   // block runs if the window is needed (no keys yet)
- (void)quickDisconnectVPN;
- (void)quickToggleYouTube;
- (void)quickQuit;
// «Ускориться» (v0.15.0): same entry points the button and the menu use.
@property (readonly) BOOL animationsTweaked;     // Raketa's animation settings are in force (menu: "Вернуть анимации")
- (void)quickSpeedUp;
- (void)quickRestoreAnimations;

@end
