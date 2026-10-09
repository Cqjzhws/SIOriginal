// ============================================================================
//  SIOPlatform — 版本/能力探测 + 巨魔(TrollStore)环境甄别
// ============================================================================
//  为什么要有这个文件：v2.x 的版本判断散落在 hook 实现里（这里 @available(iOS 13.0)、
//  那里 floatValue >= 16.0），同一件事三种写法，且多不带 fallback。v3.0 统一为：
//
//    **能用运行时能力检测就不用版本号**。
//    版本号只说明「理论上有」，而 hook 真正要知道的是「这台设备上这个类到底在不在」。
//    巨魔/越狱环境下类可能被替换，私有类跨版本改名是常态
//    （SpringBoard 的 AppSwitcher 相关宿主类在 iOS 18 就换过）。
//    因此能力一律用 objc_getClass / instancesRespondToSelector 探；
//    只有无法运行时检测的（如 UIWindowScene.windows 的引入版本）才退化到版本号，
//    并且必须配 @available 编译守卫 + 运行期兜底。
//
//  iOS 11 → 18 四段适配概览（具体差异集中在 SIOForegroundWindow）：
//    · 11–12：无 UIScene。UI 遍历只能走 UIApplication.windows / keyWindow；
//             无 os_proc_available_memory ⇒ 内存护栏只挂内存告警通知。
//    · 13–14：有 UIScene，但 UIWindowScene.windows 到 15 才可用，
//             故仍以 UIApplication.windows 为主。
//    · 15–17：UIWindowScene.windows 可用；UIApplication.windows 开始软废弃，
//             16 起不少 App 里会返回空数组 ⇒ 必须优先走 scene 遍历。
//    · 18+  ：进一步收紧 —— 私有类与 C 符号一律不假设存在，拿不到就自动少开启功能，
//             绝不崩。这正好与「能力位图 + gated 安装」的设计同构。
//
//  探测分两级：**构造期只做零成本检测**（类查找/选择器查询，不含系统调用）；
//  任何需要碰文件系统的判据都推迟到启动完成之后由 SIOProbeEnvironmentDeferred() 执行
//  —— pre-main 里哪怕一次 stat() 也会直接叠加到 App 的冷启动耗时（红线规则 #2）。
// ============================================================================

#import "SIOInternal.h"
#import <unistd.h>

SIOCaps     gSIOCaps   = kSIOCapNone;
NSInteger   gSIOMajor  = 0;
NSInteger   gSIOMinor  = 0;

static BOOL gSIOEnvProbed = NO;   // 昂贵（含 IO）的环境探测是否已跑过

#pragma mark - 版本

static void SIOProbeVersion(void) {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    gSIOMajor = v.majorVersion;
    gSIOMinor = v.minorVersion;
    // 取不到就按最低处理 —— 保守方向是走「低版本路径」，
    // 因为低版本路径用的都是 iOS 11 起就存在的老 API，反而更不容易出事。
    if (gSIOMajor <= 0) { gSIOMajor = 11; gSIOMinor = 0; }
}

BOOL SIOAtLeast(NSInteger major) { return gSIOMajor > 0 && gSIOMajor >= major; }
BOOL SIOBelow(NSInteger major)  { return gSIOMajor > 0 && gSIOMajor <  major; }

#pragma mark - 零成本能力探测（构造期）

