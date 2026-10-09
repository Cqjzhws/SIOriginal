// ============================================================================
//  SIOScheduler — 启动栅栏 / 延后安装 / 内存护栏 / QoS 策略
// ============================================================================
//  这个文件承载 v3.0 的四项「性能」能力。它们的共同点是：**都不靠改动画参数**，
//  而是靠「什么时候做」和「内存不够时退让」。
//
//   1. 启动栅栏 SIOAfterBoot：hook 安装排到 didFinishLaunching 之后。
//      v2.2.0 的做法是 dispatch_async(main)，但那一刻 App 往往还在跑
//      didFinishLaunching 与首屏布局 —— 换方法表会和首屏抢主线程，
//      并让 UIKit 的方法缓存在最忙的窗口里失效两次。
//   2. 交换预算：给 installer 提供硬性上限，防止极端 App 的方法表爆炸。
//   3. 内存护栏：两级降级。优化工具在内存吃紧时**必须退让** ——
//      一个为了流畅而让 App 被 Jetsam 杀掉的注入库是彻底的负收益。
//   4. QoS：把我们自己的后台队列压到 UTILITY，避免在首屏与主线程抢资源。
// ============================================================================

#import "SIOInternal.h"
#import <dispatch/dispatch.h>

static dispatch_once_t   gSIOBootOnce;
static NSMutableArray   *gSIOBootBlocks;
static os_unfair_lock    gSIOBootLock = OS_UNFAIR_LOCK_INIT;
static id                gSIOBootObserver = nil;
static BOOL              gSIOBootDone = NO;
static double            gSIOBootT0 = 0.0;

#pragma mark - 启动栅栏

// 通知观察者令牌必须在跑完 blocks 后摘掉：若实际走的是超时兜底路径（通知从未来到），
// 观察者会一直挂着 —— 既泄漏对象，又会在之后某个时刻对已清空的 blocks 再跑一次。
static void SIORunBootBlocks(void) {
    NSArray *blocks = nil;
    id observer = nil;
    os_unfair_lock_lock(&gSIOBootLock);
    blocks = gSIOBootBlocks;
    gSIOBootBlocks = nil;
    observer = gSIOBootObserver;
    gSIOBootObserver = nil;
    gSIOBootDone = YES;
    os_unfair_lock_unlock(&gSIOBootLock);

    if (observer) {
        @try { [[NSNotificationCenter defaultCenter] removeObserver:observer]; } @catch (__unused NSException *e) { }
    }
    for (void (^b)(void) in blocks) {
        @try { b(); } @catch (__unused NSException *e) { }
    }
}

void SIOAfterBoot(void (^block)(void)) {
    if (!block) return;
    dispatch_once(&gSIOBootOnce, ^{
        gSIOBootBlocks = [NSMutableArray array];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        // 该通知在 didFinishLaunching 返回后投递，正是我们要的时刻。
        id token = [nc addObserverForName:UIApplicationDidFinishLaunchingNotification
                                   object:nil
                                    queue:[NSOperationQueue mainQueue]
                               usingBlock:^(__unused NSNotification *n) {
            SIORunBootBlocks();
        }];
        os_unfair_lock_lock(&gSIOBootLock);
        gSIOBootObserver = token;
        os_unfair_lock_unlock(&gSIOBootLock);
        // 兜底是必需的：本 dylib 可能在 UIApplication 尚不存在时就被装载，
        // 此时该通知永远不会来。没有超时路径的话，「延后安装」会退化成
        // 「永不安装」—— 那比慢严重得多。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ SIORunBootBlocks(); });
    });

    os_unfair_lock_lock(&gSIOBootLock);
    NSMutableArray *arr = gSIOBootBlocks;
    if (arr) {
        [arr addObject:block];
        os_unfair_lock_unlock(&gSIOBootLock);
        return;
    }
    os_unfair_lock_unlock(&gSIOBootLock);
    // 已被清空 ⇒ 启动阶段已过，直接跑
    @try { block(); } @catch (__unused NSException *e) { }
}

BOOL SIOPostLaunchDone(void) { return gSIOBootDone; }

void SIOMarkBootStart(void) { gSIOBootT0 = CFAbsoluteTimeGetCurrent(); }
double SIOMarkBootCost(void) {
    if (gSIOBootT0 <= 0.0) return 0.0;
    return (CFAbsoluteTimeGetCurrent() - gSIOBootT0) * 1000.0;
}

