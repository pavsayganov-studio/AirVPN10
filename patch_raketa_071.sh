#!/bin/bash
# =============================================================================
# Raketa v0.7.1 — Rename + Clean UI
# Запускать из корня репозитория: bash patch_raketa_071.sh
# =============================================================================
set -e
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'

echo -e "${C}╔══════════════════════════════════════════╗"
echo -e "║   Raketa v0.7.1 — Rename + Clean UI      ║"
echo -e "╚══════════════════════════════════════════╝${N}\n"

if [ ! -f "ViewController.m" ]; then
    echo -e "${R}✗ Запусти из корня репозитория${N}"; exit 1
fi

for f in ViewController.m AppDelegate.m Info.plist; do
    [ -f "$f" ] && cp "$f" "${f}.bak071" && echo -e "${G}✓ Бэкап: ${f}.bak071${N}"
done
echo ""

# =============================================================================
# AppDelegate.m
# =============================================================================
echo -e "${Y}→ AppDelegate.m...${N}"
cat > AppDelegate.m << 'EOF'
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
EOF
echo -e "${G}✓ AppDelegate.m${N}"

# =============================================================================
# ViewController.m
# =============================================================================
echo -e "${Y}→ ViewController.m...${N}"
cat > ViewController.m << 'EOF'
#import "ViewController.h"
#import <SystemConfiguration/SystemConfiguration.h>

static NSInteger const kSOCKSPort    = 10808;
static NSInteger const kHTTPPort     = 10809;
static NSInteger const kTGPort       = 10810;
static NSString *const kTGSecret     = @"dd000000000000000000000000000000";
static NSString *const kSubKey       = @"RaketaSubscriptionURL";

// ── Цвета ────────────────────────────────────────────────────────────────────
#define C_BG      [NSColor colorWithRed:0.08 green:0.08 blue:0.10 alpha:1.0]
#define C_SURFACE [NSColor colorWithRed:0.12 green:0.12 blue:0.15 alpha:1.0]
#define C_CARD    [NSColor colorWithRed:0.10 green:0.10 blue:0.13 alpha:1.0]
#define C_BORDER  [NSColor colorWithRed:0.20 green:0.20 blue:0.26 alpha:1.0]
#define C_TEXT    [NSColor colorWithWhite:0.92 alpha:1.0]
#define C_SUB     [NSColor colorWithWhite:0.45 alpha:1.0]
#define C_ACCENT  [NSColor colorWithRed:0.28 green:0.60 blue:0.95 alpha:1.0]
#define C_GREEN   [NSColor colorWithRed:0.14 green:0.82 blue:0.42 alpha:1.0]
#define C_ORANGE  [NSColor colorWithRed:0.98 green:0.62 blue:0.20 alpha:1.0]
#define C_RED     [NSColor colorWithRed:0.95 green:0.32 blue:0.32 alpha:1.0]
#define C_BTN     [NSColor colorWithRed:0.14 green:0.14 blue:0.18 alpha:1.0]

static const CGFloat W       = 300.0;
static const CGFloat H_BASE  = 370.0;
static const CGFloat H_TG    = 162.0;
static const CGFloat PAD     = 16.0;

@interface ViewController ()
@property (strong) NSTextField   *urlField;
@property (strong) NSTextField   *statusLabel;
@property (strong) NSView        *statusDot;
@property (strong) NSButton      *connectBtn;
@property (strong) NSPopUpButton *dropdown;
@property (strong) NSString      *configPath;
@property (strong) NSString      *logPath;
@property (strong) NSMutableArray *proxyTags;
@property (strong) NSMutableArray *proxyOutbounds;
@property (assign) BOOL           connected;
@property (strong) NSTimer       *watchdog;
@property (strong) NSView        *tgPanel;
@property (strong) NSButton      *tgBtn;
@property (assign) BOOL           tgOpen;
@end

@implementation ViewController

// =============================================================================
#pragma mark - Geometry helper (top-down)
// =============================================================================
- (NSRect)rx:(CGFloat)x top:(CGFloat)t w:(CGFloat)w h:(CGFloat)h {
    return NSMakeRect(x, H_BASE - t - h, w, h);
}

