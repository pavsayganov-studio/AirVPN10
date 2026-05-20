#import "ViewController.h"

@interface ViewController ()
@property (strong) NSTextField *urlField;
@property (strong) NSTextField *statusLabel;
@property (strong) NSButton *connectButton;
@property (strong) NSPopUpButton *serverDropdown;
@property (strong) NSButton *stealthCheckbox;
@property (strong) NSString *configPath;
@property (strong) NSString *logPath;
@property (strong) NSMutableDictionary *downloadedJSON;
@property (strong) NSMutableArray *proxyTags;
@property (strong) NSMutableArray *proxyOutbounds;
@property (assign) BOOL isConnected;
@property (strong) NSTask *singBoxTask;
@end

@implementation ViewController

- (void)loadView {
    NSVisualEffectView *effectView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 320, 480)];
    effectView.material = NSVisualEffectMaterialDark;
    effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effectView.state = NSVisualEffectStateActive;
    
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 410, 320, 30)];
    titleLabel.stringValue = @"PauloVPN";
    titleLabel.alignment = NSTextAlignmentCenter;
    titleLabel.bezeled = NO;
    titleLabel.drawsBackground = NO;
    titleLabel.editable = NO;
    titleLabel.font = [NSFont fontWithName:@"HelveticaNeue-Light" size:26] ?: [NSFont systemFontOfSize:26];
    titleLabel.textColor = [NSColor whiteColor];
    [effectView addSubview:titleLabel];
    
    self.urlField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 350, 280, 24)];
    self.urlField.placeholderString = @"Вставьте vless:// или подписку...";
    [effectView addSubview:self.urlField];
    
    NSButton *importBtn = [[NSButton alloc] initWithFrame:NSMakeRect(80, 310, 160, 30)];
    importBtn.title = @"Загрузить серверы";
    importBtn.bezelStyle = NSBezelStyleRounded;
    importBtn.target = self;
    importBtn.action = @selector(downloadConfig);
    [effectView addSubview:importBtn];
    
    self.serverDropdown = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 260, 280, 26) pullsDown:NO];
    [self.serverDropdown addItemWithTitle:@"Серверы не загружены"];
    [self.serverDropdown setEnabled:NO];
    self.serverDropdown.target = self;
    self.serverDropdown.action = @selector(serverChanged);
    [effectView addSubview:self.serverDropdown];
    
    self.stealthCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 220, 280, 20)];
    [self.stealthCheckbox setButtonType:NSButtonTypeSwitch];
    self.stealthCheckbox.title = @"Умный режим (Только заблокированные)";
    self.stealthCheckbox.state = NSControlStateValueOn;
    self.stealthCheckbox.target = self;
    self.stealthCheckbox.action = @selector(stealthChanged);
    [effectView addSubview:self.stealthCheckbox];
    
    // [NEW]: Подсказка для Telegram
    NSTextField *telegramHint = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 195, 280, 16)];
    telegramHint.stringValue = @"Telegram: Settings → Proxy → SOCKS5 127.0.0.1:10808";
    telegramHint.alignment = NSTextAlignmentCenter;
    telegramHint.bezeled = NO;
    telegramHint.drawsBackground = NO;
    telegramHint.editable = NO;
    telegramHint.font = [NSFont systemFontOfSize:9];
    telegramHint.textColor = [NSColor colorWithWhite:1.0 alpha:0.4];
    [effectView addSubview:telegramHint];

    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 178, 320, 16)];
    self.statusLabel.stringValue = @"Готов к работе";
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.bezeled = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.editable = NO;
    self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
    [effectView addSubview:self.statusLabel];
    
    self.connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(105, 55, 110, 110)];
    self.connectButton.title = @"ВЫКЛ";
    self.connectButton.font = [NSFont systemFontOfSize:22 weight:NSFontWeightMedium];
    self.connectButton.bordered = NO;
    self.connectButton.wantsLayer = YES;
    self.connectButton.layer.cornerRadius = 55;
    self.connectButton.layer.borderWidth = 1.5;
    self.connectButton.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.3].CGColor;
    self.connectButton.layer.backgroundColor = [NSColor clearColor].CGColor;
    self.connectButton.target = self;
    self.connectButton.action = @selector(toggleConnection);
    [effectView addSubview:self.connectButton];
    
    NSButton *logBtn = [[NSButton alloc] initWithFrame:NSMakeRect(20, 15, 80, 25)];
    logBtn.title = @"Логи";
    logBtn.bezelStyle = NSBezelStyleRounded;
    logBtn.target = self;
    logBtn.action = @selector(openLogs);
    [effectView addSubview:logBtn];
    
    NSButton *quitBtn = [[NSButton alloc] initWithFrame:NSMakeRect(220, 15, 80, 25)];
    quitBtn.title = @"Выйти";
    quitBtn.bezelStyle = NSBezelStyleRounded;
    quitBtn.target = self;
    quitBtn.action = @selector(quitApp);
    [effectView addSubview:quitBtn];
    
    self.view = effectView;
    self.isConnected = NO;
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *appSupport = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    appSupport = [appSupport URLByAppendingPathComponent:@"PauloVPN"];
    [fm createDirectoryAtURL:appSupport withIntermediateDirectories:YES attributes:nil error:nil];
    self.configPath = [[appSupport URLByAppendingPathComponent:@"config.json"] path];
    self.logPath = [[appSupport URLByAppendingPathComponent:@"vpn.log"] path];
    
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
            if (json) { [self handleParsedJSON:json]; }
        }
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillTerminate:)
                                                 name:NSApplicationWillTerminateNotification
                                               object:nil];
}

