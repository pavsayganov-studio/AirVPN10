#!/bin/bash
# =============================================================================
# Raketa v0.8.3 — Fix log error, server persistence, layout compact
# Run from repo root: bash patch_raketa_083.sh
# =============================================================================
set -e
G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; R='\033[0;31m'; N='\033[0m'

echo -e "${C}╔══════════════════════════════════════════╗"
echo -e "║   Raketa v0.8.3 — Bug Fixes + Layout     ║"
echo -e "╚══════════════════════════════════════════╝${N}\n"

[ ! -f "ViewController.m" ] && echo -e "${R}✗ Run from repo root${N}" && exit 1

cp ViewController.m ViewController.m.bak083
cp Info.plist Info.plist.bak083
echo -e "${G}✓ Backups created${N}\n"

echo -e "${Y}→ ViewController.m${N}"
cat > ViewController.m << 'EOF'
#import "ViewController.h"
#import <SystemConfiguration/SystemConfiguration.h>

// ── Ports ─────────────────────────────────────────────────────────────────────
static const NSInteger kSOCKSPort = 10808;
static const NSInteger kMixedPort = 10809;   // "mixed" type: HTTP+SOCKS on one port
static const NSInteger kTGPort    = 10810;
static NSString *const kTGSecret  = @"dd000000000000000000000000000000";
static NSString *const kSubKey    = @"RaketaSubscriptionURL";
static NSString *const kSubFile   = @"subscription.json";

// ── Layout ────────────────────────────────────────────────────────────────────
static const CGFloat kW   = 290.0;
static const CGFloat kH   = 296.0;   // compact — was 370
static const CGFloat kHTG = 168.0;
static const CGFloat kPAD = 14.0;

// ── Colors ────────────────────────────────────────────────────────────────────
static NSColor *rkBG, *rkSurface, *rkCard, *rkBorder,
               *rkText, *rkSub, *rkAccent, *rkGreen, *rkOrange, *rkRed, *rkBtn;
static dispatch_queue_t sTaskQ;

@interface ViewController ()
@property (strong) NSButton       *pasteBtn;
@property (strong) NSTextField    *statusLabel;
@property (strong) NSView         *statusDot;
@property (strong) NSButton       *connectBtn;
@property (strong) NSPopUpButton  *dropdown;
@property (strong) NSButton       *secretCopyBtn;
@property (strong) NSString       *configPath;
@property (strong) NSString       *logPath;
@property (strong) NSString       *subPath;       // path to subscription.json
@property (strong) NSString       *cachedIface;
@property (strong) NSMutableArray *proxyTags;
@property (strong) NSMutableArray *proxyOutbounds;
@property (assign) BOOL            connected;
@property (assign) BOOL            stopping;
@property (assign) pid_t           corePID;
@property (strong) NSTimer        *watchdog;
@property (strong) NSView         *tgPanel;
@property (strong) NSButton       *tgToggleBtn;
@property (assign) BOOL            tgOpen;
@end

@implementation ViewController

+ (void)initialize {
    if (self != [ViewController class]) return;
    rkBG      = [NSColor colorWithRed:0.88 green:0.93 blue:0.98 alpha:1.0];
    rkSurface = [NSColor colorWithRed:0.80 green:0.89 blue:0.96 alpha:1.0];
    rkCard    = [NSColor colorWithRed:0.83 green:0.91 blue:0.97 alpha:1.0];
    rkBorder  = [NSColor colorWithRed:0.62 green:0.78 blue:0.92 alpha:1.0];
    rkText    = [NSColor colorWithWhite:0.10 alpha:1.0];
    rkSub     = [NSColor colorWithWhite:0.40 alpha:1.0];
    rkAccent  = [NSColor colorWithRed:0.10 green:0.40 blue:0.78 alpha:1.0];
    rkGreen   = [NSColor colorWithRed:0.08 green:0.55 blue:0.22 alpha:1.0];
    rkOrange  = [NSColor colorWithRed:0.75 green:0.38 blue:0.04 alpha:1.0];
    rkRed     = [NSColor colorWithRed:0.72 green:0.08 blue:0.08 alpha:1.0];
    rkBtn     = [NSColor colorWithRed:0.72 green:0.84 blue:0.94 alpha:1.0];
    sTaskQ    = dispatch_queue_create("com.samurai.raketa.tasks", DISPATCH_QUEUE_SERIAL);
}

- (NSRect)rx:(CGFloat)x top:(CGFloat)t w:(CGFloat)w h:(CGFloat)h {
    return NSMakeRect(x, kH - t - h, w, h);
}