// =============================================================================
#pragma mark - loadView
// =============================================================================
- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, H_BASE)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = C_BG.CGColor;

    // ── Header ───────────────────────────────────────────────────────────────
    NSView *header = [[NSView alloc] initWithFrame:[self rx:0 top:0 w:W h:44]];
    header.wantsLayer = YES;
    header.layer.backgroundColor = C_SURFACE.CGColor;
    [root addSubview:header];

    NSTextField *logo = [self txt:@"🚀  Raketa"
                             font:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]
                            color:C_TEXT frame:NSMakeRect(PAD, 12, 180, 20)];
    [header addSubview:logo];

    NSTextField *ver = [self txt:@"v0.7.1"
                            font:[NSFont systemFontOfSize:10]
                           color:C_SUB frame:NSMakeRect(W-52, 14, 38, 16)];
    ver.alignment = NSTextAlignmentRight;
    [header addSubview:ver];

    [root addSubview:[self line:[self rx:0 top:44 w:W h:1]]];

    // ── Subscription ─────────────────────────────────────────────────────────
    [root addSubview:[self sectionLbl:@"ПОДПИСКА" top:54]];

    self.urlField = [self inputFrame:[self rx:PAD top:66 w:W-PAD*2 h:26]
                         placeholder:@"vless:// ссылка или URL подписки"];
    [root addSubview:self.urlField];

    NSButton *loadBtn = [self flatBtn:@"Загрузить серверы"
                                frame:[self rx:PAD top:100 w:W-PAD*2 h:26]
                               action:@selector(downloadConfig)
                              primary:YES];
    [root addSubview:loadBtn];

    [root addSubview:[self line:[self rx:0 top:134 w:W h:1]]];

    // ── Server ────────────────────────────────────────────────────────────────
    [root addSubview:[self sectionLbl:@"СЕРВЕР" top:143]];

    self.dropdown = [[NSPopUpButton alloc] initWithFrame:[self rx:PAD top:155 w:W-PAD*2 h:26] pullsDown:NO];
    [self.dropdown addItemWithTitle:@"— серверы не загружены —"];
    self.dropdown.enabled = NO;
    self.dropdown.font = [NSFont systemFontOfSize:12];
    self.dropdown.target = self; self.dropdown.action = @selector(serverChanged);
    [root addSubview:self.dropdown];

    // ── Status row ───────────────────────────────────────────────────────────
    self.statusDot = [[NSView alloc] initWithFrame:[self rx:PAD top:191 w:7 h:7]];
    self.statusDot.frame = NSMakeRect(PAD, H_BASE-191-7+1, 7, 7);
    self.statusDot.wantsLayer = YES;
    self.statusDot.layer.cornerRadius = 3.5;
    self.statusDot.layer.backgroundColor = C_SUB.CGColor;
    [root addSubview:self.statusDot];

    self.statusLabel = [self txt:@"Готов к работе"
                            font:[NSFont systemFontOfSize:11]
                           color:C_SUB
                           frame:NSMakeRect(PAD+13, H_BASE-191-7+1, W-PAD*2-13, 15)];
    [root addSubview:self.statusLabel];

    // ── Connect button ───────────────────────────────────────────────────────
    CGFloat btnX = (W-76)/2;
    self.connectBtn = [[NSButton alloc] initWithFrame:[self rx:btnX top:210 w:76 h:76]];
    self.connectBtn.title   = @"ВЫКЛ";
    self.connectBtn.font    = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.connectBtn.bordered = NO;
    self.connectBtn.wantsLayer = YES;
    self.connectBtn.layer.cornerRadius = 38;
    self.connectBtn.layer.borderWidth  = 1.5;
    self.connectBtn.layer.borderColor  = C_BORDER.CGColor;
    self.connectBtn.layer.backgroundColor = C_BTN.CGColor;
    self.connectBtn.contentTintColor = C_SUB;
    self.connectBtn.target = self; self.connectBtn.action = @selector(toggle);
    [root addSubview:self.connectBtn];

    [root addSubview:[self line:[self rx:0 top:298 w:W h:1]]];

    // ── Telegram toggle button ────────────────────────────────────────────────
    self.tgBtn = [self flatBtn:@"📱  Настройка Telegram  ▾"
                         frame:[self rx:PAD top:307 w:W-PAD*2 h:26]
                        action:@selector(toggleTG) primary:NO];
    self.tgBtn.font = [NSFont systemFontOfSize:11];
    [root addSubview:self.tgBtn];

    // ── Bottom bar ────────────────────────────────────────────────────────────
    NSView *bottomBar = [[NSView alloc] initWithFrame:[self rx:0 top:340 w:W h:24]];
    bottomBar.wantsLayer = YES;
    bottomBar.layer.backgroundColor = C_SURFACE.CGColor;
    [root addSubview:bottomBar];

    NSButton *logBtn = [self flatBtn:@"Логи"
                               frame:NSMakeRect(PAD, 2, 52, 20)
                              action:@selector(openLogs) primary:NO];
    logBtn.font = [NSFont systemFontOfSize:10];
    [bottomBar addSubview:logBtn];

    NSButton *quitBtn = [self flatBtn:@"Выход"
                                frame:NSMakeRect(W-PAD-56, 2, 56, 20)
                               action:@selector(quit) primary:NO];
    quitBtn.font = [NSFont systemFontOfSize:10];
    [bottomBar addSubview:quitBtn];

    // ── Credit ────────────────────────────────────────────────────────────────
    NSTextField *credit = [self txt:@"Ради вас старался Пашенька"
                               font:[NSFont systemFontOfSize:9]
                              color:[NSColor colorWithWhite:0.25 alpha:1.0]
                              frame:[self rx:0 top:356 w:W h:14]];
    credit.alignment = NSTextAlignmentCenter;
    [root addSubview:credit];

    // ── TG Panel (hidden below) ───────────────────────────────────────────────
    [self buildTGPanel:root];

    self.view = root; self.connected = NO; self.tgOpen = NO;

    // ── Paths ─────────────────────────────────────────────────────────────────
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *sup = [[[fm URLsForDirectory:NSApplicationSupportDirectory
                              inDomains:NSUserDomainMask] firstObject]
                  URLByAppendingPathComponent:@"Raketa"];
    [fm createDirectoryAtURL:sup withIntermediateDirectories:YES attributes:nil error:nil];
    self.configPath = [[sup URLByAppendingPathComponent:@"config.json"] path];
    self.logPath    = [[sup URLByAppendingPathComponent:@"raketa.log"] path];

    if ([self isProxyOn]) [self forceProxyOff];

    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kSubKey];
    if (saved.length) {
        self.urlField.stringValue = saved;
        NSString *sub = [[self.configPath stringByDeletingLastPathComponent]
                          stringByAppendingPathComponent:@"subscription.json"];
        if ([fm fileExistsAtPath:sub]) {
            NSData *d = [NSData dataWithContentsOfFile:sub];
            NSMutableDictionary *j = [NSJSONSerialization JSONObjectWithData:d
                options:NSJSONReadingMutableContainers error:nil];
            if (j) [self parsedJSON:j];
        }
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onTerminate:) name:NSApplicationWillTerminateNotification object:nil];
}

