#import "MaintenanceEngine.h"

static const NSTimeInterval kDay        = 86400.0;
static const NSInteger      kCacheDays  = 30;     // ~/Library/Caches: files older than this
static const NSInteger      kLogDays    = 90;     // ~/Library/Logs:   files older than this
static const NSInteger      kPurgeDays  = 7;      // our own Trash folders older than this are deleted
static NSString *const kStagePrefix     = @"MacMaintenance-";
static NSString *const kRunsKey         = @"RKTrashRuns";     // [{path, date}] of the Trash folders we created
static NSString *const kTweakedKey      = @"RKAnimTweaked";   // YES while our animation values are in force
static NSString *const kBackupKey       = @"RKAnimBackup";    // "domain|key" -> original value or kAbsent
static NSString *const kAbsent          = @"__absent__";

@implementation RKTuneReport @end

// Animation settings: the same list as `APPLY_UI_TWEAKS` in the maintenance document. Domain
// "-g" is the global domain (what `defaults write -g` writes).
static NSArray *RKTweakList(void) {
    return @[
        @[@"-g",               @"NSAutomaticWindowAnimationsEnabled", @NO],
        @[@"-g",               @"NSWindowResizeTime",                 @0.001],
        @[@"com.apple.finder", @"DisableAllAnimations",               @YES],
        @[@"com.apple.dock",   @"launchanim",                         @NO],
        @[@"com.apple.dock",   @"mineffect",                          @"scale"],
        @[@"com.apple.dock",   @"magnification",                      @NO],
        @[@"com.apple.dock",   @"autohide-delay",                     @0.0],
        @[@"com.apple.dock",   @"autohide-time-modifier",             @0.15],
        @[@"com.apple.dock",   @"expose-animation-duration",          @0.1],
    ];
}
static CFStringRef RKDomain(NSString *d) {
    return [d isEqualToString:@"-g"] ? kCFPreferencesAnyApplication : (__bridge CFStringRef)d;
}
static id RKPrefGet(NSString *dom, NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyValue((__bridge CFStringRef)key, RKDomain(dom),
                                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return v ? CFBridgingRelease(v) : nil;
}
static void RKPrefSet(NSString *dom, NSString *key, id val) {   // val == nil removes the key
    CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)val, RKDomain(dom),
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}
static void RKPrefSync(NSString *dom) {
    CFPreferencesSynchronize(RKDomain(dom), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}
static BOOL RKSameValue(id a, id b) {
    if (!a || !b) return a == b;
    if ([a isKindOfClass:[NSNumber class]] && [b isKindOfClass:[NSNumber class]])
        return fabs([a doubleValue] - [b doubleValue]) < 1e-6;
    return [a isEqual:b];
}
static void RKRestartDock(void) {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/killall";
    t.arguments  = @[@"Dock"];                 // launchd starts it again; takes the new values
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError  = [NSFileHandle fileHandleWithNullDevice];
    @try { [t launch]; } @catch (NSException *e) {}
}

static unsigned long long RKAllocatedSize(NSURL *u) {
    NSNumber *n = nil;
    if ([u getResourceValue:&n forKey:NSURLTotalFileAllocatedSizeKey error:nil] && n) return n.unsignedLongLongValue;
    if ([u getResourceValue:&n forKey:NSURLFileSizeKey error:nil] && n) return n.unsignedLongLongValue;
    return 0;
}

// Total allocated size of a folder (a file counts for itself).
static unsigned long long RKTreeSize(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long sum = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtURL:[NSURL fileURLWithPath:path]
        includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey, NSURLFileSizeKey]
                           options:0 errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
    for (NSURL *u in en) sum += RKAllocatedSize(u);
    return sum;
}

@implementation MaintenanceEngine

- (BOOL)animationsTweaked {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kTweakedKey];
}