// =============================================================================
#pragma mark - loadView  (compact layout, no circle button)
// =============================================================================
- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kH)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = rkBG.CGColor;

    // ── Header (0–44) ─────────────────────────────────────────────────────────
    NSView *hdr = [[NSView alloc] initWithFrame:NSMakeRect(0, kH-44, kW, 44)];
    hdr.wantsLayer = YES;
    hdr.layer.backgroundColor = rkSurface.CGColor;
    [root addSubview:hdr];
    [hdr addSubview:[self lbl:@"🚀  Raketa"
                          font:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]
                         color:rkText frame:NSMakeRect(kPAD, 12, 180, 20)]];
    NSTextField *ver = [self lbl:@"v0.8.3" font:[NSFont systemFontOfSize:10]
                           color:rkSub frame:NSMakeRect(kW-48, 14, 36, 16)];
    ver.alignment = NSTextAlignmentRight;
    [hdr addSubview:ver];
    [root addSubview:[self sep:NSMakeRect(0, kH-45, kW, 1)]];

    // ── ПОДПИСКА (52–99) ──────────────────────────────────────────────────────
    [root addSubview:[self sectionLbl:@"ПОДПИСКА" top:52]];
    self.pasteBtn = [self btn:@"⎘  Вставить ссылку из буфера"
                        frame:[self rx:kPAD top:63 w:kW-kPAD*2 h:28]
                       action:@selector(pasteAndLoad) primary:YES];
    self.pasteBtn.font = [NSFont systemFontOfSize:12];
    [root addSubview:self.pasteBtn];
    [root addSubview:[self sep:NSMakeRect(0, kH-99, kW, 1)]];

    // ── СЕРВЕР (108–153) ──────────────────────────────────────────────────────
    [root addSubview:[self sectionLbl:@"СЕРВЕР" top:108]];
    self.dropdown = [[NSPopUpButton alloc]
                     initWithFrame:[self rx:kPAD top:119 w:kW-kPAD*2 h:26] pullsDown:NO];
    [self.dropdown addItemWithTitle:@"— серверы не загружены —"];
    self.dropdown.enabled = NO;
    self.dropdown.font    = [NSFont systemFontOfSize:12];
    self.dropdown.target  = self;
    self.dropdown.action  = @selector(serverChanged);
    [root addSubview:self.dropdown];

    // ── Status (153–170) ──────────────────────────────────────────────────────
    CGFloat dotY = kH - 153 - 8;
    self.statusDot = [[NSView alloc] initWithFrame:NSMakeRect(kPAD, dotY+1, 7, 7)];
    self.statusDot.wantsLayer = YES;
    self.statusDot.layer.cornerRadius    = 3.5;
    self.statusDot.layer.backgroundColor = rkSub.CGColor;
    [root addSubview:self.statusDot];
    self.statusLabel = [self lbl:@"Готов к работе"
                            font:[NSFont systemFontOfSize:11] color:rkSub
                           frame:NSMakeRect(kPAD+13, dotY, kW-kPAD*2-13, 14)];
    [root addSubview:self.statusLabel];

    // ── Connect button — full-width rounded rect (170–214) ────────────────────
    self.connectBtn = [[NSButton alloc]
                       initWithFrame:[self rx:kPAD top:170 w:kW-kPAD*2 h:36]];
    self.connectBtn.title    = @"";
    self.connectBtn.bordered = NO;
    self.connectBtn.wantsLayer = YES;
    self.connectBtn.layer.cornerRadius    = 10;
    self.connectBtn.layer.borderWidth     = 1.5;
    self.connectBtn.layer.borderColor     = rkBorder.CGColor;
    self.connectBtn.layer.backgroundColor = rkBtn.CGColor;
    self.connectBtn.target = self;
    self.connectBtn.action = @selector(toggle);
    [self setConnectTitle:@"ВЫКЛ" color:rkSub];
    [root addSubview:self.connectBtn];
    [root addSubview:[self sep:NSMakeRect(0, kH-214, kW, 1)]];

    // ── Telegram toggle (222–248) ─────────────────────────────────────────────
    self.tgToggleBtn = [self btn:@"📱  Настройка Telegram  ▾"
                           frame:[self rx:kPAD top:222 w:kW-kPAD*2 h:24]
                          action:@selector(toggleTG) primary:NO];
    self.tgToggleBtn.font = [NSFont systemFontOfSize:11];
    [root addSubview:self.tgToggleBtn];
    [root addSubview:[self sep:NSMakeRect(0, kH-253, kW, 1)]];

    // ── Bottom bar (253–296) ──────────────────────────────────────────────────
    NSView *bar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, 43)];
    bar.wantsLayer = YES;
    bar.layer.backgroundColor = rkSurface.CGColor;
    [root addSubview:bar];

    NSButton *logBtn = [self btn:@"Логи" frame:NSMakeRect(kPAD, 14, 48, 18)
                         action:@selector(openLogs) primary:NO];
    logBtn.font = [NSFont systemFontOfSize:10]; [bar addSubview:logBtn];

    NSButton *quitBtn = [self btn:@"Выход" frame:NSMakeRect(kW-kPAD-56, 14, 56, 18)
                          action:@selector(quit) primary:NO];
    quitBtn.font = [NSFont systemFontOfSize:10]; [bar addSubview:quitBtn];

    // Credit — tracked spacing, centred in bar
    NSTextField *credit = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 2, kW, 12)];
    credit.bezeled = NO; credit.drawsBackground = NO;
    credit.editable = NO; credit.selectable = NO;
    credit.alignment = NSTextAlignmentCenter;
    credit.attributedStringValue = [[NSAttributedString alloc]
        initWithString:@"Ради вас старался Пашенька" attributes:@{
            NSFontAttributeName:            [NSFont fontWithName:@"HelveticaNeue-Light" size:9]
                                            ?: [NSFont systemFontOfSize:9],
            NSForegroundColorAttributeName: rkSub,
            NSKernAttributeName:            @(0.8)
        }];
    [bar addSubview:credit];

    // ── TG Panel ──────────────────────────────────────────────────────────────
    [self buildTGPanel:root];

    self.view = root; self.connected = NO; self.stopping = NO;
    self.tgOpen = NO; self.corePID = 0;

    // ── Paths ─────────────────────────────────────────────────────────────────
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *sup = [[[fm URLsForDirectory:NSApplicationSupportDirectory
                              inDomains:NSUserDomainMask] firstObject]
                  URLByAppendingPathComponent:@"Raketa"];
    [fm createDirectoryAtURL:sup withIntermediateDirectories:YES attributes:nil error:nil];
    self.configPath = [[sup URLByAppendingPathComponent:@"config.json"] path];
    self.logPath    = [[sup URLByAppendingPathComponent:@"raketa.log"]  path];
    self.subPath    = [[sup URLByAppendingPathComponent:kSubFile] path];

    self.cachedIface = [self detectIface];
    if ([self isProxyOn]) [self forceProxyOff];

    // ── Load persisted servers off main thread ────────────────────────────────
    // FIX: was reading subscription.json only when savedURL existed.
    // Now we always try to load subscription.json first — it contains the
    // canonical parsed outbounds and is written by persistOutbounds: after
    // every successful parse, regardless of how the data arrived.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *d = [NSData dataWithContentsOfFile:self.subPath];
        if (!d) return;
        NSMutableDictionary *j = [NSJSONSerialization
            JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil];
        if (j) dispatch_async(dispatch_get_main_queue(), ^{ [self parsedJSON:j]; });
    });

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onTerminate:)
            name:NSApplicationWillTerminateNotification object:nil];
}