// =============================================================================
#pragma mark - TG Panel
// =============================================================================
- (void)buildTGPanel:(NSView *)root {
    self.tgPanel = [[NSView alloc] initWithFrame:NSMakeRect(0, -H_TG, W, H_TG)];
    self.tgPanel.wantsLayer = YES;
    self.tgPanel.layer.backgroundColor = C_CARD.CGColor;

    // Top border
    NSView *topLine = [[NSView alloc] initWithFrame:NSMakeRect(0, H_TG-1, W, 1)];
    topLine.wantsLayer = YES;
    topLine.layer.backgroundColor = C_BORDER.CGColor;
    [self.tgPanel addSubview:topLine];

    // Header
    NSTextField *hdr = [self txt:@"TELEGRAM — ЧЕРЕЗ VPN"
                            font:[NSFont systemFontOfSize:9 weight:NSFontWeightSemibold]
                           color:C_ACCENT
                           frame:NSMakeRect(PAD, H_TG-22, W-PAD*2, 14)];
    [self.tgPanel addSubview:hdr];

    // Method 1
    NSTextField *m1 = [self txt:@"Способ 1 — MTProxy (рекомендовано)"
                           font:[NSFont systemFontOfSize:10 weight:NSFontWeightMedium]
                          color:C_TEXT frame:NSMakeRect(PAD, H_TG-38, W-PAD*2, 14)];
    [self.tgPanel addSubview:m1];

    // Monospace details — selectable for manual copy
    NSString *mt1 = [NSString stringWithFormat:@"127.0.0.1  :  %ld  |  %@",
                     (long)kTGPort, kTGSecret];
    NSTextField *mono1 = [[NSTextField alloc] initWithFrame:NSMakeRect(PAD, H_TG-56, W-PAD*2, 14)];
    mono1.stringValue = mt1;
    mono1.font = [NSFont fontWithName:@"Menlo" size:9] ?: [NSFont systemFontOfSize:9];
    mono1.textColor = C_ACCENT; mono1.bezeled = NO; mono1.drawsBackground = NO;
    mono1.editable = NO; mono1.selectable = YES;
    [self.tgPanel addSubview:mono1];

    NSButton *deepMT = [self flatBtn:@"⚡  Открыть в Telegram"
                               frame:NSMakeRect(PAD, H_TG-80, 148, 22)
                              action:@selector(openMTLink) primary:YES];
    deepMT.font = [NSFont systemFontOfSize:10];
    [self.tgPanel addSubview:deepMT];

    NSButton *copyBtn = [self flatBtn:@"Копировать секрет"
                                frame:NSMakeRect(PAD+154, H_TG-80, W-PAD*2-154, 22)
                               action:@selector(copySecret) primary:NO];
    copyBtn.font = [NSFont systemFontOfSize:10];
    [self.tgPanel addSubview:copyBtn];

    // Divider
    NSView *div = [[NSView alloc] initWithFrame:NSMakeRect(PAD, H_TG-90, W-PAD*2, 1)];
    div.wantsLayer = YES; div.layer.backgroundColor = C_BORDER.CGColor;
    [self.tgPanel addSubview:div];

    // Method 2
    NSTextField *m2 = [self txt:@"Способ 2 — SOCKS5 (запасной)"
                           font:[NSFont systemFontOfSize:10 weight:NSFontWeightMedium]
                          color:C_TEXT frame:NSMakeRect(PAD, H_TG-106, W-PAD*2, 14)];
    [self.tgPanel addSubview:m2];

    NSString *mt2 = [NSString stringWithFormat:@"127.0.0.1  :  %ld  |  SOCKS5", (long)kSOCKSPort];
    NSTextField *mono2 = [[NSTextField alloc] initWithFrame:NSMakeRect(PAD, H_TG-122, W-PAD*2, 14)];
    mono2.stringValue = mt2;
    mono2.font = [NSFont fontWithName:@"Menlo" size:9] ?: [NSFont systemFontOfSize:9];
    mono2.textColor = C_ACCENT; mono2.bezeled = NO; mono2.drawsBackground = NO;
    mono2.editable = NO; mono2.selectable = YES;
    [self.tgPanel addSubview:mono2];

    NSButton *deepSOCKS = [self flatBtn:@"Открыть SOCKS5 в Telegram"
                                  frame:NSMakeRect(PAD, H_TG-146, W-PAD*2, 22)
                                 action:@selector(openSOCKSLink) primary:NO];
    deepSOCKS.font = [NSFont systemFontOfSize:10];
    [self.tgPanel addSubview:deepSOCKS];

    [root addSubview:self.tgPanel];
}

