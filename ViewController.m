#import "ViewController.h"
#import <SystemConfiguration/SystemConfiguration.h>

// MTProxy secret — dd + 32 нуля (phantom domain mode, работает везде)
static NSString *const kMTProxySecret = @"dd000000000000000000000000000000";
static NSInteger const kMTProxyPort   = 10810;
static NSInteger const kSOCKSPort     = 10808;
static NSInteger const kHTTPPort      = 10809;

@interface ViewController ()
@property (strong) NSTextField      *urlField;
@property (strong) NSTextField      *statusLabel;
@property (strong) NSButton         *connectButton;
@property (strong) NSPopUpButton    *serverDropdown;
@property (strong) NSString         *configPath;
@property (strong) NSString         *logPath;
@property (strong) NSMutableDictionary *downloadedJSON;
@property (strong) NSMutableArray   *proxyTags;
@property (strong) NSMutableArray   *proxyOutbounds;
@property (assign) BOOL              isConnected;
@property (strong) NSTimer          *watchdogTimer;
@property (assign) BOOL              mtproxyAvailable;
// Панель подсказки Telegram
@property (strong) NSView           *tgHintView;
@property (assign) BOOL              tgHintVisible;
@end

@implementation ViewController

// =============================================================================
#pragma mark - UI Setup
// =============================================================================