// =============================================================================
#pragma mark - Persistence
// =============================================================================

// Called after every successful parsedJSON: — writes outbounds to disk.
// This is the single source of truth for server persistence across restarts.
- (void)persistOutbounds:(NSArray *)outbounds {
    NSDictionary *payload = @{@"outbounds": outbounds};
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!data) return;
    NSString *path = self.subPath;
    dispatch_async(sTaskQ, ^{
        [data writeToFile:path atomically:YES];
    });
}

// =============================================================================
#pragma mark - Paste & Load
// =============================================================================
- (void)pasteAndLoad {
    NSString *text = [[[NSPasteboard generalPasteboard]
                        stringForType:NSPasteboardTypeString]
                       stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) {
        [self setStatus:@"Буфер обмена пуст" color:rkOrange]; return;
    }
    BOOL isVless = [text hasPrefix:@"vless://"];
    BOOL isURL   = [text hasPrefix:@"http://"] || [text hasPrefix:@"https://"];
    if (!isVless && !isURL) {
        [self setStatus:@"Нет ссылки в буфере" color:rkOrange]; return;
    }

    [[NSUserDefaults standardUserDefaults] setObject:text forKey:kSubKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    NSString *orig = self.pasteBtn.title;
    self.pasteBtn.title = @"✓  Ссылка получена";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ self.pasteBtn.title = orig; });

    if (isVless) [self rawText:text]; else [self downloadURL:text];
}