// ── 1. caches and logs -> Trash ────────────────────────────────────────────────────────────────
// Candidates are collected first and moved afterwards (moving files out of a tree that is being
// enumerated is undefined). Symlinks and directories are never moved, only regular files.
- (void)moveOldFilesFrom:(NSString *)src days:(NSInteger)days into:(NSString *)destRoot
                  report:(RKTuneReport *)rep {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:src isDirectory:&isDir] || !isDir) return;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-(days * kDay)];
    NSArray *keys = @[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey, NSURLContentModificationDateKey,
                      NSURLTotalFileAllocatedSizeKey, NSURLFileSizeKey];
    NSMutableArray<NSURL *> *old = [NSMutableArray array];
    NSDirectoryEnumerator *en = [fm enumeratorAtURL:[NSURL fileURLWithPath:src]
        includingPropertiesForKeys:keys options:0
                      errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
    for (NSURL *u in en) {
        NSNumber *reg = nil, *link = nil; NSDate *mod = nil;
        [u getResourceValue:&reg  forKey:NSURLIsRegularFileKey error:nil];
        [u getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
        [u getResourceValue:&mod  forKey:NSURLContentModificationDateKey error:nil];
        if (!reg.boolValue || link.boolValue || !mod) continue;
        if ([mod compare:cutoff] == NSOrderedAscending) [old addObject:u];
    }
    NSString *base = [NSURL fileURLWithPath:src].path;
    for (NSURL *u in old) {
        NSString *full = u.path;
        if (![full hasPrefix:[base stringByAppendingString:@"/"]]) continue;
        NSString *rel = [full substringFromIndex:base.length + 1];
        NSString *dst = [destRoot stringByAppendingPathComponent:rel];
        unsigned long long sz = RKAllocatedSize(u);
        [fm createDirectoryAtPath:dst.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                       attributes:nil error:nil];
        if ([fm moveItemAtPath:full toPath:dst error:nil]) { rep.movedBytes += sz; rep.movedFiles++; }
    }
}

// ── 2. our own old Trash folders ───────────────────────────────────────────────────────────────
// Every run's folder is put into the Trash with the system call (trashItemAtURL: works without Full
// Disk Access on 10.14+, a direct move into ~/.Trash does not) and its resulting path is recorded.
// Only those recorded folders are deleted, and only after a week; nothing else in the Trash is read
// or touched. Returns the records that are still waiting (or could not be deleted yet).
- (NSArray *)purgeOldRuns:(NSArray *)runs report:(RKTuneReport *)rep {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:-(kPurgeDays * kDay)];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSDictionary *r in runs) {
        NSString *p = r[@"path"]; NSDate *d = r[@"date"];
        if (![p isKindOfClass:[NSString class]] || ![d isKindOfClass:[NSDate class]]) continue;
        if (![fm fileExistsAtPath:p]) continue;                       // already restored or emptied by the person
        if ([d compare:limit] != NSOrderedAscending) { [keep addObject:r]; continue; }
        unsigned long long sz = RKTreeSize(p);
        if ([fm removeItemAtPath:p error:nil]) rep.purgedBytes += sz; else [keep addObject:r];
    }
    while (keep.count > 30) [keep removeObjectAtIndex:0];             // bounded, even if deletion keeps failing
    return keep;
}

// ── 3. animations ──────────────────────────────────────────────────────────────────────────────
// Original values are saved once, before the first change, so "restore" returns exactly what the
// person had (not just the macOS defaults). The Dock is restarted only if one of its keys changed;
// the Finder is NOT restarted (it would close its windows) — it takes its value at the next launch.
- (BOOL)applyAnimations {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *backup = [([ud dictionaryForKey:kBackupKey] ?: @{}) mutableCopy];
    BOOL changed = NO, dockChanged = NO;
    NSMutableSet *domains = [NSMutableSet set];
    for (NSArray *t in RKTweakList()) {
        NSString *dom = t[0], *key = t[1]; id want = t[2];
        id cur = RKPrefGet(dom, key);
        if (RKSameValue(cur, want)) continue;
        NSString *bk = [NSString stringWithFormat:@"%@|%@", dom, key];
        if (![ud boolForKey:kTweakedKey] || !backup[bk]) backup[bk] = cur ?: kAbsent;
        RKPrefSet(dom, key, want);
        [domains addObject:dom];
        changed = YES;
        if ([dom isEqualToString:@"com.apple.dock"]) dockChanged = YES;
    }
    if (changed) {
        [ud setObject:backup forKey:kBackupKey];
        [ud setBool:YES forKey:kTweakedKey];
        for (NSString *d in domains) RKPrefSync(d);
        if (dockChanged) RKRestartDock();
    }
    return changed;
}

