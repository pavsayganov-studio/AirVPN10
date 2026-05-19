#import "ViewController.h"

@interface ViewController ()
@property (strong) NSTextField *urlField;
@property (strong) NSTextField *statusLabel;
@property (strong) NSButton *connectButton;
@property (strong) NSPopUpButton *serverDropdown;
@property (strong) NSString *currentPID;
@property (strong) NSString *configPath;
@property (strong) NSMutableDictionary *downloadedJSON;
@property (strong) NSMutableArray *proxyTags;
@end

@implementation ViewController

- (void)loadView {
    // 1. Увеличили высоту окна, чтобы влез список
    NSVisualEffectView *effectView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 280, 420)];
    effectView.material = NSVisualEffectMaterialDark;
    effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effectView.state = NSVisualEffectStateActive;
    
    // 2. Заголовок
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 370, 280, 30)];
    titleLabel.stringValue = @"AirVPN";
    titleLabel.alignment = NSTextAlignmentCenter;
    titleLabel.bezeled = NO;
    titleLabel.drawsBackground = NO;
    titleLabel.editable = NO;
    titleLabel.font = [NSFont systemFontOfSize:24 weight:NSFontWeightLight];
    titleLabel.textColor = [NSColor whiteColor];
    [effectView addSubview:titleLabel];
    
    // 3. Поле ввода URL
    self.urlField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 320, 240, 24)];
    self.urlField.placeholderString = @"Paste Subscription URL here...";
    self.urlField.focusRingType = NSFocusRingTypeNone;
    [effectView addSubview:self.urlField];
    
    // 4. Кнопка скачивания
    NSButton *importBtn = [[NSButton alloc] initWithFrame:NSMakeRect(70, 280, 140, 30)];
    importBtn.title = @"Fetch Servers";
    importBtn.bezelStyle = NSBezelStyleRounded;
    importBtn.target = self;
    importBtn.action = @selector(downloadConfig);
    [effectView addSubview:importBtn];
    
    // 5. Выпадающий список серверов (Скрыт до скачивания)
    self.serverDropdown = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 230, 240, 26) pullsDown:NO];
    [self.serverDropdown addItemWithTitle:@"No servers loaded"];
    [self.serverDropdown setEnabled:NO];
    [effectView addSubview:self.serverDropdown];
    
    // 6. Статус
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 180, 280, 20)];
    self.statusLabel.stringValue = @"Ready";
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.bezeled = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.editable = NO;
    self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
    [effectView addSubview:self.statusLabel];
    
    // 7. Кнопка CONNECT
    self.connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(80, 40, 120, 120)];
    self.connectButton.title = @"OFF";
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

- (void)downloadConfig {
    NSString *urlString = self.urlField.stringValue;
    if (urlString.length == 0) return;
    
    self.statusLabel.stringValue = @"Fetching servers...";
    NSURL *url = [NSURL URLWithString:urlString];
    
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) {
                self.statusLabel.stringValue = @"Network Error!";
                return;
            }
            
            NSError *jsonError;
            NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&jsonError];
            
            if (jsonError || !json[@"outbounds"]) {
                self.statusLabel.stringValue = @"Invalid JSON format. Check URL.";
                return;
            }
            
            self.downloadedJSON = json;
            self.proxyTags = [NSMutableArray array];
            
            // Ищем все серверы
            NSArray *outbounds = json[@"outbounds"];
            for (NSDictionary *out = outbounds) {
                NSString *type = out[@"type"];
                NSString *tag = out[@"tag"];
                if (tag && ([type isEqualToString:@"vless"] || [type isEqualToString:@"vmess"] || [type isEqualToString:@"trojan"] || [type isEqualToString:@"shadowsocks"])) {
                    [self.proxyTags addObject:tag];
                }
            }
            
            [self.serverDropdown removeAllItems];
            if (self.proxyTags.count > 0) {
                [self.serverDropdown addItemWithTitle:@"⚡️ Auto (Smart Switch)"];
                [self.serverDropdown addItemsWithTitles:self.proxyTags];
                [self.serverDropdown setEnabled:YES];
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Loaded %lu servers", (unsigned long)self.proxyTags.count];
            } else {
                [self.serverDropdown addItemWithTitle:@"No compatible servers found"];
                self.statusLabel.stringValue = @"No VLESS/Trojan found in JSON.";
            }
        });
    }] resume];
}

- (void)toggleConnection {
    if (self.currentPID != nil) {
        [self stopVPN];
    } else {
        [self startVPN];
    }
}

- (void)startVPN {
    if (!self.downloadedJSON || self.proxyTags.count == 0) {
        self.statusLabel.stringValue = @"Please fetch servers first.";
        return;
    }
    
    self.statusLabel.stringValue = @"Building Tunnel...";
    
    // МАГИЯ АВТО-ПЕРЕКЛЮЧЕНИЯ И ВЫБОРА СЕРВЕРА
    NSString *selectedTitle = self.serverDropdown.titleOfSelectedItem;
    NSMutableArray *newOutbounds = [NSMutableArray arrayWithArray:self.downloadedJSON[@"outbounds"]];
    
    if ([selectedTitle isEqualToString:@"⚡️ Auto (Smart Switch)"]) {
        // Создаем блок urltest для автоматического выбора самого быстрого сервера
        NSDictionary *autoOutbound = @{
            @"type": @"urltest",
            @"tag": @"auto-switch",
            @"outbounds": self.proxyTags,
            @"url": @"http://cp.cloudflare.com/",
            @"interval": @"3m",
            @"tolerance": @50
        };
        [newOutbounds insertObject:autoOutbound atIndex:0]; // Ставим его главным
    } else {
        // Если выбран конкретный сервер, ищем его и ставим первым
        for (int i = 0; i < newOutbounds.count; i++) {
            if ([newOutbounds[i][@"tag"] isEqualToString:selectedTitle]) {
                NSDictionary *selectedOutbound = newOutbounds[i];
                [newOutbounds removeObjectAtIndex:i];
                [newOutbounds insertObject:selectedOutbound atIndex:0];
                break;
            }
        }
    }
    self.downloadedJSON[@"outbounds"] = newOutbounds;
    
    // Сохраняем итоговый конфиг
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
        self.currentPID = output.stringValue;
        [self updateUIConnected:YES];
    } else {
        self.statusLabel.stringValue = @"Failed to start Core";
    }
}

- (void)stopVPN {
    if (!self.currentPID) return;
    NSString *scriptSource = [NSString stringWithFormat:@"do shell script \"kill -9 %@\" with administrator privileges", self.currentPID];
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    [script executeAndReturnError:nil];
    self.currentPID = nil;
    [self updateUIConnected:NO];
}

- (void)updateUIConnected:(BOOL)connected {
    if (connected) {
        self.statusLabel.stringValue = @"Connected";
        self.statusLabel.textColor = [NSColor greenColor];
        self.connectButton.title = @"ON";
        self.connectButton.layer.borderColor = [NSColor greenColor].CGColor;
        self.connectButton.layer.backgroundColor = [NSColor colorWithRed:0 green:1 blue:0 alpha:0.1].CGColor;
        [self.serverDropdown setEnabled:NO];
        [self.urlField setEnabled:NO];
    } else {
        self.statusLabel.stringValue = @"Ready";
        self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
        self.connectButton.title = @"OFF";
        self.connectButton.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.3].CGColor;
        self.connectButton.layer.backgroundColor = [NSColor clearColor].CGColor;
        [self.serverDropdown setEnabled:YES];
        [self.urlField setEnabled:YES];
    }
}
@end