- (void)downloadURL:(NSString *)urlString {
    [self setStatus:@"Загрузка серверов..." color:rkSub];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { [self setStatus:@"Неверный URL" color:rkRed]; return; }
    [[[NSURLSession sharedSession] dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (e || !data) { [self setStatus:@"Ошибка сети" color:rkRed]; return; }
            NSMutableDictionary *j = [NSJSONSerialization
                JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
            if (j[@"outbounds"]) {
                [self parsedJSON:j];
            } else {
                NSString *t = [[NSString alloc] initWithData:data
                                                    encoding:NSUTF8StringEncoding];
                t ? [self rawText:t] : [self setStatus:@"Неверный формат" color:rkRed];
            }
        });
    }] resume];
}

// =============================================================================
#pragma mark - TG Panel
// =============================================================================
- (void)buildTGPanel:(NSView *)root {
    self.tgPanel = [[NSView alloc] initWithFrame:NSMakeRect(0, -kHTG, kW, kHTG)];
    self.tgPanel.wantsLayer = YES;
    self.tgPanel.layer.backgroundColor = rkCard.CGColor;

    NSView *topLine = [[NSView alloc] initWithFrame:NSMakeRect(0, kHTG-1, kW, 1)];
    topLine.wantsLayer = YES;
    topLine.layer.backgroundColor = rkBorder.CGColor;
    [self.tgPanel addSubview:topLine];

    [self.tgPanel addSubview:
     [self lbl:@"TELEGRAM — ПРОКСИ"
          font:[NSFont systemFontOfSize:9 weight:NSFontWeightSemibold]
         color:rkAccent frame:NSMakeRect(kPAD, kHTG-19, kW-kPAD*2, 13)]];

    // Method 1: MTProxy
    [self.tgPanel addSubview:
     [self lbl:@"Способ 1 — MTProxy"
          font:[NSFont systemFontOfSize:10 weight:NSFontWeightSemibold]
         color:rkText frame:NSMakeRect(kPAD, kHTG-34, 118, 13)]];
    [self.tgPanel addSubview:
     [self lbl:@"рекомендовано" font:[NSFont systemFontOfSize:8]
         color:rkAccent frame:NSMakeRect(kPAD+120, kHTG-33, 90, 12)]];

    [self.tgPanel addSubview:
     [self monoLbl:[NSString stringWithFormat:@"Сервер: 127.0.0.1   Порт: %ld",
                    (long)kTGPort]
              frame:NSMakeRect(kPAD, kHTG-49, kW-kPAD*2, 13)]];
    [self.tgPanel addSubview:
     [self monoLbl:[NSString stringWithFormat:@"Секрет: %@", kTGSecret]
              frame:NSMakeRect(kPAD, kHTG-63, kW-kPAD*2, 13)]];

    NSButton *openMT = [self btn:@"⚡  Добавить в Telegram"
                           frame:NSMakeRect(kPAD, kHTG-87, 148, 22)
                          action:@selector(openMTLink) primary:YES];
    openMT.font = [NSFont systemFontOfSize:10]; [self.tgPanel addSubview:openMT];

    self.secretCopyBtn = [self btn:@"Копировать секрет"
                             frame:NSMakeRect(kPAD+154, kHTG-87, kW-kPAD*2-154, 22)
                            action:@selector(copySecret) primary:NO];
    self.secretCopyBtn.font = [NSFont systemFontOfSize:10];
    [self.tgPanel addSubview:self.secretCopyBtn];

    [self.tgPanel addSubview:[self sep:NSMakeRect(kPAD, kHTG-97, kW-kPAD*2, 1)]];

    // Method 2: SOCKS5
    [self.tgPanel addSubview:
     [self lbl:@"Способ 2 — SOCKS5"
          font:[NSFont systemFontOfSize:10 weight:NSFontWeightSemibold]
         color:rkText frame:NSMakeRect(kPAD, kHTG-112, 118, 13)]];
    [self.tgPanel addSubview:
     [self lbl:@"запасной" font:[NSFont systemFontOfSize:8]
         color:rkSub frame:NSMakeRect(kPAD+120, kHTG-111, 70, 12)]];

    [self.tgPanel addSubview:
     [self monoLbl:[NSString stringWithFormat:
                    @"Сервер: 127.0.0.1   Порт: %ld   Тип: SOCKS5", (long)kSOCKSPort]
              frame:NSMakeRect(kPAD, kHTG-127, kW-kPAD*2, 13)]];

    NSButton *openSK = [self btn:@"⚡  Добавить SOCKS5 в Telegram"
                           frame:NSMakeRect(kPAD, kHTG-151, kW-kPAD*2, 22)
                          action:@selector(openSOCKSLink) primary:NO];
    openSK.font = [NSFont systemFontOfSize:10]; [self.tgPanel addSubview:openSK];

    [root addSubview:self.tgPanel];
}

