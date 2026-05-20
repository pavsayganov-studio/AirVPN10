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
@property (assign) BOOL isConnected;
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
    [effectView addSubview:self.serverDropdown];
    
    self.stealthCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 220, 280, 20)];
    [self.stealthCheckbox setButtonType:NSButtonTypeSwitch];
    self.stealthCheckbox.title = @"Умный режим (Только заблокированные)";
    self.stealthCheckbox.state = NSControlStateValueOn;
    [effectView addSubview:self.stealthCheckbox];
    
    // UI FIX: Избегаем наложения на кнопку
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 185, 320, 20)];
    self.statusLabel.stringValue = @"Готов к работе";
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.bezeled = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.editable = NO;
    self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
    [effectView addSubview:self.statusLabel];
    
    self.connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(105, 65, 110, 110)];
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
    
    NSButton *logBtn = [[NSButton alloc] initWithFrame:NSMakeRect(20, 20, 80, 25)];
    logBtn.title = @"Логи";
    logBtn.bezelStyle = NSBezelStyleRounded;
    logBtn.target = self;
    logBtn.action = @selector(openLogs);
    [effectView addSubview:logBtn];
    
    NSButton *quitBtn = [[NSButton alloc] initWithFrame:NSMakeRect(220, 20, 80, 25)];
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
        NSString *subPath = [[self.configPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"subscription.json"];
        if ([fm fileExistsAtPath:subPath]) {
            NSData *subData = [NSData dataWithContentsOfFile:subPath];
            NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:subData options:NSJSONReadingMutableContainers error:nil];
            if (json) { [self handleParsedJSON:json]; }
        }
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:nil];
}

- (void)quitApp {
    [self stopVPN];
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self stopVPN];
}

- (void)openLogs {
    [[NSWorkspace sharedWorkspace] openFile:self.logPath withApplication:@"Console"];
}

- (NSDictionary *)parseVlessLink:(NSString *)link {
    NSURLComponents *comp = [NSURLComponents componentsWithString:[link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    if (!comp || ![comp.scheme isEqualToString:@"vless"]) return nil;
    NSString *tag = comp.fragment ? [comp.fragment stringByRemovingPercentEncoding] : comp.host;
    NSMutableDictionary *outbound = [@{ @"type": @"vless", @"tag": tag ?: @"vless-server", @"server": comp.host ?: @"", @"server_port": comp.port ?: @443, @"uuid": comp.user ?: @"", @"packet_encoding": @"xudp" } mutableCopy];
    NSMutableDictionary *tls = [NSMutableDictionary dictionary];
    NSMutableDictionary *transport = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in comp.queryItems) {
        if ([item.name isEqualToString:@"security"]) {
            if ([item.value isEqualToString:@"tls"] || [item.value isEqualToString:@"reality"]) tls[@"enabled"] = @YES;
            if ([item.value isEqualToString:@"reality"]) tls[@"reality"] = [@{@"enabled": @YES} mutableCopy];
        }
        if ([item.name isEqualToString:@"sni"]) tls[@"server_name"] = item.value;
        if ([item.name isEqualToString:@"pbk"]) tls[@"reality"][@"public_key"] = item.value;
        if ([item.name isEqualToString:@"sid"]) tls[@"reality"][@"short_id"] = item.value;
        if ([item.name isEqualToString:@"flow"] && item.value.length > 0) outbound[@"flow"] = item.value;
        if ([item.name isEqualToString:@"type"] && item.value.length > 0) {
            if (![item.value isEqualToString:@"tcp"]) transport[@"type"] = item.value;
        }
        if ([item.name isEqualToString:@"path"] && item.value.length > 0) transport[@"path"] = item.value;
        if ([item.name isEqualToString:@"serviceName"] && item.value.length > 0) transport[@"service_name"] = item.value;
        if ([item.name isEqualToString:@"host"] && item.value.length > 0) transport[@"headers"] = @{@"Host": item.value};
    }
    if (tls[@"enabled"]) { tls[@"utls"] = @{@"enabled": @YES, @"fingerprint": @"chrome"}; }
    if (tls.count > 0) outbound[@"tls"] = tls;
    if (transport.count > 0) outbound[@"transport"] = transport;
    return outbound;
}

- (void)processRawText:(NSString *)text {
    NSString *cleanText = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:cleanText options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (decodedData) {
        NSString *decodedStr = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
        if (decodedStr) cleanText = decodedStr;
    }
    NSArray *lines = [cleanText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray *parsedOutbounds = [NSMutableArray array];
    for (NSString *line in lines) {
        if ([line hasPrefix:@"vless://"]) {
            NSDictionary *outbound = [self parseVlessLink:line];
            if (outbound) [parsedOutbounds addObject:outbound];
        }
    }
    if (parsedOutbounds.count == 0) { self.statusLabel.stringValue = @"Серверы не найдены."; return; }
    NSMutableDictionary *skeleton = [@{ @"log": @{@"level": @"info"}, @"outbounds": parsedOutbounds } mutableCopy];
    [self handleParsedJSON:skeleton];
}

- (void)handleParsedJSON:(NSMutableDictionary *)json {
    self.downloadedJSON = json;
    self.proxyTags = [NSMutableArray array];
    NSArray *outbounds = json[@"outbounds"];
    for (NSDictionary *out in outbounds) {
        NSString *tag = out[@"tag"];
        if (tag && ![tag isEqualToString:@"direct"] && ![tag isEqualToString:@"dns-out"]) {
            [self.proxyTags addObject:tag];
        }
    }
    [self.serverDropdown removeAllItems];
    if (self.proxyTags.count > 0) {
        [self.serverDropdown addItemWithTitle:@"⚡️ Авто (Умный выбор)"];
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
    NSURL *url = [NSURL URLWithString:urlString];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) { self.statusLabel.stringValue = @"Ошибка сети!"; return; }
            NSString *subPath = [[self.configPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"subscription.json"];
            [data writeToFile:subPath atomically:YES];
            NSError *jsonError;
            NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&jsonError];
            if (!jsonError && json[@"outbounds"]) { [self handleParsedJSON:json]; } else {
                NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (text) { [self processRawText:text]; } else { self.statusLabel.stringValue = @"Неверный формат ссылки."; }
            }
        });
    }] resume];
}

