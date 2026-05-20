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
    NSVisualEffectView *effectView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 300, 480)];
    effectView.material = NSVisualEffectMaterialDark;
    effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effectView.state = NSVisualEffectStateActive;
    
    // Кнопка Выйти (Работает 100%)
    NSButton *quitBtn = [[NSButton alloc] initWithFrame:NSMakeRect(230, 440, 60, 25)];
    quitBtn.title = @"Выйти";
    quitBtn.bezelStyle = NSBezelStyleRounded;
    quitBtn.target = self;
    quitBtn.action = @selector(quitApp);
    [effectView addSubview:quitBtn];
    
    // Кнопка Логи (Для дебага)
    NSButton *logBtn = [[NSButton alloc] initWithFrame:NSMakeRect(10, 440, 60, 25)];
    logBtn.title = @"Логи";
    logBtn.bezelStyle = NSBezelStyleRounded;
    logBtn.target = self;
    logBtn.action = @selector(openLogs);
    [effectView addSubview:logBtn];
    
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 400, 300, 30)];
    titleLabel.stringValue = @"PauloVPN";
    titleLabel.alignment = NSTextAlignmentCenter;
    titleLabel.bezeled = NO;
    titleLabel.drawsBackground = NO;
    titleLabel.editable = NO;
    titleLabel.font = [NSFont systemFontOfSize:26 weight:NSFontWeightLight];
    titleLabel.textColor = [NSColor whiteColor];
    [effectView addSubview:titleLabel];
    
    self.urlField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 350, 260, 24)];
    self.urlField.placeholderString = @"Вставьте vless:// или подписку...";
    [effectView addSubview:self.urlField];
    
    NSButton *importBtn = [[NSButton alloc] initWithFrame:NSMakeRect(70, 310, 160, 30)];
    importBtn.title = @"Загрузить серверы";
    importBtn.bezelStyle = NSBezelStyleRounded;
    importBtn.target = self;
    importBtn.action = @selector(downloadConfig);
    [effectView addSubview:importBtn];
    
    self.serverDropdown = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 260, 260, 26) pullsDown:NO];
    [self.serverDropdown addItemWithTitle:@"Серверы не загружены"];
    [self.serverDropdown setEnabled:NO];
    // Позволяет менять сервер на лету!
    self.serverDropdown.target = self;
    self.serverDropdown.action = @selector(serverChanged);
    [effectView addSubview:self.serverDropdown];
    
    self.stealthCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 220, 260, 20)];
    [self.stealthCheckbox setButtonType:NSButtonTypeSwitch];
    self.stealthCheckbox.title = @"Умный режим (Только TG/YT/AI)";
    self.stealthCheckbox.state = NSControlStateValueOn;
    self.stealthCheckbox.target = self;
    self.stealthCheckbox.action = @selector(stealthChanged);
    [effectView addSubview:self.stealthCheckbox];
    
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 180, 300, 20)];
    self.statusLabel.stringValue = @"Готов к работе";
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.bezeled = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.editable = NO;
    self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
    [effectView addSubview:self.statusLabel];
    
    self.connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(90, 40, 120, 120)];
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
}

- (void)quitApp {
    [self stopVPN];
    [NSApp terminate:nil];
}

- (void)openLogs {
    // Открывает лог-файл в стандартном приложении "Консоль" macOS
    [[NSWorkspace sharedWorkspace] openFile:self.logPath withApplication:@"Console"];
}

- (void)serverChanged {
    if (self.isConnected) { [self startVPN]; } // Мягкий рестарт ядра
}

- (void)stealthChanged {
    if (self.isConnected) { [self startVPN]; } // Мягкий рестарт ядра
}