- (void)toggleTG {
    self.tgOpen = !self.tgOpen;
    if (self.tgOpen) {
        self.tgPanel.frame = NSMakeRect(0, 0, kW, kHTG);
        for (NSView *v in self.view.subviews)
            if (v != self.tgPanel)
                v.frame = NSMakeRect(v.frame.origin.x, v.frame.origin.y + kHTG,
                                     v.frame.size.width, v.frame.size.height);
        self.tgToggleBtn.title = @"📱  Настройка Telegram  ▴";
    } else {
        for (NSView *v in self.view.subviews)
            if (v != self.tgPanel)
                v.frame = NSMakeRect(v.frame.origin.x, v.frame.origin.y - kHTG,
                                     v.frame.size.width, v.frame.size.height);
        self.tgPanel.frame = NSMakeRect(0, -kHTG, kW, kHTG);
        self.tgToggleBtn.title = @"📱  Настройка Telegram  ▾";
    }
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
    NSButton *b = self.secretCopyBtn;
    b.title = @"✓ Скопировано";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ b.title = @"Копировать секрет"; });
}

// =============================================================================
#pragma mark - VPN Core
// =============================================================================
- (void)toggle { self.connected ? [self stopVPN] : [self startVPN]; }

- (void)startVPN {
    if (!self.proxyTags.count) {
        [self setStatus:@"Сначала вставьте подписку" color:rkOrange]; return;
    }
    NSString *tag = self.dropdown.titleOfSelectedItem ?: @"";
    NSDictionary *outbound = nil;
    for (NSDictionary *o in self.proxyOutbounds)
        if ([o[@"tag"] isEqualToString:tag]) { outbound = o; break; }
    if (!outbound) return;

    [self setStatus:@"Запуск..." color:rkSub];

    NSDictionary *cfg = @{
        @"log": @{@"level": @"warn"},
        @"inbounds": @[
            // FIX: "mixed" handles both HTTP CONNECT and SOCKS5 on one port.
            // The previous "http" type caused "protocol wrong type for socket"
            // errors when apps sent non-HTTP traffic to the HTTP proxy port.
            @{@"type":@"mixed",@"tag":@"mixed",
              @"listen":@"127.0.0.1",@"listen_port":@(kMixedPort)},
            @{@"type":@"socks",@"tag":@"socks",
              @"listen":@"127.0.0.1",@"listen_port":@(kSOCKSPort)},
            @{@"type":@"socks",@"tag":@"tg",
              @"listen":@"127.0.0.1",@"listen_port":@(kTGPort)}
        ],
        @"outbounds": @[outbound, @{@"type":@"direct",@"tag":@"direct"}],
        @"route": @{
            @"rules": @[
                @{@"ip_cidr":@[@"127.0.0.0/8",@"192.168.0.0/16",
                               @"10.0.0.0/8",@"172.16.0.0/12"],
                  @"outbound":@"direct"},
                @{@"domain_suffix":@[@"apple.com",@"icloud.com"],
                  @"outbound":@"direct"},
                @{@"domain_suffix":@[@".ru",@".рф"],
                  @"outbound":@"direct"}
            ],
            @"final": tag
        }
    };

    NSData *cfgData = [NSJSONSerialization dataWithJSONObject:cfg options:0 error:nil];
    if (!cfgData) { [self setStatus:@"Ошибка конфига" color:rkRed]; return; }
    [cfgData writeToFile:self.configPath atomically:YES];

    NSString *bin   = [[NSBundle mainBundle] pathForResource:@"sing-box" ofType:nil];
    NSString *iface = self.cachedIface;

    NSString *sh = [NSString stringWithFormat:
        @"killall -9 sing-box 2>/dev/null||true;"
        @"sleep 0.3;"
        @"networksetup -setwebproxy '%@' 127.0.0.1 %ld;"
        @"networksetup -setsecurewebproxy '%@' 127.0.0.1 %ld;"
        @"networksetup -setsocksfirewallproxy '%@' 127.0.0.1 %ld;"
        @"nohup '%@' run -c '%@' > '%@' 2>&1 & echo $!",
        [self esc:iface],(long)kMixedPort,
        [self esc:iface],(long)kMixedPort,
        [self esc:iface],(long)kSOCKSPort,
        [self esc:bin],[self esc:self.configPath],[self esc:self.logPath]];

    NSString *scpt = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges "
        @"with prompt \"Raketa: запуск VPN\"",
        [sh stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];

    NSDictionary *err = nil;
    NSAppleEventDescriptor *res =
        [[[NSAppleScript alloc] initWithSource:scpt] executeAndReturnError:&err];
    if (err) { [self setStatus:@"Отменено" color:rkSub]; [self forceProxyOff]; return; }

    self.corePID = (pid_t)[[res stringValue] intValue];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self coreAlive]) { [self uiConnected:YES]; [self startWatchdog]; }
        else { [self setStatus:@"⚠  Ядро не запустилось — Логи" color:rkRed];
               [self forceProxyOff]; }
    });
}

