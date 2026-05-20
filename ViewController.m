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
    
    // Красивые симметричные кнопки внизу в стиле High Sierra
    NSButton *logBtn = [[NSButton alloc] initWithFrame:NSMakeRect(20, 25, 90, 25)];
    logBtn.title = @"Логи";
    logBtn.bezelStyle = NSBezelStyleRounded;
    logBtn.target = self;
    logBtn.action = @selector(openLogs);
    [effectView addSubview:logBtn];
    
    NSButton *quitBtn = [[NSButton alloc] initWithFrame:NSMakeRect(210, 25, 90, 25)];
    quitBtn.title = @"Выйти";
    quitBtn.bezelStyle = NSBezelStyleRounded;
    quitBtn.target = self;
    quitBtn.action = @selector(quitApp);
    [effectView addSubview:quitBtn];
    
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 400, 320, 30)];
    titleLabel.stringValue = @"PauloVPN";
    titleLabel.alignment = NSTextAlignmentCenter;
    titleLabel.bezeled = NO;
    titleLabel.drawsBackground = NO;
    titleLabel.editable = NO;
    titleLabel.font = [NSFont systemFontOfSize:26 weight:NSFontWeightLight];
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
    
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 180, 320, 20)];
    self.statusLabel.stringValue = @"Готов к работе";
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.bezeled = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.editable = NO;
    self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
    [effectView addSubview:self.statusLabel];
    
    self.connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(100, 75, 120, 120)];
    self.connectButton.title = @"ВЫКЛ";
    self.connectButton.font = [NSFont systemFontOfSize:24 weight:NSFontWeightMedium];
    self.connectButton.bordered = NO;
    self.connectButton.wantsLayer = YES;
    self.connectButton.layer.cornerRadius = 60;
    self.connectButton.layer.borderWidth = 2.0;
    self.connectButton.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.3].CGColor;
    self.connectButton.layer.backgroundColor = [NSColor clearColor].CGColor;
    self.connectButton.target = self;
    self.connectButton.action = @selector(toggleConnection);
    [effectView addSubview:self.connectButton];
    
    self.view = effectView;
    self.isConnected = NO;
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *appSupport = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    appSupport = [appSupport URLByAppendingPathComponent:@"PauloVPN"];
    [fm createDirectoryAtURL:appSupport withIntermediateDirectories:YES attributes:nil error:nil];
    self.configPath = [[appSupport URLByAppendingPathComponent:@"config.json"] path];
    self.logPath = [[appSupport URLByAppendingPathComponent:@"vpn.log"] path];
    
    // Автозагрузка кэшированных настроек
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
    // Если юзер отменил ввод пароля при выключении, мы НЕ закрываем приложение, чтобы сохранить интернет рабочим!
    if ([self stopVPN]) {
        [NSApp terminate:nil];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self stopVPN];
}

- (void)openLogs {
    [[NSWorkspace sharedWorkspace] openFile:self.logPath withApplication:@"Console"];
}

- (void)serverChanged {
    if (self.isConnected) { [self startVPN]; }
}

