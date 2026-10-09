// ============================================================================
//  SIOBackground — 真后台保活（v3.0 重构版，源自 v2.x 的 FUBackground 引擎）
// ============================================================================
//  原实现（v2.5.0 的 FUBG 段）功能是对的，但接入方式有三处结构性问题：
//
//   ① **两套生命周期回调**：v2.1.0 之前注册在 Darwin 中心却监听 NSNotification
//      名字，回调永不触发 → gPhysBg 永远 NO → 场景伪装/音频断言/自愈轮询
//      「三个功能从未执行过一行代码」。这个 bug 已修，但修复方式是就地又加了
//      一套 NSNotificationCenter 观察者，与既有的 Darwin 观察者并存，
//      留下两份生命周期状态。
//      v3.0：只有 NSNotificationCenter 一条路径（UIApplication 生命周期本来就是
//      NSNotification，Darwin 中心只投递 notify_post 的名字，两者互不相通）。
//
//   ② **配置读了两遍**：动画侧 SIO_reload() 读一次 plist，保活侧 _fbg_loadPref()
//      又读一次，两边还各自解析黑名单。
//      v3.0：统一复用 SIOConfig 的 SIOPrefSnapshot()（唯一磁盘读取出口），
//      黑名单复用 gSIOBlacklistItems（唯一匹配实现），本模块只额外读
//      FUBG 专属的 3 个键 + FUBGExcludeApps。
//
//   ③ **音频断言把 AVFoundation 拖进启动路径**（v2.0.7 已修为 dlopen 惰性加载）。
//      v3.0 保留该修复，并进一步把「是否有可能用到音频」前置成配置判定 ——
//      配置里没开音频断言时，连 dlopen 的那一行都不会执行。
//
//  红线 #4：不使用保活的 App，启动路径上不得出现 AVFoundation / UserNotifications。
//  本文件因此**只包含 Foundation/UIKit**，所有 AVFoundation / UserNotifications
//  符号一律 objc_getClass + dlsym 运行时解析（见 _SIOSceneInstall 与
//  _SIOAudioEnsure）。
// ============================================================================

#import "SIOInternal.h"
#include "support/FUBGNoiseData.h"   // kFBGNoiseB64：静音白噪声，音频断言用

#pragma mark - 休眠输入（保持 ABI 稳定，勿改）

// AVAudioSession 选项/类型常量（iOS 6/10 起冻结的 ABI 值，可直接内联）：
//   AVAudioSessionCategoryOptionMixWithOthers               = 1
//   AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation = 1
//   AVAudioSessionInterruptionTypeEnded                     = 0
//   AVAudioSessionInterruptionOptionShouldResume            = 1
#define kSIOAVMixWithOthers        ((NSUInteger)1)
#define kSIOAVNotifyOthers         ((NSUInteger)1)
#define kSIOAVIntTypeEnded         ((NSUInteger)0)
#define kSIOAVIntOptionShouldResume ((NSUInteger)1)

// 通知展示选项：Badge=1 Sound=2 Alert=4 Banner=16(iOS14+)。部署目标 iOS 14+。
#define kSIOUNPresentBannerSoundBadge ((NSUInteger)19)

// 惰性协议的声明形态：用 @protocol 而不是 #import <AVFoundation/...>，
// 这样编译期完全不依赖 AVFoundation 头文件。
@protocol SIOAVPlayer <NSObject>
- (instancetype)initWithData:(NSData *)data error:(NSError **)outError;
- (BOOL)prepareToPlay;
- (BOOL)play;
- (void)pause;
- (BOOL)isPlaying;
- (void)setNumberOfLoops:(NSInteger)n;
- (void)setVolume:(float)v;
@end

@protocol SIOAVSession <NSObject>
- (BOOL)setCategory:(NSString *)category withOptions:(NSUInteger)options error:(NSError **)outError;
- (BOOL)setActive:(BOOL)active error:(NSError **)outError;
- (BOOL)setActive:(BOOL)active withOptions:(NSUInteger)options error:(NSError **)outError;
@end

#pragma mark - 模块状态

static BOOL       gSIOBgEnabled  = YES;   // 保活总开关
static BOOL       gSIOBgScene    = YES;   // 场景伪装
static BOOL       gSIOBgAudio    = YES;   // 音频断言
static NSArray   *gSIOBgExclude  = nil;   // 排除表（FUBGExcludeApps ∪ Blacklist）
static BOOL       gSIOBgLoaded   = NO;