- (BOOL)stopVPN {
    if (self.stopping) return YES;
    self.stopping = YES;
    [self.watchdog invalidate]; self.watchdog = nil; self.corePID = 0;
    NSString *iface = self.cachedIface;
    NSString *sh = [NSString stringWithFormat:
        @"killall -9 sing-box 2>/dev/null||true;"
        @"networksetup -setwebproxystate '%@' off;"
        @"networksetup -setsecurewebproxystate '%@' off;"
        @"networksetup -setsocksfirewallproxystate '%@' off",
        [self esc:iface],[self esc:iface],[self esc:iface]];
    NSString *scpt = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges "
        @"with prompt \"Raketa: отключение\"",
        [sh stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
    NSDictionary *err = nil;
    [[[NSAppleScript alloc] initWithSource:scpt] executeAndReturnError:&err];
    self.stopping = NO;
    if (err) { [self setStatus:@"Ошибка сброса" color:rkRed]; return NO; }
    [self uiConnected:NO]; return YES;
}

- (void)forceProxyOff {
    NSString *iface = self.cachedIface ?: [self detectIface];
    NSString *sh = [NSString stringWithFormat:
        @"networksetup -setwebproxystate '%@' off;"
        @"networksetup -setsecurewebproxystate '%@' off;"
        @"networksetup -setsocksfirewallproxystate '%@' off",
        [self esc:iface],[self esc:iface],[self esc:iface]];
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
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:12.0
        target:self selector:@selector(watchTick) userInfo:nil repeats:YES];
}
- (void)watchTick {
    dispatch_async(sTaskQ, ^{
        if ([self coreAlive]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.watchdog invalidate]; self.watchdog = nil;
            self.connected = NO; [self uiConnected:NO];
            [self setStatus:@"⚠  Ядро упало — нажми ВКЛ" color:rkOrange];
            if ([self isProxyOn]) [self forceProxyOff];
        });
    });
}
- (BOOL)coreAlive {
    if (self.corePID > 0) {
        if (kill(self.corePID, 0) == 0) return YES;
        self.corePID = 0;
    }
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/bin/sh"; t.arguments = @[@"-c", @"pgrep -x sing-box"];
    NSPipe *p = [NSPipe pipe]; t.standardOutput = p;
    [t launch]; [t waitUntilExit];
    NSString *o = [[NSString alloc]
                   initWithData:[[p fileHandleForReading] readDataToEndOfFile]
                       encoding:NSUTF8StringEncoding];
    if (o.length > 0) { self.corePID = (pid_t)[o intValue]; return YES; }
    return NO;
}