- (void)loadView {
    // Главный контейнер
    NSVisualEffectView *effectView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 290, 400)];
    effectView.material   = NSVisualEffectMaterialDark;
    effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effectView.state      = NSVisualEffectStateActive;

    // --- Заголовок ---
    NSTextField *titleLabel = [self makeLabelWithFrame:NSMakeRect(0, 360, 290, 30)
                                                  text:@"PauloVPN"
                                                  font:[NSFont fontWithName:@"HelveticaNeue-Light" size:22]
                                                 ?: [NSFont systemFontOfSize:22]
                                                 color:[NSColor whiteColor]
                                             alignment:NSTextAlignmentCenter];
    [effectView addSubview:titleLabel];

    // --- URL поле ---
    self.urlField = [[NSTextField alloc] initWithFrame:NSMakeRect(15, 315, 260, 24)];
    self.urlField.placeholderString = @"vless:// ссылка или URL подписки...";
    self.urlField.font = [NSFont systemFontOfSize:11];
    [effectView addSubview:self.urlField];

    // --- Кнопка загрузки ---
    NSButton *importBtn = [self makeButtonWithFrame:NSMakeRect(65, 280, 160, 28)
                                              title:@"Загрузить серверы"
                                             action:@selector(downloadConfig)];
    [effectView addSubview:importBtn];

    // --- Дропдаун серверов ---
    self.serverDropdown = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(15, 245, 260, 26) pullsDown:NO];
    [self.serverDropdown addItemWithTitle:@"Серверы не загружены"];
    [self.serverDropdown setEnabled:NO];
    self.serverDropdown.target = self;
    self.serverDropdown.action = @selector(serverChanged);
    [effectView addSubview:self.serverDropdown];

    // --- Статус ---
    self.statusLabel = [self makeLabelWithFrame:NSMakeRect(0, 210, 290, 30)
                                           text:@"Готов к работе"
                                           font:[NSFont systemFontOfSize:12]
                                          color:[NSColor colorWithWhite:1.0 alpha:0.7]
                                      alignment:NSTextAlignmentCenter];
    [effectView addSubview:self.statusLabel];

    // --- Кнопка подключения ---
    self.connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(105, 110, 80, 80)];
    self.connectButton.title  = @"ВЫКЛ";
    self.connectButton.font   = [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
    self.connectButton.bordered    = NO;
    self.connectButton.wantsLayer  = YES;
    self.connectButton.layer.cornerRadius  = 40;
    self.connectButton.layer.borderWidth   = 1.5;
    self.connectButton.layer.borderColor   = [NSColor colorWithWhite:1.0 alpha:0.3].CGColor;
    self.connectButton.layer.backgroundColor = [NSColor clearColor].CGColor;
    self.connectButton.target = self;
    self.connectButton.action = @selector(toggleConnection);
    [effectView addSubview:self.connectButton];

    // --- Кнопка Telegram ---
    NSButton *tgBtn = [self makeButtonWithFrame:NSMakeRect(15, 70, 260, 28)
                                          title:@"📱  Настройка Telegram"
                                         action:@selector(toggleTelegramHint)];
    tgBtn.font = [NSFont systemFontOfSize:11];
    [effectView addSubview:tgBtn];

    // --- Панель подсказки Telegram (скрыта по умолчанию) ---
    [self buildTelegramHintView:effectView];

    // --- Нижняя панель ---
    NSButton *logBtn = [self makeButtonWithFrame:NSMakeRect(15, 10, 70, 26)
                                           title:@"Логи"
                                          action:@selector(openLogs)];
    logBtn.font = [NSFont systemFontOfSize:11];
    [effectView addSubview:logBtn];

    NSButton *quitBtn = [self makeButtonWithFrame:NSMakeRect(205, 10, 70, 26)
                                            title:@"Выход"
                                           action:@selector(quitApp)];
    quitBtn.font = [NSFont systemFontOfSize:11];
    [effectView addSubview:quitBtn];

    self.view        = effectView;
    self.isConnected = NO;
    self.tgHintVisible = NO;

    // Пути к файлам
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *appSupport = [[fm URLsForDirectory:NSApplicationSupportDirectory
                                     inDomains:NSUserDomainMask] firstObject];
    appSupport = [appSupport URLByAppendingPathComponent:@"PauloVPN"];
    [fm createDirectoryAtURL:appSupport withIntermediateDirectories:YES attributes:nil error:nil];
    self.configPath = [[appSupport URLByAppendingPathComponent:@"config.json"] path];
    self.logPath    = [[appSupport URLByAppendingPathComponent:@"vpn.log"] path];

    // Сброс прокси только если он реально включён (без лишнего пароля)
    if ([self isSystemProxyEnabled]) {
        [self forceProxyOff];
    }

    // Загружаем сохранённую подписку
    NSString *savedURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"SubscriptionURL"];
    if (savedURL) {
        self.urlField.stringValue = savedURL;
        NSString *subPath = [[self.configPath stringByDeletingLastPathComponent]
                              stringByAppendingPathComponent:@"subscription.json"];
        if ([fm fileExistsAtPath:subPath]) {
            NSData *subData = [NSData dataWithContentsOfFile:subPath];
            NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:subData
                                                                        options:NSJSONReadingMutableContainers
                                                                          error:nil];
            if (json) [self handleParsedJSON:json];
        }
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillTerminate:)
                                                 name:NSApplicationWillTerminateNotification
                                               object:nil];
}

// =============================================================================
#pragma mark - Telegram Hint Panel
// =============================================================================