- (void)emergencyProxyReset {
    NSString *interface = [self getActiveNetworkInterface];
    NSString *cmd = [NSString stringWithFormat:
        @"networksetup -setwebproxystate '%@' off ; "
        @"networksetup -setsecurewebproxystate '%@' off ; "
        @"networksetup -setsocksfirewallproxystate '%@' off",
        interface, interface, interface];
    NSString *src = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges", cmd];
    [[[NSAppleScript alloc] initWithSource:src] executeAndReturnError:nil];
}

- (void)quitApp {
    if (self.isConnected) { [self stopVPN]; }
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.isConnected) { [self stopVPN]; }
}

- (void)openLogs {
    [[NSWorkspace sharedWorkspace] openFile:self.logPath withApplication:@"Console"];
}

- (void)serverChanged {
    if (self.isConnected) { [self startCoreOnly]; }
}

- (void)stealthChanged {
    if (self.isConnected) { [self startCoreOnly]; }
}

- (NSDictionary *)parseVlessLink:(NSString *)link {
    NSURLComponents *comp = [NSURLComponents componentsWithString:
        [link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    if (!comp || ![comp.scheme isEqualToString:@"vless"]) return nil;
    NSString *tag = comp.fragment
        ? [comp.fragment stringByRemovingPercentEncoding]
        : comp.host;
    NSMutableDictionary *outbound = [@{
        @"type":             @"vless",
        @"tag":              tag ?: @"vless-server",
        @"server":           comp.host ?: @"",
        @"server_port":      comp.port ?: @443,
        @"uuid":             comp.user ?: @"",
        @"packet_encoding":  @"xudp"
    } mutableCopy];
    NSMutableDictionary *tls = [NSMutableDictionary dictionary];
    NSMutableDictionary *transport = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in comp.queryItems) {
        if ([item.name isEqualToString:@"security"]) {
            if ([item.value isEqualToString:@"tls"] ||
                [item.value isEqualToString:@"reality"]) {
                tls[@"enabled"] = @YES;
            }
            if ([item.value isEqualToString:@"reality"]) {
                if (!tls[@"reality"]) tls[@"reality"] = [NSMutableDictionary dictionary];
                tls[@"reality"][@"enabled"] = @YES;
            }
        }
        if ([item.name isEqualToString:@"sni"])  tls[@"server_name"] = item.value;
        if ([item.name isEqualToString:@"pbk"]) {
            if (!tls[@"reality"]) tls[@"reality"] = [NSMutableDictionary dictionary];
            tls[@"reality"][@"public_key"] = item.value;
        }
        if ([item.name isEqualToString:@"sid"]) {
            if (!tls[@"reality"]) tls[@"reality"] = [NSMutableDictionary dictionary];
            tls[@"reality"][@"short_id"] = item.value;
        }
        if ([item.name isEqualToString:@"flow"] && item.value.length > 0)
            outbound[@"flow"] = item.value;
        if ([item.name isEqualToString:@"type"] && item.value.length > 0 &&
            ![item.value isEqualToString:@"tcp"])
            transport[@"type"] = item.value;
        if ([item.name isEqualToString:@"path"] && item.value.length > 0)
            transport[@"path"] = item.value;
        if ([item.name isEqualToString:@"serviceName"] && item.value.length > 0)
            transport[@"service_name"] = item.value;
        if ([item.name isEqualToString:@"host"] && item.value.length > 0)
            transport[@"headers"] = @{@"Host": item.value};
    }
    if (tls[@"enabled"])
        tls[@"utls"] = @{@"enabled": @YES, @"fingerprint": @"chrome"};
    if (tls.count > 0) outbound[@"tls"] = tls;
    if (transport.count > 0) outbound[@"transport"] = transport;
    return outbound;
}

- (void)processRawText:(NSString *)text {
    NSString *clean = [text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:clean
                                                         options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (decoded) {
        NSString *s = [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding];
        if (s) clean = s;
    }
    NSMutableArray *parsed = [NSMutableArray array];
    for (NSString *line in [clean componentsSeparatedByCharactersInSet:
                             [NSCharacterSet newlineCharacterSet]]) {
        if ([line hasPrefix:@"vless://"]) {
            NSDictionary *o = [self parseVlessLink:line];
            if (o) [parsed addObject:o];
        }
    }
    if (parsed.count == 0) { self.statusLabel.stringValue = @"Серверы не найдены."; return; }
    [self handleParsedJSON:[@{@"log": @{@"level": @"warn"}, @"outbounds": parsed} mutableCopy]];
}

- (void)handleParsedJSON:(NSMutableDictionary *)json {
    self.downloadedJSON = json;
    self.proxyTags = [NSMutableArray array];
    self.proxyOutbounds = [NSMutableArray array];
    for (NSDictionary *out in json[@"outbounds"]) {
        NSString *type = out[@"type"];
        NSString *tag  = out[@"tag"];
        if (tag && ([type isEqualToString:@"vless"]    ||
                    [type isEqualToString:@"vmess"]    ||
                    [type isEqualToString:@"trojan"]   ||
                    [type isEqualToString:@"shadowsocks"])) {
            [self.proxyTags addObject:tag];
            [self.proxyOutbounds addObject:out];
        }
    }
    [self.serverDropdown removeAllItems];
    if (self.proxyTags.count > 0) {
        [self.serverDropdown addItemWithTitle:@"⚡️ Авто (Умный выбор)"];
        [self.serverDropdown addItemsWithTitles:self.proxyTags];
        [self.serverDropdown setEnabled:YES];
        self.statusLabel.stringValue = [NSString stringWithFormat:
            @"Загружено %lu серверов", (unsigned long)self.proxyTags.count];
    } else {
        self.statusLabel.stringValue = @"Серверы не найдены.";
    }
}

- (void)downloadConfig {
    NSString *urlString = self.urlField.stringValue;
    if (urlString.length == 0) return;
    [[NSUserDefaults standardUserDefaults] setObject:urlString forKey:@"SubscriptionURL"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if ([urlString hasPrefix:@"vless://"]) { [self processRawText:urlString]; return; }
    self.statusLabel.stringValue = @"Загрузка...";
    NSURL *url = [NSURL URLWithString:urlString];
    [[[NSURLSession sharedSession] dataTaskWithURL:url
                                completionHandler:^(NSData *data, NSURLResponse *r, NSError *err) {
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
                else   self.statusLabel.stringValue = @"Неверный формат.";
            }
        });
    }] resume];
}