// =============================================================================
#pragma mark - Network utils
// =============================================================================
- (BOOL)isProxyOn {
    NSDictionary *px = (__bridge_transfer NSDictionary *)SCDynamicStoreCopyProxies(NULL);
    return [px[@"HTTPEnable"] boolValue]||[px[@"HTTPSEnable"] boolValue]||[px[@"SOCKSEnable"] boolValue];
}
- (NSString *)detectIface {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/sbin/networksetup";
    t.arguments  = @[@"-listnetworkserviceorder"];
    NSPipe *p = [NSPipe pipe]; t.standardOutput = p;
    [t launch]; [t waitUntilExit];
    NSString *o = [[NSString alloc]
                   initWithData:[[p fileHandleForReading] readDataToEndOfFile]
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
- (void)rawText:(NSString *)txt {
    NSString *s = [txt stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSData *dec = [[NSData alloc] initWithBase64EncodedString:s
                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (dec) { NSString *ds = [[NSString alloc] initWithData:dec
                                                     encoding:NSUTF8StringEncoding];
               if (ds) s = ds; }
    NSMutableArray *arr = [NSMutableArray array];
    for (NSString *line in [s componentsSeparatedByCharactersInSet:
                             [NSCharacterSet newlineCharacterSet]])
        if ([line hasPrefix:@"vless://"]) {
            NSDictionary *o = [self parseVless:line]; if (o) [arr addObject:o];
        }
    if (!arr.count) { [self setStatus:@"Серверы не найдены" color:rkOrange]; return; }
    [self parsedJSON:[@{@"outbounds": arr} mutableCopy]];
}

- (void)parsedJSON:(NSMutableDictionary *)j {
    self.proxyTags      = [NSMutableArray array];
    self.proxyOutbounds = [NSMutableArray array];
    NSArray *srv = @[@"vless",@"vmess",@"trojan",@"shadowsocks",
                     @"hysteria2",@"tuic",@"trojan-go"];
    NSArray *grp = @[@"selector",@"urltest",@"dns",@"direct",@"block",@"dns-out"];
    for (NSDictionary *o in j[@"outbounds"]) {
        NSString *type = o[@"type"], *tag = o[@"tag"];
        if (!type || !tag) continue;
        if ([srv containsObject:type] && ![grp containsObject:type]) {
            [self.proxyTags addObject:tag]; [self.proxyOutbounds addObject:o];
        }
    }
    [self.dropdown removeAllItems];
    if (self.proxyTags.count) {
        [self.dropdown addItemsWithTitles:self.proxyTags];
        [self.dropdown setEnabled:YES];
        [self setStatus:[NSString stringWithFormat:@"Серверов: %lu",
                         (unsigned long)self.proxyTags.count] color:rkGreen];
        // FIX: persist outbounds after every successful parse —
        // whether data came from rawText:, downloadURL:, or a remote subscription.
        // This guarantees subscription.json is always up-to-date and
        // loadView can restore servers on next launch without re-fetching.
        [self persistOutbounds:self.proxyOutbounds];
    } else {
        [self setStatus:@"Серверы не найдены" color:rkOrange];
    }
}

- (void)persistOutbounds:(NSArray *)outbounds {
    NSDictionary *payload = @{@"outbounds": outbounds};
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!data) return;
    NSString *path = self.subPath;
    dispatch_async(sTaskQ, ^{ [data writeToFile:path atomically:YES]; });
}

- (NSDictionary *)parseVless:(NSString *)link {
    NSURLComponents *c = [NSURLComponents componentsWithString:
        [link stringByTrimmingCharactersInSet:
         [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    if (!c || ![c.scheme isEqualToString:@"vless"]) return nil;
    NSString *tag = c.fragment.length
        ? [c.fragment stringByRemovingPercentEncoding] : c.host;
    NSMutableDictionary *out = [@{
        @"type":@"vless", @"tag":tag?:@"server",
        @"server":c.host?:@"", @"server_port":c.port?:@443,
        @"uuid":c.user?:@"", @"packet_encoding":@"xudp"
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
        if ([q.name isEqualToString:@"sni"]  && q.value.length) tls[@"server_name"] = q.value;
        if ([q.name isEqualToString:@"fp"]   && q.value.length)
            tls[@"utls"] = @{@"enabled":@YES, @"fingerprint":q.value};
        if ([q.name isEqualToString:@"pbk"]  && q.value.length) {
            if (!tls[@"reality"]) tls[@"reality"] = [NSMutableDictionary dictionary];
            tls[@"reality"][@"public_key"] = q.value;
        }
        if ([q.name isEqualToString:@"sid"]  && q.value.length) {
            if (!tls[@"reality"]) tls[@"reality"] = [NSMutableDictionary dictionary];
            tls[@"reality"][@"short_id"] = q.value;
        }
        if ([q.name isEqualToString:@"flow"] && q.value.length) out[@"flow"] = q.value;
        if ([q.name isEqualToString:@"type"] && q.value.length
            && ![q.value isEqualToString:@"tcp"]) tr[@"type"] = q.value;
        if ([q.name isEqualToString:@"path"] && q.value.length) tr[@"path"] = q.value;
        if ([q.name isEqualToString:@"serviceName"] && q.value.length)
            tr[@"service_name"] = q.value;
        if ([q.name isEqualToString:@"host"] && q.value.length)
            tr[@"headers"] = @{@"Host": q.value};
    }
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
    if ([self stopVPN])
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self startVPN]; });
}
- (void)uiConnected:(BOOL)on {
    self.connected = on;
    NSString *lbl = on ? [NSString stringWithFormat:@"Подключено · %@",
                           self.dropdown.titleOfSelectedItem ?: @""]
                       : @"Готов к работе";
    [self setStatus:lbl color:on ? rkGreen : rkSub];
    [self setConnectTitle:(on ? @"● ВКЛ" : @"○ ВЫКЛ") color:(on ? rkGreen : rkSub)];
    self.connectBtn.layer.borderColor =
        on ? rkGreen.CGColor : rkBorder.CGColor;
    self.connectBtn.layer.backgroundColor = on
        ? [NSColor colorWithRed:0.06 green:0.45 blue:0.18 alpha:0.15].CGColor
        : rkBtn.CGColor;
}
- (void)setStatus:(NSString *)text color:(NSColor *)color {
    self.statusLabel.stringValue         = text;
    self.statusLabel.textColor           = color;
    self.statusDot.layer.backgroundColor = color.CGColor;
}
- (void)setConnectTitle:(NSString *)title color:(NSColor *)color {
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    self.connectBtn.attributedTitle = [[NSAttributedString alloc]
        initWithString:title attributes:@{
            NSFontAttributeName:            [NSFont systemFontOfSize:13
                                                             weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: color,
            NSParagraphStyleAttributeName:  ps
        }];
}
- (void)openLogs {
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.logPath])
        [[NSWorkspace sharedWorkspace] openFile:self.logPath withApplication:@"Console"];
    else [self setStatus:@"Логов нет" color:rkSub];
}
- (void)quit { if (self.connected) [self stopVPN]; [NSApp terminate:nil]; }
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
               color:rkSub frame:[self rx:kPAD top:t w:200 h:11]];
}
- (NSTextField *)monoLbl:(NSString *)s frame:(NSRect)r {
    NSTextField *v = [[NSTextField alloc] initWithFrame:r];
    v.stringValue = s;
    v.font = [NSFont fontWithName:@"Menlo" size:9] ?: [NSFont systemFontOfSize:9];
    v.textColor = rkAccent; v.bezeled = NO; v.drawsBackground = NO;
    v.editable = NO; v.selectable = YES;
    return v;
}
- (NSView *)sep:(NSRect)r {
    NSView *v = [[NSView alloc] initWithFrame:r];
    v.wantsLayer = YES; v.layer.backgroundColor = rkBorder.CGColor; return v;
}
- (NSButton *)btn:(NSString *)t frame:(NSRect)r action:(SEL)a primary:(BOOL)p {
    NSButton *b = [[NSButton alloc] initWithFrame:r];
    b.title = t; b.font = [NSFont systemFontOfSize:12];
    b.bezelStyle = NSBezelStyleRounded; b.target = self; b.action = a;
    return b;
}
@end
EOF
echo -e "${G}✓ ViewController.m${N}"

# ── Info.plist ────────────────────────────────────────────────────────────────
echo -e "${Y}→ Info.plist (v0.8.3)${N}"
cat > Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>         <string>Raketa</string>
    <key>CFBundleIdentifier</key>         <string>com.samurai.raketa</string>
    <key>CFBundleName</key>               <string>Raketa</string>
    <key>CFBundleDisplayName</key>        <string>Raketa</string>
    <key>CFBundleVersion</key>            <string>0.8.3</string>
    <key>CFBundleShortVersionString</key> <string>0.8.3</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>LSMinimumSystemVersion</key>     <string>10.13.0</string>
    <key>LSUIElement</key>                <true/>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>NSHumanReadableCopyright</key>   <string>Raketa — Ради вас старался Пашенька</string>
</dict>
</plist>
EOF
echo -e "${G}✓ Info.plist${N}"

# ── build.yml ─────────────────────────────────────────────────────────────────
echo -e "${Y}→ build.yml (v0.8.3)${N}"
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
          ### v0.8.3 — Bug fixes
          **Критический: серверы не сохранялись**
          Исправлен механизм персистентности — `parsedJSON:` теперь всегда записывает
          `subscription.json` после успешного парсинга, независимо от источника
          (vless:// ссылка, base64, JSON подписка). При запуске читается этот файл.

          **Лог-ошибка "protocol wrong type for socket"**
          HTTP inbound заменён на `mixed` — он корректно обрабатывает как HTTP CONNECT,
          так и SOCKS5 на одном порту. Ошибка в логах исчезнет.

          **Layout**
          Окно уменьшено (370→296px), круглая кнопка заменена на компактный прямоугольник,
          кнопка Telegram больше не перекрывается нижней панелью.
        files: Raketa-macOS-10.13-*.zip
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
EOF
echo -e "${G}✓ build.yml${N}"

echo ""
echo -e "${C}╔══════════════════════════════════════════════════════╗"
echo -e "║  Patch applied. Next:                                ║"
echo -e "╠══════════════════════════════════════════════════════╣"
echo -e "║  git add -A                                          ║"
echo -e "║  git commit -m 'v0.8.3: server persistence + fixes' ║"
echo -e "║  git tag v0.8.3                                      ║"
echo -e "║  git push origin main --tags                         ║"
echo -e "╚══════════════════════════════════════════════════════╝${N}"
