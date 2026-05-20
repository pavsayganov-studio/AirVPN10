#import "ViewController.h"

@interface ViewController ()
@property (strong) NSTextField *urlField;
@property (strong) NSTextField *statusLabel;
@property (strong) NSButton *connectButton;
@property (strong) NSPopUpButton *serverDropdown;
@property (strong) NSButton *stealthCheckbox;
@property (strong) NSString *currentPID;
@property (strong) NSString *configPath;
@property (strong) NSMutableDictionary *downloadedJSON;
@property (strong) NSMutableArray *proxyTags;
@end

@implementation ViewController

- (void)loadView {
    NSVisualEffectView *effectView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 280, 460)];
    effectView.material = NSVisualEffectMaterialDark;
    effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effectView.state = NSVisualEffectStateActive;
    
    NSButton *quitBtn = [[NSButton alloc] initWithFrame:NSMakeRect(210, 420, 60, 25)];
    quitBtn.title = @"Выйти";
    quitBtn.bezelStyle = NSBezelStyleRounded;
    quitBtn.font = [NSFont systemFontOfSize:11];
    quitBtn.target = self;
    quitBtn.action = @selector(quitApp);
    [effectView addSubview:quitBtn];
    
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 410, 280, 30)];
    titleLabel.stringValue = @"PauloVPN";
    titleLabel.alignment = NSTextAlignmentCenter;
    titleLabel.bezeled = NO;
    titleLabel.drawsBackground = NO;
    titleLabel.editable = NO;
    titleLabel.font = [NSFont systemFontOfSize:24 weight:NSFontWeightLight];
    titleLabel.textColor = [NSColor whiteColor];
    [effectView addSubview:titleLabel];
    
    self.urlField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 360, 240, 24)];
    self.urlField.placeholderString = @"Вставьте vless:// или подписку...";
    self.urlField.focusRingType = NSFocusRingTypeNone;
    [effectView addSubview:self.urlField];
    
    NSButton *importBtn = [[NSButton alloc] initWithFrame:NSMakeRect(60, 320, 160, 30)];
    importBtn.title = @"Загрузить серверы";
    importBtn.bezelStyle = NSBezelStyleRounded;
    importBtn.target = self;
    importBtn.action = @selector(downloadConfig);
    [effectView addSubview:importBtn];
    
    self.serverDropdown = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 270, 240, 26) pullsDown:NO];
    [self.serverDropdown addItemWithTitle:@"Серверы не загружены"];
    [self.serverDropdown setEnabled:NO];
    [effectView addSubview:self.serverDropdown];
    
    // ПЕРЕИМЕНОВАННЫЙ ЧЕКБОКС
    self.stealthCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 230, 240, 20)];
    [self.stealthCheckbox setButtonType:NSButtonTypeSwitch];
    self.stealthCheckbox.title = @"Умный режим (Только TG/YT/AI)";
    self.stealthCheckbox.state = NSControlStateValueOn;
    self.stealthCheckbox.font = [NSFont systemFontOfSize:11];
    [effectView addSubview:self.stealthCheckbox];
    
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 180, 280, 20)];
    self.statusLabel.stringValue = @"Готов к работе";
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.bezeled = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.editable = NO;
    self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
    [effectView addSubview:self.statusLabel];
    
    self.connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(80, 40, 120, 120)];
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
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *appSupport = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    appSupport = [appSupport URLByAppendingPathComponent:@"AirVPN"];
    [fm createDirectoryAtURL:appSupport withIntermediateDirectories:YES attributes:nil error:nil];
    self.configPath = [[appSupport URLByAppendingPathComponent:@"config.json"] path];
}

- (void)quitApp {
    if (self.currentPID != nil) {
        [self stopVPN];
    }
    // Жестко добиваем все зависшие ядра при выходе
    NSAppleScript *killScript = [[NSAppleScript alloc] initWithSource:@"do shell script \"killall -9 sing-box\" with administrator privileges"];
    [killScript executeAndReturnError:nil];
    [NSApp terminate:nil];
}

// Парсеры (Оставляем как были)
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
        if ([item.name isEqualToString:@"fp"]) tls[@"utls"] = @{@"enabled": @YES, @"fingerprint": item.value};
        if ([item.name isEqualToString:@"type"] && [item.value isEqualToString:@"ws"]) transport[@"type"] = @"ws";
        if ([item.name isEqualToString:@"type"] && [item.value isEqualToString:@"grpc"]) transport[@"type"] = @"grpc";
        if ([item.name isEqualToString:@"path"]) transport[@"path"] = item.value;
        if ([item.name isEqualToString:@"serviceName"]) transport[@"service_name"] = item.value;
        if ([item.name isEqualToString:@"host"]) transport[@"headers"] = @{@"Host": item.value};
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
        @"log": @{@"level": @"info"},
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
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Найдено серверов: %lu", (unsigned long)self.proxyTags.count];
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

- (void)toggleConnection { if (self.currentPID != nil) { [self stopVPN]; } else { [self startVPN]; } }

