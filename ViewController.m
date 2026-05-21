#import "ViewController.h"
#import <SystemConfiguration/SystemConfiguration.h>

@interface ViewController ()
@property (strong) NSTextField *urlField;
@property (strong) NSTextField *statusLabel;
@property (strong) NSButton *connectButton;
@property (strong) NSPopUpButton *serverDropdown;
@property (strong) NSString *configPath;
@property (strong) NSString *logPath;
@property (strong) NSMutableDictionary *downloadedJSON;
@property (strong) NSMutableArray *proxyTags;
@property (strong) NSMutableArray *proxyOutbounds;
@property (assign) BOOL isConnected;
@end

@implementation ViewController

- (void)loadView {
    NSVisualEffectView *effectView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 280, 350)];
    effectView.material = NSVisualEffectMaterialDark;
    effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effectView.state = NSVisualEffectStateActive;

    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 310, 280, 30)];
    titleLabel.stringValue = @"PauloVPN";
    titleLabel.alignment = NSTextAlignmentCenter;
    titleLabel.bezeled = NO;
    titleLabel.drawsBackground = NO;
    titleLabel.editable = NO;
    titleLabel.font = [NSFont fontWithName:@"HelveticaNeue-Light" size:24] ?: [NSFont systemFontOfSize:24];
    titleLabel.textColor = [NSColor whiteColor];
    [effectView addSubview:titleLabel];

    self.urlField = [[NSTextField alloc] initWithFrame:NSMakeRect(15, 260, 250, 24)];
    self.urlField.placeholderString = @"Ссылка vless:// или подписку...";
    [effectView addSubview:self.urlField];

    NSButton *importBtn = [[NSButton alloc] initWithFrame:NSMakeRect(60, 225, 160, 30)];
    importBtn.title = @"Загрузить серверы";
    importBtn.bezelStyle = NSBezelStyleRounded;
    importBtn.target = self;
    importBtn.action = @selector(downloadConfig);
    [effectView addSubview:importBtn];

    self.serverDropdown = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(15, 185, 250, 26) pullsDown:NO];
    [self.serverDropdown addItemWithTitle:@"Серверы не загружены"];
    [self.serverDropdown setEnabled:NO];
    self.serverDropdown.target = self;
    self.serverDropdown.action = @selector(serverChanged);
    [effectView addSubview:self.serverDropdown];

    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 150, 280, 16)];
    self.statusLabel.stringValue = @"Готов к работе";
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.bezeled = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.editable = NO;
    self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
    [effectView addSubview:self.statusLabel];

    self.connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(95, 45, 90, 90)];
    self.connectButton.title = @"ВЫКЛ";
    self.connectButton.font = [NSFont systemFontOfSize:18 weight:NSFontWeightMedium];
    self.connectButton.bordered = NO;
    self.connectButton.wantsLayer = YES;
    self.connectButton.layer.cornerRadius = 45;
    self.connectButton.layer.borderWidth = 1.5;
    self.connectButton.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.3].CGColor;
    self.connectButton.layer.backgroundColor = [NSColor clearColor].CGColor;
    self.connectButton.target = self;
    self.connectButton.action = @selector(toggleConnection);
    [effectView addSubview:self.connectButton];

    NSButton *logBtn = [[NSButton alloc] initWithFrame:NSMakeRect(15, 10, 60, 25)];
    logBtn.title = @"Логи";
    logBtn.bezelStyle = NSBezelStyleRounded;
    logBtn.target = self;
    logBtn.action = @selector(openLogs);
    [effectView addSubview:logBtn];

    NSButton *quitBtn = [[NSButton alloc] initWithFrame:NSMakeRect(205, 10, 60, 25)];
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
    self.logPath    = [[appSupport URLByAppendingPathComponent:@"vpn.log"] path];

    // Сброс прокси при старте (если остались от прошлого краша)
    [self forceProxyOff];

    NSString *savedURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"SubscriptionURL"];
    if (savedURL) {
        self.urlField.stringValue = savedURL;
        NSString *subPath = [[self.configPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"subscription.json"];
        if ([fm fileExistsAtPath:subPath]) {
            NSData *subData = [NSData dataWithContentsOfFile:subPath];
            NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:subData options:NSJSONReadingMutableContainers error:nil];
            if (json) [self handleParsedJSON:json];
        }
    }

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:nil];
}

- (void)quitApp {
    if (self.isConnected) [self stopVPN];
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)n {
    if (self.isConnected) [self stopVPN];
}

- (void)openLogs {
    [[NSWorkspace sharedWorkspace] openFile:self.logPath withApplication:@"Console"];
}

- (void)serverChanged {
    if (self.isConnected) {
        [self stopVPN];
        [self startVPN];
    }
}

