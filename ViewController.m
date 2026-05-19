#import "ViewController.h"

@interface ViewController ()
@property (strong) NSTextField *urlField;
@property (strong) NSTextField *statusLabel;
@property (strong) NSButton *connectButton;
@property (strong) NSString *currentPID;
@property (strong) NSString *configPath;
@end

@implementation ViewController

- (void)loadView {
    // 1. Главный фон (Матовое стекло)
    NSVisualEffectView *effectView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 280, 360)];
    effectView.material = NSVisualEffectViewMaterialDark;
    effectView.blendingMode = NSVisualEffectViewBlendingModeBehindWindow;
    effectView.state = NSVisualEffectViewStateActive;
    
    // 2. Заголовок
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 310, 280, 30)];
    titleLabel.stringValue = @"AirVPN";
    titleLabel.alignment = NSTextAlignmentCenter;
    titleLabel.bezeled = NO;
    titleLabel.drawsBackground = NO;
    titleLabel.editable = NO;
    titleLabel.font = [NSFont systemFontOfSize:24 weight:NSFontWeightLight];
    titleLabel.textColor = [NSColor whiteColor];
    [effectView addSubview:titleLabel];
    
    // 3. Поле ввода для ссылки на конфиг
    self.urlField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 250, 240, 24)];
    self.urlField.placeholderString = @"Paste JSON Config URL here...";
    self.urlField.focusRingType = NSFocusRingTypeNone;
    [effectView addSubview:self.urlField];
    
    // 4. Кнопка импорта
    NSButton *importBtn = [[NSButton alloc] initWithFrame:NSMakeRect(80, 210, 120, 30)];
    importBtn.title = @"Download Config";
    importBtn.bezelStyle = NSBezelStyleRounded;
    importBtn.target = self;
    importBtn.action = @selector(downloadConfig);
    [effectView addSubview:importBtn];
    
    // 5. Статус
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 170, 280, 20)];
    self.statusLabel.stringValue = @"Ready";
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.bezeled = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.editable = NO;
    self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
    [effectView addSubview:self.statusLabel];
    
    // 6. Огромная круглая кнопка CONNECT
    self.connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(80, 30, 120, 120)];
    self.connectButton.title = @"OFF";
    self.connectButton.font = [NSFont systemFontOfSize:24 weight:NSFontWeightMedium];
    self.connectButton.bordered = NO;
    self.connectButton.wantsLayer = YES;
    self.connectButton.layer.cornerRadius = 60; // Круглая
    self.connectButton.layer.borderWidth = 2.0;
    self.connectButton.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.3].CGColor;
    self.connectButton.layer.backgroundColor = [NSColor clearColor].CGColor;
    self.connectButton.target = self;
    self.connectButton.action = @selector(toggleConnection);
    [effectView addSubview:self.connectButton];
    
    self.view = effectView;
    
    // Подготовка пути для конфига
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *appSupport = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    appSupport = [appSupport URLByAppendingPathComponent:@"AirVPN"];
    [fm createDirectoryAtURL:appSupport withIntermediateDirectories:YES attributes:nil error:nil];
    self.configPath = [[appSupport URLByAppendingPathComponent:@"config.json"] path];
}

- (void)downloadConfig {
    NSString *urlString = self.urlField.stringValue;
    if (urlString.length == 0) {
        self.statusLabel.stringValue = @"Please enter a URL";
        return;
    }
    
    self.statusLabel.stringValue = @"Downloading...";
    NSURL *url = [NSURL URLWithString:urlString];
    
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (data && !error) {
                [data writeToFile:self.configPath atomically:YES];
                self.statusLabel.stringValue = @"Config Saved! Ready to connect.";
            } else {
                self.statusLabel.stringValue = @"Download Failed!";
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
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.configPath]) {
        self.statusLabel.stringValue = @"No config! Please download first.";
        return;
    }
    
    self.statusLabel.stringValue = @"Connecting...";
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
        self.statusLabel.stringValue = @"Auth Failed or Error";
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
        self.statusLabel.stringValue = @"Connected & Secured";
        self.statusLabel.textColor = [NSColor greenColor];
        self.connectButton.title = @"ON";
        self.connectButton.layer.borderColor = [NSColor greenColor].CGColor;
        self.connectButton.layer.backgroundColor = [NSColor colorWithRed:0 green:1 blue:0 alpha:0.1].CGColor;
    } else {
        self.statusLabel.stringValue = @"Ready";
        self.statusLabel.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
        self.connectButton.title = @"OFF";
        self.connectButton.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.3].CGColor;
        self.connectButton.layer.backgroundColor = [NSColor clearColor].CGColor;
    }
}
@end
