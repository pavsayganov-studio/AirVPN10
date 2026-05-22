#!/bin/bash
# =============================================================================
# Raketa v0.8.0 — Deep code review patch
# Run from repo root: bash patch_raketa_080.sh
# =============================================================================
set -e
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'

echo -e "${C}╔══════════════════════════════════════════╗"
echo -e "║   Raketa v0.8.0 — Deep Review Patch      ║"
echo -e "╚══════════════════════════════════════════╝${N}\n"

[ ! -f "ViewController.m" ] && echo -e "${R}✗ Run from repo root${N}" && exit 1

for f in ViewController.m AppDelegate.m Info.plist .github/workflows/build.yml; do
    [ -f "$f" ] && cp "$f" "${f}.bak080" && echo -e "${G}✓ Backup: ${f}.bak080${N}"
done
echo ""

# =============================================================================
echo -e "${Y}→ AppDelegate.m${N}"
cat > AppDelegate.m << 'EOF'
#import "AppDelegate.h"
#import "ViewController.h"

@interface AppDelegate ()
@property (strong) NSStatusItem *statusItem;
@property (strong) NSPopover    *popover;
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
EOF
echo -e "${G}✓ AppDelegate.m${N}"

# =============================================================================
echo -e "${Y}→ ViewController.m${N}"
cat > ViewController.m << 'EOF'
#import "ViewController.h"
#import <SystemConfiguration/SystemConfiguration.h>

// ── Ports ─────────────────────────────────────────────────────────────────────
static const NSInteger kSOCKSPort  = 10808;
static const NSInteger kHTTPPort   = 10809;
static const NSInteger kTGPort     = 10810;
static NSString *const kTGSecret   = @"dd000000000000000000000000000000";
static NSString *const kSubKey     = @"RaketaSubscriptionURL";

// ── Layout ────────────────────────────────────────────────────────────────────
static const CGFloat kW      = 300.0;
static const CGFloat kH      = 370.0;   // base height (without TG panel)
static const CGFloat kHTG    = 158.0;   // TG panel height
static const CGFloat kPAD    = 16.0;

// ── Colors — allocated once at +initialize, never again ───────────────────────
static NSColor *cBG, *cSurface, *cCard, *cBorder,
               *cText, *cSub, *cAccent, *cGreen, *cOrange, *cRed, *cBtn;

// ── Background serial queue for all NSTask work ───────────────────────────────
// NSTimer fires on the main run loop; we offload NSTask to avoid any UI jank.
static dispatch_queue_t sTaskQ;

@interface ViewController ()
// UI
@property (strong) NSTextField    *urlField;
@property (strong) NSTextField    *statusLabel;
@property (strong) NSView         *statusDot;
@property (strong) NSButton       *connectBtn;
@property (strong) NSPopUpButton  *dropdown;
@property (strong) NSButton       *copySecretBtn;   // direct ref — no subview search
// State
@property (strong) NSString       *configPath;
@property (strong) NSString       *logPath;
@property (strong) NSString       *cachedIface;     // cached — avoids repeated NSTask forks
@property (strong) NSMutableArray *proxyTags;
@property (strong) NSMutableArray *proxyOutbounds;
@property (assign) BOOL            connected;
@property (assign) BOOL            stopping;        // guard against double-stop
@property (assign) pid_t           corePID;         // saved PID — kill(pid,0) instead of pgrep
@property (strong) NSTimer        *watchdog;
// TG panel
@property (strong) NSView         *tgPanel;
@property (strong) NSButton       *tgToggleBtn;
@property (assign) BOOL            tgOpen;
@end

@implementation ViewController

// =============================================================================
#pragma mark - Class init — colors & queue, executed once
// =============================================================================
+ (void)initialize {
    if (self != [ViewController class]) return;

    // All colors created exactly once per process lifetime
    cBG      = [NSColor colorWithRed:0.08 green:0.08 blue:0.10 alpha:1.0];
    cSurface = [NSColor colorWithRed:0.12 green:0.12 blue:0.15 alpha:1.0];
    cCard    = [NSColor colorWithRed:0.10 green:0.10 blue:0.13 alpha:1.0];
    cBorder  = [NSColor colorWithRed:0.20 green:0.20 blue:0.26 alpha:1.0];
    cText    = [NSColor colorWithWhite:0.92 alpha:1.0];
    cSub     = [NSColor colorWithWhite:0.45 alpha:1.0];
    cAccent  = [NSColor colorWithRed:0.28 green:0.60 blue:0.95 alpha:1.0];
    cGreen   = [NSColor colorWithRed:0.14 green:0.82 blue:0.42 alpha:1.0];
    cOrange  = [NSColor colorWithRed:0.98 green:0.62 blue:0.20 alpha:1.0];
    cRed     = [NSColor colorWithRed:0.95 green:0.32 blue:0.32 alpha:1.0];
    cBtn     = [NSColor colorWithRed:0.14 green:0.14 blue:0.18 alpha:1.0];

    sTaskQ = dispatch_queue_create("com.samurai.raketa.tasks", DISPATCH_QUEUE_SERIAL);
}

// =============================================================================
#pragma mark - Geometry helper (Y measured from top of base view)
// =============================================================================
- (NSRect)rx:(CGFloat)x top:(CGFloat)t w:(CGFloat)w h:(CGFloat)h {
    return NSMakeRect(x, kH - t - h, w, h);
}