- (void)toggleConnection {
    if (self.isConnected) { [self stopVPN]; } else { [self startVPN]; }
}

- (NSString *)getActiveNetworkInterface {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/sbin/networksetup";
    t.arguments  = @[@"-listnetworkserviceorder"];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    [t launch];
    NSString *out = [[NSString alloc] initWithData:[[p fileHandleForReading] readDataToEndOfFile]
                                          encoding:NSUTF8StringEncoding];
    if ([out containsString:@"Wi-Fi"])    return @"Wi-Fi";
    if ([out containsString:@"Ethernet"]) return @"Ethernet";
    return @"Wi-Fi";
}

- (void)startCoreOnly {
    if (self.singBoxTask && [self.singBoxTask isRunning]) {
        [self.singBoxTask terminate];
        [self.singBoxTask waitUntilExit];
    }
    
    NSString *selectedTitle  = self.serverDropdown.titleOfSelectedItem;
    BOOL      isAuto         = [selectedTitle isEqualToString:@"⚡️ Авто (Умный выбор)"];
    NSString *activeProxyTag = isAuto ? @"auto-switch" : selectedTitle;
    
    NSMutableArray *outbounds = [NSMutableArray array];

    // [FIX 1]: urltest на порту 443 — порт 80 блокируется TSPU через туннель
    if (isAuto) {
        [outbounds addObject:@{
            @"type":      @"urltest",
            @"tag":       @"auto-switch",
            @"outbounds": self.proxyTags,
            @"url":       @"https://www.gstatic.com/generate_204",
            @"interval":  @"30s",   // быстрее реагирует на сбой сервера
            @"tolerance": @50
        }];
    }
    [outbounds addObjectsFromArray:self.proxyOutbounds];
    [outbounds addObject:@{@"type": @"direct", @"tag": @"direct"}];
    [outbounds addObject:@{@"type": @"dns",    @"tag": @"dns-out"}];

    // Адрес VPN-сервера для правила direct (чтобы не зациклить)
    NSString *activeServerHost = @"";
    for (NSDictionary *o in self.proxyOutbounds) {
        if ([o[@"tag"] isEqualToString:activeProxyTag]) {
            activeServerHost = o[@"server"] ?: @"";
            break;
        }
    }

    // [FIX 2]: UDP DNS 8.8.8.8 через direct — ноль зависимостей от туннеля
    NSDictionary *dnsConfig = @{
        @"servers": @[
            @{@"tag": @"remote-dns", @"address": @"8.8.8.8", @"detour": @"direct"},
            @{@"tag": @"local-dns",  @"address": @"local",   @"detour": @"direct"}
        ],
        @"rules": @[
            @{@"domain_suffix": @[@"gsupport.support"],
              @"server": @"local-dns"},
            @{@"domain_suffix": @[@".ru", @".su", @".рф"],
              @"server": @"local-dns"}
        ]
    };

    // Routing rules
    NSMutableArray *rules = [NSMutableArray array];
    [rules addObject:@{@"protocol": @[@"dns"], @"outbound": @"dns-out"}];
    if (activeServerHost.length > 0) {
        [rules addObject:@{@"domain": @[activeServerHost], @"outbound": @"direct"}];
    }

    NSDictionary *routeConfig;

    if (self.stealthCheckbox.state == NSControlStateValueOn) {
        // Умный режим
        NSArray *blockedDomains = @[
            @"telegram.org", @"t.me", @"telegram.me", @"tdesktop.com",
            @"whatsapp.com", @"whatsapp.net",
            @"discord.com", @"discordapp.com", @"discord.gg",
            @"youtube.com", @"youtu.be", @"ytimg.com",
            @"googlevideo.com", @"ggpht.com",
            @"openai.com", @"chatgpt.com", @"oaistatic.com", @"oaiusercontent.com",
            @"anthropic.com", @"claude.ai",
            @"gemini.google.com", @"ai.google.dev",
            @"instagram.com", @"cdninstagram.com",
            @"facebook.com", @"fbcdn.net",
            @"twitter.com", @"x.com", @"twimg.com",
            @"github.com", @"githubusercontent.com",
            @"medium.com", @"meduza.io", @"svoboda.org",
            @"rutracker.org", @"rutracker.cc",
            @"spotify.com", @"scdn.co"
        ];
        NSArray *telegramIPs = @[
            @"91.108.4.0/22",  @"91.108.8.0/22",   @"91.108.12.0/22",
            @"91.108.16.0/22", @"91.108.20.0/22",   @"91.108.36.0/23",
            @"91.108.56.0/22", @"149.154.160.0/20", @"149.154.164.0/22",
            @"149.154.172.0/22", @"185.76.8.0/22"
        ];
        [rules addObject:@{@"domain_suffix": blockedDomains, @"outbound": activeProxyTag}];
        [rules addObject:@{@"ip_cidr": telegramIPs,          @"outbound": activeProxyTag}];
        routeConfig = @{
            @"rules":                rules,
            @"final":                @"direct",
            @"auto_detect_interface": @YES
        };
    } else {
        // Глобальный режим
        routeConfig = @{
            @"rules":                rules,
            @"final":                activeProxyTag,
            @"auto_detect_interface": @YES
        };
    }

    NSDictionary *goldConfig = @{
        @"log":      @{@"level": @"warn"},
        @"inbounds": @[
            @{@"type": @"socks", @"tag": @"socks-in",
              @"listen": @"127.0.0.1", @"listen_port": @10808},
            @{@"type": @"http",  @"tag": @"http-in",
              @"listen": @"127.0.0.1", @"listen_port": @10809}
        ],
        @"outbounds": outbounds,
        @"dns":       dnsConfig,
        @"route":     routeConfig
    };

    NSError *je = nil;
    NSData  *finalData = [NSJSONSerialization dataWithJSONObject:goldConfig options:0 error:&je];
    if (je || !finalData) { self.statusLabel.stringValue = @"Ошибка конфига!"; return; }
    [finalData writeToFile:self.configPath atomically:YES];

    NSString *bin = [[NSBundle mainBundle] pathForResource:@"sing-box" ofType:nil];
    self.singBoxTask = [[NSTask alloc] init];
    self.singBoxTask.launchPath = bin;
    self.singBoxTask.arguments  = @[@"run", @"-c", self.configPath];

    [[NSFileManager defaultManager] createFileAtPath:self.logPath contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
    self.singBoxTask.standardOutput = fh;
    self.singBoxTask.standardError  = fh;

    __weak typeof(self) ws = self;
    self.singBoxTask.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ws.isConnected) {
                ws.statusLabel.stringValue = @"Сбой ядра! Перезапустите.";
                ws.statusLabel.textColor   = [NSColor redColor];
                [ws forceProxyOff];
                [ws updateUIConnected:NO];
            }
        });
    };
    [self.singBoxTask launch];
}