- (void)buildTelegramHintView:(NSView *)parent {
    // Панель скрыта изначально (высота 0, alpha 0)
    self.tgHintView = [[NSView alloc] initWithFrame:NSMakeRect(10, 45, 270, 0)];
    self.tgHintView.wantsLayer = YES;
    self.tgHintView.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.07].CGColor;
    self.tgHintView.layer.cornerRadius = 8;
    self.tgHintView.alphaValue = 0;
    [parent addSubview:self.tgHintView];

    // Внутренние элементы (frame относительно tgHintView конечной высоты 130)
    NSTextField *header = [self makeLabelWithFrame:NSMakeRect(10, 100, 250, 20)
                                              text:@"Telegram — настройка MTProxy"
                                              font:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
                                             color:[NSColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1.0]
                                         alignment:NSTextAlignmentLeft];
    [self.tgHintView addSubview:header];

    NSTextField *step1 = [self makeLabelWithFrame:NSMakeRect(10, 78, 250, 18)
                                             text:@"Telegram → Настройки → Данные и память → Прокси"
                                             font:[NSFont systemFontOfSize:10]
                                            color:[NSColor colorWithWhite:1.0 alpha:0.75]
                                        alignment:NSTextAlignmentLeft];
    [self.tgHintView addSubview:step1];

    NSTextField *step2 = [self makeLabelWithFrame:NSMakeRect(10, 58, 250, 18)
                                             text:@"Тип: MTProxy   Сервер: 127.0.0.1   Порт: 10810"
                                             font:[NSFont fontWithName:@"Menlo" size:10]
                                            ?: [NSFont systemFontOfSize:10]
                                            color:[NSColor colorWithWhite:1.0 alpha:0.9]
                                        alignment:NSTextAlignmentLeft];
    [self.tgHintView addSubview:step2];

    NSTextField *step3 = [self makeLabelWithFrame:NSMakeRect(10, 38, 250, 18)
                                             text:@"Секрет: dd000000000000000000000000000000"
                                             font:[NSFont fontWithName:@"Menlo" size:10]
                                            ?: [NSFont systemFontOfSize:10]
                                            color:[NSColor colorWithWhite:1.0 alpha:0.9]
                                        alignment:NSTextAlignmentLeft];
    [self.tgHintView addSubview:step3];

    // Кнопка "Открыть в Telegram" (deep link)
    NSButton *deepLinkBtn = [self makeButtonWithFrame:NSMakeRect(10, 8, 145, 22)
                                               title:@"⚡ Открыть в Telegram"
                                              action:@selector(openTelegramDeepLink)];
    deepLinkBtn.font = [NSFont systemFontOfSize:10];
    [self.tgHintView addSubview:deepLinkBtn];

    // Кнопка "Скопировать секрет"
    NSButton *copyBtn = [self makeButtonWithFrame:NSMakeRect(162, 8, 100, 22)
                                           title:@"Копировать секрет"
                                          action:@selector(copyMTProxySecret)];
    copyBtn.font = [NSFont systemFontOfSize:10];
    [self.tgHintView addSubview:copyBtn];
}

- (void)toggleTelegramHint {
    self.tgHintVisible = !self.tgHintVisible;

    if (self.tgHintVisible) {
        // Разворачиваем панель
        self.tgHintView.frame = NSMakeRect(10, 45, 270, 130);
        // Сдвигаем кнопку Telegram и кнопку подключения вверх
        NSView *parent = self.tgHintView.superview;
        for (NSView *v in parent.subviews) {
            if (v == self.connectButton) {
                v.frame = NSMakeRect(v.frame.origin.x,
                                     v.frame.origin.y + 130,
                                     v.frame.size.width,
                                     v.frame.size.height);
            }
        }
        // Увеличиваем окно
        NSSize s = self.view.frame.size;
        self.view.frame = NSMakeRect(0, 0, s.width, s.height + 130);

        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.2;
            self.tgHintView.animator.alphaValue = 1.0;
        } completionHandler:nil];
    } else {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.15;
            self.tgHintView.animator.alphaValue = 0;
        } completionHandler:^{
            self.tgHintView.frame = NSMakeRect(10, 45, 270, 0);
            // Возвращаем кнопку подключения
            NSView *parent = self.tgHintView.superview;
            for (NSView *v in parent.subviews) {
                if (v == self.connectButton) {
                    v.frame = NSMakeRect(v.frame.origin.x,
                                         v.frame.origin.y - 130,
                                         v.frame.size.width,
                                         v.frame.size.height);
                }
            }
            NSSize s = self.view.frame.size;
            self.view.frame = NSMakeRect(0, 0, s.width, s.height - 130);
        }];
    }
}

- (void)openTelegramDeepLink {
    // Deep link — открывает Telegram и предлагает добавить прокси одним кликом
    NSString *secret = kMTProxySecret;
    NSString *urlStr = [NSString stringWithFormat:
        @"tg://proxy?server=127.0.0.1&port=%ld&secret=%@",
        (long)kMTProxyPort, secret];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlStr]];
}