// =============================================================================
#pragma mark - loadView
// =============================================================================
- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kH)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = cBG.CGColor;

    // ── Header ────────────────────────────────────────────────────────────────
    NSView *hdr = [[NSView alloc] initWithFrame:NSMakeRect(0, kH-44, kW, 44)];
    hdr.wantsLayer = YES;
    hdr.layer.backgroundColor = cSurface.CGColor;
    [root addSubview:hdr];

    [hdr addSubview:[self lbl:@"🚀  Raketa"
                          font:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]
                         color:cText frame:NSMakeRect(kPAD, 12, 200, 20)]];

    NSTextField *ver = [self lbl:@"v0.8.0"
                            font:[NSFont systemFontOfSize:10]
                           color:cSub frame:NSMakeRect(kW-52, 14, 38, 16)];
    ver.alignment = NSTextAlignmentRight;
    [hdr addSubview:ver];

    [root addSubview:[self sep:NSMakeRect(0, kH-45, kW, 1)]];

    // ── Subscription ──────────────────────────────────────────────────────────
    [root addSubview:[self sectionLbl:@"ПОДПИСКА" top:54]];
    self.urlField = [self input:[self rx:kPAD top:66 w:kW-kPAD*2 h:26]
                    placeholder:@"vless:// ссылка или URL подписки"];
    [root addSubview:self.urlField];
    [root addSubview:[self btn:@"Загрузить серверы"
                         frame:[self rx:kPAD top:100 w:kW-kPAD*2 h:26]
                        action:@selector(downloadConfig) primary:YES]];
    [root addSubview:[self sep:NSMakeRect(0, kH-134, kW, 1)]];

    // ── Server ────────────────────────────────────────────────────────────────
    [root addSubview:[self sectionLbl:@"СЕРВЕР" top:143]];
    self.dropdown = [[NSPopUpButton alloc] initWithFrame:[self rx:kPAD top:155 w:kW-kPAD*2 h:26]
                                               pullsDown:NO];
    [self.dropdown addItemWithTitle:@"— серверы не загружены —"];
    self.dropdown.enabled = NO;
    self.dropdown.font = [NSFont systemFontOfSize:12];
    self.dropdown.target = self;
    self.dropdown.action = @selector(serverChanged);
    [root addSubview:self.dropdown];

    // ── Status ────────────────────────────────────────────────────────────────
    // Dot: positioned absolutely — no rx: (avoids the double-set bug)
    CGFloat dotY = kH - 191 - 7;
    self.statusDot = [[NSView alloc] initWithFrame:NSMakeRect(kPAD, dotY, 7, 7)];
    self.statusDot.wantsLayer = YES;
    self.statusDot.layer.cornerRadius = 3.5;
    self.statusDot.layer.backgroundColor = cSub.CGColor;
    [root addSubview:self.statusDot];

    self.statusLabel = [self lbl:@"Готов к работе"
                            font:[NSFont systemFontOfSize:11]
                           color:cSub
                           frame:NSMakeRect(kPAD+13, dotY, kW-kPAD*2-13, 15)];
    [root addSubview:self.statusLabel];

    // ── Connect button ────────────────────────────────────────────────────────
    CGFloat btnX = (kW - 76) / 2.0;
    self.connectBtn = [[NSButton alloc] initWithFrame:[self rx:btnX top:210 w:76 h:76]];
    self.connectBtn.title    = @"";
    self.connectBtn.bordered = NO;
    self.connectBtn.wantsLayer = YES;
    self.connectBtn.layer.cornerRadius   = 38;
    self.connectBtn.layer.borderWidth    = 1.5;
    self.connectBtn.layer.borderColor    = cBorder.CGColor;
    self.connectBtn.layer.backgroundColor = cBtn.CGColor;
    self.connectBtn.target = self;
    self.connectBtn.action = @selector(toggle);
    // Use attributed title — contentTintColor is unreliable on 10.13 with borderedNO
    [self setConnectBtnTitle:@"ВЫКЛ" color:cSub];
    [root addSubview:self.connectBtn];

    [root addSubview:[self sep:NSMakeRect(0, kH-298, kW, 1)]];

    // ── Telegram toggle ───────────────────────────────────────────────────────
    self.tgToggleBtn = [self btn:@"📱  Настройка Telegram  ▾"
                           frame:[self rx:kPAD top:307 w:kW-kPAD*2 h:26]
                          action:@selector(toggleTG) primary:NO];
    self.tgToggleBtn.font = [NSFont systemFontOfSize:11];
    [root addSubview:self.tgToggleBtn];

    // ── Bottom bar ────────────────────────────────────────────────────────────
    NSView *bar = [[NSView alloc] initWithFrame:NSMakeRect(0, kH-340, kW, 24)];
    // BUG FIX: was kH-340 for a 16px bar — correct
    bar.wantsLayer = YES;
    bar.layer.backgroundColor = cSurface.CGColor;
    [root addSubview:bar];

    NSButton *logBtn = [self btn:@"Логи"
                           frame:NSMakeRect(kPAD, 2, 52, 20)
                          action:@selector(openLogs) primary:NO];
    logBtn.font = [NSFont systemFontOfSize:10];
    [bar addSubview:logBtn];

    NSButton *quitBtn = [self btn:@"Выход"
                            frame:NSMakeRect(kW-kPAD-60, 2, 60, 20)
                           action:@selector(quit) primary:NO];
    quitBtn.font = [NSFont systemFontOfSize:10];
    [bar addSubview:quitBtn];

    // ── Credit ────────────────────────────────────────────────────────────────
    NSTextField *credit = [self lbl:@"Ради вас старался Пашенька"
                               font:[NSFont systemFontOfSize:9]
                              color:[NSColor colorWithWhite:0.22 alpha:1.0]
                              frame:NSMakeRect(0, kH-370, kW, 14)];
    credit.alignment = NSTextAlignmentCenter;
    [root addSubview:credit];

    // ── TG Panel (starts hidden below view bottom) ────────────────────────────
    [self buildTGPanel:root];

    self.view      = root;
    self.connected = NO;
    self.stopping  = NO;
    self.tgOpen    = NO;
    self.corePID   = 0;

    // ── Paths ─────────────────────────────────────────────────────────────────
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *sup = [[[fm URLsForDirectory:NSApplicationSupportDirectory
                              inDomains:NSUserDomainMask] firstObject]
                  URLByAppendingPathComponent:@"Raketa"];
    [fm createDirectoryAtURL:sup withIntermediateDirectories:YES attributes:nil error:nil];
    self.configPath = [[sup URLByAppendingPathComponent:@"config.json"] path];
    self.logPath    = [[sup URLByAppendingPathComponent:@"raketa.log"]  path];

    // Cache interface name once — avoids spawning networksetup on every VPN op
    self.cachedIface = [self detectIface];

    // Reset proxy only if it's actually on (avoids spurious password prompt)
    if ([self isProxyOn]) [self forceProxyOff];

    // Load cached subscription asynchronously — never stall the main thread
    NSString *savedURL = [[NSUserDefaults standardUserDefaults] stringForKey:kSubKey];
    if (savedURL.length) {
        self.urlField.stringValue = savedURL;
        NSString *subPath = [[self.configPath stringByDeletingLastPathComponent]
                              stringByAppendingPathComponent:@"subscription.json"];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSData *d = [NSData dataWithContentsOfFile:subPath];
            if (!d) return;
            NSMutableDictionary *j = [NSJSONSerialization JSONObjectWithData:d
                options:NSJSONReadingMutableContainers error:nil];
            if (j) dispatch_async(dispatch_get_main_queue(), ^{ [self parsedJSON:j]; });
        });
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onTerminate:)
            name:NSApplicationWillTerminateNotification object:nil];
}