- (void)toggleTG {
    self.tgOpen = !self.tgOpen;
    CGFloat sign = self.tgOpen ? 1 : -1;
    CGFloat newH = self.view.frame.size.height + sign * H_TG;
    self.view.frame = NSMakeRect(0, 0, W, newH);

    if (self.tgOpen) {
        self.tgPanel.frame = NSMakeRect(0, 0, W, H_TG);
        for (NSView *v in self.view.subviews)
            if (v != self.tgPanel)
                v.frame = NSMakeRect(v.frame.origin.x, v.frame.origin.y + H_TG,
                                     v.frame.size.width, v.frame.size.height);
        self.tgBtn.title = @"📱  Настройка Telegram  ▴";
    } else {
        for (NSView *v in self.view.subviews)
            if (v != self.tgPanel)
                v.frame = NSMakeRect(v.frame.origin.x, v.frame.origin.y - H_TG,
                                     v.frame.size.width, v.frame.size.height);
        self.tgPanel.frame = NSMakeRect(0, -H_TG, W, H_TG);
        self.tgBtn.title = @"📱  Настройка Telegram  ▾";
    }
}

- (void)openMTLink {
    NSString *u = [NSString stringWithFormat:@"tg://proxy?server=127.0.0.1&port=%ld&secret=%@",
                   (long)kTGPort, kTGSecret];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:u]];
}
- (void)openSOCKSLink {
    NSString *u = [NSString stringWithFormat:@"tg://socks?server=127.0.0.1&port=%ld", (long)kSOCKSPort];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:u]];
}
- (void)copySecret {
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:kTGSecret forType:NSPasteboardTypeString];
    for (NSView *v in self.tgPanel.subviews) {
        if ([v isKindOfClass:[NSButton class]]) {
            NSButton *b = (NSButton *)v;
            if ([b.title containsString:@"Копировать"]) {
                b.title = @"✓ Скопировано";
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5*NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{ b.title = @"Копировать секрет"; });
                break;
            }
        }
    }
}

// =============================================================================
#pragma mark - VPN Core
// =============================================================================
- (void)toggle { self.connected ? [self stopVPN] : [self startVPN]; }