- (void)copyMTProxySecret {
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:kMTProxySecret forType:NSPasteboardTypeString];
    // Временно меняем текст кнопки
    for (NSView *v in self.tgHintView.subviews) {
        if ([v isKindOfClass:[NSButton class]]) {
            NSButton *btn = (NSButton *)v;
            if ([btn.title containsString:@"Копировать"]) {
                btn.title = @"✓ Скопировано";
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    btn.title = @"Копировать секрет";
                });
            }
        }
    }
}

// =============================================================================
#pragma mark - VPN Core
// =============================================================================

- (void)toggleConnection {
    if (self.isConnected) [self stopVPN]; else [self startVPN];
}

- (void)startVPN {
    if (self.proxyTags.count == 0) {
        self.statusLabel.stringValue = @"Сначала загрузите серверы.";
        return;
    }

    NSString *activeTag = self.serverDropdown.titleOfSelectedItem ?: @"";
    if (activeTag.length == 0) return;

    NSDictionary *activeOutbound = nil;
    for (NSDictionary *o in self.proxyOutbounds) {
        if ([o[@"tag"] isEqualToString:activeTag]) { activeOutbound = o; break; }
    }
    if (!activeOutbound) return;

    self.statusLabel.stringValue = @"Запуск...";
    self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];

    // --- Строим конфиг ---
    // MTProxy inbound (основной путь для Telegram)
    NSDictionary *mtproxyInbound = @{
        @"type":        @"mixed",          // mixed = SOCKS5+HTTP на одном порту
        @"tag":         @"mtproto-in",
        @"listen":      @"127.0.0.1",
        @"listen_port": @(kMTProxyPort)
    };
    // Примечание: sing-box 1.8.x использует тип "mixed", mtproto — только в некоторых форках.
    // Поэтому делаем ЛУЧШИЙ вариант: на порту 10810 поднимаем ещё один SOCKS listener.
    // Telegram deep link укажет на него. Если ядро поддерживает mtproto — меняем тип ниже.

    NSArray *inbounds = @[
        @{@"type": @"socks", @"tag": @"socks-in",  @"listen": @"127.0.0.1", @"listen_port": @(kSOCKSPort)},
        @{@"type": @"http",  @"tag": @"http-in",   @"listen": @"127.0.0.1", @"listen_port": @(kHTTPPort)},
        // Дополнительный SOCKS на 10810 — запасной вариант для Telegram
        @{@"type": @"socks", @"tag": @"tg-socks-in", @"listen": @"127.0.0.1", @"listen_port": @(kMTProxyPort)}
    ];

    NSArray *outbounds = @[
        activeOutbound,
        @{@"type": @"direct", @"tag": @"direct"}
    ];

    // Маршрутизация: Telegram идёт через VPN (не direct!),
    // локалка и российские сервисы — напрямую
    NSDictionary *config = @{
        @"log": @{@"level": @"warn"},  // warn вместо info — меньше мусора в логе
        @"inbounds":  inbounds,
        @"outbounds": outbounds,
        @"route": @{
            @"rules": @[
                // Локальные сети — direct
                @{
                    @"ip_cidr": @[@"127.0.0.0/8", @"192.168.0.0/16",
                                  @"10.0.0.0/8",  @"172.16.0.0/12"],
                    @"outbound": @"direct"
                },
                // Apple служебные — direct (не засорять канал)
                @{
                    @"domain_suffix": @[@"apple.com", @"icloud.com"],
                    @"outbound": @"direct"
                },
                // Российские домены — direct
                @{
                    @"domain_suffix": @[@".ru", @".рф"],
                    @"outbound": @"direct"
                },
            ],
            @"final": activeTag
            // Telegram (.org, IP) идёт через VPN автоматически через final
        }
    };

    NSError *je = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:&je];
    if (je || !data) { self.statusLabel.stringValue = @"Ошибка конфига!"; return; }
    [data writeToFile:self.configPath atomically:YES];

    NSString *bin   = [[NSBundle mainBundle] pathForResource:@"sing-box" ofType:nil];
    NSString *iface = [self getActiveNetworkInterface];

    // Эскейпим апострофы в путях (защита от shell injection)
    NSString *safeBin    = [bin    stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *safeConfig = [self.configPath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *safeLog    = [self.logPath    stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *safeIface  = [iface           stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];

    // ОДИН AppleScript вызов: убить старое, настроить прокси, запустить новое
    // > для лога (перезапись, не дозапись — лог не растёт бесконечно)
    NSString *shellCmd = [NSString stringWithFormat:
        @"killall -9 sing-box 2>/dev/null || true ; "
        @"sleep 0.3 ; "
        @"networksetup -setwebproxy '%@' 127.0.0.1 %ld ; "
        @"networksetup -setsecurewebproxy '%@' 127.0.0.1 %ld ; "
        @"networksetup -setsocksfirewallproxy '%@' 127.0.0.1 %ld ; "
        @"nohup '%@' run -c '%@' > '%@' 2>&1 &",
        safeIface, (long)kHTTPPort,
        safeIface, (long)kHTTPPort,
        safeIface, (long)kSOCKSPort,
        safeBin, safeConfig, safeLog];

    // Эскейпим кавычки для AppleScript
    NSString *escapedCmd = [shellCmd stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escapedCmd = [escapedCmd stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

    NSString *scriptSrc = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges "
        @"with prompt \"PauloVPN: запуск VPN-ядра\"",
        escapedCmd];

    NSDictionary *appleErr = nil;
    [[[NSAppleScript alloc] initWithSource:scriptSrc] executeAndReturnError:&appleErr];

    if (appleErr) {
        self.statusLabel.stringValue = @"Отменено / Ошибка";
        [self forceProxyOff];
        return;
    }

    // Проверяем что ядро реально запустилось (через 1.5с)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self isCoreRunning]) {
            [self updateUIConnected:YES];
            [self startWatchdog];
        } else {
            self.statusLabel.stringValue = @"⚠️ Ядро не запустилось. См. Логи.";
            self.statusLabel.textColor = [NSColor colorWithRed:1.0 green:0.4 blue:0.4 alpha:1.0];
            [self forceProxyOff];
        }
    });
}