// =============================================================================
#pragma mark - TG Panel
// =============================================================================
- (void)buildTGPanel:(NSView *)root {
    self.tgPanel = [[NSView alloc] initWithFrame:NSMakeRect(0, -kHTG, kW, kHTG)];
    self.tgPanel.wantsLayer = YES;
    self.tgPanel.layer.backgroundColor = cCard.CGColor;

    NSView *topLine = [[NSView alloc] initWithFrame:NSMakeRect(0, kHTG-1, kW, 1)];
    topLine.wantsLayer = YES;
    topLine.layer.backgroundColor = cBorder.CGColor;
    [self.tgPanel addSubview:topLine];

    // Header
    [self.tgPanel addSubview:
     [self lbl:@"TELEGRAM — ПОДКЛЮЧЕНИЕ"
          font:[NSFont systemFontOfSize:9 weight:NSFontWeightSemibold]
         color:cAccent frame:NSMakeRect(kPAD, kHTG-22, kW-kPAD*2, 14)]];

    // ── Method 1: MTProxy ─────────────────────────────────────────────────────
    [self.tgPanel addSubview:
     [self lbl:@"Способ 1 — MTProxy (рекомендовано)"
          font:[NSFont systemFontOfSize:10 weight:NSFontWeightMedium]
         color:cText frame:NSMakeRect(kPAD, kHTG-38, kW-kPAD*2, 14)]];

    [self.tgPanel addSubview:
     [self monoLbl:[NSString stringWithFormat:@"127.0.0.1  ·  %ld  ·  %@",
                    (long)kTGPort, kTGSecret]
              frame:NSMakeRect(kPAD, kHTG-54, kW-kPAD*2, 13)]];

    NSButton *openMT = [self btn:@"⚡  Открыть в Telegram"
                           frame:NSMakeRect(kPAD, kHTG-78, 148, 22)
                          action:@selector(openMTLink) primary:YES];
    openMT.font = [NSFont systemFontOfSize:10];
    [self.tgPanel addSubview:openMT];

    // Direct property reference — no subview search needed in copySecret
    self.copySecretBtn = [self btn:@"Копировать секрет"
                             frame:NSMakeRect(kPAD+154, kHTG-78, kW-kPAD*2-154, 22)
                            action:@selector(copySecret) primary:NO];
    self.copySecretBtn.font = [NSFont systemFontOfSize:10];
    [self.tgPanel addSubview:self.copySecretBtn];

    // Divider
    NSView *div = [[NSView alloc] initWithFrame:NSMakeRect(kPAD, kHTG-88, kW-kPAD*2, 1)];
    div.wantsLayer = YES;
    div.layer.backgroundColor = cBorder.CGColor;
    [self.tgPanel addSubview:div];

    // ── Method 2: SOCKS5 ──────────────────────────────────────────────────────
    [self.tgPanel addSubview:
     [self lbl:@"Способ 2 — SOCKS5 (запасной)"
          font:[NSFont systemFontOfSize:10 weight:NSFontWeightMedium]
         color:cText frame:NSMakeRect(kPAD, kHTG-104, kW-kPAD*2, 14)]];

    [self.tgPanel addSubview:
     [self monoLbl:[NSString stringWithFormat:@"127.0.0.1  ·  %ld  ·  SOCKS5", (long)kSOCKSPort]
              frame:NSMakeRect(kPAD, kHTG-120, kW-kPAD*2, 13)]];

    NSButton *openSK = [self btn:@"Открыть SOCKS5 в Telegram"
                           frame:NSMakeRect(kPAD, kHTG-144, kW-kPAD*2, 22)
                          action:@selector(openSOCKSLink) primary:NO];
    openSK.font = [NSFont systemFontOfSize:10];
    [self.tgPanel addSubview:openSK];

    [root addSubview:self.tgPanel];
}