- (void)startVPN {
    if (!self.proxyTags.count) { [self status:@"Сначала загрузите серверы" c:C_ORANGE]; return; }
    NSString *tag = self.dropdown.titleOfSelectedItem ?: @"";
    NSDictionary *outbound = nil;
    for (NSDictionary *o in self.proxyOutbounds)
        if ([o[@"tag"] isEqualToString:tag]) { outbound = o; break; }
    if (!outbound) return;

    [self status:@"Запуск..." c:C_SUB];

    NSDictionary *cfg = @{
        @"log": @{@"level": @"warn"},
        @"inbounds": @[
            @{@"type":@"socks",@"tag":@"socks",@"listen":@"127.0.0.1",@"listen_port":@(kSOCKSPort)},
            @{@"type":@"http", @"tag":@"http", @"listen":@"127.0.0.1",@"listen_port":@(kHTTPPort)},
            @{@"type":@"socks",@"tag":@"tg",   @"listen":@"127.0.0.1",@"listen_port":@(kTGPort)}
        ],
        @"outbounds": @[outbound, @{@"type":@"direct",@"tag":@"direct"}],
        @"route": @{
            @"rules": @[
                @{@"ip_cidr":    @[@"127.0.0.0/8",@"192.168.0.0/16",@"10.0.0.0/8",@"172.16.0.0/12"],
                  @"outbound":@"direct"},
                @{@"domain_suffix":@[@"apple.com",@"icloud.com"], @"outbound":@"direct"},
                @{@"domain_suffix":@[@".ru",@".рф"],              @"outbound":@"direct"}
            ],
            @"final": tag
        }
    };

    NSData *d = [NSJSONSerialization dataWithJSONObject:cfg options:0 error:nil];
    if (!d) { [self status:@"Ошибка конфига" c:C_RED]; return; }
    [d writeToFile:self.configPath atomically:YES];

    NSString *bin = [[NSBundle mainBundle] pathForResource:@"sing-box" ofType:nil];
    NSString *if_ = [self iface];
    NSString *sh  = [NSString stringWithFormat:
        @"killall -9 sing-box 2>/dev/null||true;sleep 0.3;"
        @"networksetup -setwebproxy '%@' 127.0.0.1 %ld;"
        @"networksetup -setsecurewebproxy '%@' 127.0.0.1 %ld;"
        @"networksetup -setsocksfirewallproxy '%@' 127.0.0.1 %ld;"
        @"nohup '%@' run -c '%@' > '%@' 2>&1 &",
        [self esc:if_],(long)kHTTPPort,[self esc:if_],(long)kHTTPPort,
        [self esc:if_],(long)kSOCKSPort,[self esc:bin],[self esc:self.configPath],[self esc:self.logPath]];

    NSString *scpt = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges "
        @"with prompt \"Raketa: запуск VPN\"",
        [sh stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];

    NSDictionary *err = nil;
    [[[NSAppleScript alloc] initWithSource:scpt] executeAndReturnError:&err];
    if (err) { [self status:@"Отменено" c:C_SUB]; [self forceProxyOff]; return; }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self coreAlive]) {
            [self uiConnected:YES];
            [self startWatchdog];
        } else {
            [self status:@"⚠  Ядро не запустилось — Логи" c:C_RED];
            [self forceProxyOff];
        }
    });
}

- (BOOL)stopVPN {
    [self.watchdog invalidate]; self.watchdog = nil;
    NSString *if_ = [self iface];
    NSString *sh  = [NSString stringWithFormat:
        @"killall -9 sing-box 2>/dev/null||true;"
        @"networksetup -setwebproxystate '%@' off;"
        @"networksetup -setsecurewebproxystate '%@' off;"
        @"networksetup -setsocksfirewallproxystate '%@' off",
        [self esc:if_],[self esc:if_],[self esc:if_]];
    NSString *scpt = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges "
        @"with prompt \"Raketa: отключение\"",
        [sh stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
    NSDictionary *err = nil;
    [[[NSAppleScript alloc] initWithSource:scpt] executeAndReturnError:&err];
    if (err) { [self status:@"Ошибка сброса" c:C_RED]; return NO; }
    [self uiConnected:NO]; return YES;
}

- (void)forceProxyOff {
    NSString *if_ = [self iface];
    NSString *sh  = [NSString stringWithFormat:
        @"networksetup -setwebproxystate '%@' off;"
        @"networksetup -setsecurewebproxystate '%@' off;"
        @"networksetup -setsocksfirewallproxystate '%@' off",
        [self esc:if_],[self esc:if_],[self esc:if_]];
    NSString *scpt = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges "
        @"with prompt \"Raketa: сброс прокси\"",
        [sh stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
    [[[NSAppleScript alloc] initWithSource:scpt] executeAndReturnError:nil];
}

// =============================================================================
#pragma mark - Watchdog
// =============================================================================
- (void)startWatchdog {
    [self.watchdog invalidate];
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:8.0
        target:self selector:@selector(watchTick) userInfo:nil repeats:YES];
}
- (void)watchTick {
    if ([self coreAlive]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.watchdog invalidate]; self.watchdog = nil;
        self.connected = NO; [self uiConnected:NO];
        [self status:@"⚠  Ядро упало — нажми ВКЛ" c:C_ORANGE];
        if ([self isProxyOn]) [self forceProxyOff];
    });
}
- (BOOL)coreAlive {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/bin/sh"; t.arguments = @[@"-c",@"pgrep -x sing-box"];
    NSPipe *p = [NSPipe pipe]; t.standardOutput = p;
    [t launch]; [t waitUntilExit];
    NSString *o = [[NSString alloc] initWithData:[[p fileHandleForReading] readDataToEndOfFile]
                                        encoding:NSUTF8StringEncoding];
    return o.length > 0;
}