- (BOOL)restoreAnimations {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *backup = [ud dictionaryForKey:kBackupKey];
    if (![ud boolForKey:kTweakedKey] || !backup.count) return NO;
    BOOL dockChanged = NO;
    NSMutableSet *domains = [NSMutableSet set];
    for (NSString *bk in backup) {
        NSRange bar = [bk rangeOfString:@"|"];
        if (bar.location == NSNotFound) continue;
        NSString *dom = [bk substringToIndex:bar.location], *key = [bk substringFromIndex:bar.location + 1];
        id orig = backup[bk];
        RKPrefSet(dom, key, [orig isEqual:kAbsent] ? nil : orig);
        [domains addObject:dom];
        if ([dom isEqualToString:@"com.apple.dock"]) dockChanged = YES;
    }
    for (NSString *d in domains) RKPrefSync(d);
    [ud removeObjectForKey:kBackupKey];
    [ud setBool:NO forKey:kTweakedKey];
    if (dockChanged) RKRestartDock();
    return YES;
}

// ── the run ────────────────────────────────────────────────────────────────────────────────────
// Files are first moved (a rename on the same volume, instant) into a staging folder under
// ~/Library/Application Support/Raketa, then that one folder goes to the Trash.
- (void)runWithCompletion:(void (^)(RKTuneReport *))done {
    NSArray *runsBefore = [[NSUserDefaults standardUserDefaults] arrayForKey:kRunsKey] ?: @[];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        RKTuneReport *rep = [[RKTuneReport alloc] init];
        NSString *home  = NSHomeDirectory();
        NSFileManager *fm = [NSFileManager defaultManager];

        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.dateFormat = @"yyyyMMdd-HHmmss";
        NSString *folder = [kStagePrefix stringByAppendingString:[df stringFromDate:[NSDate date]]];
        NSString *stage  = [[home stringByAppendingPathComponent:@"Library/Application Support/Raketa"]
                            stringByAppendingPathComponent:folder];

        [self moveOldFilesFrom:[home stringByAppendingPathComponent:@"Library/Caches"] days:kCacheDays
                          into:[stage stringByAppendingPathComponent:@"OldUserCaches"] report:rep];
        [self moveOldFilesFrom:[home stringByAppendingPathComponent:@"Library/Logs"] days:kLogDays
                          into:[stage stringByAppendingPathComponent:@"OldUserLogs"] report:rep];

        NSMutableArray *runsAfter = [[self purgeOldRuns:runsBefore report:rep] mutableCopy];
        if (rep.movedFiles > 0) {
            NSURL *inTrash = nil;
            if ([fm trashItemAtURL:[NSURL fileURLWithPath:stage isDirectory:YES] resultingItemURL:&inTrash error:nil] && inTrash.path)
                [runsAfter addObject:@{ @"path": inTrash.path, @"date": [NSDate date] }];
            else
                rep.trashFailed = YES;       // the files stay in `stage`; nothing is lost
        }

        rep.freeBytes = -1;
        NSNumber *cap = nil;
        if ([[NSURL fileURLWithPath:home] getResourceValue:&cap forKey:NSURLVolumeAvailableCapacityKey error:nil] && cap)
            rep.freeBytes = cap.longLongValue;

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSUserDefaults standardUserDefaults] setObject:runsAfter forKey:kRunsKey];
            rep.animationsChanged = [self applyAnimations];     // defaults + Dock restart on the main thread
            if (done) done(rep);
        });
    });
}
@end