- (void)toggleTG {
    self.tgOpen = !self.tgOpen;

    if (self.tgOpen) {
        // Move TG panel into visible area (at the bottom)
        self.tgPanel.frame = NSMakeRect(0, 0, kW, kHTG);
        // Shift all other subviews upward
        for (NSView *v in self.view.subviews)
            if (v != self.tgPanel)
                v.frame = NSMakeRect(v.frame.origin.x, v.frame.origin.y + kHTG,
                                     v.frame.size.width, v.frame.size.height);
        self.tgToggleBtn.title = @"📱  Настройка Telegram  ▴";
    } else {
        // Shift all other subviews back down
        for (NSView *v in self.view.subviews)
            if (v != self.tgPanel)
                v.frame = NSMakeRect(v.frame.origin.x, v.frame.origin.y - kHTG,
                                     v.frame.size.width, v.frame.size.height);
        self.tgPanel.frame = NSMakeRect(0, -kHTG, kW, kHTG);
        self.tgToggleBtn.title = @"📱  Настройка Telegram  ▾";
    }

    // Update popover size — required for NSPopover to actually resize
    self.preferredContentSize = NSMakeSize(kW, self.tgOpen ? kH + kHTG : kH);
}

- (void)openMTLink {
    NSString *u = [NSString stringWithFormat:
                   @"tg://proxy?server=127.0.0.1&port=%ld&secret=%@",
                   (long)kTGPort, kTGSecret];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:u]];
}

- (void)openSOCKSLink {
    NSString *u = [NSString stringWithFormat:
                   @"tg://socks?server=127.0.0.1&port=%ld", (long)kSOCKSPort];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:u]];
}

- (void)copySecret {
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:kTGSecret forType:NSPasteboardTypeString];
    // Direct property ref — no subview iteration
    NSButton *b = self.copySecretBtn;
    b.title = @"✓ Скопировано";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ b.title = @"Копировать секрет"; });
}

// =============================================================================
#pragma mark - VPN Core
// =============================================================================
- (void)toggle {
    self.connected ? [self stopVPN] : [self startVPN];
}

- (void)startVPN {
    if (!self.proxyTags.count) {
        [self setStatus:@"Сначала загрузите серверы" color:cOrange]; return;
    }
    NSString *tag = self.dropdown.titleOfSelectedItem ?: @"";
    NSDictionary *outbound = nil;
    for (NSDictionary *o in self.proxyOutbounds)
        if ([o[@"tag"] isEqualToString:tag]) { outbound = o; break; }
    if (!outbound) return;

    [self setStatus:@"Запуск..." color:cSub];

    // Build config
    NSDictionary *cfg = @{
        @"log": @{ @"level": @"warn" },
        @"inbounds": @[
            @{@"type":@"socks", @"tag":@"socks", @"listen":@"127.0.0.1", @"listen_port":@(kSOCKSPort)},
            @{@"type":@"http",  @"tag":@"http",  @"listen":@"127.0.0.1", @"listen_port":@(kHTTPPort)},
            @{@"type":@"socks", @"tag":@"tg",    @"listen":@"127.0.0.1", @"listen_port":@(kTGPort)}
        ],
        @"outbounds": @[ outbound, @{@"type":@"direct", @"tag":@"direct"} ],
        @"route": @{
            @"rules": @[
                @{ @"ip_cidr":       @[@"127.0.0.0/8",@"192.168.0.0/16",
                                       @"10.0.0.0/8",  @"172.16.0.0/12"],
                   @"outbound":@"direct" },
                @{ @"domain_suffix": @[@"apple.com",@"icloud.com"],
                   @"outbound":@"direct" },
                @{ @"domain_suffix": @[@".ru",@".рф"],
                   @"outbound":@"direct" }
            ],
            @"final": tag
        }
    };

    NSData *cfgData = [NSJSONSerialization dataWithJSONObject:cfg options:0 error:nil];
    if (!cfgData) { [self setStatus:@"Ошибка конфига" color:cRed]; return; }
    [cfgData writeToFile:self.configPath atomically:YES];

    NSString *bin   = [[NSBundle mainBundle] pathForResource:@"sing-box" ofType:nil];
    // Use cached interface — NO extra networksetup fork here
    NSString *iface = self.cachedIface;

    // Build shell script — one AppleScript call, all ops atomic
    NSString *sh = [NSString stringWithFormat:
        @"killall -9 sing-box 2>/dev/null||true;"
        @"sleep 0.3;"
        @"networksetup -setwebproxy '%@' 127.0.0.1 %ld;"
        @"networksetup -setsecurewebproxy '%@' 127.0.0.1 %ld;"
        @"networksetup -setsocksfirewallproxy '%@' 127.0.0.1 %ld;"
        @"nohup '%@' run -c '%@' > '%@' 2>&1 &"
        @"echo $!",   // print PID so we can capture it
        [self esc:iface], (long)kHTTPPort,
        [self esc:iface], (long)kHTTPPort,
        [self esc:iface], (long)kSOCKSPort,
        [self esc:bin], [self esc:self.configPath], [self esc:self.logPath]];

    NSString *scpt = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges "
        @"with prompt \"Raketa: запуск VPN\"",
        [sh stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];

    NSDictionary *err = nil;
    NSAppleEventDescriptor *result =
        [[[NSAppleScript alloc] initWithSource:scpt] executeAndReturnError:&err];

    if (err) {
        [self setStatus:@"Отменено" color:cSub];
        [self forceProxyOff];
        return;
    }

    // Try to parse PID from AppleScript result (nohup echo $! output)
    pid_t pid = (pid_t)[[result stringValue] intValue];
    self.corePID = pid;

    // Verify core is alive after 1.5s — use saved PID if we have it
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self coreAlive]) {
            [self uiConnected:YES];
            [self startWatchdog];
        } else {
            [self setStatus:@"⚠  Ядро не запустилось — Логи" color:cRed];
            [self forceProxyOff];
        }
    });
}