- (void)startVPN {
    if (!self.downloadedJSON || self.proxyTags.count == 0) {
        self.statusLabel.stringValue = @"Сначала загрузите серверы."; return;
    }
    self.statusLabel.stringValue = @"Запуск ядра...";
    [self startCoreOnly];

    NSString *iface = [self getActiveNetworkInterface];
    NSString *cmd   = [NSString stringWithFormat:
        @"networksetup -setwebproxy '%@' 127.0.0.1 10809 ; "
        @"networksetup -setsecurewebproxy '%@' 127.0.0.1 10809 ; "
        @"networksetup -setsocksfirewallproxy '%@' 127.0.0.1 10808",
        iface, iface, iface];
    NSString *src = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges", cmd];
    NSDictionary *err = nil;
    [[[NSAppleScript alloc] initWithSource:src] executeAndReturnError:&err];
    if (!err) {
        [self updateUIConnected:YES];
    } else {
        self.statusLabel.stringValue = @"Отменено / Ошибка";
        [self forceProxyOff];
    }
}

- (void)forceProxyOff {
    NSString *iface = [self getActiveNetworkInterface];
    NSString *cmd   = [NSString stringWithFormat:
        @"networksetup -setwebproxystate '%@' off ; "
        @"networksetup -setsecurewebproxystate '%@' off ; "
        @"networksetup -setsocksfirewallproxystate '%@' off",
        iface, iface, iface];
    NSString *src = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges", cmd];
    [[[NSAppleScript alloc] initWithSource:src] executeAndReturnError:nil];
}

