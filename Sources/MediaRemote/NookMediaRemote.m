// Bridge to the system "Now Playing" (MediaRemote), loaded into /usr/bin/perl by nook-media.pl.
// Since macOS 15.4 MediaRemote answers only Apple-signed processes; perl is one, Nook is not.
// Output: one JSON object per line on stdout whenever the track or its state changes.
// Input: commands on stdin, one per line: play, pause, toggle, next, previous, seek <seconds>.
// EOF on stdin (Nook quit) ends the process.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <unistd.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetPID)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSendCommand)(int, NSDictionary *);
typedef void (*MRSetElapsed)(double);

static void *framework;
static NSString *lastLine;
static NSString *lastArtworkKey;
static NSTimer *poll;
static dispatch_source_t input;
static NSMutableData *pending;
static BOOL refreshQueued;

static void *symbol(const char *name) {
    if (!framework) framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    return framework ? dlsym(framework, name) : NULL;
}

static NSString *text(NSDictionary *d, NSString *key) {
    id v = d[key];
    return [v isKindOfClass:NSString.class] ? v : @"";
}

static double number(NSDictionary *d, NSString *key) {
    id v = d[key];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0;
}

static void writeLine(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void emit(NSDictionary *info, BOOL playing, int pid) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"title"] = text(info, @"kMRMediaRemoteNowPlayingInfoTitle");
    out[@"artist"] = text(info, @"kMRMediaRemoteNowPlayingInfoArtist");
    out[@"album"] = text(info, @"kMRMediaRemoteNowPlayingInfoAlbum");
    out[@"duration"] = @(number(info, @"kMRMediaRemoteNowPlayingInfoDuration"));
    out[@"elapsed"] = @(number(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime"));
    out[@"rate"] = @(number(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate"));
    id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    // 0 when the player gives no time: "now" would make every poll look like a change and wake Nook.
    out[@"timestamp"] = @([stamp isKindOfClass:NSDate.class] ? [stamp timeIntervalSince1970] : 0);
    out[@"playing"] = @(playing);
    out[@"pid"] = @(pid);

    // Artwork is large: send it only when it changes.
    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    BOOL hasArt = [art isKindOfClass:NSData.class] && art.length > 0;
    NSString *artKey = [NSString stringWithFormat:@"%@|%@|%@|%lu", text(info, @"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"),
                        out[@"title"], out[@"artist"], (unsigned long)(hasArt ? art.length : 0)];
    BOOL artChanged = hasArt && ![artKey isEqualToString:lastArtworkKey];

    NSData *plain = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
    NSString *line = plain ? [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding] : @"";
    if ([line isEqualToString:lastLine] && !artChanged) return;
    lastLine = line;
    if (artChanged) {
        lastArtworkKey = artKey;
        out[@"artwork"] = [art base64EncodedStringWithOptions:0];
    }
    writeLine(out);
}

static void refresh(void) {
    refreshQueued = NO;
    MRGetInfo getInfo = (MRGetInfo)symbol("MRMediaRemoteGetNowPlayingInfo");
    MRGetPlaying getPlaying = (MRGetPlaying)symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetPID getPID = (MRGetPID)symbol("MRMediaRemoteGetNowPlayingApplicationPID");
    if (!getInfo || !getPlaying || !getPID) return;
    dispatch_queue_t main = dispatch_get_main_queue();
    getInfo(main, ^(NSDictionary *info) {
        getPlaying(main, ^(Boolean playing) {
            getPID(main, ^(int pid) { emit(info ?: @{}, playing, pid); });
        });
    });
}

/// Several notifications arrive together on a track change; one refresh covers them.
static void scheduleRefresh(void) {
    if (refreshQueued) return;
    refreshQueued = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ refresh(); });
}

static void run(NSString *command) {
    NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
    NSString *name = parts.firstObject;
    if ([name isEqualToString:@"seek"] && parts.count > 1) {
        MRSetElapsed setElapsed = (MRSetElapsed)symbol("MRMediaRemoteSetElapsedTime");
        if (setElapsed) setElapsed(parts[1].doubleValue);
    } else {
        NSDictionary<NSString *, NSNumber *> *codes = @{@"play": @0, @"pause": @1, @"toggle": @2, @"next": @4, @"previous": @5};
        NSNumber *code = codes[name];
        MRSendCommand send = (MRSendCommand)symbol("MRMediaRemoteSendCommand");
        if (code && send) send(code.intValue, nil);
    }
    scheduleRefresh();
}

static void readInput(void) {
    char buffer[512];
    ssize_t n = read(STDIN_FILENO, buffer, sizeof buffer);
    if (n <= 0) exit(0);
    [pending appendBytes:buffer length:(NSUInteger)n];
    while (true) {
        NSRange newline = [pending rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, pending.length)];
        if (newline.location == NSNotFound) break;
        NSData *lineData = [pending subdataWithRange:NSMakeRange(0, newline.location)];
        [pending replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        NSString *command = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (command.length) run(command);
    }
}

/// Entry point, installed as a perl XSUB; never returns.
void nook_stream(void) {
    @autoreleasepool {
        pending = [NSMutableData data];
        MRRegister registerForNotifications = (MRRegister)symbol("MRMediaRemoteRegisterForNowPlayingNotifications");
        if (registerForNotifications) registerForNotifications(dispatch_get_main_queue());
        const char *names[] = {"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                               "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                               "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"};
        for (int i = 0; i < 3; i++) {
            CFStringRef *name = (CFStringRef *)symbol(names[i]);
            if (!name || !*name) continue;
            [NSNotificationCenter.defaultCenter addObserverForName:(__bridge NSString *)*name object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *note) { scheduleRefresh(); }];
        }
        // Some players post no notifications; a slow poll catches them (unchanged state prints nothing).
        poll = [NSTimer scheduledTimerWithTimeInterval:10 repeats:YES block:^(NSTimer *timer) { refresh(); }];
        poll.tolerance = 2;
        input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(input, ^{ readInput(); });
        dispatch_resume(input);
        writeLine(@{@"ready": @YES});
        refresh();
    }
    CFRunLoopRun();
}