- (BOOL)stopVPN {
    // Guard: prevent double-stop (quit + onTerminate race)
    if (self.stopping) return YES;
    self.stopping = YES;

    [self.watchdog invalidate];
    self.watchdog = nil;
    self.corePID  = 0;

    NSString *iface = self.cachedIface;  // cached — no extra fork
    NSString *sh = [NSString stringWithFormat:
        @"killall -9 sing-box 2>/dev/null||true;"
        @"networksetup -setwebproxystate '%@' off;"
        @"networksetup -setsecurewebproxystate '%@' off;"
        @"networksetup -setsocksfirewallproxystate '%@' off",
        [self esc:iface], [self esc:iface], [self esc:iface]];

    NSString *scpt = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges "
        @"with prompt \"Raketa: отключение\"",
        [sh stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];

    NSDictionary *err = nil;
    [[[NSAppleScript alloc] initWithSource:scpt] executeAndReturnError:&err];
    self.stopping = NO;

    if (err) { [self setStatus:@"Ошибка сброса" color:cRed]; return NO; }
    [self uiConnected:NO];
    return YES;
}

- (void)forceProxyOff {
    NSString *iface = self.cachedIface ?: [self detectIface];
    NSString *sh = [NSString stringWithFormat:
        @"networksetup -setwebproxystate '%@' off;"
        @"networksetup -setsecurewebproxystate '%@' off;"
        @"networksetup -setsocksfirewallproxystate '%@' off",
        [self esc:iface], [self esc:iface], [self esc:iface]];
    NSString *scpt = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges "
        @"with prompt \"Raketa: сброс прокси\"",
        [sh stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
    [[[NSAppleScript alloc] initWithSource:scpt] executeAndReturnError:nil];
}

// =============================================================================
#pragma mark - Watchdog  (CPU-minimal: uses kill(pid,0) instead of spawning pgrep)
// =============================================================================
- (void)startWatchdog {
    [self.watchdog invalidate];
    // 12s interval — generous enough to avoid false positives, light on CPU
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:12.0
                                                     target:self
                                                   selector:@selector(watchTick)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void)watchTick {
    // Run check on background queue — never block main thread
    dispatch_async(sTaskQ, ^{
        BOOL alive = [self coreAlive];
        if (alive) return;  // most common case — return immediately
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.watchdog invalidate]; self.watchdog = nil;
            self.connected = NO;
            [self uiConnected:NO];
            [self setStatus:@"⚠  Ядро упало — нажми ВКЛ" color:cOrange];
            if ([self isProxyOn]) [self forceProxyOff];
        });
    });
}

- (BOOL)coreAlive {
    // If we have a saved PID, use kill(pid,0) — zero cost, no fork
    if (self.corePID > 0) {
        if (kill(self.corePID, 0) == 0) return YES;
        // PID gone — fall through to pgrep as last resort
        self.corePID = 0;
    }
    // Fallback: pgrep (only reaches here if PID was never captured)
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/bin/sh";
    t.arguments  = @[@"-c", @"pgrep -x sing-box"];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    [t launch]; [t waitUntilExit];
    NSString *o = [[NSString alloc] initWithData:[[p fileHandleForReading] readDataToEndOfFile]
                                        encoding:NSUTF8StringEncoding];
    if (o.length > 0) {
        self.corePID = (pid_t)[o intValue];
        return YES;
    }
    return NO;
}

// =============================================================================
#pragma mark - Network utils
// =============================================================================
- (BOOL)isProxyOn {
    // SCDynamicStoreCopyProxies is fast — reads kernel cache, no disk I/O
    NSDictionary *p = (__bridge_transfer NSDictionary *)SCDynamicStoreCopyProxies(NULL);
    return [p[@"HTTPEnable"] boolValue]
        || [p[@"HTTPSEnable"] boolValue]
        || [p[@"SOCKSEnable"] boolValue];
}

