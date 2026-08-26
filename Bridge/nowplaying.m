// 「正在播放」的桥（实时状态设计 §5）。
//
// macOS 15.4 起 MediaRemote 不再答复普通进程。同一个调用实测下来：直接跑返回 0 个字段，
// 装进 /usr/bin/perl 里跑返回 13 个。起作用的是宿主进程的平台二进制身份——社区的说法是
// 「bundle identifier 以 com.apple. 开头」，但 perl 进程里读到的 bundle identifier 其实
// 是空的，所以那个说法不对，对的是它是 Apple 签的平台二进制。
//
// 于是这里不需要任何第三方二进制：这个 dylib 由 perl 加载进去，调用就发生在它的身份底下。
//
//   /usr/bin/perl nowplaying.pl <这个 dylib> stream          一行一条 JSON，随变化推送
//   /usr/bin/perl nowplaying.pl <这个 dylib> command pause   发一条控制指令
//
// **不写进 Sources/。** 它不是 Swift 包的一部分，由 Scripts/build-app.sh 单独编译进
// app bundle；放进 Sources/ 会让 SwiftPM 去管一个它管不了的目标。
#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*GetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetClient)(dispatch_queue_t, void (^)(id));
typedef void (*GetIsPlaying)(dispatch_queue_t, void (^)(BOOL));
typedef NSString *(*ClientBundleID)(id);
typedef void (*RegisterNotifications)(dispatch_queue_t);
typedef BOOL (*SendCommand)(int, NSDictionary *);

static void *media;

/// 上一次报出去的封面标识。封面几十 KB，只在换了的时候才带上。
static NSString *lastArtwork;

/// 取框架里那些 NSString 常量（通知名）。
static id Constant(const char *name) {
    void *address = dlsym(media, name);
    return address ? *(__unsafe_unretained id *)address : nil;
}

static double Number(id value) {
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0;
}

/// 把当前状态拼成一行 JSON 打出去。
static void Emit(NSDictionary *info, NSString *bundleID, BOOL playing) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"playing"] = @(playing);
    if (bundleID.length) out[@"bundleID"] = bundleID;

    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    if (title.length) out[@"title"] = title;
    NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
    if (artist.length) out[@"artist"] = artist;
    NSString *album = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
    if (album.length) out[@"album"] = album;

    id duration = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
    if (duration) out[@"duration"] = @(Number(duration));
    id elapsed = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
    if (elapsed) out[@"elapsed"] = @(Number(elapsed));
    id rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
    if (rate) out[@"rate"] = @(Number(rate));
    // 进度在条那边本地推算，而推算的起点是「这个 elapsed 是什么时候的读数」。
    // 没有这个时间戳就只能去轮询，而轮询正是这座桥想省掉的东西。
    NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([stamp isKindOfClass:[NSDate class]]) {
        out[@"timestamp"] = @(stamp.timeIntervalSince1970);
    }

    NSString *artworkID = info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"];
    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if (artworkID.length) out[@"artworkID"] = artworkID;
    if (artwork.length && (!artworkID.length || ![artworkID isEqualToString:lastArtwork])) {
        out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
        lastArtwork = artworkID;
    }

    NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    // stdout 接的是管道，默认全缓冲。不冲，条那边一行也收不到（实测踩过）。
    fflush(stdout);
}

/// 取一次完整状态：曲目信息、是谁在放、放没放。三个调用都是异步的，凑齐再报。
static void Sample(void) {
    GetInfo getInfo = (GetInfo)dlsym(media, "MRMediaRemoteGetNowPlayingInfo");
    GetClient getClient = (GetClient)dlsym(media, "MRMediaRemoteGetNowPlayingClient");
    GetIsPlaying getIsPlaying =
        (GetIsPlaying)dlsym(media, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    ClientBundleID clientBundleID =
        (ClientBundleID)dlsym(media, "MRNowPlayingClientGetBundleIdentifier");
    if (!getInfo) return;

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    __block NSDictionary *info = nil;
    __block NSString *bundleID = nil;
    __block BOOL playing = NO;
    dispatch_group_t group = dispatch_group_create();

    dispatch_group_enter(group);
    getInfo(queue, ^(NSDictionary *result) {
        info = result;
        dispatch_group_leave(group);
    });
    if (getClient && clientBundleID) {
        dispatch_group_enter(group);
        getClient(queue, ^(id client) {
            if (client) bundleID = clientBundleID(client);
            dispatch_group_leave(group);
        });
    }
    if (getIsPlaying) {
        dispatch_group_enter(group);
        getIsPlaying(queue, ^(BOOL result) {
            playing = result;
            dispatch_group_leave(group);
        });
    }
    if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
        fprintf(stderr, "nowplaying: 三秒内没凑齐一次采样\n");
        return;
    }
    Emit(info, bundleID, playing);
}