- (void)stealthChanged {
    if (self.isConnected) { [self startVPN]; }
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
    
    // [Y-C SMART SELECTOR DETECTOR]: Ищем встроенный селектор Hiddify
    for (NSDictionary *out in outbounds) {
        NSString *type = out[@"type"];
        if ([type isEqualToString:@"selector"] || [type isEqualToString:@"urltest"]) {
            NSArray *subOutbounds = out[@"outbounds"];
            for (NSString *tag in subOutbounds) {
                if (![tag isEqualToString:@"direct"] && ![tag isEqualToString:@"block"] && ![tag isEqualToString:@"dns-out"]) {
                    [self.proxyTags addObject:tag];
                }
            }
            break;
        }
    }
    
    // Если селектора нет, собираем теги вручную
    if (self.proxyTags.count == 0) {
        for (NSDictionary *out in outbounds) {
            NSString *tag = out[@"tag"];
            if (tag && ![tag isEqualToString:@"direct"] && ![tag isEqualToString:@"dns-out"]) {
                [self.proxyTags addObject:tag];
            }
        }
    }
    
    [self.serverDropdown removeAllItems];
    if (self.proxyTags.count > 0) {
        [self.serverDropdown addItemWithTitle:@"⚡️ Авто (Умный выбор)"];
        [self.serverDropdown addItemsWithTitles:self.proxyTags];
        [self.serverDropdown setEnabled:YES];
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Загружено %lu серверов", (unsigned long)self.proxyTags.count];
    } else {
        [self.serverDropdown addItemWithTitle:@"Нет поддерживаемых серверов"];
        self.statusLabel.stringValue = @"VLESS серверы не найдены.";
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
    
    // Клонируем конфиг (Deep Copy)
    NSData *tempData = [NSJSONSerialization dataWithJSONObject:self.downloadedJSON options:0 error:nil];
    NSMutableDictionary *activeConfig = [NSJSONSerialization JSONObjectWithData:tempData options:NSJSONReadingMutableContainers error:nil];
    
    NSString *selectedTitle = self.serverDropdown.titleOfSelectedItem;
    NSString *activeProxyTag = [selectedTitle isEqualToString:@"⚡️ Авто (Умный выбор)"] ? @"auto-switch" : selectedTitle;
    
    NSMutableArray *newOutbounds = [NSMutableArray arrayWithArray:activeConfig[@"outbounds"]];
    
    // [TUNNEL SELECTOR MODIFICATION]: Мягко переключаем внутренний селектор Hiddify!
    for (NSInteger i = 0; i < newOutbounds.count; i++) {
        NSMutableDictionary *out = [newOutbounds[i] mutableCopy];
        if ([out[@"type"] isEqualToString:@"selector"]) {
            out[@"selected"] = activeProxyTag;
            newOutbounds[i] = out;
        }
    }
    
    BOOL hasDirect = NO, hasDnsOut = NO;
    for (NSDictionary *outbound in newOutbounds) { 
        if ([outbound[@"tag"] isEqualToString:@"direct"]) hasDirect = YES; 
        if ([outbound[@"tag"] isEqualToString:@"dns-out"]) hasDnsOut = YES; 
    }
    if (!hasDirect) { [newOutbounds addObject:@{@"type": @"direct", @"tag": @"direct"}]; }
    if (!hasDnsOut) { [newOutbounds addObject:@{@"type": @"dns", @"tag": @"dns-out"}]; }
    
    // Если выбран авто-выбор, добавляем его в начало
    if ([selectedTitle isEqualToString:@"⚡️ Авто (Умный выбор)"]) {
        NSDictionary *autoOutbound = @{ @"type": @"urltest", @"tag": @"auto-switch", @"outbounds": self.proxyTags, @"url": @"http://cp.cloudflare.com/generate_204", @"interval": @"3m", @"tolerance": @50 };
        [newOutbounds insertObject:autoOutbound atIndex:0];
    }
    activeConfig[@"outbounds"] = newOutbounds;
    
    // [SOCKS5 + HTTP INBOUNDS]
    activeConfig[@"inbounds"] = @[ 
        @{"type": @"socks", @"tag": @"socks-in", @"listen": @"127.0.0.1", @"listen_port": @10808},
        @{"type": @"http", @"tag": @"http-in", @"listen": @"127.0.0.1", @"listen_port": @10809}
    ];
    
    // СОХРАНЯЕМ ОРИГИНАЛЬНЫЙ DNS И ROUTE ОТ HIDDIFY! Мы больше не перезаписываем их.
    // Это решает проблему DNS таймаутов навсегда.
    
    NSData *finalData = [NSJSONSerialization dataWithJSONObject:activeConfig options:0 error:nil];
    [finalData writeToFile:self.configPath atomically:YES];
    
    NSString *binaryPath = [[NSBundle mainBundle] pathForResource:@"sing-box" ofType:nil];
    NSString *interface = [self getActiveNetworkInterface];
    
    // Запуск под рутом (Один пароль)
    NSString *shellCommand = [NSString stringWithFormat:
        @"killall -9 sing-box 2>/dev/null || true ; "
        @"nohup '%@' run -c '%@' > '%@' 2>&1 & "
        @"networksetup -setwebproxy '%@' 127.0.0.1 10809 ; "
        @"networksetup -setsecurewebproxy '%@' 127.0.0.1 10809 ; "
        @"networksetup -setsocksfirewallproxy '%@' 127.0.0.1 10808", 
        binaryPath, self.configPath, self.logPath, interface, interface, interface];
        
    NSString *scriptSource = [NSString stringWithFormat:@"do shell script \"\(shellCommand)\" with administrator privileges"];
    
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorInfo = nil;
    [script executeAndReturnError:&errorInfo];
    
    if (!errorInfo) { 
        [self updateUIConnected:YES]; 
    } else { 
        self.statusLabel.stringValue = @"Отменено / Ошибка"; 
        [self stopVPN]; 
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
    NSDictionary *errorInfo = nil;
    [script executeAndReturnError:&errorInfo];
    if (errorInfo) {
        self.statusLabel.stringValue = @"Ошибка сброса прокси!";
        return NO;
    }
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
