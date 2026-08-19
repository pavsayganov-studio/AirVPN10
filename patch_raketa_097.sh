#!/bin/bash
# =============================================================================
# Raketa v0.9.7 — fix refresh icon visibility + connect/bar overlap
# Run from repo root: bash patch_raketa_095b.sh
# =============================================================================
set -e
G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; R='\033[0;31m'; N='\033[0m'

echo -e "${C}╔══════════════════════════════════════════╗"
echo -e "║   Raketa v0.9.7 — Icon + Layout Fix      ║"
echo -e "╚══════════════════════════════════════════╝${N}\n"

[ ! -f "ViewController.m" ] && echo -e "${R}✗ Run from repo root${N}" && exit 1

cp ViewController.m ViewController.m.bak095
cp Info.plist Info.plist.bak095
cp .github/workflows/build.yml .github/workflows/build.yml.bak095
echo -e "${G}✓ Backups created${N}\n"

echo -e "${Y}→ ViewController.m${N}"
cat > ViewController.m << 'EOF'
#import "ViewController.h"
#import <SystemConfiguration/SystemConfiguration.h>

// ── Ports ─────────────────────────────────────────────────────────────────────
static const NSInteger kSOCKSPort = 10808;
static const NSInteger kMixedPort = 10809;
static const NSInteger kTGPort    = 10810;
static NSString *const kTGSecret  = @"dd000000000000000000000000000000";
static NSString *const kSubKey    = @"RaketaSubscriptionURL";
static NSString *const kSubFile   = @"subscription.json";

// ── Layout ────────────────────────────────────────────────────────────────────
// kH=278: one-row subscription buttons save 36pt vs two-row layout.
// Bottom bar is 73pt — comfortable for credit + buttons.
//
// Map (top-down, pt):
//   0  – 32   header
//  32  – 33   sep
//  33  – 44   gap (12pt)
//  44  – 55   ПОДПИСКА label (11pt)
//  55  – 83   [＋ Добавить ключи (224pt)] [↻ (28pt)]  h=28
//  83  – 84   sep
//  84  – 96   gap (12pt)
//  96  –107   СЕРВЕР label
// 107  –115   gap (8pt)
// 115  –141   dropdown (26pt)
// 141  –149   gap (8pt)
// 149  –156   status row (dot + text)
// 156  –168   gap (12pt)
// 168  –204   connect button (36pt, corner radius 18)
// 204  –205   sep
// 205  –278   bottom bar (73pt): Логи | credit | ✈ | Выход
static const CGFloat kW      = 300.0;
static const CGFloat kH      = 278.0;
static const CGFloat kHTG    = 170.0;
static const CGFloat kPAD    = 20.0;
// Width of "Добавить ключи" button: kW - kPAD*2 - 8(gap) - 28(refresh) = 224
static const CGFloat kAddW   = 224.0;
// Width of refresh square button
static const CGFloat kRefW   = 28.0;

// ── Colors — allocated once in +initialize ────────────────────────────────────
static NSColor *rkBG, *rkSurface, *rkCard, *rkBorder,
               *rkText, *rkSub, *rkAccent, *rkGreen, *rkOrange, *rkRed, *rkBtn;
static dispatch_queue_t sTaskQ;