- (void)toggleConnection { if (self.isConnected) { [self stopVPN]; } else { [self startVPN]; } }

- (NSString *)getActiveNetworkInterface {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/sbin/networksetup"];
    [task setArguments:@[@"-listnetworkserviceorder"]];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task launch];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ([output containsString:@"Wi-Fi"]) return @"Wi-Fi";
    if ([output containsString:@"Ethernet"]) return @"Ethernet";
    return @"Wi-Fi";
}

- (void)startVPN {
    if (!self.downloadedJSON || self.proxyTags.count == 0) { self.statusLabel.stringValue = @"Сначала загрузите серверы."; return; }
    self.statusLabel.stringValue = @"Запуск ядра...";
    
    NSString *selectedTitle = self.serverDropdown.titleOfSelectedItem;
    NSString *activeProxyTag = [selectedTitle isEqualToString:@"⚡️ Авто (Умный выбор)"] ? @"auto-switch" : selectedTitle;
    
    // Чистая генерация конфига
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    config[@"log"] = @{ @"level": @"info" };
    config[@"inbounds"] = @[ 
        @{@"type": @"socks", @"tag": @"socks-in", @"listen": @"127.0.0.1", @"listen_port": @10808},
        @{@"type": @"http", @"tag": @"http-in", @"listen": @"127.0.0.1", @"listen_port": @10809}
    ];
    
    NSMutableArray *newOutbounds = [NSMutableArray array];
    for (NSDictionary *out in self.downloadedJSON[@"outbounds"]) {
        if (![out[@"tag"] isEqualToString:@"direct"] && ![out[@"tag"] isEqualToString:@"dns-out"]) {
            [newOutbounds addObject:out];
        }
    }
    
    [newOutbounds addObject:@{@"type": @"direct", @"tag": @"direct"}];
    [newOutbounds addObject:@{@"type": @"dns", @"tag": @"dns-out"}];
    
    if ([selectedTitle isEqualToString:@"⚡️ Авто (Умный выбор)"]) {
        [newOutbounds insertObject:@{ @"type": @"urltest", @"tag": @"auto-switch", @"outbounds": self.proxyTags, @"url": @"http://cp.cloudflare.com/generate_204", @"interval": @"3m", @"tolerance": @50 } atIndex:0];
    }
    config[@"outbounds"] = newOutbounds;
    
    // DNS без петель
    config[@"dns"] = @{
        @"servers": @[ @{@"tag": @"remote-dns", @"address": @"8.8.8.8", @"detour": @"direct"} ]
    };
    
    NSMutableArray *rules = [NSMutableArray array];
    [rules addObject:@{@"protocol": @[@"dns"], @"outbound": @"dns-out"}];
    
    NSString *activeServerAddress = @"";
    for (NSDictionary *out in newOutbounds) {
        if ([out[@"tag"] isEqualToString:activeProxyTag]) { activeServerAddress = out[@"server"]; break; }
    }
    if (activeServerAddress.length > 0) {
        [rules addObject:@{ @"domain": @[activeServerAddress], @"outbound": @"direct" }];
    }
    
    if (self.stealthCheckbox.state == NSControlStateValueOn) {
        NSArray *blockedDomains = @[ @"telegram.org", @"t.me", @"whatsapp.com", @"youtube.com", @"youtu.be", @"ytimg.com", @"googlevideo.com", @"ggpht.com", @"openai.com", @"chatgpt.com", @"anthropic.com", @"claude.ai", @"gemini.google.com", @"instagram.com", @"facebook.com", @"x.com", @"rutracker.org", @"discord.com" ];
        NSArray *telegramIPs = @[ @"91.108.4.0/22", @"91.108.8.0/22", @"91.108.12.0/22", @"91.108.16.0/22", @"91.108.20.0/22", @"91.108.36.0/23", @"91.108.38.0/23", @"91.108.56.0/22", @"91.108.56.0/23", @"91.108.56.0/24", @"149.154.160.0/20", @"149.154.164.0/22", @"149.154.172.0/22", @"185.76.8.0/22" ];
        [rules addObject:@{ @"domain_suffix": blockedDomains, @"ip_cidr": telegramIPs, @"outbound": activeProxyTag }];
        config[@"route"] = @{ @"rules": rules, @"final": @"direct" };
    } else {
        config[@"route"] = @{ @"rules": rules, @"final": activeProxyTag };
    }
    
    NSData *finalData = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
    [finalData writeToFile:self.configPath atomically:YES];
    
    NSString *binaryPath = [[NSBundle mainBundle] pathForResource:@"sing-box" ofType:nil];
    NSString *interface = [self getActiveNetworkInterface];
    
    NSString *shellCommand = [NSString stringWithFormat:
        @"killall -9 sing-box 2>/dev/null || true ; "
        @"nohup '%@' run -c '%@' > '%@' 2>&1 & "
        @"networksetup -setwebproxy '%@' 127.0.0.1 10809 ; "
        @"networksetup -setsecurewebproxy '%@' 127.0.0.1 10809 ; "
        @"networksetup -setsocksfirewallproxy '%@' 127.0.0.1 10808", 
        binaryPath, self.configPath, self.logPath, interface, interface, interface];
        
    NSString *scriptSource = [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", shellCommand];
    
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorInfo = nil;
    [script executeAndReturnError:&errorInfo];
    
    if (!errorInfo) { 
        [self updateUIConnected:YES]; 
    } else { 
        self.statusLabel.stringValue = @"Отменено / Ошибка"; 
    }
}

- (BOOL)stopVPN {
    NSString *interface = [self getActiveNetworkInterface];
    NSString *shellCommand = [NSString stringWithFormat:
        @"/bin/bash -c 'killall -9 sing-box 2>/dev/null || true ; "
        @"networksetup -setwebproxystate \\\"%@\\\" off ; "
        @"networksetup -setsecurewebproxystate \\\"%@\\\" off ; "
        @"networksetup -setsocksfirewallproxystate \\\"%@\\\" off'", interface, interface, interface];
        
    NSString *scriptSource = [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", shellCommand];
    
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    [script executeAndReturnError:nil];
    [self updateUIConnected:NO];
    return YES;
}

- (void)updateUIConnected:(BOOL)connected {
    self.isConnected = connected;
    if (connected) {
        self.statusLabel.stringValue = self.stealthCheckbox.state == NSControlStateValueOn ? @"Подключено (Умный режим)" : @"Подключено (Глобально)";
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