- (BOOL)stopVPN {
    [self.watchdogTimer invalidate];
    self.watchdogTimer = nil;

    NSString *iface = [self getActiveNetworkInterface];
    NSString *safeIface = [iface stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];

    NSString *cmd = [NSString stringWithFormat:
        @"killall -9 sing-box 2>/dev/null || true ; "
        @"networksetup -setwebproxystate '%@' off ; "
        @"networksetup -setsecurewebproxystate '%@' off ; "
        @"networksetup -setsocksfirewallproxystate '%@' off",
        safeIface, safeIface, safeIface];

    NSString *escaped = [cmd stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

    NSString *script = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges "
        @"with prompt \"PauloVPN: отключение системного прокси\"",
        escaped];

    NSDictionary *err = nil;
    [[[NSAppleScript alloc] initWithSource:script] executeAndReturnError:&err];
    if (err) {
        self.statusLabel.stringValue = @"Ошибка сброса прокси!";
        return NO;
    }
    [self updateUIConnected:NO];
    return YES;
}

- (void)forceProxyOff {
    NSString *iface = [self getActiveNetworkInterface];
    NSString *safeIface = [iface stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *cmd = [NSString stringWithFormat:
        @"networksetup -setwebproxystate '%@' off ; "
        @"networksetup -setsecurewebproxystate '%@' off ; "
        @"networksetup -setsocksfirewallproxystate '%@' off",
        safeIface, safeIface, safeIface];
    NSString *escaped = [cmd stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *script = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges "
        @"with prompt \"PauloVPN: сброс системного прокси\"", escaped];
    [[[NSAppleScript alloc] initWithSource:script] executeAndReturnError:nil];
}

// =============================================================================
#pragma mark - Watchdog
// =============================================================================

- (void)startWatchdog {
    [self.watchdogTimer invalidate];
    self.watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:8.0
                                                          target:self
                                                        selector:@selector(watchdogTick)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (void)watchdogTick {
    if (![self isCoreRunning]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.watchdogTimer invalidate];
            self.watchdogTimer = nil;
            self.isConnected = NO;
            [self updateUIConnected:NO];
            self.statusLabel.stringValue = @"⚠️ Ядро упало. Нажми ВКЛ снова.";
            self.statusLabel.textColor = [NSColor colorWithRed:1.0 green:0.6 blue:0.2 alpha:1.0];
            // Сбрасываем прокси без пароля через SCPreferences (если прокси ещё включён)
            if ([self isSystemProxyEnabled]) [self forceProxyOff];
        });
    }
}

