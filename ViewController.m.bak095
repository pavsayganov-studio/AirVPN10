#import "ViewController.h"
#import <SystemConfiguration/SystemConfiguration.h>

// ── Ports ─────────────────────────────────────────────────────────────────────
static const NSInteger kSOCKSPort = 10808;
static const NSInteger kMixedPort = 10809;
static const NSInteger kTGPort    = 10810;
static NSString *const kTGSecret  = @"dd000000000000000000000000000000";
static NSString *const kSubKey    = @"RaketaSubscriptionURL";
static NSString *const kSubFile   = @"subscription.json";

// ── Layout — HIG 10.13 compliant ─────────────────────────────────────────────
static const CGFloat kW      = 300.0;
static const CGFloat kH      = 314.0;
static const CGFloat kHTG    = 170.0;
static const CGFloat kPAD    = 20.0;   // HIG: 20pt outer margin
static const CGFloat kGRP    = 12.0;   // HIG: 12pt between groups
static const CGFloat kREL    =  8.0;   // HIG: 8pt between related elements

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
@property (strong) NSString       *subPath;
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

// =============================================================================
#pragma mark - Class init
// =============================================================================
+ (void)initialize {
    if (self != [ViewController class]) return;
    // Soft blue theme — brand colours, HIG allows custom palettes
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

// ── Geometry: Y measured from top ────────────────────────────────────────────
- (NSRect)rx:(CGFloat)x top:(CGFloat)t w:(CGFloat)w h:(CGFloat)h {
    return NSMakeRect(x, kH - t - h, w, h);
}

// =============================================================================
#pragma mark - loadView
// Layout map (top-down, all values in pt):
//   0  – 32  header (32pt — compact, closer to HIG 22pt title bar)
//   32 – 33  separator
//   33 – 44  gap (kGRP = 12 — between header and first section)  [was 11]
//   44 – 55  ПОДПИСКА label  (11pt Small — HIG Small)
//   55 – 63  gap 8pt  (kREL — related: label to control)
//   63 – 91  paste button (28pt — comfortable push button)
//   91 – 92  separator
//   92 –104  gap 12pt  (kGRP)
//  104 –115  СЕРВЕР label
//  115 –123  gap 8pt
//  123 –149  dropdown (26pt — standard menu control height)
//  149 –157  gap 8pt
//  157 –164  status row (dot + text, 13pt Regular)
//  164 –176  gap 12pt
//  176 –212  connect button (36pt tall, corner radius 18 = capsule feel)
//  212 –213  separator
//  213 –225  gap 12pt
//  225 –249  Telegram toggle button (24pt)
//  249 –250  separator
//  250 –314  bottom bar (64pt: 21pt buttons + credit + internal padding)
// =============================================================================
- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kH)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = rkBG.CGColor;

    // ── Header (0–32) — 32pt, closer to HIG 22pt title bar ───────────────────
    NSView *hdr = [[NSView alloc] initWithFrame:NSMakeRect(0, kH-32, kW, 32)];
    hdr.wantsLayer = YES;
    hdr.layer.backgroundColor = rkSurface.CGColor;
    [root addSubview:hdr];
    // 14pt Semibold — HIG: SF Pro Display for headings
    [hdr addSubview:[self lbl:@"🚀  Raketa"
                          font:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]
                         color:rkText frame:NSMakeRect(kPAD, 7, 180, 18)]];
    NSTextField *ver = [self lbl:@"v0.9.3"
                            font:[NSFont systemFontOfSize:10]
                           color:rkSub frame:NSMakeRect(kW-50, 8, 36, 16)];
    ver.alignment = NSTextAlignmentRight;
    [hdr addSubview:ver];
    [root addSubview:[self sep:NSMakeRect(0, kH-33, kW, 1)]];

    // ── ПОДПИСКА (44–91) ──────────────────────────────────────────────────────
    // Section label: 11pt Small per HIG
    [root addSubview:[self sectionLbl:@"ПОДПИСКА" top:44]];
    self.pasteBtn = [self btn:@"⎘  Вставить ссылку из буфера"
                        frame:[self rx:kPAD top:55 w:kW-kPAD*2 h:28]
                       action:@selector(pasteAndLoad) primary:YES];
    // 13pt Regular — HIG base text size
    self.pasteBtn.font = [NSFont systemFontOfSize:13];
    [root addSubview:self.pasteBtn];
    [root addSubview:[self sep:NSMakeRect(0, kH-91, kW, 1)]];

    // ── СЕРВЕР (104–149) ──────────────────────────────────────────────────────
    [root addSubview:[self sectionLbl:@"СЕРВЕР" top:104]];
    self.dropdown = [[NSPopUpButton alloc]
                     initWithFrame:[self rx:kPAD top:115 w:kW-kPAD*2 h:26]
                          pullsDown:NO];
    [self.dropdown addItemWithTitle:@"— серверы не загружены —"];
    self.dropdown.enabled = NO;
    // 13pt Regular — HIG base text size for controls
    self.dropdown.font   = [NSFont systemFontOfSize:13];
    self.dropdown.target = self;
    self.dropdown.action = @selector(serverChanged);
    [root addSubview:self.dropdown];

    // ── Status (149–164) ─────────────────────────────────────────────────────
    // 8pt gap after dropdown, then status row
    CGFloat dotY = kH - 157 - 7;
    self.statusDot = [[NSView alloc] initWithFrame:NSMakeRect(kPAD, dotY+1, 7, 7)];
    self.statusDot.wantsLayer = YES;
    self.statusDot.layer.cornerRadius    = 3.5;
    self.statusDot.layer.backgroundColor = rkSub.CGColor;
    [root addSubview:self.statusDot];
    // 11pt Small — secondary status text
    self.statusLabel = [self lbl:@"Готов к работе"
                            font:[NSFont systemFontOfSize:11] color:rkSub
                           frame:NSMakeRect(kPAD+13, dotY, kW-kPAD*2-13, 14)];
    [root addSubview:self.statusLabel];

    // ── Connect button (176–212) ─────────────────────────────────────────────
    // Full-width, 36pt tall, corner radius 18 → capsule feel per HIG button style
    self.connectBtn = [[NSButton alloc]
                       initWithFrame:[self rx:kPAD top:176 w:kW-kPAD*2 h:36]];
    self.connectBtn.title    = @"";
    self.connectBtn.bordered = NO;
    self.connectBtn.wantsLayer = YES;
    self.connectBtn.layer.cornerRadius    = 18;
    self.connectBtn.layer.borderWidth     = 1.0;
    self.connectBtn.layer.borderColor     = rkBorder.CGColor;
    self.connectBtn.layer.backgroundColor = rkBtn.CGColor;
    self.connectBtn.target = self;
    self.connectBtn.action = @selector(toggle);
    [self setConnectTitle:@"ВЫКЛ" color:rkSub];
    [root addSubview:self.connectBtn];
    [root addSubview:[self sep:NSMakeRect(0, kH-212, kW, 1)]];

    // ── Telegram toggle (225–249) ─────────────────────────────────────────────
    self.tgToggleBtn = [self btn:@"📱  Настройка Telegram  ▾"
                           frame:[self rx:kPAD top:225 w:kW-kPAD*2 h:24]
                          action:@selector(toggleTG) primary:NO];
    // 11pt Small — secondary action
    self.tgToggleBtn.font = [NSFont systemFontOfSize:11];
    [root addSubview:self.tgToggleBtn];
    [root addSubview:[self sep:NSMakeRect(0, kH-249, kW, 1)]];

    // ── Bottom bar (249–314) ─────────────────────────────────────────────────
    NSView *bar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, 65)];
    bar.wantsLayer = YES;
    bar.layer.backgroundColor = rkSurface.CGColor;
    [root addSubview:bar];

    // HIG: push button height = 21pt
    // "Логи" and "Выход" — 11pt Small font, 21pt height
    NSButton *logBtn = [self btn:@"Логи"
                           frame:NSMakeRect(kPAD, 33, 66, 21)
                          action:@selector(openLogs) primary:NO];
    logBtn.font = [NSFont systemFontOfSize:11];
    [bar addSubview:logBtn];

    NSButton *quitBtn = [self btn:@"Выход"
                            frame:NSMakeRect(kW-kPAD-72, 33, 72, 21)
                           action:@selector(quit) primary:NO];
    quitBtn.font = [NSFont systemFontOfSize:11];
    [bar addSubview:quitBtn];

    // Credit — 9pt Mini per HIG, tracked, centred
    // Positioned in lower part of bar with 8pt bottom margin
    NSTextField *credit = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 8, kW, 14)];
    credit.bezeled = NO; credit.drawsBackground = NO;
    credit.editable = NO; credit.selectable = NO;
    credit.alignment = NSTextAlignmentCenter;
    credit.attributedStringValue = [[NSAttributedString alloc]
        initWithString:@"Ради вас старался Пашенька" attributes:@{
            NSFontAttributeName:  [NSFont fontWithName:@"HelveticaNeue-Light" size:9]
                                  ?: [NSFont systemFontOfSize:9],
            NSForegroundColorAttributeName: rkSub,
            NSKernAttributeName:  @(0.8)   // letter tracking — prevents glyph crowding
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

    // Load persisted servers asynchronously — never stall main thread
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

    // Header — 9pt Mini label
    [self.tgPanel addSubview:
     [self lbl:@"TELEGRAM — ПРОКСИ"
          font:[NSFont systemFontOfSize:9 weight:NSFontWeightSemibold]
         color:rkAccent frame:NSMakeRect(kPAD, kHTG-19, kW-kPAD*2, 13)]];

    // Method 1: MTProxy
    [self.tgPanel addSubview:
     [self lbl:@"Способ 1 — MTProxy"
          font:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
         color:rkText frame:NSMakeRect(kPAD, kHTG-34, 126, 13)]];
    [self.tgPanel addSubview:
     [self lbl:@"рекомендовано"
          font:[NSFont systemFontOfSize:9]
         color:rkAccent frame:NSMakeRect(kPAD+130, kHTG-33, 100, 12)]];

    // 11pt Small mono details — selectable for manual copy
    [self.tgPanel addSubview:
     [self monoLbl:[NSString stringWithFormat:@"Сервер: 127.0.0.1   Порт: %ld",
                    (long)kTGPort]
              frame:NSMakeRect(kPAD, kHTG-49, kW-kPAD*2, 13)]];
    [self.tgPanel addSubview:
     [self monoLbl:[NSString stringWithFormat:@"Секрет: %@", kTGSecret]
              frame:NSMakeRect(kPAD, kHTG-63, kW-kPAD*2, 13)]];

    NSButton *openMT = [self btn:@"⚡  Добавить в Telegram"
                           frame:NSMakeRect(kPAD, kHTG-87, 148, 21)
                          action:@selector(openMTLink) primary:YES];
    openMT.font = [NSFont systemFontOfSize:11];
    [self.tgPanel addSubview:openMT];

    self.secretCopyBtn = [self btn:@"Копировать секрет"
                             frame:NSMakeRect(kPAD+154, kHTG-87, kW-kPAD*2-154, 21)
                            action:@selector(copySecret) primary:NO];
    self.secretCopyBtn.font = [NSFont systemFontOfSize:11];
    [self.tgPanel addSubview:self.secretCopyBtn];

    [self.tgPanel addSubview:[self sep:NSMakeRect(kPAD, kHTG-97, kW-kPAD*2, 1)]];

    // Method 2: SOCKS5
    [self.tgPanel addSubview:
     [self lbl:@"Способ 2 — SOCKS5"
          font:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
         color:rkText frame:NSMakeRect(kPAD, kHTG-112, 126, 13)]];
    [self.tgPanel addSubview:
     [self lbl:@"запасной"
          font:[NSFont systemFontOfSize:9]
         color:rkSub frame:NSMakeRect(kPAD+130, kHTG-111, 70, 12)]];

    [self.tgPanel addSubview:
     [self monoLbl:[NSString stringWithFormat:
                    @"Сервер: 127.0.0.1   Порт: %ld   Тип: SOCKS5",
                    (long)kSOCKSPort]
              frame:NSMakeRect(kPAD, kHTG-127, kW-kPAD*2, 13)]];

    NSButton *openSK = [self btn:@"⚡  Добавить SOCKS5 в Telegram"
                           frame:NSMakeRect(kPAD, kHTG-151, kW-kPAD*2, 21)
                          action:@selector(openSOCKSLink) primary:NO];
    openSK.font = [NSFont systemFontOfSize:11];
    [self.tgPanel addSubview:openSK];

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
                @{@"ip_cidr":       @[@"127.0.0.0/8",@"192.168.0.0/16",
                                      @"10.0.0.0/8",@"172.16.0.0/12"],
                  @"outbound":@"direct"},
                @{@"domain_suffix": @[@"apple.com",@"icloud.com"],
                  @"outbound":@"direct"},
                @{@"domain_suffix": @[@".ru",@".рф"],
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
        @"'%@' run -c '%@' > '%@' 2>&1 & echo $!",
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
#pragma mark - Watchdog  (kill(pid,0) — near-zero CPU cost)
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
    return [px[@"HTTPEnable"] boolValue]
        || [px[@"HTTPSEnable"] boolValue]
        || [px[@"SOCKSEnable"] boolValue];
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
#pragma mark - Paste & Load
// =============================================================================
- (void)pasteAndLoad {
    NSString *text = [[[NSPasteboard generalPasteboard]
                        stringForType:NSPasteboardTypeString]
                       stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) { [self setStatus:@"Буфер обмена пуст" color:rkOrange]; return; }
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
#pragma mark - Config parsing
// =============================================================================
- (void)rawText:(NSString *)txt {
    NSString *s = [txt stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSData *dec = [[NSData alloc] initWithBase64EncodedString:s
                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (dec) { NSString *ds = [[NSString alloc] initWithData:dec
                               encoding:NSUTF8StringEncoding]; if (ds) s = ds; }
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
    self.proxyTags = [NSMutableArray array];
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
        if ([q.name isEqualToString:@"sni"]  && q.value.length) tls[@"server_name"]=q.value;
        if ([q.name isEqualToString:@"fp"]   && q.value.length)
            tls[@"utls"]=@{@"enabled":@YES,@"fingerprint":q.value};
        if ([q.name isEqualToString:@"pbk"]  && q.value.length) {
            if (!tls[@"reality"]) tls[@"reality"]=[NSMutableDictionary dictionary];
            tls[@"reality"][@"public_key"]=q.value;
        }
        if ([q.name isEqualToString:@"sid"]  && q.value.length) {
            if (!tls[@"reality"]) tls[@"reality"]=[NSMutableDictionary dictionary];
            tls[@"reality"][@"short_id"]=q.value;
        }
        if ([q.name isEqualToString:@"flow"] && q.value.length) out[@"flow"]=q.value;
        if ([q.name isEqualToString:@"type"] && q.value.length
            && ![q.value isEqualToString:@"tcp"]) tr[@"type"]=q.value;
        if ([q.name isEqualToString:@"path"] && q.value.length) tr[@"path"]=q.value;
        if ([q.name isEqualToString:@"serviceName"] && q.value.length)
            tr[@"service_name"]=q.value;
        if ([q.name isEqualToString:@"host"] && q.value.length)
            tr[@"headers"]=@{@"Host":q.value};
    }
    if (tls[@"enabled"] && !tls[@"utls"])
        tls[@"utls"]=@{@"enabled":@YES,@"fingerprint":@"chrome"};
    if (tls.count) out[@"tls"]=tls;
    if (tr.count)  out[@"transport"]=tr;
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
    self.connectBtn.layer.borderColor = on ? rkGreen.CGColor : rkBorder.CGColor;
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
    v.stringValue=s; v.font=f; v.textColor=c;
    v.bezeled=NO; v.drawsBackground=NO; v.editable=NO; v.selectable=NO;
    return v;
}
- (NSTextField *)sectionLbl:(NSString *)s top:(CGFloat)t {
    // 11pt Small per HIG — section labels / secondary text
    return [self lbl:s font:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium]
               color:rkSub frame:[self rx:kPAD top:t w:200 h:13]];
}
- (NSTextField *)monoLbl:(NSString *)s frame:(NSRect)r {
    NSTextField *v = [[NSTextField alloc] initWithFrame:r];
    v.stringValue=s;
    v.font=[NSFont fontWithName:@"Menlo" size:10] ?: [NSFont systemFontOfSize:10];
    v.textColor=rkAccent; v.bezeled=NO; v.drawsBackground=NO;
    v.editable=NO; v.selectable=YES;
    return v;
}
- (NSView *)sep:(NSRect)r {
    NSView *v=[[NSView alloc] initWithFrame:r];
    v.wantsLayer=YES; v.layer.backgroundColor=rkBorder.CGColor; return v;
}
- (NSButton *)btn:(NSString *)t frame:(NSRect)r action:(SEL)a primary:(BOOL)p {
    NSButton *b=[[NSButton alloc] initWithFrame:r];
    b.title=t; b.font=[NSFont systemFontOfSize:13];
    b.bezelStyle=NSBezelStyleRounded; b.target=self; b.action=a;
    return b;
}
@end