// =============================================================================
#pragma mark - Network utils
// =============================================================================
- (BOOL)isProxyOn {
    NSDictionary *p = (__bridge_transfer NSDictionary *)SCDynamicStoreCopyProxies(NULL);
    return [p[@"HTTPEnable"] boolValue]||[p[@"HTTPSEnable"] boolValue]||[p[@"SOCKSEnable"] boolValue];
}
- (NSString *)iface {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/sbin/networksetup"; t.arguments = @[@"-listnetworkserviceorder"];
    NSPipe *p = [NSPipe pipe]; t.standardOutput = p;
    [t launch]; [t waitUntilExit];
    NSString *o = [[NSString alloc] initWithData:[[p fileHandleForReading] readDataToEndOfFile]
                                        encoding:NSUTF8StringEncoding];
    for (NSString *n in @[@"Wi-Fi",@"Ethernet",@"USB 10/100 LAN",
                           @"Thunderbolt Ethernet",@"iPhone USB",@"Bluetooth PAN"])
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
    [self status:@"Загрузка..." c:C_SUB];
    NSURL *url = [NSURL URLWithString:u];
    if (!url) { [self status:@"Неверный URL" c:C_RED]; return; }
    [[[NSURLSession sharedSession] dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (e||!data) { [self status:@"Ошибка сети" c:C_RED]; return; }
            NSString *sub = [[self.configPath stringByDeletingLastPathComponent]
                              stringByAppendingPathComponent:@"subscription.json"];
            [data writeToFile:sub atomically:YES];
            NSMutableDictionary *j = [NSJSONSerialization JSONObjectWithData:data
                options:NSJSONReadingMutableContainers error:nil];
            if (j[@"outbounds"]) [self parsedJSON:j];
            else { NSString *t = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                   t ? [self rawText:t] : [self status:@"Неверный формат" c:C_RED]; }
        });
    }] resume];
}