// 由 installer 调用：把 postLaunch 档的 hook 排到启动完成之后。
void SIODeferPostLaunch(void) {
    SIOAfterBoot(^{
        @try { SIOInstallStage(kSIOStagePostLaunch); } @catch (__unused NSException *e) { }
        @try { SIOInstallStage(kSIOStageOnDemand);  } @catch (__unused NSException *e) { }
    });
}

#pragma mark - 内部队列 QoS

static dispatch_queue_t gSIOWorkQueue = NULL;

dispatch_queue_t SIOWorkQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_attr_t attr = NULL;
        // UTILITY 而非 DEFAULT：我们要的是「不抢首屏」，不是「立刻做完」。
        if (@available(iOS 8.0, *)) {
            attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        }
        gSIOWorkQueue = dispatch_queue_create("com.local.sioriginal.work", attr);
    });
    return gSIOWorkQueue;
}

void SIOApplyQoSPolicy(void) {
    // 预热工作队列（构造期创建会在首次使用时才分配，这里提前但不做重活）
    (void)SIOWorkQueue();
    // v3.0：保活相关的 timer 与 IO 走全局队列，但明确标注 BACKGROUND QoS。
    // 这一步的目的不是让它更快，而是**避免与前台 UI 争抢** ——
    // 后台任务用 USER_INITIATED 会抬高整体 CPU 频率竞争，得不偿失。
}

#pragma mark - 内存护栏

static int gSIOMemoryPressure = 0;
static SIOConfigState gSIOCfgPristine;
static BOOL gSIOCfgPristineValid = NO;

int SIOMemoryPressureLevel(void) { return gSIOMemoryPressure; }

// 降级阶梯：**先退的是收益低、风险高的那一端**。
//   level 1（告警）：关掉 LayerBoost / 列表 / 布局 / 缩放 —— 这些是「锦上添花」，
//                    且列表 hook 本身有状态机风险，内存吃紧时更不该承担。
//   level 2（严重）：核心时长换算也旁路（等价于临时关掉本 kuc），由 SIO_blocked 兜底。
// 恢复：压力回到 normal 时从快照原样还原 —— 用户不需要重新配置。
static void SIOApplyMemoryLevel(int level) {
    if (!gSIOCfg.memoryGuard) { gSIOMemoryPressure = level; return; }
    if (!gSIOCfgPristineValid && level == 0) return;
    if (!gSIOCfgPristineValid) {
        gSIOCfgPristine = gSIOCfg;
        gSIOCfgPristineValid = YES;
    }
    gSIOMemoryPressure = level;
    if (level == 0) {
        gSIOCfg = gSIOCfgPristine;
    } else if (level >= 1) {
        gSIOCfg.layerBoost = 1.0;
        gSIOCfg.listAccel = NO;
        gSIOCfg.layoutAccel = NO;
        gSIOCfg.zoomAccel = NO;
    }
    if (level >= 2) {
        gSIOCfg.transitionBoost = 1.0;
    }
    SIOEnginePrepare();
}

void SIOSetupResourceWatchdog(void) {
    if (!gSIOCfg.memoryGuard) return;

    // ---- 路径 A：dispatch 内存压力源（内核级，比内存告警通知更早、更准）----
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                                                   DISPATCH_MEMORYPRESSURE_NORMAL |
                                                   DISPATCH_MEMORYPRESSURE_WARN |
                                                   DISPATCH_MEMORYPRESSURE_CRITICAL,
                                                   SIOWorkQueue());
    if (src) {
        dispatch_source_set_event_handler(src, ^{
            unsigned long flags = dispatch_source_get_data(src);
            int level = 0;
            if (flags & DISPATCH_MEMORYPRESSURE_CRITICAL) level = 2;
            else if (flags & DISPATCH_MEMORYPRESSURE_WARN) level = 1;
            if (level != gSIOMemoryPressure) {
                SIOApplyMemoryLevel(level);
                NSLog(@"[SIOriginal] memory pressure -> level %d (%@)", level,
                      level ? @"degraded" : @"restored");
            }
        });
        dispatch_resume(src);
    }

    // ---- 路径 B：UIApplication 内存告警通知（iOS 11+ 全版本兜底）----
    // 两条路径都保留：压力源在个别系统上事件偏少，而 UIKit 通知是 App 级别的、
    // 一定会在 UIApplication 已经被投递到时进行。二者互补，谁先到谁生效。
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *n) {
        if (gSIOMemoryPressure < 1) SIOApplyMemoryLevel(1);
    }];
}
