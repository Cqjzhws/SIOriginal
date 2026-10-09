// ============================================================================
//  SIOConfig — 全项目唯一的配置入口
// ============================================================================
//  v2.x 的配置有三个入口在互相打架：SIO_reload() 读一遍 plist、保活的
//  _fbg_loadPref() 再读一遍、黑名单又被两套不同语义（精确 vs 前缀）匹配。
//  v3.0 收敛成：
//    单结构体 gSIOCfg（唯一状态） → SIOEnginePrepare()（唯一派生计算） → hook 只读。
//
//  四条硬性约束（历史上都出过事）：
//   1. plist **每个进程内只读一次**（构造期一次），结果进缓存；
//      热重载时先失效再重读 —— 但整条重载路径必须在 serial queue 上串行执行，
//      且所有对 gSIOCfg / 对象型全局的访问必须在 os_unfair_lock 下。
//      （v2.5.0 修过一个真实崩溃：ARC 下给 __strong 静态变量赋值会 release 旧值，
//        写入方 Darwin 通知线程 × 读取方任意动画线程 ⇒ 悬垂指针 EXC_BAD_ACCESS）
//   2. 缺键一律 fail-safe 到「关」，尤其是会破坏列表状态机的高危开关。
//   3. 范围外的值回落到默认，而不是夹到边界（用户改坏配置文件时行为可预测）。
//   4. 磁盘 IO 绝不放在锁里 —— 那会让所有动画 hook 在重载瞬间一起阻塞。
// ============================================================================

#import "SIOInternal.h"

NSString *const kSIOSysKeyDragCoefficient = @"UIAnimationDragCoefficient";

SIOConfigState gSIOCfg;
NSString *gSIOBundleID       = nil;
BOOL      gSIOSelfBlacklisted = NO;
NSArray  *gSIOBlacklistItems  = nil;
BOOL      gSIOHasOverride     = NO;
BOOL      gSIOListHardGuarded = NO;
BOOL      gSIOEditing         = NO;

static BOOL gSIOConfigLoaded = NO;

#pragma mark - plist 缓存

static NSDictionary *gSIOPrefCache = nil;
static os_unfair_lock gSIOPrefLock = OS_UNFAIR_LOCK_INIT;
static dispatch_queue_t gSIOConfigQueue = NULL;

