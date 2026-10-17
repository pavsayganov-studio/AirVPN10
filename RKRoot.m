#import "RKRoot.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/select.h>
#include <sys/time.h>

// Defaults key: `defaults write com.samurai.raketa RKSessionAuth -bool NO` turns the session off
// (every step then asks for the password itself, as in v0.14.2).
static NSString *const kRKSessionKey = @"RKSessionAuth";

// One password prompt for the whole session; the text says so, because it is longer-lived than before.
static NSString *const kRKSessionPrompt = @"Raketa: доступ к сети на время работы (пароль — один раз)";

// '...' quoting for /bin/sh.
static NSString *RKShellQuote(NSString *s) {
    return [NSString stringWithFormat:@"'%@'",
            [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}
// Escaping for an AppleScript string literal: backslash first, then the quote.
static NSString *RKASEscape(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    return [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

@interface RKRoot () {
    NSString *_script, *_sup, *_res, *_dir;
    int  _cmd, _ack;
    BOOL _active, _broken;      // _broken: the session failed once; stay on the legacy path until relaunch
}
@end

@implementation RKRoot

- (instancetype)initWithHelperScript:(NSString *)scriptPath supportDir:(NSString *)supportDir
                        resourcesDir:(NSString *)resourcesDir {
    if ((self = [super init])) {
        _script = [scriptPath copy]; _sup = [supportDir copy]; _res = [resourcesDir copy];
        _cmd = _ack = -1;
    }
    return self;
}

- (BOOL)active { return _active; }

- (BOOL)enabled {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kRKSessionKey];
    return !(v && ![v boolValue]);
}

- (void)closeFDs {
    if (_cmd >= 0) close(_cmd);
    if (_ack >= 0) close(_ack);
    _cmd = _ack = -1; _active = NO;
}

// The ONE prompt. Everything the helper needs is created here as root, before it starts: its private
// directory (per app pid, so a dying older helper can never remove a newer session's directory), the
// helper script itself (written by root, so it cannot be swapped by the person's processes) and the
// two FIFOs owned by the person (0600).
- (RKRootStatus)startSession {
    if (!_script.length || ![[NSFileManager defaultManager] isReadableFileAtPath:_script]) return RKRootUnavailable;
    NSData *code = [NSData dataWithContentsOfFile:_script];
    if (!code.length) return RKRootUnavailable;
    NSString *b64 = [code base64EncodedStringWithOptions:0];
    unsigned uid = (unsigned)getuid();
    int pid = (int)getpid();
    _dir = [NSString stringWithFormat:@"/var/run/raketa.%u.%d", uid, pid];

    NSString *d = RKShellQuote(_dir);
    NSString *sh = [NSString stringWithFormat:
        @"D=%@; rm -rf \"$D\"; mkdir -p \"$D\" && chmod 755 \"$D\" && "
        @"echo '%@' | /usr/bin/base64 -D > \"$D/helper.sh\" && chmod 700 \"$D/helper.sh\" && "
        @"mkfifo \"$D/cmd\" \"$D/ack\" && chown %u \"$D/cmd\" \"$D/ack\" && chmod 600 \"$D/cmd\" \"$D/ack\" && "
        @"(/bin/bash \"$D/helper.sh\" %u %d \"$D\" %@ %@ </dev/null >/dev/null 2>&1 &) && echo started",
        d, b64, uid, uid, pid, RKShellQuote(_sup), RKShellQuote(_res)];
    NSString *scpt = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges with prompt \"%@\"",
        RKASEscape(sh), RKASEscape(kRKSessionPrompt)];

    NSDictionary *err = nil;
    NSAppleEventDescriptor *res = [[[NSAppleScript alloc] initWithSource:scpt] executeAndReturnError:&err];
    if (err) {
        // -128 = the person cancelled: not a failure, and the next step will ask again.
        if ([err[NSAppleScriptErrorNumber] integerValue] == -128) return RKRootCancelled;
        _broken = YES;
        return RKRootUnavailable;
    }
    if (![[res stringValue] isEqualToString:@"started"]) { _broken = YES; return RKRootUnavailable; }

    // O_RDWR on a FIFO never blocks on open and never sees EOF: the helper and the app can start in any order.
    _cmd = open([[_dir stringByAppendingPathComponent:@"cmd"] fileSystemRepresentation], O_RDWR | O_NONBLOCK);
    _ack = open([[_dir stringByAppendingPathComponent:@"ack"] fileSystemRepresentation], O_RDWR | O_NONBLOCK);
    if (_cmd < 0 || _ack < 0) { [self closeFDs]; _broken = YES; return RKRootUnavailable; }
    _active = YES;
    return RKRootOK;
}

// Waits up to `secs` for one reply line from the helper. nil on timeout.
- (NSString *)readLineWithin:(double)secs {
    NSMutableData *buf = [NSMutableData data];
    struct timeval start; gettimeofday(&start, NULL);
    for (;;) {
        struct timeval now; gettimeofday(&now, NULL);
        double left = secs - ((now.tv_sec - start.tv_sec) + (now.tv_usec - start.tv_usec) / 1e6);
        if (left <= 0) return nil;
        fd_set rf; FD_ZERO(&rf); FD_SET(_ack, &rf);
        struct timeval tv = { (time_t)left, (suseconds_t)((left - (time_t)left) * 1e6) };
        int n = select(_ack + 1, &rf, NULL, NULL, &tv);
        if (n < 0) { if (errno == EINTR) continue; return nil; }
        if (n == 0) return nil;
        char tmp[256];
        ssize_t r = read(_ack, tmp, sizeof tmp);
        if (r < 0) { if (errno == EAGAIN || errno == EINTR) continue; return nil; }
        if (r == 0) return nil;
        [buf appendBytes:tmp length:(NSUInteger)r];
        const char *p = buf.bytes;
        for (NSUInteger i = 0; i < buf.length; i++)
            if (p[i] == '\n') return [[NSString alloc] initWithBytes:p length:i encoding:NSUTF8StringEncoding];
    }
}

- (RKRootStatus)run:(NSArray<NSString *> *)verbAndArgs reply:(NSString **)reply {
    if (reply) *reply = nil;
    @synchronized (self) {
        if (_broken || ![self enabled]) return RKRootUnavailable;
        for (NSString *a in verbAndArgs)             // the wire format is TAB-separated lines
            if ([a rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\t\n\r"]].location != NSNotFound)
                return RKRootUnavailable;
        if (!_active) {
            RKRootStatus s = [self startSession];
            if (s != RKRootOK) return s;
        }
        // Drop anything left from an earlier timed-out request, so replies cannot get out of step.
        char junk[256]; while (read(_ack, junk, sizeof junk) > 0) {}

        NSData *line = [[[verbAndArgs componentsJoinedByString:@"\t"] stringByAppendingString:@"\n"]
                        dataUsingEncoding:NSUTF8StringEncoding];
        if (write(_cmd, line.bytes, line.length) != (ssize_t)line.length) {
            [self closeFDs]; _broken = YES; return RKRootUnavailable;
        }
        // core-start sleeps 0.3 s and runs three networksetup calls: a few seconds on an old Mac.
        NSString *r = [self readLineWithin:12.0];
        if (!r) { [self closeFDs]; _broken = YES; return RKRootUnavailable; }   // helper gone: legacy from now on
        if ([r hasPrefix:@"OK"]) {
            if (reply) *reply = r.length > 3 ? [r substringFromIndex:3] : @"";
            return RKRootOK;
        }
        // ERR <reason>: the helper refused the arguments (an unusual path or interface name).
        // The session is fine; this one step goes through the legacy prompt.
        return RKRootUnavailable;
    }
}

- (void)shutdown {
    @synchronized (self) {
        if (!_active) return;
        const char *q = "quit\n";
        (void)!write(_cmd, q, 5);       // the helper replies, removes its directory and exits
        [self closeFDs];
    }
}
@end