static BOOL       gSIOBgActive   = NO;    // 本 App 是否参与保活
static BOOL       gSIOBgUseScene = NO;    // 是否启用场景伪装
static BOOL       gSIOBgUseAudio = NO;    // 是否启用音频断言
static BOOL       gSIOBgPhysBg   = NO;    // 物理上是否处于后台
static BOOL       gSIOBgHasAudioMode = NO;// 宿主 Info.plist 是否含 audio 后台模式

static void (*gSIOOrigSceneUpdate)(id, SEL, id, id, id, id);
static UIApplicationState (*gSIOOrigAppState)(id, SEL);
static void (*gSIOOrigWillPresent)(id, SEL, id, id, void (^)(NSUInteger));
static void (*gSIOOrigUNSetDelegate)(id, SEL, id);

static id<SIOAVPlayer>  gSIOPlayer = nil;
static id               gSIOAVSessionCls = nil;
static Class            gSIOAVPlayerCls  = nil;
static NSString        *gSIOAVCatPlayback = nil;
static NSString        *gSIOAVNoteInt = nil;
static NSString        *gSIOAVNoteRoute = nil;
static NSString        *gSIOAVKeyIntType = nil;
static NSString        *gSIOAVKeyIntOption = nil;

// 桥接任务标识。UIBackgroundTaskInvalid 不是文件级编译期常量，故用 0 表示「无」。
static UIBackgroundTaskIdentifier gSIOBgTask = 0;
static NSTimer *gSIOBgWatchdog = nil;

#pragma mark - 内置排除

// 保活的**内置**排除表：这些进程绝不能做保活（要么没有 UIApplication 语义，
// 要么本身就是系统后台服务的宿主）。优先级高于任何配置 —— 配置里也打不开。
static BOOL SIOBgBuiltinExcluded(void) {
    NSString *bid = SIOBundleID();
    if (!bid.length) return NO;
    if ([bid isEqualToString:@"com.apple.springboard"])            return YES;
    if ([bid isEqualToString:@"com.apple.backboardd"])             return YES;
    if ([bid isEqualToString:@"com.apple.runningboardd"])          return YES;
    if ([bid hasPrefix:@"com.apple.Preferences"])                  return YES;
    return NO;
}

// 排除判定：复用全项目唯一的 SIOBundleMatches（精确 + 尾 `*` 前缀）。
// v2.1.0 修过一个真 bug：原实现用 hasPrefix:，配置里写 com.tencent.wework
// 会连带排除 com.tencent.weworkhelper 等一串无关 App。
static BOOL SIOBgIsExcluded(void) {
    if (SIOBgBuiltinExcluded()) return YES;
    for (NSString *b in gSIOBgExclude) {
        if (SIOBundleMatches(b)) return YES;
    }
    return NO;
}

static void SIOBgRecalc(void) {
    gSIOBgActive   = gSIOBgEnabled && !SIOBgIsExcluded();
    gSIOBgUseScene = gSIOBgActive && gSIOBgScene;
    // 音频断言额外需要「宿主声明了 audio 后台模式」（否则 iOS 会在几秒后
    // 直接杀掉进程，抢占式断言反而更早被杀）。无该模式时仍可尝试 ——
    // 部分巨魔环境放开了限制，但作为降级路径记录在诊断里。
    gSIOBgUseAudio = gSIOBgActive && gSIOBgAudio;
}

#pragma mark - 配置（复用唯一的 plist 快照）