- (void)rawText:(NSString *)txt {
    NSString *s = [txt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSData *dec = [[NSData alloc] initWithBase64EncodedString:s
                   options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (dec) { NSString *ds = [[NSString alloc] initWithData:dec encoding:NSUTF8StringEncoding];
               if (ds) s = ds; }
    NSMutableArray *arr = [NSMutableArray array];
    for (NSString *line in [s componentsSeparatedByCharactersInSet:
                             [NSCharacterSet newlineCharacterSet]])
        if ([line hasPrefix:@"vless://"]) { NSDictionary *o = [self parseVless:line]; if(o)[arr addObject:o]; }
    if (!arr.count) { [self status:@"Серверы не найдены" c:C_ORANGE]; return; }
    [self parsedJSON:[@{@"outbounds":arr} mutableCopy]];
}

- (void)parsedJSON:(NSMutableDictionary *)j {
    self.proxyTags=[NSMutableArray array]; self.proxyOutbounds=[NSMutableArray array];
    NSArray *srv=@[@"vless",@"vmess",@"trojan",@"shadowsocks",@"hysteria2",@"tuic",@"trojan-go"];
    NSArray *grp=@[@"selector",@"urltest",@"dns",@"direct",@"block",@"dns-out"];
    for (NSDictionary *o in j[@"outbounds"]) {
        NSString *type=o[@"type"],*tag=o[@"tag"];
        if (!tag||!type) continue;
        if ([srv containsObject:type]&&![grp containsObject:type]) {
            [self.proxyTags addObject:tag]; [self.proxyOutbounds addObject:o]; }
    }
    [self.dropdown removeAllItems];
    if (self.proxyTags.count) {
        [self.dropdown addItemsWithTitles:self.proxyTags]; [self.dropdown setEnabled:YES];
        [self status:[NSString stringWithFormat:@"Загружено серверов: %lu",
                      (unsigned long)self.proxyTags.count] c:C_GREEN];
    } else [self status:@"Серверы не найдены" c:C_ORANGE];
}

- (NSDictionary *)parseVless:(NSString *)link {
    NSURLComponents *c = [NSURLComponents componentsWithString:
        [link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    if (!c||![c.scheme isEqualToString:@"vless"]) return nil;
    NSString *tag=(c.fragment.length)?[c.fragment stringByRemovingPercentEncoding]:c.host;
    NSMutableDictionary *out=[@{@"type":@"vless",@"tag":tag?:@"server",
        @"server":c.host?:@"",@"server_port":c.port?:@443,
        @"uuid":c.user?:@"",@"packet_encoding":@"xudp"} mutableCopy];
    NSMutableDictionary *tls=[NSMutableDictionary dictionary],*tr=[NSMutableDictionary dictionary];
    for (NSURLQueryItem *q in c.queryItems) {
        if ([q.name isEqualToString:@"security"]&&[@[@"tls",@"reality"] containsObject:q.value]) {
            tls[@"enabled"]=@YES;
            if ([q.value isEqualToString:@"reality"]) {
                tls[@"reality"]=tls[@"reality"]?:[NSMutableDictionary dictionary];
                tls[@"reality"][@"enabled"]=@YES; }
        }
        if ([q.name isEqualToString:@"sni"])  tls[@"server_name"]=q.value;
        if ([q.name isEqualToString:@"fp"]&&q.value.length)
            tls[@"utls"]=@{@"enabled":@YES,@"fingerprint":q.value};
        if ([q.name isEqualToString:@"pbk"]) {
            tls[@"reality"]=tls[@"reality"]?:[NSMutableDictionary dictionary];
            tls[@"reality"][@"public_key"]=q.value; }
        if ([q.name isEqualToString:@"sid"]) {
            tls[@"reality"]=tls[@"reality"]?:[NSMutableDictionary dictionary];
            tls[@"reality"][@"short_id"]=q.value; }
        if ([q.name isEqualToString:@"flow"]&&q.value.length) out[@"flow"]=q.value;
        if ([q.name isEqualToString:@"type"]&&q.value.length&&![q.value isEqualToString:@"tcp"])
            tr[@"type"]=q.value;
        if ([q.name isEqualToString:@"path"]&&q.value.length) tr[@"path"]=q.value;
        if ([q.name isEqualToString:@"serviceName"]&&q.value.length) tr[@"service_name"]=q.value;
        if ([q.name isEqualToString:@"host"]&&q.value.length) tr[@"headers"]=@{@"Host":q.value};
    }
    if (tls[@"enabled"]&&!tls[@"utls"]) tls[@"utls"]=@{@"enabled":@YES,@"fingerprint":@"chrome"};
    if (tls.count) out[@"tls"]=tls; if (tr.count) out[@"transport"]=tr;
    return out;
}

// =============================================================================
#pragma mark - UI State
// =============================================================================
- (void)serverChanged {
    if (!self.connected) return;
    [self stopVPN];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.5*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self startVPN]; });
}

- (void)uiConnected:(BOOL)on {
    self.connected = on;
    NSString *lbl = on ? [NSString stringWithFormat:@"Подключено · %@",
                          self.dropdown.titleOfSelectedItem?:@""] : @"Готов к работе";
    NSColor  *col = on ? C_GREEN : C_SUB;
    [self status:lbl c:col];
    self.connectBtn.title = on ? @"ВКЛ" : @"ВЫКЛ";
    self.connectBtn.layer.borderColor     = on ? C_GREEN.CGColor : C_BORDER.CGColor;
    self.connectBtn.layer.backgroundColor = on
        ? [NSColor colorWithRed:.10 green:.45 blue:.22 alpha:.25].CGColor
        : C_BTN.CGColor;
    self.connectBtn.contentTintColor = on ? C_GREEN : C_SUB;
}

- (void)status:(NSString *)t c:(NSColor *)c {
    self.statusLabel.stringValue = t; self.statusLabel.textColor = c;
    self.statusDot.layer.backgroundColor = c.CGColor;
}

- (void)openLogs {
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.logPath])
        [[NSWorkspace sharedWorkspace] openFile:self.logPath withApplication:@"Console"];
    else [self status:@"Логов нет" c:C_SUB];
}
- (void)quit   { if (self.connected) [self stopVPN]; [NSApp terminate:nil]; }
- (void)onTerminate:(NSNotification *)n { [self.watchdog invalidate]; if (self.connected) [self stopVPN]; }