static void Stream(void) {
    RegisterNotifications registerNotifications =
        (RegisterNotifications)dlsym(media, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!registerNotifications) {
        fprintf(stderr, "nowplaying: 找不到 MRMediaRemoteRegisterForNowPlayingNotifications\n");
        exit(1);
    }
    // 不能挂主队列：宿主 perl 的主线程在读 stdin，那个队列没有人抽。
    registerNotifications(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    // 观察者也给一条自己的队列，免得投递依赖发送方那个线程上有没有 runloop。
    NSOperationQueue *delivery = [[NSOperationQueue alloc] init];
    delivery.maxConcurrentOperationCount = 1;

    NSArray *symbols = @[
        @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
        @"kMRNowPlayingPlaybackQueueChangedNotification",
    ];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSString *symbol in symbols) {
        NSString *name = Constant(symbol.UTF8String);
        if (!name) {
            fprintf(stderr, "nowplaying: 没有 %s，跳过\n", symbol.UTF8String);
            continue;
        }
        [center addObserverForName:name object:nil queue:delivery
                        usingBlock:^(NSNotification *_) { Sample(); }];
    }
    // 先报一次当前状态：条刚起来时要立刻知道有没有在放，不能等到下一次换歌。
    Sample();
    // 这条线程到此为止。进程由宿主 perl 撑着——它在读 stdin，条那边一关管道就 EOF，
    // 这个进程随之退出。两端都不必去盯对方的 pid。
}

static void Command(const char *name) {
    SendCommand send = (SendCommand)dlsym(media, "MRMediaRemoteSendCommand");
    if (!send) {
        fprintf(stderr, "nowplaying: 找不到 MRMediaRemoteSendCommand\n");
        exit(1);
    }
    NSDictionary *codes = @{
        @"play": @0, @"pause": @1, @"toggle": @2, @"stop": @3,
        @"next": @4, @"previous": @5,
    };
    NSNumber *code = codes[[NSString stringWithUTF8String:name]];
    if (!code) {
        fprintf(stderr, "nowplaying: 不认识的指令 %s\n", name);
        exit(1);
    }
    BOOL ok = send(code.intValue, @{});
    // 指令是发出去就不管的。立刻退出有可能赶在它真正送达之前把进程收掉，
    // 停一下再走——这是这里唯一一处凭经验取的数。
    usleep(400 * 1000);
    exit(ok ? 0 : 1);
}

static void Run(int argc, const char **argv) {
    @autoreleasepool {
        media = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!media) {
            fprintf(stderr, "nowplaying: 打不开 MediaRemote：%s\n", dlerror());
            exit(1);
        }
        // argv 是宿主 perl 的整条命令行：perl 脚本 dylib 动作 [参数]
        const char *action = argc > 3 ? argv[3] : "get";
        if (strcmp(action, "stream") == 0) {
            Stream();
        } else if (strcmp(action, "command") == 0 && argc > 4) {
            Command(argv[4]);
        } else {
            Sample();
            exit(0);
        }
    }
}

// 构造函数里不能直接干活：那时 dyld 还没加载完，从里面发 XPC 收不到回调（实测五秒无声）。
// 甩到后台线程，等宿主进程自己起来。
__attribute__((constructor)) static void boot(int argc, const char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    static int savedArgc;
    static const char **savedArgv;
    savedArgc = argc;
    savedArgv = argv;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        Run(savedArgc, savedArgv);
    });
}