void SIOProbePlatform(void) {
    SIOProbeVersion();
    SIOCaps caps = kSIOCapNone;

    // ---- API 可用性：一律运行时检测 ----
    if (objc_getClass("UIScene") && objc_getClass("UIWindowScene")) caps |= kSIOCapWindowScene;
    if (objc_getClass("UIScene"))                                   caps |= kSIOCapMultiScene;
    if (objc_getClass("UIHostingController"))                       caps |= kSIOCapSwiftUIHosting;
    if ([[UIScreen mainScreen] respondsToSelector:@selector(maximumFramesPerSecond)])
        caps |= kSIOCapMaxFPSReadable;
    {
        Class springCls = objc_getClass("CASpringAnimation");
        if (springCls && [springCls instancesRespondToSelector:@selector(setVelocity:)])
            caps |= kSIOCapSpringVelocity;
    }
    // os_proc_available_memory 是 iOS 13+ 的 C 符号。用 dlsym 探测而不是比版本号：
    // 即便将来被改名，这里也只是「拿不到」，不会误判成可用。
    if (dlsym(RTLD_DEFAULT, "os_proc_available_memory") != NULL)    caps |= kSIOCapOsProcMem;
    if (SIOAtLeast(15))                                             caps |= kSIOCapBlurHosting;
    if (SIOAtLeast(17))                                             caps |= kSIOCapRefreshPkgChg;

    // ---- 「本进程被注入」判据 ----
    // 配置 App 自己装载的 image 不算注入；其余进程里只要本 image 存在，
    // 就必然是 TrollFools / DYLD_INSERT 之类机制塞进来的。
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    BOOL isOwnApp = [bid isEqualToString:@"com.local.sioriginal"];
    if (!isOwnApp) caps |= kSIOCapInjected;

    gSIOCaps = caps;
}

#pragma mark - 昂贵环境探测（启动完成之后才调用）

// 巨魔装机判据。三条互相交叉验证，任一命中即认为「疑似巨魔环境」：
//  1) 已知安装根路径是否存在（TrollStore 2.x 装在 /var/containers/Bundle/ 下）
//  2) 本 App 是否自身位于 /var/containers/Bundle/Application/ 且不以 /private 开头
//     —— 巨魔装的 App 就是这个形态；App Store / AltStore 装的在
//     /private/var/containers/...，两者前缀不同。
//  3) 是否具备巨魔赋予的提权表现（可读沙箱外路径）。
//
// 这些都是 **启发式**，绝不因为探测失败就把功能做成不可用。
// 本文件所有判据只用于「能不能给更多」，不用于「要不要给」——
// 降级永远发生在「少启用」的方向，而且失败一律安全（功能少开，不影响稳定性）。
static BOOL SIOPathLooksTrollStored(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *kCandidates[4];
    kCandidates[0] = @"/var/containers/Bundle/trollstore";
    kCandidates[1] = @"/var/containers/Bundle/TrollStore.app";
    kCandidates[2] = @"/var/containers/Bundle/zmzalgo90.vip";
    kCandidates[3] = @"/var/containers/Bundle/TS-updated.app";
    for (NSUInteger i = 0; i < 4; i++) {
        @try {
            if ([fm fileExistsAtPath:kCandidates[i]]) return YES;
        } @catch (__unused NSException *e) { }
    }
    @try {
        NSString *exe = [[NSBundle mainBundle] executablePath];
        if ([exe hasPrefix:@"/var/containers/Bundle/Application/"]) return YES;
    } @catch (__unused NSException *e) { }
    return NO;
}

// 无沙箱判据：读一个沙箱外路径。读不到不代表一定有沙箱，所以只作「加分项」。
static BOOL SIOProbablyUnsandboxed(void) {
    @try {
        return [[NSFileManager defaultManager] isReadableFileAtPath:@"/var/mobile/Library/Preferences"];
    } @catch (__unused NSException *e) { return NO; }
}

void SIOProbeEnvironmentDeferred(void) {
    if (gSIOEnvProbed) return;
    gSIOEnvProbed = YES;

    SIOCaps caps = gSIOCaps;
    @try {
        if (SIOPathLooksTrollStored()) caps |= kSIOCapTrollStore;
        if (SIOProbablyUnsandboxed())  caps |= kSIOCapUnsandboxed;
        // 写 Managed Preferences 的能力 —— 这是「系统级参数」能否在本进程写入的前提。
        // 没有写权限时该项只能由宿主配置 App 完成（见 App/main.m）。
        if (access("/var/Managed Preferences/mobile", W_OK) == 0) caps |= kSIOCapWriteManagedPrefs;
        // RootHelper：存在且可执行才算。**iOS 17.6+/18 起 XNU 禁止非 root 二进制
        // 再以 persona-mgmt 拉起 root 进程**，所以这个位即使为 1 也只是「形态上存在」，
        // 调用方必须自己处理执行失败。
        NSString *helper = @"/var/containers/Bundle/TrollStore.app/trollstorehelper";
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:helper]) caps |= kSIOCapRootHelper;
    } @catch (__unused NSException *e) { }
    gSIOCaps = caps;
}