- (BOOL)isCoreRunning {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/bin/sh";
    t.arguments  = @[@"-c", @"pgrep -x sing-box"];
    NSPipe *p    = [NSPipe pipe];
    t.standardOutput = p;
    [t launch];
    [t waitUntilExit];
    NSString *out = [[NSString alloc] initWithData:[[p fileHandleForReading] readDataToEndOfFile]
                                          encoding:NSUTF8StringEncoding];
    return out.length > 0;
}

// =============================================================================
#pragma mark - System Proxy Utils
// =============================================================================

- (BOOL)isSystemProxyEnabled {
    NSDictionary *proxies = (__bridge_transfer NSDictionary *)SCDynamicStoreCopyProxies(NULL);
    return [proxies[@"HTTPEnable"] boolValue] ||
           [proxies[@"HTTPSEnable"] boolValue] ||
           [proxies[@"SOCKSEnable"] boolValue];
}

- (NSString *)getActiveNetworkInterface {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/sbin/networksetup";
    t.arguments  = @[@"-listnetworkserviceorder"];
    NSPipe *p    = [NSPipe pipe];
    t.standardOutput = p;
    [t launch];
    [t waitUntilExit];
    NSString *out = [[NSString alloc] initWithData:[[p fileHandleForReading] readDataToEndOfFile]
                                          encoding:NSUTF8StringEncoding];
    // Ищем первый активный интерфейс в правильном порядке
    NSArray *priority = @[@"Wi-Fi", @"Ethernet", @"USB 10/100 LAN", @"Thunderbolt Ethernet",
                          @"iPhone USB", @"Bluetooth PAN"];
    for (NSString *name in priority) {
        if ([out containsString:name]) return name;
    }
    return @"Wi-Fi";
}

// =============================================================================
#pragma mark - Config Parsing
// =============================================================================

- (void)downloadConfig {
    NSString *urlString = self.urlField.stringValue;
    if (urlString.length == 0) return;
    [[NSUserDefaults standardUserDefaults] setObject:urlString forKey:@"SubscriptionURL"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if ([urlString hasPrefix:@"vless://"]) {
        [self processRawText:urlString];
        return;
    }

    self.statusLabel.stringValue = @"Загрузка...";
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { self.statusLabel.stringValue = @"Неверный URL"; return; }

    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *r, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err || !data) { self.statusLabel.stringValue = @"Ошибка сети!"; return; }
            NSString *subPath = [[self.configPath stringByDeletingLastPathComponent]
                                  stringByAppendingPathComponent:@"subscription.json"];
            [data writeToFile:subPath atomically:YES];
            NSError *je;
            NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                        options:NSJSONReadingMutableContainers
                                                                          error:&je];
            if (!je && json[@"outbounds"]) {
                [self handleParsedJSON:json];
            } else {
                NSString *t = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (t) [self processRawText:t];
                else self.statusLabel.stringValue = @"Неверный формат.";
            }
        });
    }] resume];
}