// v3.0：唯一配置读取出口。保活模块（SIOBackground）也复用这一份解析结果，
// 不允许自己再 dictionaryWithContentsOfFile: 一次 —— v2.x 就是这么做了两遍。
NSDictionary *SIOPrefSnapshot(void) {
    os_unfair_lock_lock(&gSIOPrefLock);
    NSDictionary *cached = gSIOPrefCache;
    os_unfair_lock_unlock(&gSIOPrefLock);
    if (cached) return cached;
    // 磁盘 IO 在锁外做（约束 4）
    @try {
        NSDictionary *fresh = [NSDictionary dictionaryWithContentsOfFile:kSIOPrefPath];
        os_unfair_lock_lock(&gSIOPrefLock);
        if (!gSIOPrefCache) gSIOPrefCache = fresh;   // 期间可能已被别的线程填好
        cached = gSIOPrefCache;
        os_unfair_lock_unlock(&gSIOPrefLock);
        return cached;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

BOOL SIOConfigReadable(void) { return SIOPrefSnapshot() != nil; }

#pragma mark - 取值小工具

static double SIONum(NSDictionary *d, NSString *k, double def, double lo, double hi) {
    id v = d[k];
    if (![v respondsToSelector:@selector(doubleValue)]) return def;
    double x = [(NSNumber *)v doubleValue];
    if (!(x >= lo && x <= hi)) return def;      // NaN 也在这里被挡掉
    return x;
}
static BOOL SIOBool(NSDictionary *d, NSString *k, BOOL def) {
    id v = d[k];
    if (![v respondsToSelector:@selector(boolValue)]) return def;
    return [(NSNumber *)v boolValue];
}

#pragma mark - 名单硬保护（最高优先级）

BOOL SIOSelfBlacklisted(void) { return gSIOSelfBlacklisted; }

// 这些进程的列表 hook 一旦打开就是黑屏/白苹果级别的事故，而且必须做到
// 「忘关也不许生效」。所以是**不接受 App 级覆盖打开的硬闸**。
static BOOL SIOListHardBlocked(void) {
    NSString *bid = SIOBundleID();
    if (!bid.length) return NO;
    return [bid isEqualToString:@"com.apple.springboard"];
}

// v2.1.0 修过的真 bug：黑名单此前有两套匹配语义互相打脸。
//   SIO_reload 用 isEqualToString:（精确）／ _fbg_isExcluded 用 hasPrefix:（前缀）
// 结果配置里写的 com.tencent.wework 在前缀语义下连带排除了所有同前缀 App。
// v3.0 全项目只剩这一个实现：默认精确；确需前缀时条目末尾显式写 `*`。
BOOL SIOBundleMatches(NSString *entry) {
    if (![entry isKindOfClass:[NSString class]] || entry.length == 0) return NO;
    NSString *bid = SIOBundleID();
    if (bid.length == 0) return NO;
    if ([entry hasSuffix:@"*"]) {
        NSString *prefix = [entry substringToIndex:entry.length - 1];
        return prefix.length > 0 && [bid hasPrefix:prefix];
    }
    return [bid isEqualToString:entry];
}

NSDictionary *SIOAppOverrideLookup(NSDictionary *root) {
    // v3.0：保活模块也要用同一套 App 级覆盖语义 —— 提升为公开接口，
    // 但实现保持唯一（原来叫 SIOAppOverride，仅本文件内部可见）。
    id ov = [root isKindOfClass:[NSDictionary class]] ? root[@"AppOverrides"] : nil;
    if (![ov isKindOfClass:[NSDictionary class]]) return nil;
    NSString *bid = SIOBundleID();
    if (bid.length == 0) return nil;
    id mine = ((NSDictionary *)ov)[bid];
    return [mine isKindOfClass:[NSDictionary class]] ? mine : nil;
}

// 场景伪装属于「偏侵入」能力：吞掉 App 的 backgrounding scene diff。
// 在有沙箱的普通 App 里可用；若用户显式要求「仅巨魔环境启用」，则需要
// TrollStore 或无沙箱凭据。非巨魔一律自动降级为「只做音频断言兜底」。
BOOL SIOSceneFakingAllowed(void) {
    if (!gSIOCfg.privilegeGated) return YES;
    return (gSIOCaps & (kSIOCapTrollStore | kSIOCapUnsandboxed)) != 0;
}

#pragma mark - 默认值

static void SIOApplyDefaults(SIOConfigState *c) {
    c->enabled              = YES;
    c->mode                 = 0;
    c->speed                = 8.0;
    c->slowFactor           = 2.0;
    c->floorSec             = 0.008;
    c->spring               = YES;
    c->extra                = YES;
    c->listAccel            = NO;   // 高危，默认关
    c->zoomAccel            = NO;   // 实验，默认关
    c->fastScroll           = NO;
    c->fastTap              = NO;
    c->longPress            = YES;
    c->longPressDuration    = 0.30;
    c->layoutAccel          = NO;   // 实验，默认关
    c->speedMode            = NO;
    c->respectReduceMotion  = YES;
    c->frameAlign           = YES;  // v2.3.0 起默认开：纯收益的无眩光方案
    c->notify               = YES;
    c->layerBoost           = 2.0;
    c->transitionBoost      = 2.0;
    // ---- v3.0 新增：系统级 / 内存 / 调度 ----
    c->systemSpeed          = 0.0;  // 0 = 未启用
    c->systemSpeedCompensate = YES;
    c->memoryGuard          = YES;
    c->schedulingBoost      = YES;
    c->fastColdStart        = YES;
    c->legacyKitMode        = 0;
    c->swapBudget           = 220;  // 兜底上限：正常安装约 150–180 次
    c->privilegeGated       = NO;
}

#pragma mark - 解析（唯一的 plist → gSIOCfg 通道）

static void SIOApply(NSDictionary *d, SIOConfigState *c, NSDictionary *ovr) {
    if (d) {
        c->enabled    = SIOBool(d, @"Enabled", YES);
        int m = [d[@"Mode"] respondsToSelector:@selector(intValue)] ? [d[@"Mode"] intValue] : 0;
        c->mode = (m >= 0 && m <= 2) ? m : 0;
        c->speed      = SIONum(d, @"Speed", 5.0, 1.0, 50.0);
        c->slowFactor = SIONum(d, @"SlowFactor", 2.0, 1.0, 10.0);
        c->floorSec   = SIONum(d, @"Floor", 0.02, 0.001, 1.0);
        c->spring     = SIOBool(d, @"Spring", YES);
        c->extra      = SIOBool(d, @"Extra", YES);
        // 缺键一律 NO（fail-safe）：这些会改变 App 既有行为，必须由用户显式打开
        c->listAccel  = SIOBool(d, @"ListAccel", NO);
        c->zoomAccel  = SIOBool(d, @"ZoomAccel", NO);
        c->fastScroll = SIOBool(d, @"FastScroll", NO);
        c->fastTap    = SIOBool(d, @"FastTap", NO);
        c->layoutAccel = SIOBool(d, @"LayoutAccel", NO);
        c->speedMode  = SIOBool(d, @"SpeedMode", NO);
        c->longPress  = SIOBool(d, @"LongPress", YES);
        c->longPressDuration = SIONum(d, @"LongPressDuration", 0.30, 0.1, 2.0);
        c->respectReduceMotion = SIOBool(d, @"RespectReduceMotion", YES);
        c->frameAlign = SIOBool(d, @"FrameAlign", YES);
        c->notify     = SIOBool(d, @"Notify", YES);
        c->layerBoost = SIONum(d, @"LayerBoost", 1.0, 1.0, 10.0);
        c->transitionBoost = SIONum(d, @"TransitionBoost", 1.0, 1.0, 10.0);
        // v3.0：系统级系数 —— 配置 App 写进同一个 plist 的 UIAnimationDragCoefficient。
        // 这里读它**不是为了改它**，而是为了知道「UIKit 还会再乘一次」从而做补偿，
        // 避免 hook 与系统参数叠加成双重加速（用户设 ×5，实际变成 ≈×8.6）。
        // 1.0 或不存在 ⇒ 无补偿（除数为 1）。
        double ss = SIONum(d, kSIOSysKeyDragCoefficient, 1.0, 0.05, 20.0);
        c->systemSpeed = ss;
        c->systemSpeedCompensate = SIOBool(d, @"SystemSpeedCompensate", YES);
        c->memoryGuard = SIOBool(d, @"MemoryGuard", YES);
        c->schedulingBoost = SIOBool(d, @"SchedulingBoost", YES);
        c->fastColdStart = SIOBool(d, @"FastColdStart", YES);
        int lk = [d[@"LegacyKitMode"] respondsToSelector:@selector(intValue)] ? [d[@"LegacyKitMode"] intValue] : 0;
        c->legacyKitMode = (lk >= 0 && lk <= 2) ? lk : 0;
        int sb = [d[@"SwapBudget"] respondsToSelector:@selector(intValue)] ? [d[@"SwapBudget"] intValue] : 0;
        c->swapBudget = (sb >= 0 && sb <= 2000) ? sb : 0;
        c->privilegeGated = SIOBool(d, @"PrivilegeGated", NO);
    }

    // ---- App 专属覆盖（优先级：硬保护 > App 覆盖 > 全局） ----
    if (ovr) {
        if (ovr[@"Enabled"])     c->enabled = [ovr[@"Enabled"] boolValue];
        if ([ovr[@"Mode"] respondsToSelector:@selector(intValue)]) {
            int m2 = [ovr[@"Mode"] intValue];
            if (m2 >= 0 && m2 <= 2) c->mode = m2;
        }
        c->speed       = SIONum(ovr, @"Speed", c->speed, 1.0, 50.0);
        c->slowFactor  = SIONum(ovr, @"SlowFactor", c->slowFactor, 1.0, 10.0);
        c->floorSec    = SIONum(ovr, @"Floor", c->floorSec, 0.001, 1.0);
        c->layerBoost  = SIONum(ovr, @"LayerBoost", c->layerBoost, 1.0, 10.0);
        c->transitionBoost = SIONum(ovr, @"TransitionBoost", c->transitionBoost, 1.0, 10.0);
        c->longPressDuration = SIONum(ovr, @"LongPressDuration", c->longPressDuration, 0.1, 2.0);
        if (ovr[@"Spring"])      c->spring = [ovr[@"Spring"] boolValue];
        if (ovr[@"Extra"])       c->extra = [ovr[@"Extra"] boolValue];
        if (ovr[@"ListAccel"])   c->listAccel = [ovr[@"ListAccel"] boolValue];
        if (ovr[@"ZoomAccel"])   c->zoomAccel = [ovr[@"ZoomAccel"] boolValue];
        if (ovr[@"FastScroll"])  c->fastScroll = [ovr[@"FastScroll"] boolValue];
        if (ovr[@"FastTap"])     c->fastTap = [ovr[@"FastTap"] boolValue];
        if (ovr[@"LongPress"])   c->longPress = [ovr[@"LongPress"] boolValue];
        if (ovr[@"LayoutAccel"]) c->layoutAccel = [ovr[@"LayoutAccel"] boolValue];
        if (ovr[@"SpeedMode"])   c->speedMode = [ovr[@"SpeedMode"] boolValue];
        if (ovr[@"RespectReduceMotion"]) c->respectReduceMotion = [ovr[@"RespectReduceMotion"] boolValue];
        if (ovr[@"FrameAlign"])  c->frameAlign = [ovr[@"FrameAlign"] boolValue];
        if (ovr[@"MemoryGuard"]) c->memoryGuard = [ovr[@"MemoryGuard"] boolValue];
    }

    // ---- 硬保护：必须在所有覆盖之后，优先级最高 ----
    gSIOListHardGuarded = SIOListHardBlocked();
    if (gSIOListHardGuarded && c->listAccel) c->listAccel = NO;
}

#pragma mark - 加载 / 热重载

void SIOConfigLoad(void) {
    gSIOBundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    SIOApplyDefaults(&gSIOCfg);
    NSDictionary *d = SIOPrefSnapshot();
    if (!d) {
        // v2.0.6 补的可观测性：静默回默认会让用户分不清「plist 缺失 / 路径错 / 权限不足」，
        // 而这三者处理方式完全不同。这条日志只在缺少配置时打一次。
        NSLog(@"[SIOriginal] config plist not readable at %@ — falling back to built-in defaults "
              @"(speed x%.1f). Write it from the config app or check Managed Preferences permissions.",
              kSIOPrefPath, 5.0);
        gSIOSelfBlacklisted = NO;
        gSIOBlacklistItems  = nil;
        gSIOHasOverride     = NO;
    } else {
        gSIOHasOverride = (SIOAppOverrideLookup(d) != nil);
        SIOApply(d, &gSIOCfg, SIOAppOverrideLookup(d));
    }
    SIOConfigReloadItems();
    gSIOConfigLoaded = YES;
    SIOEnginePrepare();
}

// 黑名单解析：全项目唯一的一次，结果同时给动画侧（旁路）与保活侧（排除）用。
// v2.5.0 这里原本被解析两次（两个 constructor 各一遍），启动期付两次代价；
// v3.0 只有 SIOConfigLoad / SIOConfigReload 会走到这里。
void SIOConfigReloadItems(void) {
    os_unfair_lock_lock(&gSIOPrefLock);
    NSDictionary *d = gSIOPrefCache;
    os_unfair_lock_unlock(&gSIOPrefLock);
    if (!d) d = SIOPrefSnapshot();

    NSDictionary *dLocal = d;
    id bl = dLocal[@"Blacklist"];
    NSArray *items = nil;
    if ([bl isKindOfClass:[NSArray class]]) {
        items = bl;
    } else if ([bl isKindOfClass:[NSString class]]) {
        // v2.x 这里对 NSString 直接调 componentsJoinedByString: → unrecognized selector 崩溃
        items = [(NSString *)bl componentsSeparatedByString:@","];
    }

    NSMutableArray *cleaned = [NSMutableArray array];
    BOOL blacklisted = NO;
    NSString *bid = gSIOBundleID ?: @"";
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];   // 提到循环外：每次调用返回新对象
    for (id it in items) {
        if (![it isKindOfClass:[NSString class]]) continue;
        NSString *s = [(NSString *)it stringByTrimmingCharactersInSet:ws];
        if (s.length == 0) continue;
        [cleaned addObject:s];
        if (!blacklisted && bid.length && SIOBundleMatches(s)) blacklisted = YES;
    }
    gSIOSelfBlacklisted = blacklisted;
    gSIOBlacklistItems  = cleaned;
}

// 热重载。必须在 **串行队列** 上执行：磁盘 IO + 派生计算 + （可能）补装 hook，
// 三件事都不能和动画线程并发。
void SIOConfigReload(void) {
    if (!gSIOConfigQueue) {
        dispatch_queue_attr_t attr = NULL;
        if (@available(iOS 8.0, *)) {
            attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        }
        gSIOConfigQueue = dispatch_queue_create("com.local.sioriginal.config", attr);
    }
    dispatch_async(gSIOConfigQueue, ^{
        @try {
            os_unfair_lock_lock(&gSIOPrefLock);
            gSIOPrefCache = nil;      // 失效
            os_unfair_lock_unlock(&gSIOPrefLock);

            SIOApplyDefaults(&gSIOCfg);
            NSDictionary *d = SIOPrefSnapshot();
            if (d) {
                gSIOHasOverride = (SIOAppOverrideLookup(d) != nil);
                SIOApply(d, &gSIOCfg, SIOAppOverrideLookup(d));
            }
            SIOConfigReloadItems();
            SIOEnginePrepare();
            // 用户可能在「运行之后」才把某个默认关闭的开关打开 ——
            // v2.2.0 引入按需安装时的必然副作用；这里幂等补装。
            dispatch_async(dispatch_get_main_queue(), ^{
                @try { SIOInstallStage(kSIOStageOnDemand); } @catch (__unused NSException *e) { }
                SIOBackgroundReload();
            });
        } @catch (NSException *e) {
            NSLog(@"[SIOriginal] config reload failed (previous values kept): %@", e);
        }
    });
}

void SIOConfigRegisterObserver(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    SIOConfigNotifyCallback,
                                    (__bridge CFStringRef)kSIONotifyName, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

void SIOConfigNotifyCallback(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    SIOConfigReload();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSIOCfg.notify) SIOShowSettingsToast();
    });
}