- (NSDictionary *)parseVlessLink:(NSString *)link {
    NSURLComponents *comp = [NSURLComponents componentsWithString:[link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    if (!comp || ![comp.scheme isEqualToString:@"vless"]) return nil;

    NSString *tag = comp.fragment ? [comp.fragment stringByRemovingPercentEncoding] : comp.host;
    NSMutableDictionary *out = [@{ @"type": @"vless", @"tag": tag ?: @"vless-server", @"server": comp.host ?: @"", @"server_port": comp.port ?: @443, @"uuid": comp.user ?: @"", @"packet_encoding": @"xudp" } mutableCopy];

    NSMutableDictionary *tls = [NSMutableDictionary dictionary];
    NSMutableDictionary *transport = [NSMutableDictionary dictionary];

    for (NSURLQueryItem *item in comp.queryItems) {
        if ([item.name isEqualToString:@"security"]) {
            if ([item.value isEqualToString:@"tls"] || [item.value isEqualToString:@"reality"]) tls[@"enabled"] = @YES;
            if ([item.value isEqualToString:@"reality"]) {
                if (!tls[@"reality"]) tls[@"reality"] = [NSMutableDictionary dictionary];
                tls[@"reality"][@"enabled"] = @YES;
            }
        }
        if ([item.name isEqualToString:@"sni"]) tls[@"server_name"] = item.value;
        if ([item.name isEqualToString:@"pbk"]) {
            if (!tls[@"reality"]) tls[@"reality"] = [NSMutableDictionary dictionary];
            tls[@"reality"][@"public_key"] = item.value;
        }
        if ([item.name isEqualToString:@"sid"]) {
            if (!tls[@"reality"]) tls[@"reality"] = [NSMutableDictionary dictionary];
            tls[@"reality"][@"short_id"] = item.value;
        }
        if ([item.name isEqualToString:@"flow"] && item.value.length > 0) out[@"flow"] = item.value;
        if ([item.name isEqualToString:@"type"] && item.value.length > 0 && ![item.value isEqualToString:@"tcp"]) transport[@"type"] = item.value;
        if ([item.name isEqualToString:@"path"] && item.value.length > 0) transport[@"path"] = item.value;
        if ([item.name isEqualToString:@"serviceName"] && item.value.length > 0) transport[@"service_name"] = item.value;
        if ([item.name isEqualToString:@"host"] && item.value.length > 0) transport[@"headers"] = @{@"Host": item.value};
    }

    if (tls[@"enabled"]) tls[@"utls"] = @{@"enabled": @YES, @"fingerprint": @"chrome"};
    if (tls.count > 0) out[@"tls"] = tls;
    if (transport.count > 0) out[@"transport"] = transport;
    return out;
}

- (void)processRawText:(NSString *)text {
    NSString *clean = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:clean options:NSDataBase64DecodingIgnoreUnknownCharacters];
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
    self.proxyTags = [NSMutableArray array];
    self.proxyOutbounds = [NSMutableArray array];

    for (NSDictionary *o in json[@"outbounds"]) {
        NSString *type = o[@"type"], *tag = o[@"tag"];
        if (tag && ([type isEqualToString:@"vless"] || [type isEqualToString:@"vmess"] || [type isEqualToString:@"trojan"] || [type isEqualToString:@"shadowsocks"])) {
            [self.proxyTags addObject:tag];
            [self.proxyOutbounds addObject:o];
        }
    }

    [self.serverDropdown removeAllItems];
    if (self.proxyTags.count > 0) {
        [self.serverDropdown addItemsWithTitles:self.proxyTags];
        [self.serverDropdown setEnabled:YES];
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Загружено %lu серверов", (unsigned long)self.proxyTags.count];
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
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:urlString] completionHandler:^(NSData *data, NSURLResponse *r, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err || !data) { self.statusLabel.stringValue = @"Ошибка сети!"; return; }
            NSString *subPath = [[self.configPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"subscription.json"];
            [data writeToFile:subPath atomically:YES];
            NSError *je;
            NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&je];
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

- (void)toggleConnection {
    if (self.isConnected) [self stopVPN]; else [self startVPN];
}

- (NSString *)getActiveNetworkInterface {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/sbin/networksetup";
    t.arguments = @[@"-listnetworkserviceorder"];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    [t launch];
    NSString *out = [[NSString alloc] initWithData:[[p fileHandleForReading] readDataToEndOfFile] encoding:NSUTF8StringEncoding];
    if ([out containsString:@"Wi-Fi"]) return @"Wi-Fi";
    if ([out containsString:@"Ethernet"]) return @"Ethernet";
    return @"Wi-Fi";
}

- (void)startVPN {
    if (self.proxyTags.count == 0) { self.statusLabel.stringValue = @"Сначала загрузите серверы."; return; }
    self.statusLabel.stringValue = @"Запуск...";

    NSString *activeTag = self.serverDropdown.titleOfSelectedItem ?: @"";
    if (activeTag.length == 0) return;

    NSDictionary *activeOutbound = nil;
    for (NSDictionary *o in self.proxyOutbounds) {
        if ([o[@"tag"] isEqualToString:activeTag]) { activeOutbound = o; break; }
    }
    if (!activeOutbound) return;

    // [CTO ARCHITECTURE]: Только SOCKS и HTTP Прокси. Никакого TUN.
    NSArray *outbounds = @[
        activeOutbound,
        @{@"type": @"direct", @"tag": @"direct"}
    ];

    NSDictionary *config = @{
        @"log": @{@"level": @"info"},
        @"inbounds": @[
            @{@"type": @"socks", @"tag": @"socks-in", @"listen": @"127.0.0.1", @"listen_port": @10808},
            @{@"type": @"http", @"tag": @"http-in", @"listen": @"127.0.0.1", @"listen_port": @10809}
        ],
        @"outbounds": outbounds,
        @"route": @{
            @"rules": @[
                @{@"ip_cidr": @[@"127.0.0.0/8", @"192.168.0.0/16", @"10.0.0.0/8", @"172.16.0.0/12"], @"outbound": @"direct"}
            ],
            @"final": activeTag
        }
    };

    NSError *je = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:&je];
    if (je || !data) { self.statusLabel.stringValue = @"Ошибка конфига!"; return; }
    [data writeToFile:self.configPath atomically:YES];

    NSString *bin = [[NSBundle mainBundle] pathForResource:@"sing-box" ofType:nil];
    NSString *iface = [self getActiveNetworkInterface];
    
    // [ONE SCRIPT TO RULE THEM ALL]: Убиваем старое, пишем прокси, запускаем новое. Один пароль!
    NSString *shellCommand = [NSString stringWithFormat:
        @"killall -9 sing-box 2>/dev/null || true ; "
        @"networksetup -setwebproxy '%@' 127.0.0.1 10809 ; "
        @"networksetup -setsecurewebproxy '%@' 127.0.0.1 10809 ; "
        @"networksetup -setsocksfirewallproxy '%@' 127.0.0.1 10808 ; "
        @"nohup '%@' run -c '%@' > '%@' 2>&1 &", 
        iface, iface, iface, bin, self.configPath, self.logPath];
        
    NSString *scriptSource = [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", shellCommand];
    NSDictionary *err = nil;
    [[[NSAppleScript alloc] initWithSource:scriptSource] executeAndReturnError:&err];

    if (!err) {
        [self updateUIConnected:YES];
    } else {
        self.statusLabel.stringValue = @"Отменено / Ошибка";
        [self forceProxyOff];
    }
}

- (void)forceProxyOff {
    NSString *iface = [self getActiveNetworkInterface];
    NSString *cmd = [NSString stringWithFormat:
        @"networksetup -setwebproxystate '%@' off ; "
        @"networksetup -setsecurewebproxystate '%@' off ; "
        @"networksetup -setsocksfirewallproxystate '%@' off",
        iface, iface, iface];
    [[[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", cmd]] executeAndReturnError:nil];
}

- (BOOL)stopVPN {
    // Безопасная остановка через AppleScript
    NSString *iface = [self getActiveNetworkInterface];
    NSString *cmd = [NSString stringWithFormat:
        @"killall -9 sing-box 2>/dev/null || true ; "
        @"networksetup -setwebproxystate '%@' off ; "
        @"networksetup -setsecurewebproxystate '%@' off ; "
        @"networksetup -setsocksfirewallproxystate '%@' off",
        iface, iface, iface];
    NSDictionary *err = nil;
    [[[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", cmd]] executeAndReturnError:&err];
    if (err) { self.statusLabel.stringValue = @"Ошибка сброса прокси!"; return NO; }
    [self updateUIConnected:NO];
    return YES;
}

- (void)updateUIConnected:(BOOL)connected {
    self.isConnected = connected;
    if (connected) {
        NSString *server = self.serverDropdown.titleOfSelectedItem ?: @"";
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Глобально · %@", server];
        self.statusLabel.textColor = [NSColor greenColor];
        self.connectButton.title = @"ВКЛ";
        self.connectButton.layer.borderColor = [NSColor greenColor].CGColor;
        self.connectButton.layer.backgroundColor = [NSColor colorWithRed:0 green:1 blue:0 alpha:0.1].CGColor;
    } else {
        self.statusLabel.stringValue = @"Готов к работе";
        self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
        self.connectButton.title = @"ВЫКЛ";
        self.connectButton.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.3].CGColor;
        self.connectButton.layer.backgroundColor = [NSColor clearColor].CGColor;
    }
}
@end