@interface ViewController ()
@property (strong) NSButton       *addKeysBtn;
@property (strong) NSButton       *refreshIconBtn;  // square ↻ button
@property (strong) NSTextField    *statusLabel;
@property (strong) NSView         *statusDot;
@property (strong) NSButton       *connectBtn;
@property (strong) NSPopUpButton  *dropdown;
@property (strong) NSView         *tgPanel;
@property (strong) NSButton       *tgIconBtn;
@property (assign) BOOL            tgOpen;
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
#pragma mark - loadView
// =============================================================================
- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kH)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = rkBG.CGColor;

    // ── Header (0–32) ─────────────────────────────────────────────────────────
    NSView *hdr = [[NSView alloc] initWithFrame:NSMakeRect(0, kH-32, kW, 32)];
    hdr.wantsLayer = YES;
    hdr.layer.backgroundColor = rkSurface.CGColor;
    [root addSubview:hdr];
    [hdr addSubview:[self lbl:@"🚀  Raketa"
                          font:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]
                         color:rkText frame:NSMakeRect(kPAD, 7, 180, 18)]];
    NSTextField *ver = [self lbl:@"v0.9.7"
                            font:[NSFont systemFontOfSize:10]
                           color:rkSub frame:NSMakeRect(kW-50, 8, 36, 16)];
    ver.alignment = NSTextAlignmentRight;
    [hdr addSubview:ver];
    [root addSubview:[self sep:NSMakeRect(0, kH-33, kW, 1)]];

    // ── ПОДПИСКА (44–83) — one row: wide add button + square refresh ──────────
    [root addSubview:[self sectionLbl:@"ПОДПИСКА" top:44]];

    // "Добавить ключи" — primary, wide
    self.addKeysBtn = [self btn:@"＋  Добавить ключи"
                          frame:[self rx:kPAD top:55 w:kAddW h:28]
                         action:@selector(addKeys) primary:YES];
    self.addKeysBtn.font = [NSFont systemFontOfSize:13];
    [root addSubview:self.addKeysBtn];

    // ↻ refresh button — square, icon only, right of add button
    // ↻ = U+21BB CLOCKWISE OPEN CIRCLE ARROW — clear refresh metaphor,
    // present in all macOS system fonts since 10.9
    CGFloat refX = kPAD + kAddW + 8;
    self.refreshIconBtn = [[NSButton alloc]
                           initWithFrame:[self rx:refX top:55 w:kRefW h:28]];
    // attributedTitle + bordered=NO: NSBezelStyleRounded clips/hides the ↻
    // glyph at small button sizes on macOS 10.13. This renders reliably.
    NSDictionary *iconAttrs = @{
        NSFontAttributeName:            [NSFont systemFontOfSize:16
                                                         weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: rkSub
    };
    self.refreshIconBtn.attributedTitle =
        [[NSAttributedString alloc] initWithString:@"↻" attributes:iconAttrs];
    self.refreshIconBtn.bordered    = NO;
    self.refreshIconBtn.wantsLayer  = YES;
    self.refreshIconBtn.layer.cornerRadius    = 6;
    self.refreshIconBtn.layer.borderWidth     = 0.5;
    self.refreshIconBtn.layer.borderColor     = rkBorder.CGColor;
    self.refreshIconBtn.layer.backgroundColor = rkBtn.CGColor;
    self.refreshIconBtn.toolTip    = @"Обновить ключи";
    self.refreshIconBtn.target     = self;
    self.refreshIconBtn.action     = @selector(refreshKeys);
    [root addSubview:self.refreshIconBtn];

    [root addSubview:[self sep:NSMakeRect(0, kH-83, kW, 1)]];

    // ── СЕРВЕР (96–141) ───────────────────────────────────────────────────────
    [root addSubview:[self sectionLbl:@"СЕРВЕР" top:96]];
    self.dropdown = [[NSPopUpButton alloc]
                     initWithFrame:[self rx:kPAD top:107 w:kW-kPAD*2 h:26] pullsDown:NO];
    [self.dropdown addItemWithTitle:@"— серверы не загружены —"];
    self.dropdown.enabled = NO;
    self.dropdown.font    = [NSFont systemFontOfSize:13];
    self.dropdown.target  = self;
    self.dropdown.action  = @selector(serverChanged);
    [root addSubview:self.dropdown];

    // ── Status (149–156) ──────────────────────────────────────────────────────
    CGFloat dotY = kH - 149 - 8;
    self.statusDot = [[NSView alloc] initWithFrame:NSMakeRect(kPAD, dotY+1, 7, 7)];
    self.statusDot.wantsLayer = YES;
    self.statusDot.layer.cornerRadius    = 3.5;
    self.statusDot.layer.backgroundColor = rkSub.CGColor;
    [root addSubview:self.statusDot];
    self.statusLabel = [self lbl:@"Готов к работе"
                            font:[NSFont systemFontOfSize:11] color:rkSub
                           frame:NSMakeRect(kPAD+13, dotY, kW-kPAD*2-13, 14)];
    [root addSubview:self.statusLabel];

    // ── Connect button (168–204) — capsule-style rounded rect ────────────────
    self.connectBtn = [[NSButton alloc]
                       initWithFrame:[self rx:kPAD top:152 w:kW-kPAD*2 h:36]];
    self.connectBtn.title    = @"";
    self.connectBtn.bordered = NO;
    self.connectBtn.wantsLayer = YES;
    self.connectBtn.layer.cornerRadius    = 18;
    self.connectBtn.layer.borderWidth     = 1.0;
    self.connectBtn.layer.borderColor     = rkBorder.CGColor;
    self.connectBtn.layer.backgroundColor = rkBtn.CGColor;
    self.connectBtn.target = self;
    self.connectBtn.action = @selector(toggle);
    [self setConnectTitle:@"○  ВЫКЛ" color:rkSub];
    [root addSubview:self.connectBtn];
    [root addSubview:[self sep:NSMakeRect(0, kH-204, kW, 1)]];

    // ── Bottom bar (204–278) — 74pt: Логи | credit | ✈ | Выход ──────────────
    NSView *bar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, 73)];
    bar.wantsLayer = YES;
    bar.layer.backgroundColor = rkSurface.CGColor;
    [root addSubview:bar];

    NSButton *logBtn = [self btn:@"Логи"
                           frame:NSMakeRect(kPAD, 36, 58, 21)
                          action:@selector(openLogs) primary:NO];
    logBtn.font = [NSFont systemFontOfSize:11];
    [bar addSubview:logBtn];

    NSButton *quitBtn = [self btn:@"Выход"
                            frame:NSMakeRect(kW-kPAD-68, 36, 68, 21)
                           action:@selector(quit) primary:NO];
    quitBtn.font = [NSFont systemFontOfSize:11];
    [bar addSubview:quitBtn];

    // ✈ Telegram icon button — 32×21pt, left of Выход with 4pt gap
    self.tgIconBtn = [[NSButton alloc]
                      initWithFrame:NSMakeRect(kW-kPAD-68-4-32, 36, 32, 21)];
    self.tgIconBtn.title      = @"✈";
    self.tgIconBtn.font       = [NSFont systemFontOfSize:14];
    self.tgIconBtn.bezelStyle = NSBezelStyleRounded;
    self.tgIconBtn.toolTip    = @"Настройка Telegram";
    self.tgIconBtn.target     = self;
    self.tgIconBtn.action     = @selector(toggleTG);
    [bar addSubview:self.tgIconBtn];

    // Credit — 9pt Mini, tracked, centred
    NSTextField *credit = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 10, kW, 14)];
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

    // Load persisted servers off main thread — never stall UI
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
#pragma mark - Subscription actions
// =============================================================================