static void SIOBgLoadPref(void) {
    @try {
        // 复用 SIOConfig 的唯一快照 —— 不再第二次读 plist（v2.x 的重复 IO）。
        NSDictionary *d = SIOPrefSnapshot();
        if (d) {
            id v;
            if ((v = d[@"FUBGEnabled"]))   gSIOBgEnabled = [v boolValue];
            if ((v = d[@"FUBGSceneFake"])) gSIOBgScene   = [v boolValue];
            if ((v = d[@"FUBGAudioKeep"])) gSIOBgAudio   = [v boolValue];

            // 排除表 = FUBGExcludeApps ∪ Blacklist。
            // v1.8.12 修过的坑：原实现先赋 FUBGExcludeApps、紧接着被 Blacklist
            // 无条件覆盖 —— 只要配置里存在 Blacklist（配置 App 默认会写），
            // 排除表就永久失效。这里保持「并集」语义。
            NSMutableArray *clean = [NSMutableArray array];
            id rawEx = d[@"FUBGExcludeApps"];
            if ([rawEx isKindOfClass:[NSArray class]]) {
                NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
                for (id it in (NSArray *)rawEx) {
                    if (![it isKindOfClass:[NSString class]]) continue;
                    NSString *s = [(NSString *)it stringByTrimmingCharactersInSet:ws];
                    if (s.length) [clean addObject:s];
                }
            }
            // Blacklist 已在 SIOConfig 里清洗过一遍，直接复用（唯一解析）。
            if (gSIOBlacklistItems.count) [clean addObjectsFromArray:gSIOBlacklistItems];
            gSIOBgExclude = clean;

            // App 级覆盖：与动画侧共用同一份 AppOverrides 语义。
            NSDictionary *ovr = SIOAppOverrideLookup(d);
            if (ovr) {
                if ((v = ovr[@"FUBGEnabled"]))   gSIOBgEnabled = [v boolValue];
                if ((v = ovr[@"FUBGSceneFake"])) gSIOBgScene   = [v boolValue];
                if ((v = ovr[@"FUBGAudioKeep"])) gSIOBgAudio   = [v boolValue];
            }
        }
    } @catch (__unused NSException *e) {}
    if (!gSIOBgExclude) gSIOBgExclude = @[];

    // 宿主是否声明 audio 后台模式（决定音频断言的可行性）。
    id modes = [[NSBundle mainBundle] infoDictionary][@"UIBackgroundModes"];
    gSIOBgHasAudioMode = [modes isKindOfClass:[NSArray class]] &&
                         [(NSArray *)modes containsObject:@"audio"];

    gSIOBgLoaded = YES;
    SIOBgRecalc();
}

#pragma mark - 引擎一：场景伪装
// 思路移植自 ImmortalizerJailed（GPLv3），致谢 @khanhduytran0。
// 原理：把「让本 App 退到后台」的那条 FBScene 设置变更吞掉，使 App 在系统
// 视角里仍在前台；再伪装 applicationState 让 App 自己以为还在活跃态。
// 这是**唯一**不依赖音频、不占后台任务额度的真后台手段，但需要私有类存在。

// 判断一条场景设置变更是否属于「后台化」。参数 desc 是 [arg2 description]，
// 由调用方**无条件**生成（可能数 KB）。我们无法省掉上游的 description，
// 但可以把下游扫描从「7 次独立全串扫描」降到「1 次定位 + 局部比较」：
// 4 条 foreground 判据都以 "foreground = " 开头，先定位再比紧随其后的字符。
static BOOL SIOBgIsBackgroundingDiff(NSString *desc) {
    if (!desc) return NO;

    NSRange fg = [desc rangeOfString:@"foreground = "];
    if (fg.location != NSNotFound) {
        NSUInteger start = fg.location + fg.length;
        NSUInteger len = desc.length;
        if (start < len) {
            NSUInteger avail = len - start;
            // 比较 4 种写法：NotSet / No / BSSettingFlagNo / NO
            if ([desc compare:@"NotSet" options:0
                        range:NSMakeRange(start, MIN((NSUInteger)6, avail))] == NSOrderedSame) return YES;
            if ([desc compare:@"No" options:0
                        range:NSMakeRange(start, MIN((NSUInteger)2, avail))] == NSOrderedSame) return YES;
            if ([desc compare:@"BSSettingFlagNo" options:0
                        range:NSMakeRange(start, MIN((NSUInteger)15, avail))] == NSOrderedSame) return YES;
            if ([desc compare:@"NO" options:0
                        range:NSMakeRange(start, MIN((NSUInteger)2, avail))] == NSOrderedSame) return YES;
        }
    }
    // 后台切换器快照相关更新同样吞掉，避免快照暴露 / 状态推进。
    if ([desc containsString:@"hostContextIdentifierForSnapshotting = 0"] ||
        [desc containsString:@"scenePresenterRenderIdentifierForSnapshotting = 0"] ||
        [desc containsString:@"targetOfEventDeferringEnvironments = (empty)"] ||
        [desc containsString:@"FBSceneSnapshotAction:"]) {
        return YES;
    }
    return NO;
}