// УЛЬТИМАТИВНЫЙ ПАРСЕР С ОБХОДОМ ТСПУ (DPI)
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
        if ([item.name isEqualToString:@"type"] && [item.value isEqualToString:@"ws"]) transport[@"type"] = @"ws";
        if ([item.name isEqualToString:@"type"] && [item.value isEqualToString:@"grpc"]) transport[@"type"] = @"grpc";
        if ([item.name isEqualToString:@"path"]) transport[@"path"] = item.value;
        if ([item.name isEqualToString:@"serviceName"]) transport[@"service_name"] = item.value;
        if ([item.name isEqualToString:@"host"]) transport[@"headers"] = @{@"Host": item.value};
    }
    
    // [Y-COMBINATOR FIX]: Жестко форсируем UTLS (Хром) для всех VLESS, иначе ТСПУ заблокирует!
    if (tls[@"enabled"]) {
        tls[@"utls"] = @{@"enabled": @YES, @"fingerprint": @"chrome"};
    }
    
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
    if (parsedOutbounds.count == 0) {
        self.statusLabel.stringValue = @"Серверы не найдены.";
        return;
    }
    NSMutableDictionary *skeleton = [@{
        @"log": @{@"level": @"debug"}, // DEBUG для отлова ошибок!
        @"outbounds": parsedOutbounds,
    } mutableCopy];
    [self handleParsedJSON:skeleton];
}