#pragma mark - 诊断

NSString *SIOPlatformSummary(void) {
    NSMutableArray *parts = [NSMutableArray array];
#define ADD_CAP(bit_, name_) do { if (gSIOCaps & (bit_)) [parts addObject:(name_)]; } while (0)
    ADD_CAP(kSIOCapWindowScene,       @"scene");
    ADD_CAP(kSIOCapMultiScene,        @"multiscene");
    ADD_CAP(kSIOCapSpringVelocity,    @"springVel");
    ADD_CAP(kSIOCapSwiftUIHosting,    @"swiftui");
    ADD_CAP(kSIOCapMaxFPSReadable,    @"maxFPS");
    ADD_CAP(kSIOCapOsProcMem,         @"procMem");
    ADD_CAP(kSIOCapBlurHosting,       @"blur15");
    ADD_CAP(kSIOCapInjected,          @"injected");
    ADD_CAP(kSIOCapTrollStore,        @"trollstore");
    ADD_CAP(kSIOCapRootHelper,        @"roothelper");
    ADD_CAP(kSIOCapUnsandboxed,       @"unsandboxed");
    ADD_CAP(kSIOCapWriteManagedPrefs, @"writeprefs");
#undef ADD_CAP
    return [NSString stringWithFormat:@"iOS %ld.%ld [%@] envProbed=%d",
            (long)gSIOMajor, (long)gSIOMinor,
            parts.count ? [parts componentsJoinedByString:@","] : @"-", gSIOEnvProbed];
}

#pragma mark - UI 遍历（版本差异最大处，全项目只此一处实现）

// 取用户可见的前台 keyWindow。iOS 11–18 写法各不相同，集中于此避免各 hook 各写一遍
// （v2.x 里 toast 与悬浮球就各有一份遍历逻辑，iOS 16 上一起失效，修一处漏一处）。
UIWindow *SIOForegroundWindow(void) {
    UIApplication *app = nil;
    @try { app = [UIApplication sharedApplication]; } @catch (__unused NSException *e) { return nil; }
    if (!app) return nil;

    // 优先 scene 路径（iOS 15+ 的正确姿势）。@available 守卫是编译期必需的：
    // 本库最低支持 iOS 11，而 UIWindowScene 是 13 才引入。
    if (@available(iOS 15.0, *)) {
        @try {
            if ((gSIOCaps & kSIOCapWindowScene) && app.connectedScenes.count > 0) {
                for (UIScene *sc in app.connectedScenes) {
                    if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                    if (sc.activationState != UISceneActivationStateForegroundActive) continue;
                    UIWindowScene *ws = (UIWindowScene *)sc;
                    for (UIWindow *w in ws.windows) {
                        if (!w.hidden && w.isKeyWindow) return w;
                    }
                }
            }
        } @catch (__unused NSException *e) { }
    }

    // 兜底：经典路径（iOS 11–15 可靠；iOS 16+ 上很多 App 会返回空 ⟹ 落到下一段）
    @try {
        NSArray *wins = [app respondsToSelector:@selector(windows)] ? app.windows : nil;
        for (UIWindow *w in wins) {
            if (!w.hidden && w.isKeyWindow) return w;
        }
        for (UIWindow *w in wins) {
            if (!w.hidden) return w;      // 退一步：至少挑一个可见窗口
        }
    } @catch (__unused NSException *e) { }
    return nil;
}

BOOL SIOAppIsActive(void) {
    UIApplication *app = nil;
    @try { app = [UIApplication sharedApplication]; } @catch (__unused NSException *e) { return NO; }
    return app && app.applicationState == UIApplicationStateActive;
}