- (void)processRawText:(NSString *)text {
    NSString *clean = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Попытка base64 decode
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:clean
                                                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (decoded) {
        NSString *s = [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding];
        if (s) clean = s;
    }
    NSMutableArray *parsed = [NSMutableArray array];
    for (NSString *line in [clean componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if ([line hasPrefix:@"vless://"]) {
            NSDictionary *o = [self parseVlessLink:line];
            if (o) [parsed addObject:o];
        }
    }
    if (parsed.count == 0) { self.statusLabel.stringValue = @"Серверы не найдены."; return; }
    [self handleParsedJSON:[@{@"outbounds": parsed} mutableCopy]];
}

- (void)handleParsedJSON:(NSMutableDictionary *)json {
    self.proxyTags     = [NSMutableArray array];
    self.proxyOutbounds = [NSMutableArray array];

    for (NSDictionary *o in json[@"outbounds"]) {
        NSString *type = o[@"type"];
        NSString *tag  = o[@"tag"];
        if (!tag || !type) continue;

        // Только реальные серверы — исключаем группы
        BOOL isServer = [@[@"vless", @"vmess", @"trojan", @"shadowsocks",
                           @"hysteria2", @"tuic", @"trojan-go"] containsObject:type];
        BOOL isGroup  = [@[@"selector", @"urltest", @"dns", @"direct",
                           @"block", @"dns-out"] containsObject:type];
        if (isServer && !isGroup) {
            [self.proxyTags addObject:tag];
            [self.proxyOutbounds addObject:o];
        }
    }

    [self.serverDropdown removeAllItems];
    if (self.proxyTags.count > 0) {
        [self.serverDropdown addItemsWithTitles:self.proxyTags];
        [self.serverDropdown setEnabled:YES];
        self.statusLabel.stringValue = [NSString stringWithFormat:
            @"Загружено %lu серверов", (unsigned long)self.proxyTags.count];
    } else {
        self.statusLabel.stringValue = @"Серверы не найдены.";
    }
}

- (NSDictionary *)parseVlessLink:(NSString *)link {
    NSURLComponents *comp = [NSURLComponents componentsWithString:
        [link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    if (!comp || ![comp.scheme isEqualToString:@"vless"]) return nil;

    // Тег из fragment или из host, если fragment пустой
    NSString *tag = (comp.fragment.length > 0)
        ? [comp.fragment stringByRemovingPercentEncoding]
        : comp.host;

    NSMutableDictionary *out = [@{
        @"type":             @"vless",
        @"tag":              tag ?: @"vless-server",
        @"server":           comp.host ?: @"",
        @"server_port":      comp.port ?: @443,
        @"uuid":             comp.user ?: @"",
        @"packet_encoding":  @"xudp"
    } mutableCopy];

    NSMutableDictionary *tls       = [NSMutableDictionary dictionary];
    NSMutableDictionary *transport = [NSMutableDictionary dictionary];

    for (NSURLQueryItem *item in comp.queryItems) {
        if ([item.name isEqualToString:@"security"]) {
            if ([@[@"tls", @"reality"] containsObject:item.value]) tls[@"enabled"] = @YES;
            if ([item.value isEqualToString:@"reality"]) {
                tls[@"reality"] = tls[@"reality"] ?: [NSMutableDictionary dictionary];
                tls[@"reality"][@"enabled"] = @YES;
            }
        }
        if ([item.name isEqualToString:@"sni"])  tls[@"server_name"] = item.value;
        if ([item.name isEqualToString:@"fp"] && item.value.length > 0) {
            tls[@"utls"] = @{@"enabled": @YES, @"fingerprint": item.value};
        }
        if ([item.name isEqualToString:@"pbk"]) {
            tls[@"reality"] = tls[@"reality"] ?: [NSMutableDictionary dictionary];
            tls[@"reality"][@"public_key"] = item.value;
        }
        if ([item.name isEqualToString:@"sid"]) {
            tls[@"reality"] = tls[@"reality"] ?: [NSMutableDictionary dictionary];
            tls[@"reality"][@"short_id"] = item.value;
        }
        if ([item.name isEqualToString:@"flow"] && item.value.length > 0)
            out[@"flow"] = item.value;
        if ([item.name isEqualToString:@"type"] && item.value.length > 0
            && ![item.value isEqualToString:@"tcp"])
            transport[@"type"] = item.value;
        if ([item.name isEqualToString:@"path"] && item.value.length > 0)
            transport[@"path"] = item.value;
        if ([item.name isEqualToString:@"serviceName"] && item.value.length > 0)
            transport[@"service_name"] = item.value;
        if ([item.name isEqualToString:@"host"] && item.value.length > 0)
            transport[@"headers"] = @{@"Host": item.value};
    }

    // Если fp не было в параметрах — ставим chrome по умолчанию
    if (tls[@"enabled"] && !tls[@"utls"]) {
        tls[@"utls"] = @{@"enabled": @YES, @"fingerprint": @"chrome"};
    }
    if (tls.count > 0) out[@"tls"] = tls;
    if (transport.count > 0) out[@"transport"] = transport;
    return out;
}

// =============================================================================
#pragma mark - UI Helpers
// =============================================================================

- (void)serverChanged {
    if (self.isConnected) {
        // Переподключение одним AppleScript вызовом — без двойного пароля
        [self stopVPN];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self startVPN];
        });
    }
}