- (void)handleParsedJSON:(NSMutableDictionary *)json {
    self.downloadedJSON = json;
    self.proxyTags = [NSMutableArray array];
    NSArray *outbounds = json[@"outbounds"];
    for (NSDictionary *out in outbounds) {
        NSString *tag = out[@"tag"];
        if (tag && ![tag isEqualToString:@"direct"] && ![tag isEqualToString:@"dns-out"]) { [self.proxyTags addObject:tag]; }
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
    if ([urlString hasPrefix:@"vless://"]) { [self processRawText:urlString]; return; }
    
    self.statusLabel.stringValue = @"Загрузка...";
    NSURL *url = [NSURL URLWithString:urlString];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) { self.statusLabel.stringValue = @"Ошибка сети!"; return; }
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

- (void)startVPN {
    if (!self.downloadedJSON || self.proxyTags.count == 0) { self.statusLabel.stringValue = @"Сначала загрузите серверы."; return; }
    self.statusLabel.stringValue = @"Запуск ядра...";
    
    // ВСЕГДА убиваем старое ядро перед запуском нового (важно для смены серверов на лету)
    [[[NSAppleScript alloc] initWithSource:@"do shell script \"killall -9 sing-box\" with administrator privileges"] executeAndReturnError:nil];
    
    NSString *selectedTitle = self.serverDropdown.titleOfSelectedItem;
    NSString *activeProxyTag = [selectedTitle isEqualToString:@"⚡️ Авто (Умный выбор)"] ? @"auto-switch" : selectedTitle;
    
    NSMutableArray *newOutbounds = [NSMutableArray arrayWithArray:self.downloadedJSON[@"outbounds"]];
    BOOL hasDirect = NO, hasDnsOut = NO;
    for (NSDictionary *outbound in newOutbounds) { 
        if ([outbound[@"tag"] isEqualToString:@"direct"]) hasDirect = YES; 
        if ([outbound[@"tag"] isEqualToString:@"dns-out"]) hasDnsOut = YES; 
    }
    if (!hasDirect) { [newOutbounds addObject:@{@"type": @"direct", @"tag": @"direct"}]; }
    if (!hasDnsOut) { [newOutbounds addObject:@{@"type": @"dns", @"tag": @"dns-out"}]; }
    
    if ([selectedTitle isEqualToString:@"⚡️ Авто (Умный выбор)"]) {
        NSDictionary *autoOutbound = @{ @"type": @"urltest", @"tag": @"auto-switch", @"outbounds": self.proxyTags, @"url": @"http://cp.cloudflare.com/", @"interval": @"3m", @"tolerance": @50 };
        [newOutbounds insertObject:autoOutbound atIndex:0];
    }
    self.downloadedJSON[@"outbounds"] = newOutbounds;
    
    // ЖЕСТКИЙ DNS РЕЗОЛВЕР ДЛЯ РОССИИ
    self.downloadedJSON[@"dns"] = @{
        @"servers": @[ 
            @{@"tag": @"remote-dns", @"address": @"8.8.8.8", @"detour": activeProxyTag},
            @{@"tag": @"local-dns", @"address": @"local", @"detour": @"direct"}
        ],
        @"rules": @[ 
            @{@"outbound": @[@"any"], @"server": @"remote-dns"},
            @{@"geosite": @[@"cn", @"ru"], @"server": @"local-dns"}
        ]
    };
    
    self.downloadedJSON[@"inbounds"] = @[ @{
        @"type": @"tun", @"tag": @"tun-in", @"interface_name": @"utun9", @"inet4_address": @"172.19.0.1/30",
        @"auto_route": @YES, @"strict_route": @YES, @"stack": @"system",
        @"sniff": @YES, @"sniff_override_destination": @YES // КРИТИЧНО ДЛЯ ПЕРЕХВАТА YOUTUBE
    } ];
    
    NSMutableDictionary *route = [NSMutableDictionary dictionary];
    NSMutableArray *rules = [NSMutableArray array];
    
    [rules addObject:@{@"protocol": @[@"dns"], @"outbound": @"dns-out"}];
    
    if (self.stealthCheckbox.state == NSControlStateValueOn) {
        NSArray *blockedDomains = @[ @"telegram.org", @"t.me", @"whatsapp.com", @"whatsapp.net", @"youtube.com", @"youtu.be", @"ytimg.com", @"googlevideo.com", @"ggpht.com", @"openai.com", @"chatgpt.com", @"oaistatic.com", @"anthropic.com", @"claude.ai", @"gemini.google.com", @"instagram.com", @"cdninstagram.com", @"facebook.com", @"x.com" ];
        [rules addObject:@{ @"domain_suffix": blockedDomains, @"outbound": activeProxyTag }];
        route[@"final"] = @"direct"; 
    } else { 
        route[@"final"] = activeProxyTag; 
    }
    
    route[@"rules"] = rules; route[@"auto_detect_interface"] = @YES;
    self.downloadedJSON[@"route"] = route;
    
    NSData *finalData = [NSJSONSerialization dataWithJSONObject:self.downloadedJSON options:0 error:nil];
    [finalData writeToFile:self.configPath atomically:YES];
    
    NSString *binaryPath = [[NSBundle mainBundle] pathForResource:@"sing-box" ofType:nil];
    // НАДЕЖНЫЙ ЗАПУСК В ФОНЕ ЧЕРЕЗ BASH
    NSString *shellCommand = [NSString stringWithFormat:@"/bin/bash -c 'nohup \\\"%@\\\" run -c \\\"%@\\\" > \\\"%@\\\" 2>&1 &'", binaryPath, self.configPath, self.logPath];
    NSString *scriptSource = [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", shellCommand];
    
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorInfo = nil;
    [script executeAndReturnError:&errorInfo];
    
    if (!errorInfo) { 
        [self updateUIConnected:YES]; 
    } else { 
        self.statusLabel.stringValue = @"Ошибка прав доступа"; 
    }
}

- (void)stopVPN {
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:@"do shell script \"killall -9 sing-box\" with administrator privileges"];
    [script executeAndReturnError:nil];
    [self updateUIConnected:NO];
}

- (void)updateUIConnected:(BOOL)connected {
    self.isConnected = connected;
    if (connected) {
        self.statusLabel.stringValue = self.stealthCheckbox.state == NSControlStateValueOn ? @"Подключено (Умный режим)" : @"Подключено (Глобально)";
        self.statusLabel.textColor = [NSColor greenColor];
        self.connectButton.title = @"ВКЛ";
        self.connectButton.layer.borderColor = [NSColor greenColor].CGColor;
        self.connectButton.layer.backgroundColor = [NSColor colorWithRed:0 green:1 blue:0 alpha:0.1].CGColor;
        // Дропдаун ОСТАЕТСЯ АКТИВНЫМ для смены на лету!
    } else {
        self.statusLabel.stringValue = @"Отключено";
        self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
        self.connectButton.title = @"ВЫКЛ";
        self.connectButton.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.3].CGColor;
        self.connectButton.layer.backgroundColor = [NSColor clearColor].CGColor;
    }
}
@end