static void SIOBgSceneUpdate(id self, SEL _cmd, id a1, id a2, id a3, id a4) {
    if (!gSIOOrigSceneUpdate) return;
    if (gSIOBgUseScene) {
        @try {
            if (SIOBgIsBackgroundingDiff([a2 description])) return;   // 吞掉
        } @catch (__unused NSException *e) {}
    }
    gSIOOrigSceneUpdate(self, _cmd, a1, a2, a3, a4);
}

// applicationState 伪装。推送/通知框架需要真实答案（前台态时它们不会建立
// 后台接收通道），因此需要识别调用方是否来自推送框架。
// 调用点地址稳定，用 8 槽直映缓存记住判定结果；多线程并发写同一槽最坏
// 只是重算一次（结果幂等），无需加锁。
// v2.5.0 的实质优化：去掉 NSString 分配 —— dli_fname 本来就是 C 字符串，
// 直接用 strstr 判定，每次省一次 malloc + free。后台期这是高频查询。
static UIApplicationState SIOBgAppState(id self, SEL _cmd) {
    if (gSIOBgUseScene && gSIOBgPhysBg) {
        void *ret = __builtin_extract_return_addr(__builtin_return_address(0));
        static void *cacheAddr[8] = {0};
        static BOOL  cacheIsPush[8] = {0};

        uintptr_t ka = (uintptr_t)ret;
        uintptr_t slot = ((ka >> 4) ^ (ka >> 20) ^ (ka >> 36)) & 7;
        BOOL isPush;
        if (__builtin_expect(cacheAddr[slot] == ret, 1)) {
            isPush = cacheIsPush[slot];
        } else {
            isPush = NO;
            Dl_info info;
            if (dladdr(ret, &info) && info.dli_fname) {
                if (strstr(info.dli_fname, "UserNotifications") ||
                    strstr(info.dli_fname, "PushKit")) {
                    isPush = YES;
                }
            }
            cacheAddr[slot] = ret;
            cacheIsPush[slot] = isPush;
        }
        return isPush ? UIApplicationStateBackground : UIApplicationStateActive;
    }
    return gSIOOrigAppState ? gSIOOrigAppState(self, _cmd) : UIApplicationStateActive;
}

// 通知横幅伪装：后台期把「不展示」改成「横幅+声音+角标」，让用户仍能收到提醒。
static void SIOBgWillPresent(id self, SEL _cmd, id center, id note,
                             void (^handler)(NSUInteger)) {
    if (gSIOBgUseScene && gSIOBgPhysBg) {
        if (handler) handler(kSIOUNPresentBannerSoundBadge);
        return;
    }
    if (gSIOOrigWillPresent) gSIOOrigWillPresent(self, _cmd, center, note, handler);
}

// UNUserNotificationCenter 是延迟解析的（宿主不用通知框架时类不存在）——
// 拿不到就少一层横幅伪装，不影响其它功能（红线 #3）。
static void SIOBgUNSetDelegate(id self, SEL _cmd, id delegate) {
    if (gSIOOrigUNSetDelegate) gSIOOrigUNSetDelegate(self, _cmd, delegate);
    if (!delegate) return;
    Class dc = [delegate class];
    SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
    Method m = class_getInstanceMethod(dc, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur != (IMP)SIOBgWillPresent) {
        gSIOOrigWillPresent = (void *)cur;
        // 这里是本项目唯一一处**有意**不走 SIOExchange 的交换，原因如下：
        // willPresentNotification: 是 UNUserNotificationCenterDelegate 的协议方法，
        // 实现它的类由宿主 App 决定（可能是任意自定义类，运行时才知道）。
        // SIOExchange 需要一个编译期的类名常量，这里拿不到。
        // 三个安全性质仍需自行保证，且已在下方具备：
        //   · 方法不存在 ⇒ 已提前 return（不会凭空 add 方法）
        //   · 重复安装   ⇒ cur != 当前 IMP 的判断（幂等）
        //   · 继承污染   ⇒ delegate 类通常自有实现；即便来自父类，
        //                  受影响面仅限「同类通知代理」，不涉及框架公共类。
        method_setImplementation(m, (IMP)SIOBgWillPresent);
    }
}