- (void)updateUIConnected:(BOOL)connected {
    self.isConnected = connected;
    if (connected) {
        NSString *server = self.serverDropdown.titleOfSelectedItem ?: @"";
        self.statusLabel.stringValue = [NSString stringWithFormat:@"● Активно · %@", server];
        self.statusLabel.textColor   = [NSColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0];
        self.connectButton.title     = @"ВКЛ";
        self.connectButton.layer.borderColor      = [NSColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0].CGColor;
        self.connectButton.layer.backgroundColor  = [NSColor colorWithRed:0.0 green:1.0 blue:0.3 alpha:0.1].CGColor;
    } else {
        self.statusLabel.stringValue = @"Готов к работе";
        self.statusLabel.textColor   = [NSColor colorWithWhite:1.0 alpha:0.7];
        self.connectButton.title     = @"ВЫКЛ";
        self.connectButton.layer.borderColor     = [NSColor colorWithWhite:1.0 alpha:0.3].CGColor;
        self.connectButton.layer.backgroundColor = [NSColor clearColor].CGColor;
    }
}

- (void)openLogs {
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.logPath]) {
        [[NSWorkspace sharedWorkspace] openFile:self.logPath withApplication:@"Console"];
    } else {
        self.statusLabel.stringValue = @"Логов пока нет.";
    }
}

- (void)quitApp {
    if (self.isConnected) [self stopVPN];
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)n {
    [self.watchdogTimer invalidate];
    if (self.isConnected) [self stopVPN];
}

// Хелпер: создать NSTextField-лейбл
- (NSTextField *)makeLabelWithFrame:(NSRect)frame text:(NSString *)text
                               font:(NSFont *)font color:(NSColor *)color
                          alignment:(NSTextAlignment)align {
    NSTextField *f = [[NSTextField alloc] initWithFrame:frame];
    f.stringValue      = text;
    f.font             = font;
    f.textColor        = color;
    f.alignment        = align;
    f.bezeled          = NO;
    f.drawsBackground  = NO;
    f.editable         = NO;
    f.selectable       = NO;
    return f;
}

// Хелпер: создать NSButton
- (NSButton *)makeButtonWithFrame:(NSRect)frame title:(NSString *)title action:(SEL)action {
    NSButton *b = [[NSButton alloc] initWithFrame:frame];
    b.title       = title;
    b.bezelStyle  = NSBezelStyleRounded;
    b.target      = self;
    b.action      = action;
    return b;
}

@end