// =============================================================================
#pragma mark - UI Factory
// =============================================================================
- (NSTextField *)txt:(NSString *)s font:(NSFont *)f color:(NSColor *)c frame:(NSRect)r {
    NSTextField *v = [[NSTextField alloc] initWithFrame:r];
    v.stringValue=s; v.font=f; v.textColor=c;
    v.bezeled=NO; v.drawsBackground=NO; v.editable=NO; v.selectable=NO;
    return v;
}
- (NSTextField *)sectionLbl:(NSString *)s top:(CGFloat)t {
    return [self txt:s font:[NSFont systemFontOfSize:9 weight:NSFontWeightMedium]
               color:C_SUB frame:[self rx:PAD top:t w:200 h:11]];
}
- (NSView *)line:(NSRect)r {
    NSView *v=[[NSView alloc] initWithFrame:r]; v.wantsLayer=YES;
    v.layer.backgroundColor=C_BORDER.CGColor; return v;
}
- (NSTextField *)inputFrame:(NSRect)r placeholder:(NSString *)ph {
    NSTextField *f=[[NSTextField alloc] initWithFrame:r];
    f.placeholderString=ph; f.font=[NSFont systemFontOfSize:11];
    f.textColor=C_TEXT; f.backgroundColor=C_SURFACE;
    f.wantsLayer=YES; f.layer.cornerRadius=6;
    f.layer.borderWidth=1; f.layer.borderColor=C_BORDER.CGColor;
    f.focusRingType=NSFocusRingTypeNone; return f;
}
- (NSButton *)flatBtn:(NSString *)t frame:(NSRect)r action:(SEL)a primary:(BOOL)p {
    NSButton *b=[[NSButton alloc] initWithFrame:r];
    b.title=t; b.font=[NSFont systemFontOfSize:12];
    b.bezelStyle=NSBezelStyleRounded; b.bordered=YES;
    b.target=self; b.action=a;
    if (!p) b.contentTintColor=C_SUB;
    return b;
}
@end
EOF
echo -e "${G}✓ ViewController.m${N}"

# =============================================================================
# Info.plist
# =============================================================================
echo -e "${Y}→ Info.plist...${N}"
cat > Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>         <string>Raketa</string>
    <key>CFBundleIdentifier</key>         <string>com.samurai.raketa</string>
    <key>CFBundleName</key>               <string>Raketa</string>
    <key>CFBundleDisplayName</key>        <string>Raketa</string>
    <key>CFBundleVersion</key>            <string>0.7.1</string>
    <key>CFBundleShortVersionString</key> <string>0.7.1</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>LSMinimumSystemVersion</key>     <string>10.13.0</string>
    <key>LSUIElement</key>                <true/>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>NSHumanReadableCopyright</key>   <string>Raketa — Ради вас старался Пашенька</string>
</dict>
</plist>
EOF
echo -e "${G}✓ Info.plist${N}"

# =============================================================================
# Переименование папки .app в build.yml
# =============================================================================
echo -e "${Y}→ build.yml...${N}"
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
        cp sing-box Raketa.app/Contents/Resources/sing-box
        chmod +x Raketa.app/Contents/Resources/sing-box

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
        name: "Raketa ${{ github.ref_name }}"
        body: |
          ## 🚀 Raketa ${{ github.ref_name }}

          ### Что нового
          - Переименован в **Raketa** (статус-бар: 🚀 Raketa)
          - Чистый непрозрачный тёмный интерфейс, без прозрачности
          - Аккуратные секции: Подписка / Сервер / Статус / Кнопка
          - Панель Telegram: MTProxy (10810) + SOCKS5 (10808), deep link одним кликом
          - Данные подключения можно выделить и скопировать
          - Подпись в нижней части: «Ради вас старался Пашенька»
          - Watchdog, shell escape, фильтрация selector/urltest

          ### Telegram
          Нажми «📱 Настройка Telegram» → «⚡ Открыть в Telegram»
        files: Raketa-macOS-10.13-*.zip
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
EOF
echo -e "${G}✓ build.yml (Raketa.app)${N}"

# =============================================================================
echo ""
echo -e "${C}╔═══════════════════════════════════════════════════╗"
echo -e "║  Патч применён. Далее:                            ║"
echo -e "╠═══════════════════════════════════════════════════╣"
echo -e "║  git add -A                                       ║"
echo -e "║  git commit -m 'v0.7.1: rename Raketa, clean UI' ║"
echo -e "║  git tag v0.7.1                                   ║"
echo -e "║  git push origin main --tags                      ║"
echo -e "╠═══════════════════════════════════════════════════╣"
echo -e "║  Статус-бар:  🚀 Raketa                           ║"
echo -e "║  Логи:        ~/Library/AppSupport/Raketa/        ║"
echo -e "╚═══════════════════════════════════════════════════╝${N}"