// 场景伪装的安装。三条链路各自独立、各自可缺：
//   · FBSWorkspaceScenesClient 吞后台化 diff（核心，iOS 11–18 名称稳定）
//   · UIApplication applicationState 伪装
//   · UNUserNotificationCenter setDelegate: 挂钩横幅伪装
static void SIOBgInstallSceneHooks(void) {
    // 三条链路统一走 SIOExchange —— 与本项目其余 hook 完全同一套安全语义：
    //   · 类/方法不存在 ⇒ 不安装（自动少开一项，红线 #3）
    //   · 继承污染防护（本类无自有实现时 addMethod，orig 指向父类）
    //   · 重复安装保护（orig 槽已填充则跳过）
    // 场景伪装相关的类名在 iOS 11–18 之间变过（私有 API），因此全部
    // ? 用 objc_getClass 探测：拿不到就什么都不做，绝不假设它存在。
    SIOExchange("FBSWorkspaceScenesClient",
                @selector(sceneID:updateWithSettingsDiff:transitionContext:completion:),
                (IMP)SIOBgSceneUpdate,
                (IMP *)&gSIOOrigSceneUpdate, NO);

    SIOExchange("UIApplication",
                @selector(applicationState),
                (IMP)SIOBgAppState,
                (IMP *)&gSIOOrigAppState, NO);

    SIOExchange("UNUserNotificationCenter",
                @selector(setDelegate:),
                (IMP)SIOBgUNSetDelegate,
                (IMP *)&gSIOOrigUNSetDelegate, NO);
}

#pragma mark - 引擎二：音频断言（AVFoundation 惰性加载）

static void SIOBgOnInterruption(NSNotification *note);

// 首次真正需要音频断言时才 dlopen AVFoundation。
// 关键点：宿主 App 自己已链接 AVFoundation 时，dlopen 只是引用计数 +1，
// 零额外加载成本；未链接时才真正加载。无论哪种情况，**不使用保活的 App
// 永远不会走到这里**（红线 #4）。
static BOOL SIOBgAVEnsure(void) {
    if (gSIOAVSessionCls && gSIOAVPlayerCls) return YES;
    static dispatch_once_t once;
    __block BOOL ok = NO;
    dispatch_once(&once, ^{
        @try {
            void *h = dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation",
                             RTLD_LAZY | RTLD_LOCAL);
            if (!h) return;
            Class p = objc_getClass("AVAudioPlayer");
            Class s = objc_getClass("AVAudioSession");
            // 字符串常量必须从框架句柄解析：RTLD_LOCAL 下不能依赖全局符号域。
            // ARC 要求指向 ObjC 对象的指针显式声明所有权，故加 __strong。
            NSString *__strong *cat = (NSString *__strong *)dlsym(h, "AVAudioSessionCategoryPlayback");
            NSString *__strong *ni  = (NSString *__strong *)dlsym(h, "AVAudioSessionInterruptionNotification");
            NSString *__strong *nr  = (NSString *__strong *)dlsym(h, "AVAudioSessionRouteChangeNotification");
            NSString *__strong *kt  = (NSString *__strong *)dlsym(h, "AVAudioSessionInterruptionTypeKey");
            NSString *__strong *ko  = (NSString *__strong *)dlsym(h, "AVAudioSessionInterruptionOptionKey");
            if (!p || !s || !cat || !*cat || !ni || !*ni || !nr || !*nr || !kt || !*kt || !ko || !*ko) {
                return;   // 符号不全 ⇒ 整个音频引擎禁用（不半开）
            }
            gSIOAVPlayerCls = p; gSIOAVSessionCls = s;
            gSIOAVCatPlayback = *cat; gSIOAVNoteInt = *ni; gSIOAVNoteRoute = *nr;
            gSIOAVKeyIntType = *kt;  gSIOAVKeyIntOption = *ko;

            // 打断 / 路由变更通知此刻才注册 —— 此前字符串常量尚不存在。
            // 用 nil 名字注册会订阅到**全部**通知，那是 v2.x 的隐患。
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc addObserverForName:gSIOAVNoteInt object:nil queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *n) { SIOBgOnInterruption(n); }];
            [nc addObserverForName:gSIOAVNoteRoute object:nil queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *n) {
                if (!gSIOBgUseAudio || !gSIOBgPhysBg) return;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (gSIOPlayer && ![gSIOPlayer isPlaying]) [gSIOPlayer play];
                });
            }];
            ok = YES;
        } @catch (__unused NSException *e) {}
    });
    return ok;
}