// Called once at startup, result cached in self.cachedIface
- (NSString *)detectIface {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/sbin/networksetup";
    t.arguments  = @[@"-listnetworkserviceorder"];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    [t launch]; [t waitUntilExit];
    NSString *o = [[NSString alloc] initWithData:[[p fileHandleForReading] readDataToEndOfFile]
                                        encoding:NSUTF8StringEncoding];
    for (NSString *n in @[@"Wi-Fi", @"Ethernet", @"USB 10/100 LAN",
                           @"Thunderbolt Ethernet", @"iPhone USB", @"Bluetooth PAN"])
        if ([o containsString:n]) return n;
    return @"Wi-Fi";
}

- (NSString *)esc:(NSString *)s {
    return [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
}

// =============================================================================
#pragma mark - Config parsing
// =============================================================================
- (void)downloadConfig {
    NSString *u = self.urlField.stringValue;
    if (!u.length) return;
    [[NSUserDefaults standardUserDefaults] setObject:u forKey:kSubKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if ([u hasPrefix:@"vless://"]) { [self rawText:u]; return; }

    [self setStatus:@"Загрузка..." color:cSub];
    NSURL *url = [NSURL URLWithString:u];
    if (!url) { [self setStatus:@"Неверный URL" color:cRed]; return; }

    [[[NSURLSession sharedSession] dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (e || !data) { [self setStatus:@"Ошибка сети" color:cRed]; return; }
            // Save cache async — don't block UI
            dispatch_async(sTaskQ, ^{
                NSString *sub = [[self.configPath stringByDeletingLastPathComponent]
                                  stringByAppendingPathComponent:@"subscription.json"];
                [data writeToFile:sub atomically:YES];
            });
            NSError *je;
            NSMutableDictionary *j = [NSJSONSerialization JSONObjectWithData:data
                options:NSJSONReadingMutableContainers error:&je];
            if (!je && j[@"outbounds"]) {
                [self parsedJSON:j];
            } else {
                NSString *t = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                t ? [self rawText:t] : [self setStatus:@"Неверный формат" color:cRed];
            }
        });
    }] resume];
}