// "Добавить ключи" — paste vless:// or subscription URL from clipboard
- (void)addKeys {
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
    [self flashButton:self.addKeysBtn title:@"✓  Получено"];
    if (isVless) [self rawText:text]; else [self downloadURL:text];
}

// ↻ "Обновить ключи" — re-fetch from saved source
- (void)refreshKeys {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kSubKey];
    if (!saved.length) {
        [self setStatus:@"Сначала добавьте ключи" color:rkOrange]; return;
    }
    // Spin the icon while loading — simple visual feedback without animation overhead
    // Feedback via status line — avoids clobbering the icon's attributedTitle
    [self setStatus:@"Обновление серверов..." color:rkSub];
    if ([saved hasPrefix:@"http://"] || [saved hasPrefix:@"https://"]) {
        [self downloadURL:saved];
    } else if ([saved hasPrefix:@"vless://"]) {
        [self rawText:saved];
    } else {
        [self setStatus:@"Неизвестный формат" color:rkRed];
    }
}

- (void)flashButton:(NSButton *)btn title:(NSString *)newTitle {
    NSString *orig = btn.title;
    btn.title = newTitle;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ btn.title = orig; });
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
          font:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
         color:rkText frame:NSMakeRect(kPAD, kHTG-34, 126, 13)]];
    [self.tgPanel addSubview:
     [self lbl:@"рекомендовано" font:[NSFont systemFontOfSize:9]
         color:rkAccent frame:NSMakeRect(kPAD+130, kHTG-33, 100, 12)]];
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
     [self lbl:@"запасной" font:[NSFont systemFontOfSize:9]
         color:rkSub frame:NSMakeRect(kPAD+130, kHTG-111, 70, 12)]];
    [self.tgPanel addSubview:
     [self monoLbl:[NSString stringWithFormat:
                    @"Сервер: 127.0.0.1   Порт: %ld   Тип: SOCKS5", (long)kSOCKSPort]
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
        self.tgIconBtn.wantsLayer = YES;
        self.tgIconBtn.layer.backgroundColor =
            [NSColor colorWithRed:0.10 green:0.40 blue:0.78 alpha:0.15].CGColor;
    } else {
        for (NSView *v in self.view.subviews)
            if (v != self.tgPanel)
                v.frame = NSMakeRect(v.frame.origin.x, v.frame.origin.y - kHTG,
                                     v.frame.size.width, v.frame.size.height);
        self.tgPanel.frame = NSMakeRect(0, -kHTG, kW, kHTG);
        self.tgIconBtn.layer.backgroundColor = [NSColor clearColor].CGColor;
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
    [self flashButton:self.secretCopyBtn title:@"✓ Скопировано"];
}

// =============================================================================
#pragma mark - VPN Core
// =============================================================================
- (void)toggle { self.connected ? [self stopVPN] : [self startVPN]; }

- (void)startVPN {
    if (!self.proxyTags.count) {
        [self setStatus:@"Сначала добавьте ключи" color:rkOrange]; return;
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

    // FIX (macOS 10.13 + 12.x): removed `nohup`.
    // nohup on macOS 12 fails with ENOTTY when there is no controlling terminal
    // (AppleScript's "do shell script" provides none). The `&` operator alone is
    // sufficient — sing-box is reparented to launchd when the parent shell exits.
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
#pragma mark - Config parsing
// =============================================================================
- (void)rawText:(NSString *)txt {
    NSString *s = [txt stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
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
    [self setConnectTitle:(on ? @"●  ВКЛ" : @"○  ВЫКЛ") color:(on ? rkGreen : rkSub)];
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
EOF
echo -e "${G}✓ ViewController.m${N}"

echo -e "${Y}→ Info.plist (v0.9.7)${N}"
python3 -c "
import re, sys
s = open('Info.plist').read()
s = re.sub(r'0\.9\.[0-9]+', '0.9.7', s)
open('Info.plist','w').write(s)
print('✓ Info.plist → v0.9.7')
"

echo -e "${Y}→ build.yml (v0.9.7)${N}"
python3 - << 'PY'
with open('.github/workflows/build.yml', 'r') as f:
    s = f.read()
# Update release body
old = s[s.find('        body: |'):s.find('        files:')]
new = """        body: |
          ## 🚀 Raketa ${{ github.ref_name }}

          ### v0.9.7
          - ↻ иконка обновления подписки теперь видна (была пустая кнопка).
            Причина: NSBezelStyleRounded скрывал Unicode-глиф на macOS 10.13
            при малом размере кнопки. Исправлено через attributedTitle + bordered=NO.
          - Кнопка ВКЛ/ВЫКЛ больше не перекрывается нижней панелью (зазор 17pt)
          - Обновление ключей отображается в строке статуса, а не на самой иконке
          - Все исправления v0.9.5 (совместимость с macOS 12) сохранены

"""
s = s.replace(old, new)
with open('.github/workflows/build.yml', 'w') as f:
    f.write(s)
print("✓ build.yml updated")
PY

echo ""
echo -e "${G}Verification:${N}"
grep -c 'nohup' ViewController.m && echo "ERROR: nohup still present" || echo "✓ nohup removed"
grep -q 'refreshIconBtn' ViewController.m && echo "✓ refreshIconBtn present" || echo "ERROR: missing"
grep -q "0.9.7" Info.plist && echo "✓ Info.plist v0.9.7" || echo "ERROR: version not updated"

echo ""
echo -e "${C}╔══════════════════════════════════════════════════════╗"
echo -e "║  Commands:                                           ║"
echo -e "╠══════════════════════════════════════════════════════╣"
echo -e "║  git add -A                                          ║"
echo -e "║  git commit -m 'v0.9.7: fix refresh icon + overlap' ║"
echo -e "║  git tag v0.9.7                                      ║"
echo -e "║  git push origin main --tags                         ║"
echo -e "╚══════════════════════════════════════════════════════╝${N}"