static id<SIOAVSession> SIOBgSession(void) {
    // +sharedInstance 是类方法，经 objc_msgSend 显式签名调用，
    // 不依赖编译器对「id<协议> 上调类方法」的可见性推断。
    if (!gSIOAVSessionCls) return nil;
    return ((id<SIOAVSession> (*)(Class, SEL))objc_msgSend)(gSIOAVSessionCls,
                                                            @selector(sharedInstance));
}

static BOOL SIOBgActivateSession(void) {
    if (!SIOBgAVEnsure()) return NO;
    NSError *e = nil;
    id<SIOAVSession> s = SIOBgSession();
    if (!s) return NO;
    if (![s setCategory:gSIOAVCatPlayback withOptions:kSIOAVMixWithOthers error:&e] || e) return NO;
    e = nil;
    if (![s setActive:YES error:&e] || e) return NO;
    return YES;
}

// 静音噪声循环播放。数据是 base64 内联的（support/FUBGNoiseData.h），
// 避免额外资源文件与包体签名负担。volume=0 保证用户听不到。
static void SIOBgBuildAndPlay(void) {
    @try {
        if (!gSIOAVPlayerCls) return;
        NSData *data = [[NSData alloc] initWithBase64EncodedString:kFBGNoiseB64
                                                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (!data.length) return;
        id<SIOAVPlayer> p = [[gSIOAVPlayerCls alloc] initWithData:data error:nil];
        if (!p) return;
        [p setNumberOfLoops:-1];
        [p setVolume:0.0f];
        [p prepareToPlay];
        [p play];
        gSIOPlayer = p;
    } @catch (__unused NSException *e) {}
}

static void SIOBgStartAudio(void) {
    if (!gSIOBgUseAudio) return;
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        // 桥接任务：给「会话激活 + 首次播放」这段窗口争取时间。
        // 注意它不是保活手段本身（额度只有约 30 秒），只是过桥。
        if (gSIOBgTask == 0) {
            __weak UIApplication *weakApp = app;
            gSIOBgTask = [app beginBackgroundTaskWithName:@"sio-bg-bridge" expirationHandler:^{
                if (gSIOBgTask != 0) {
                    [weakApp endBackgroundTask:gSIOBgTask];
                    gSIOBgTask = 0;
                }
            }];
        }
        if (SIOBgActivateSession() && (!gSIOPlayer || ![gSIOPlayer isPlaying])) {
            if (gSIOPlayer) [gSIOPlayer play];
            else            SIOBgBuildAndPlay();
        }
    } @catch (__unused NSException *e) {}
}

static void SIOBgStopAudio(BOOL releaseSession) {
    @try {
        if ([gSIOPlayer isPlaying]) [gSIOPlayer pause];
        // 经验（Immortalizer 作者）：mix 模式下保持 session 激活、不主动
        // setActive:NO，可避免与目标 App 自身音频会话打架造成卡顿；
        // 仅在彻底关闭时才通知其他 App 恢复。
        if (releaseSession && gSIOAVSessionCls) {
            [SIOBgSession() setActive:NO withOptions:kSIOAVNotifyOthers error:nil];
        }
        UIApplication *app = [UIApplication sharedApplication];
        if (gSIOBgTask != 0) { [app endBackgroundTask:gSIOBgTask]; gSIOBgTask = 0; }
    } @catch (__unused NSException *e) {}
}

// 自愈轮询：只在「真的进了后台 + 真的用音频断言」时存在。
// v2.5.0 修过的坑：原实现在构造期就起一个 1.5s 重复定时器并挂到 CommonModes，
// 前台后台一直跑，而回调首行就是 `if (!gUseAudio || !gPhysBg) return;` ——
// 前台期 100% 空转，只消耗唤醒次数与电量。改为随生命周期启停，行为完全等价。
static void SIOBgWatchdogFire(NSTimer *t);