- (void)rawText:(NSString *)txt {
    NSString *s = [txt stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Attempt base64 decode (some providers encode subscriptions)
    NSData *dec = [[NSData alloc] initWithBase64EncodedString:s
                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (dec) {
        NSString *ds = [[NSString alloc] initWithData:dec encoding:NSUTF8StringEncoding];
        if (ds) s = ds;
    }
    NSMutableArray *arr = [NSMutableArray array];
    for (NSString *line in [s componentsSeparatedByCharactersInSet:
                             [NSCharacterSet newlineCharacterSet]])
        if ([line hasPrefix:@"vless://"]) {
            NSDictionary *o = [self parseVless:line];
            if (o) [arr addObject:o];
        }
    if (!arr.count) { [self setStatus:@"Серверы не найдены" color:cOrange]; return; }
    [self parsedJSON:[@{@"outbounds": arr} mutableCopy]];
}

- (void)parsedJSON:(NSMutableDictionary *)j {
    self.proxyTags      = [NSMutableArray array];
    self.proxyOutbounds = [NSMutableArray array];

    NSArray *serverTypes = @[@"vless",@"vmess",@"trojan",@"shadowsocks",
                              @"hysteria2",@"tuic",@"trojan-go"];
    NSArray *groupTypes  = @[@"selector",@"urltest",@"dns",
                              @"direct",@"block",@"dns-out"];

    for (NSDictionary *o in j[@"outbounds"]) {
        NSString *type = o[@"type"], *tag = o[@"tag"];
        if (!type || !tag) continue;
        if ([serverTypes containsObject:type] && ![groupTypes containsObject:type]) {
            [self.proxyTags addObject:tag];
            [self.proxyOutbounds addObject:o];
        }
    }

    [self.dropdown removeAllItems];
    if (self.proxyTags.count) {
        [self.dropdown addItemsWithTitles:self.proxyTags];
        [self.dropdown setEnabled:YES];
        [self setStatus:[NSString stringWithFormat:@"Серверов: %lu",
                         (unsigned long)self.proxyTags.count] color:cGreen];
    } else {
        [self setStatus:@"Серверы не найдены" color:cOrange];
    }
}

- (NSDictionary *)parseVless:(NSString *)link {
    NSURLComponents *c = [NSURLComponents componentsWithString:
        [link stringByTrimmingCharactersInSet:
         [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    if (!c || ![c.scheme isEqualToString:@"vless"]) return nil;

    NSString *tag = c.fragment.length
        ? [c.fragment stringByRemovingPercentEncoding]
        : c.host;

    NSMutableDictionary *out = [@{
        @"type":            @"vless",
        @"tag":             tag ?: @"server",
        @"server":          c.host  ?: @"",
        @"server_port":     c.port  ?: @443,
        @"uuid":            c.user  ?: @"",
        @"packet_encoding": @"xudp"
    } mutableCopy];

    NSMutableDictionary *tls = [NSMutableDictionary dictionary];
    NSMutableDictionary *tr  = [NSMutableDictionary dictionary];

    for (NSURLQueryItem *q in c.queryItems) {
        if ([q.name isEqualToString:@"security"]
            && [@[@"tls",@"reality"] containsObject:q.value]) {
            tls[@"enabled"] = @YES;
            if ([q.value isEqualToString:@"reality"]) {
                if (!tls[@"reality"]) tls[@"reality"] = [NSMutableDictionary dictionary];
                tls[@"reality"][@"enabled"] = @YES;
            }
        }
        if ([q.name isEqualToString:@"sni"] && q.value.length)
            tls[@"server_name"] = q.value;
        if ([q.name isEqualToString:@"fp"] && q.value.length)
            tls[@"utls"] = @{@"enabled":@YES, @"fingerprint":q.value};
        if ([q.name isEqualToString:@"pbk"] && q.value.length) {
            if (!tls[@"reality"]) tls[@"reality"] = [NSMutableDictionary dictionary];
            tls[@"reality"][@"public_key"] = q.value;
        }
        if ([q.name isEqualToString:@"sid"] && q.value.length) {
            if (!tls[@"reality"]) tls[@"reality"] = [NSMutableDictionary dictionary];
            tls[@"reality"][@"short_id"] = q.value;
        }
        if ([q.name isEqualToString:@"flow"] && q.value.length)
            out[@"flow"] = q.value;
        if ([q.name isEqualToString:@"type"] && q.value.length
            && ![q.value isEqualToString:@"tcp"])
            tr[@"type"] = q.value;
        if ([q.name isEqualToString:@"path"] && q.value.length)
            tr[@"path"] = q.value;
        if ([q.name isEqualToString:@"serviceName"] && q.value.length)
            tr[@"service_name"] = q.value;
        if ([q.name isEqualToString:@"host"] && q.value.length)
            tr[@"headers"] = @{@"Host": q.value};
    }

    // Default to chrome fingerprint if none specified — best for Russia DPI
    if (tls[@"enabled"] && !tls[@"utls"])
        tls[@"utls"] = @{@"enabled":@YES, @"fingerprint":@"chrome"};

    if (tls.count) out[@"tls"] = tls;
    if (tr.count)  out[@"transport"] = tr;
    return out;
}

// =============================================================================
#pragma mark - UI State
// =============================================================================
- (void)serverChanged {
    if (!self.connected) return;
    // Only start if stop succeeds (guards against cancelled-password half-state)
    if ([self stopVPN]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self startVPN]; });
    }
}

- (void)uiConnected:(BOOL)on {
    self.connected = on;
    NSString *lbl = on
        ? [NSString stringWithFormat:@"Подключено · %@",
           self.dropdown.titleOfSelectedItem ?: @""]
        : @"Готов к работе";
    [self setStatus:lbl color:on ? cGreen : cSub];
    [self setConnectBtnTitle:(on ? @"ВКЛ" : @"ВЫКЛ") color:(on ? cGreen : cSub)];
    self.connectBtn.layer.borderColor     = on ? cGreen.CGColor : cBorder.CGColor;
    self.connectBtn.layer.backgroundColor = on
        ? [NSColor colorWithRed:0.10 green:0.45 blue:0.22 alpha:0.25].CGColor
        : cBtn.CGColor;
}

- (void)setStatus:(NSString *)text color:(NSColor *)color {
    self.statusLabel.stringValue             = text;
    self.statusLabel.textColor               = color;
    self.statusDot.layer.backgroundColor     = color.CGColor;
}

// Attributed title — reliable text color on bordered=NO buttons across 10.13
- (void)setConnectBtnTitle:(NSString *)title color:(NSColor *)color {
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    NSDictionary *attrs = @{
        NSFontAttributeName:            [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName:  ps
    };
    self.connectBtn.attributedTitle =
        [[NSAttributedString alloc] initWithString:title attributes:attrs];
}

- (void)openLogs {
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.logPath])
        [[NSWorkspace sharedWorkspace] openFile:self.logPath withApplication:@"Console"];
    else
        [self setStatus:@"Логов нет" color:cSub];
}

- (void)quit {
    if (self.connected) [self stopVPN];
    [NSApp terminate:nil];
}

// onTerminate: fires AFTER quit: on normal exit — guard prevents double-stop
- (void)onTerminate:(NSNotification *)n {
    [self.watchdog invalidate];
    if (self.connected && !self.stopping) [self stopVPN];
}

// =============================================================================
#pragma mark - UI Factory
// =============================================================================
- (NSTextField *)lbl:(NSString *)s font:(NSFont *)f color:(NSColor *)c frame:(NSRect)r {
    NSTextField *v = [[NSTextField alloc] initWithFrame:r];
    v.stringValue = s; v.font = f; v.textColor = c;
    v.bezeled = NO; v.drawsBackground = NO; v.editable = NO; v.selectable = NO;
    return v;
}

- (NSTextField *)sectionLbl:(NSString *)s top:(CGFloat)t {
    return [self lbl:s font:[NSFont systemFontOfSize:9 weight:NSFontWeightMedium]
               color:cSub frame:[self rx:kPAD top:t w:200 h:11]];
}

- (NSTextField *)monoLbl:(NSString *)s frame:(NSRect)r {
    NSTextField *v = [[NSTextField alloc] initWithFrame:r];
    v.stringValue = s;
    v.font = [NSFont fontWithName:@"Menlo" size:9] ?: [NSFont systemFontOfSize:9];
    v.textColor = cAccent; v.bezeled = NO; v.drawsBackground = NO;
    v.editable = NO; v.selectable = YES;  // selectable: user can copy manually
    return v;
}

- (NSView *)sep:(NSRect)r {
    NSView *v = [[NSView alloc] initWithFrame:r];
    v.wantsLayer = YES;
    v.layer.backgroundColor = cBorder.CGColor;
    return v;
}

- (NSTextField *)input:(NSRect)r placeholder:(NSString *)ph {
    NSTextField *f = [[NSTextField alloc] initWithFrame:r];
    f.placeholderString = ph;
    f.font = [NSFont systemFontOfSize:11];
    f.textColor = cText;
    f.backgroundColor = cSurface;
    f.wantsLayer = YES;
    f.layer.cornerRadius = 5;
    f.layer.borderWidth  = 1;
    f.layer.borderColor  = cBorder.CGColor;
    f.focusRingType = NSFocusRingTypeNone;
    return f;
}

- (NSButton *)btn:(NSString *)t frame:(NSRect)r action:(SEL)a primary:(BOOL)p {
    NSButton *b = [[NSButton alloc] initWithFrame:r];
    b.title      = t;
    b.font       = [NSFont systemFontOfSize:12];
    b.bezelStyle = NSBezelStyleRounded;
    b.target     = self;
    b.action     = a;
    if (!p) b.contentTintColor = cSub;
    return b;
}
@end
EOF
echo -e "${G}✓ ViewController.m${N}"

# =============================================================================
echo -e "${Y}→ Info.plist${N}"
cat > Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>         <string>Raketa</string>
    <key>CFBundleIdentifier</key>         <string>com.samurai.raketa</string>
    <key>CFBundleName</key>               <string>Raketa</string>
    <key>CFBundleDisplayName</key>        <string>Raketa</string>
    <key>CFBundleVersion</key>            <string>0.8.0</string>
    <key>CFBundleShortVersionString</key> <string>0.8.0</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>LSMinimumSystemVersion</key>     <string>10.13.0</string>
    <key>LSUIElement</key>                <true/>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>NSHumanReadableCopyright</key>   <string>Raketa — Ради вас старался Пашенька</string>
</dict>
</plist>
EOF
echo -e "${G}✓ Info.plist (v0.8.0)${N}"

# =============================================================================
echo -e "${Y}→ build.yml${N}"
cat > .github/workflows/build.yml << 'EOF'
name: Build Raketa
on:
  workflow_dispatch:
  push:
    tags:
      - 'v*'
permissions:
  contents: write
jobs:
  build:
    runs-on: macos-latest
    steps:
    - uses: actions/checkout@v3

    - name: Set up Go 1.20
      uses: actions/setup-go@v4
      with:
        go-version: '1.20'

    - name: Build sing-box core
      run: |
        git clone --depth=1 -b v1.8.11 https://github.com/SagerNet/sing-box.git core-build
        cd core-build
        CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 \
          go build -tags "with_utls,with_grpc,with_reality" \
          -trimpath -ldflags="-s -w" \
          -o ../sing-box ./cmd/sing-box

    - name: Compile app
      run: |
        mkdir -p Raketa.app/Contents/MacOS Raketa.app/Contents/Resources
        echo "APPL????" > Raketa.app/Contents/PkgInfo
        cp Info.plist Raketa.app/Contents/Info.plist
        cp sing-box   Raketa.app/Contents/Resources/sing-box
        chmod +x      Raketa.app/Contents/Resources/sing-box

        clang -fobjc-arc \
          -framework Cocoa \
          -framework SystemConfiguration \
          -arch x86_64 -mmacosx-version-min=10.13 \
          -o Raketa.app/Contents/MacOS/Raketa \
          main.m AppDelegate.m ViewController.m

        codesign --force --deep -s - Raketa.app
        zip -r "Raketa-macOS-10.13-${{ github.ref_name }}.zip" Raketa.app

    - name: Release
      uses: softprops/action-gh-release@v1
      with:
        tag_name: ${{ github.ref_name }}
        name: "🚀 Raketa ${{ github.ref_name }}"
        body: |
          ## 🚀 Raketa ${{ github.ref_name }}

          ### v0.8.0 — Deep Review
          **CPU fixes**
          - Watchdog uses `kill(pid,0)` instead of spawning `pgrep` — near-zero CPU cost
          - Watchdog interval raised from 8s → 12s
          - Network interface detected once at startup and cached — was spawning 3 NSTask forks per VPN op
          - Subscription file loaded asynchronously — main thread never stalls on disk I/O

          **Bug fixes**
          - Double-stop on quit fixed with `stopping` guard flag
          - `serverChanged` only calls `startVPN` if `stopVPN` succeeded (password cancel no longer leaves broken state)
          - `statusDot` frame double-set removed
          - Connect button title color now uses `attributedTitle` — reliable on macOS 10.13 with borderless buttons
          - `copySecret` uses direct property reference instead of subview title search
          - `preferredContentSize` updated on TG panel toggle — popover actually resizes
          - Colors allocated once in `+initialize` — not on every `#define` access

          **Architecture unchanged** — same System Proxy + SOCKS5 + sing-box approach
        files: Raketa-macOS-10.13-*.zip
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
EOF
echo -e "${G}✓ build.yml${N}"

# =============================================================================
echo ""
echo -e "${C}╔══════════════════════════════════════════════════════╗"
echo -e "║  Patch applied. Next:                                ║"
echo -e "╠══════════════════════════════════════════════════════╣"
echo -e "║  git add -A                                          ║"
echo -e "║  git commit -m 'v0.8.0: deep review, CPU fixes'     ║"
echo -e "║  git tag v0.8.0                                      ║"
echo -e "║  git push origin main --tags                         ║"
echo -e "╚══════════════════════════════════════════════════════╝${N}"