- (BOOL)stopVPN {
    if (self.singBoxTask && [self.singBoxTask isRunning])
        [self.singBoxTask terminate];
    NSString *iface = [self getActiveNetworkInterface];
    NSString *cmd   = [NSString stringWithFormat:
        @"networksetup -setwebproxystate '%@' off ; "
        @"networksetup -setsecurewebproxystate '%@' off ; "
        @"networksetup -setsocksfirewallproxystate '%@' off",
        iface, iface, iface];
    NSString *src = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges", cmd];
    NSDictionary *err = nil;
    [[[NSAppleScript alloc] initWithSource:src] executeAndReturnError:&err];
    if (err) { self.statusLabel.stringValue = @"Ошибка сброса прокси!"; return NO; }
    [self updateUIConnected:NO];
    return YES;
}

- (void)updateUIConnected:(BOOL)connected {
    self.isConnected = connected;
    if (connected) {
        self.statusLabel.stringValue = self.stealthCheckbox.state == NSControlStateValueOn
            ? @"Подключено (Умный режим)"
            : @"Подключено (Глобально)";
        self.statusLabel.textColor = [NSColor greenColor];
        self.connectButton.title = @"ВКЛ";
        self.connectButton.layer.borderColor = [NSColor greenColor].CGColor;
        self.connectButton.layer.backgroundColor =
            [NSColor colorWithRed:0 green:1 blue:0 alpha:0.1].CGColor;
    } else {
        self.statusLabel.stringValue = @"Готов к работе";
        self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
        self.connectButton.title = @"ВЫКЛ";
        self.connectButton.layer.borderColor =
            [NSColor colorWithWhite:1.0 alpha:0.3].CGColor;
        self.connectButton.layer.backgroundColor = [NSColor clearColor].CGColor;
    }
}
@end