static void SIOBgStartWatchdog(void) {
    if (!gSIOBgUseAudio) return;      // 不用音频断言 ⇒ 定时器无事可做
    if (gSIOBgWatchdog) return;       // 已在跑
    gSIOBgWatchdog = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES
                                                       block:^(NSTimer *t) { SIOBgWatchdogFire(t); }];
    // CommonModes：滚动/拖拽时 runloop 处于 tracking mode，
    // 不加这一行定时器会在滑动期间停摆。
    [[NSRunLoop mainRunLoop] addTimer:gSIOBgWatchdog forMode:NSRunLoopCommonModes];
}

static void SIOBgStopWatchdog(void) {
    if (gSIOBgWatchdog) {
        [gSIOBgWatchdog invalidate];
        gSIOBgWatchdog = nil;
    }
}

static void SIOBgWatchdogFire(__unused NSTimer *t) {
    if (!gSIOBgUseAudio || !gSIOBgPhysBg) return;
    @try {
        if (!gSIOPlayer || ![gSIOPlayer isPlaying]) {
            SIOBgActivateSession();
            if (gSIOPlayer) [gSIOPlayer play];
            else            SIOBgBuildAndPlay();
        }
    } @catch (__unused NSException *e) {}
}

static void SIOBgOnInterruption(NSNotification *note) {
    if (!gSIOBgUseAudio || !gSIOAVKeyIntType) return;
    NSNumber *type = note.userInfo[gSIOAVKeyIntType];
    if (type.unsignedIntegerValue != kSIOAVIntTypeEnded) return;
    NSNumber *opt = note.userInfo[gSIOAVKeyIntOption];
    if (!(opt.unsignedIntegerValue & kSIOAVIntOptionShouldResume)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gSIOBgUseAudio || !gSIOBgPhysBg) return;
        SIOBgActivateSession();
        if (gSIOPlayer) [gSIOPlayer play];
        else            SIOBgBuildAndPlay();
    });
}

#pragma mark - 入口

// 由 SIOInstaller 在「启动完成之后」调用（不是 constructor）。
// 原因：本模块要动 UIApplication / AVAudioSession，而 constructor 运行在
// 非主线程；v2.x 正是在这里踩过「UIKit 主线程约束」的坑。
void SIOSetupBackground(void) {
    @try {
        SIOBgLoadPref();

        // hook 一次性安装，内部按 gSIOBgUseScene 决定行为。
        SIOBgInstallSceneHooks();

        // 生命周期：只用 NSNotificationCenter 一条路径。
        // v2.1.0[致命] 的教训 —— UIApplicationDidEnterBackgroundNotification 是
        // NSNotification 名字，Darwin 中心只投递 notify_post() 的名字，
        // 两套系统互不相通；注册错中心会让 gSIOBgPhysBg 永远 NO，
        // 于是场景伪装/音频断言/自愈轮询三件事从未执行过一行代码。
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *n) {
            gSIOBgPhysBg = YES;
            SIOBgStartAudio();
            SIOBgStartWatchdog();       // 只有此刻 watchdog 才可能做有用功
        }];
        [nc addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *n) {
            gSIOBgPhysBg = NO;
            SIOBgStopWatchdog();        // 回前台立刻停定时器（前台 100% 空转）
            // 回前台只暂停播放、保留会话（mix 模式下不与 App 音频冲突）
            if ([gSIOPlayer isPlaying]) [gSIOPlayer pause];
            if (gSIOBgTask != 0) {
                [[UIApplication sharedApplication] endBackgroundTask:gSIOBgTask];
                gSIOBgTask = 0;
            }
        }];
        // 注意：不再注册 UIBackgroundTask expiration 链 —— 桥接任务的
        // expirationHandler 已在上方内联，额外的全局监听只会重复处理。
    } @catch (NSException *e) {
        NSLog(@"[SIO] keep-alive install failed (app unaffected): %@", e);
    }
}

// 配置热重载时由 SIOConfig 调用（同一 Darwin 名字，语义幂等）。
void SIOBackgroundReload(void) {
    if (!gSIOBgLoaded) return;
    SIOBgLoadPref();
    if (!gSIOBgUseAudio && gSIOBgPhysBg) SIOBgStopAudio(NO);
    if (gSIOBgUseAudio && gSIOBgPhysBg && (!gSIOPlayer || ![gSIOPlayer isPlaying])) {
        SIOBgStartAudio();
    }
}