- (void)startVPN {
    if (!self.downloadedJSON || self.proxyTags.count == 0) { self.statusLabel.stringValue = @"Сначала загрузите серверы."; return; }
    self.statusLabel.stringValue = @"Создаем туннель...";
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
    
    // ИСПРАВЛЕНИЕ 1: ДОБАВЛЯЕМ ВСТРОЕННЫЙ DNS РЕЗОЛВЕР
    self.downloadedJSON[@"dns"] = @{
        @"servers": @[ @{@"tag": @"remote-dns", @"address": @"8.8.8.8", @"detour": activeProxyTag} ],
        @"rules": @[ @{@"outbound": @[@"any"], @"server": @"remote-dns"} ]
    };
    
    // ИСПРАВЛЕНИЕ 2: ДОБАВЛЯЕМ "sniff": true ДЛЯ РАСПОЗНАВАНИЯ ДОМЕНОВ
    self.downloadedJSON[@"inbounds"] = @[ @{
        @"type": @"tun", @"tag": @"tun-in", @"interface_name": @"utun9", @"inet4_address": @"172.19.0.1/30",
        @"auto_route": @YES, @"strict_route": @YES, @"stack": @"system",
        @"sniff": @YES, @"sniff_override_destination": @NO
    } ];
    
    NSMutableDictionary *route = [NSMutableDictionary dictionary];
    NSMutableArray *rules = [NSMutableArray array];
    
    // Обязательно перехватываем DNS
    [rules addObject:@{@"protocol": @[@"dns"], @"outbound": @"dns-out"}];
    
    if (self.stealthCheckbox.state == NSControlStateValueOn) {
        NSArray *blockedDomains = @[ @"telegram.org", @"t.me", @"tdesktop.com", @"whatsapp.com", @"whatsapp.net", @"youtube.com", @"youtu.be", @"ytimg.com", @"googlevideo.com", @"ggpht.com", @"openai.com", @"chatgpt.com", @"oaistatic.com", @"anthropic.com", @"claude.ai", @"gemini.google.com", @"instagram.com", @"cdninstagram.com", @"facebook.com", @"x.com" ];
        NSDictionary *stealthRule = @{ @"domain_suffix": blockedDomains, @"outbound": activeProxyTag };
        [rules addObject:stealthRule];
        route[@"final"] = @"direct"; 
    } else { 
        route[@"final"] = activeProxyTag; 
    }
    
    route[@"rules"] = rules; route[@"auto_detect_interface"] = @YES;
    self.downloadedJSON[@"route"] = route;
    
    NSData *finalData = [NSJSONSerialization dataWithJSONObject:self.downloadedJSON options:0 error:nil];
    [finalData writeToFile:self.configPath atomically:YES];
    
    NSString *logPath = [[self.configPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"vpn.log"];
    NSString *binaryPath = [[NSBundle mainBundle] pathForResource:@"sing-box" ofType:nil];
    NSString *shellCommand = [NSString stringWithFormat:@"nohup '%@' run -c '%@' > '%@' 2>&1 & echo $!", binaryPath, self.configPath, logPath];
    NSString *scriptSource = [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", shellCommand];
    
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorInfo = nil;
    NSAppleEventDescriptor *output = [script executeAndReturnError:&errorInfo];
    
    if (output && output.stringValue && output.stringValue.length > 0) { 
        self.currentPID = output.stringValue; [self updateUIConnected:YES]; 
    } else { 
        self.statusLabel.stringValue = @"Ошибка запуска ядра"; 
    }
}

- (void)stopVPN {
    // Надежное закрытие через killall
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:@"do shell script \"killall -9 sing-box\" with administrator privileges"];
    [script executeAndReturnError:nil];
    self.currentPID = nil;
    [self updateUIConnected:NO];
}

- (void)updateUIConnected:(BOOL)connected {
    if (connected) {
        self.statusLabel.stringValue = self.stealthCheckbox.state == NSControlStateValueOn ? @"Подключено (Умный режим)" : @"Подключено (Глобально)";
        self.statusLabel.textColor = [NSColor greenColor];
        self.connectButton.title = @"ВКЛ";
        self.connectButton.layer.borderColor = [NSColor greenColor].CGColor;
        self.connectButton.layer.backgroundColor = [NSColor colorWithRed:0 green:1 blue:0 alpha:0.1].CGColor;
        [self.serverDropdown setEnabled:NO]; [self.urlField setEnabled:NO]; [self.stealthCheckbox setEnabled:NO];
    } else {
        self.statusLabel.stringValue = @"Готов к работе";
        self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
        self.connectButton.title = @"ВЫКЛ";
        self.connectButton.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.3].CGColor;
        self.connectButton.layer.backgroundColor = [NSColor clearColor].CGColor;
        [self.serverDropdown setEnabled:YES]; [self.urlField setEnabled:YES]; [self.stealthCheckbox setEnabled:YES];
    }
}
@end
