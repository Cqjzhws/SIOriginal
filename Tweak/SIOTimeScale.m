// SIOTimeScale.m — v2.6.0 时间源缩放引擎（P0 + P1）
//
// 设计要点（对照 OpenSpeedy 的移植决策，全部结论都落在 iOS 16.2 真机上验证过推演）：
//  1) 只缩放「进程读到的单调时间」。内核看的是真实时间 —— App 看门狗（内核侧）
//     不会因缩放被误触发；CA 渲染服务器用的是自己的时钟，vsync 节奏不变。
//     这与 OpenSpeedy「不碰内核、只改目标进程时间感知」完全同构。
//  2) 统一锚点数学，三个读取面共享同一条缩放时间轴：
//       scaled(t) = anchorScaled + (t - anchorReal) × factor
//     倍率运行时切换时，用「旧参数算出的当前映射值」做新锚点 —— 缩放时间
//     单调不减（倍率调小也不会 dt 倒退；这是 OpenSpeedy 的已知缺陷，此处修掉）。
//  3) 读路径用 seqlock（版本号）保护，无锁快路径：mach_absolute_time 是
//     游戏主循环每帧必调的热函数，不能用 os_unfair_lock 阻塞。
//  4) 挂钟（CLOCK_REALTIME / gettimeofday / NSDate）恒不缩放。
//     证书有效期校验、请求时间戳、服务器对账全部依赖真实挂钟。
//  5) dispatch_time 只缩放「相对 NOW 的延时」，返回值保持真实绝对域 ——
//     dispatch_after 内部用真实域计算剩余时长，缩放只体现在延时长短上，
//     绝不污染绝对时间轴（否则 dispatch_after 会把 scaled 绝对值当真实值算出
//     超长延时）。
//  6) fishhook 只重绑「经 GOT/lazy 表寻址」的调用 —— App 自身镜像（含内嵌的
//     Unity/Cocos 等引擎）生效；UIKit/CF/libdispatch 共享缓存内部互调不受影响，
//     恰好等价 OpenSpeedy 的「只改游戏进程」的进程隔离语义。
//  7) fishhook 是纯数据表重绑定，不改代码页 —— arm64e PAC 无关、无私有
//     entitlement、iOS 14+ 全版本可用（含 chained fixups，Meta 最新版支持）。

#import "SIOTimeScale.h"
#import "fishhook.h"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <os/lock.h>
#import <mach/mach_time.h>
#import <time.h>
#import <unistd.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>

// ===========================================================================
// P0 核心：seqlock 保护的锚点状态
// ===========================================================================

// 两个时钟域：绝对域（mach_absolute_time 族）与连续域（mach_continuous_time 族）。
// 两者相差「休眠时长」，必须各持一套锚点，否则跨域混读会下溢。
#define TS_DOMAIN_ABS  0
#define TS_DOMAIN_CONT 1
#define TS_DOMAIN_N    2

static _Atomic uint64_t gTS_seq;                        // seqlock 版本号（偶=稳定）
static _Atomic double   gTS_factor;                     // 当前有效倍率（含前后台回落）
static _Atomic uint64_t gTS_aReal[TS_DOMAIN_N];         // 锚点：真实时间（ns）
static _Atomic uint64_t gTS_aScaled[TS_DOMAIN_N];       // 锚点：映射时间（ns）

static _Atomic BOOL     gTS_installed;
static _Atomic BOOL     gTSSleepOn;                     // P1：节拍缩短是否生效
static os_unfair_lock   gTSApplyLock = OS_UNFAIR_LOCK_INIT;

// mach 时间基（ticks → ns 的换算系数）。Apple arm64 上通常 1:1，仍按通用公式算。
static double gTS_tbNum = 1.0, gTS_tbDen = 1.0;

static inline uint64_t ts_ticks_to_ns(uint64_t ticks) {
    return (uint64_t)(((double)ticks) * gTS_tbNum / gTS_tbDen);
}
static inline uint64_t ts_ns_to_ticks(uint64_t ns) {
    return (uint64_t)(((double)ns) * gTS_tbDen / gTS_tbNum);
}

// 当前有效倍率（给 dispatch_time / sleep 等非热路径用；热路径走 ts_scale）
static inline double ts_factor_now(void) {
    for (;;) {
        uint64_t v1 = atomic_load_explicit(&gTS_seq, memory_order_acquire);
        if (v1 & 1) continue;
        double f = atomic_load_explicit(&gTS_factor, memory_order_relaxed);
        uint64_t v2 = atomic_load_explicit(&gTS_seq, memory_order_acquire);
        if (v1 == v2) return f;
    }
}

// 热路径：单调 ns → 缩放 ns。未启用（factor≈1）时一次读即返回，开销 ~2ns。
static inline uint64_t ts_scale(int domain, uint64_t realNs) {
    for (;;) {
        uint64_t v1 = atomic_load_explicit(&gTS_seq, memory_order_acquire);
        if (v1 & 1) continue;   // 写入方正在改，重试
        double   f  = atomic_load_explicit(&gTS_factor,       memory_order_relaxed);
        uint64_t ar = atomic_load_explicit(&gTS_aReal[domain],   memory_order_relaxed);
        uint64_t as = atomic_load_explicit(&gTS_aScaled[domain], memory_order_relaxed);
        uint64_t v2 = atomic_load_explicit(&gTS_seq, memory_order_acquire);
        if (v1 != v2) continue; // 读到一半被改，重试
        if (f <= 1.000001) return realNs;              // 未启用 → 恒等快路径
        if (realNs < ar)   return realNs;              // 时钟异常兜底（绝不下溢回退）
        return as + (uint64_t)(((double)(realNs - ar)) * f);
    }
}

// ===========================================================================
// 被 fishhook 重绑的 C 函数（P0 + P1）
// ===========================================================================

static uint64_t       (*o_mach_absolute_time)(void);
static uint64_t       (*o_mach_continuous_time)(void);
static int            (*o_clock_gettime)(clock_id_t, struct timespec *);
static uint64_t       (*o_clock_gettime_nsec_np)(clock_id_t);
static double         (*o_CACurrentMediaTime)(void);
static dispatch_time_t(*o_dispatch_time)(dispatch_time_t, int64_t);
static void           (*o_usleep)(useconds_t);
static int            (*o_nanosleep)(const struct timespec *, struct timespec *);
static unsigned       (*o_sleep)(unsigned);

static uint64_t ts_mach_absolute_time(void) {
    return ts_ns_to_ticks(ts_scale(TS_DOMAIN_ABS, ts_ticks_to_ns(o_mach_absolute_time())));
}

static uint64_t ts_mach_continuous_time(void) {
    return ts_ns_to_ticks(ts_scale(TS_DOMAIN_CONT, ts_ticks_to_ns(o_mach_continuous_time())));
}

// 单调族 → 缩放；挂钟 / CPU 时间 → 恒等放行。
static inline int ts_clk_domain(clock_id_t c) {
    switch (c) {
        case CLOCK_MONOTONIC:
        case CLOCK_MONOTONIC_RAW:
        case CLOCK_UPTIME_RAW:
#ifdef CLOCK_MONOTONIC_RAW_APPROX
        case CLOCK_MONOTONIC_RAW_APPROX:
#endif
#ifdef CLOCK_UPTIME_RAW_APPROX
        case CLOCK_UPTIME_RAW_APPROX:
#endif
            return TS_DOMAIN_ABS;
        case CLOCK_CONTINUOUS:
#ifdef CLOCK_MONOTONIC_SAFE
        case CLOCK_MONOTONIC_SAFE:      // 语义含休眠时长 → 连续域
#endif
            return TS_DOMAIN_CONT;
        default:
            return -1;   // REALTIME / WALL / CPUTIME 等 → 不缩放
    }
}

static int ts_clock_gettime(clock_id_t clk, struct timespec *ts) {
    int r = o_clock_gettime(clk, ts);
    if (r != 0 || !ts) return r;
    int d = ts_clk_domain(clk);
    if (d < 0) return r;
    uint64_t ns = (uint64_t)ts->tv_sec * 1000000000ull + (uint64_t)ts->tv_nsec;
    ns = ts_scale(d, ns);
    ts->tv_sec  = (time_t)(ns / 1000000000ull);
    ts->tv_nsec = (long)(ns % 1000000000ull);
    return r;
}

static uint64_t ts_clock_gettime_nsec_np(clock_id_t clk) {
    uint64_t ns = o_clock_gettime_nsec_np(clk);
    int d = ts_clk_domain(clk);
    if (d < 0) return ns;
    return ts_scale(d, ns);
}

static double ts_CACurrentMediaTime(void) {
    double s = o_CACurrentMediaTime();
    if (!(s > 0)) return s;
    return (double)ts_scale(TS_DOMAIN_ABS, (uint64_t)(s * 1e9)) / 1e9;
}

static dispatch_time_t ts_dispatch_time(dispatch_time_t when, int64_t delta) {
    // 只处理「相对 NOW」分支；FOREVER / 绝对时刻 / 负数（挂钟域）原样放行。
    // 负 delta（早于 NOW ≈ 立即触发）缩放无收益，且 nowNs + 负数在无符号域
    // 会回绕成「极远的未来」—— 必须放行。
    if (when != DISPATCH_TIME_NOW || delta <= 0) return o_dispatch_time(when, delta);
    double f = ts_factor_now();
    if (f <= 1.000001) return o_dispatch_time(when, delta);
    // 极大 delta（≈FOREVER 语义）不缩放，防溢出
    if (delta > (int64_t)1 << 56) return o_dispatch_time(when, delta);
    uint64_t nowNs = ts_ticks_to_ns(o_mach_absolute_time());
    int64_t scaledDelta = (int64_t)(((double)delta) * f);
    return (dispatch_time_t)(nowNs + scaledDelta);
}

// ---- P1：节拍缩短（显式延时才有明确「预期时长」语义，锁/条件等待不碰） ----

static void ts_usleep(useconds_t usec) {
    if (usec <= 1000 || !atomic_load_explicit(&gTSSleepOn, memory_order_relaxed)) { o_usleep(usec); return; }
    double f = ts_factor_now();
    if (f <= 1.000001) { o_usleep(usec); return; }
    useconds_t v = (useconds_t)(((double)usec) / f);
    o_usleep(v < 1 ? 1 : v);
}

static int ts_nanosleep(const struct timespec *req, struct timespec *rem) {
    if (!req) return o_nanosleep(req, rem);
    if (!atomic_load_explicit(&gTSSleepOn, memory_order_relaxed)) return o_nanosleep(req, rem);
    double f = ts_factor_now();
    if (f <= 1.000001) return o_nanosleep(req, rem);
    uint64_t ns = (uint64_t)req->tv_sec * 1000000000ull + (uint64_t)req->tv_nsec;
    if (ns <= 1000000ull) return o_nanosleep(req, rem);  // ≤1ms 不动
    ns = (uint64_t)(((double)ns) / f);
    struct timespec s2;
    s2.tv_sec  = (time_t)(ns / 1000000000ull);
    s2.tv_nsec = (long)(ns % 1000000000ull);
    return o_nanosleep(&s2, rem);
}

static unsigned ts_sleep(unsigned sec) {
    if (!atomic_load_explicit(&gTSSleepOn, memory_order_relaxed)) { o_sleep(sec); return sec; }
    double f = ts_factor_now();
    if (f <= 1.000001 || sec <= 1) { o_sleep(sec); return sec; }
    unsigned v = (unsigned)(((double)sec) / f);
    o_sleep(v < 1 ? 1 : v);
    return sec;
}

// ===========================================================================
// P1：ObjC 层（CADisplayLink / NSTimer）
// ===========================================================================

static IMP o_DL_timestamp, o_DL_duration, o_DL_targetTimestamp;
static IMP o_tm_initFireDateTRSUR, o_tm_initFireDateRBlock;
static IMP o_tm_cTimerRBlock, o_tm_cSchedRBlock;
static IMP o_tm_cTimerTSUR,   o_tm_cSchedTSUR;
static IMP o_tm_cTimerInv,    o_tm_cSchedInv;

// 倍率>1 时把 interval 缩短（timer 每 f 倍真实时间触发一次 → 逻辑加速 f 倍）
static inline NSTimeInterval ts_scaled_interval(NSTimeInterval ti) {
    if (!(ti > 0)) return ti;
    double f = ts_factor_now();
    if (f <= 1.000001) return ti;
    NSTimeInterval v = ti / f;
    return v > 0 ? v : ti;
}

static double ts_DL_timestamp(id self, SEL _cmd) {
    double v = ((double (*)(id, SEL))o_DL_timestamp)(self, _cmd);
    if (!(v > 0)) return v;
    return (double)ts_scale(TS_DOMAIN_ABS, (uint64_t)(v * 1e9)) / 1e9;
}

static double ts_DL_duration(id self, SEL _cmd) {
    double v = ((double (*)(id, SEL))o_DL_duration)(self, _cmd);
    if (!(v > 0)) return v;
    return (double)ts_scale(TS_DOMAIN_ABS, (uint64_t)(v * 1e9)) / 1e9;
}

// targetTimestamp 必须与 timestamp 同轴缩放：游戏常用
// dt = targetTimestamp - timestamp 做帧预算，只缩一边会得到负 dt。
static double ts_DL_targetTimestamp(id self, SEL _cmd) {
    double v = ((double (*)(id, SEL))o_DL_targetTimestamp)(self, _cmd);
    if (!(v > 0)) return v;
    return (double)ts_scale(TS_DOMAIN_ABS, (uint64_t)(v * 1e9)) / 1e9;
}

// 防双重缩放：CoreFoundation 里 scheduled 变体内部会委托 timer 变体
// （target/selector/invocation 族就是这种实现），两层 wrapper 叠加会把
// interval 除两次 f。规则：只有最外层 wrapper 缩放，嵌套调用原样透传。
static _Thread_local int gTS_tmDepth = 0;

typedef id (*TS_initFDateTRSUR_IMP)(id, SEL, NSDate *, NSTimeInterval, id, SEL, id, BOOL);
static id ts_tm_initFireDateTRSUR(id self, SEL _cmd, NSDate *d, NSTimeInterval ti,
                                  id target, SEL sel, id ui, BOOL rep) {
    if (gTS_tmDepth > 0)
        return ((TS_initFDateTRSUR_IMP)o_tm_initFireDateTRSUR)(self, _cmd, d, ti, target, sel, ui, rep);
    gTS_tmDepth++;
    id r = ((TS_initFDateTRSUR_IMP)o_tm_initFireDateTRSUR)(self, _cmd, d, ts_scaled_interval(ti), target, sel, ui, rep);
    gTS_tmDepth--;
    return r;
}

typedef id (*TS_initFDateRBlock_IMP)(id, SEL, NSDate *, NSTimeInterval, BOOL, dispatch_block_t);
static id ts_tm_initFireDateRBlock(id self, SEL _cmd, NSDate *d, NSTimeInterval ti,
                                   BOOL rep, dispatch_block_t blk) {
    if (gTS_tmDepth > 0)
        return ((TS_initFDateRBlock_IMP)o_tm_initFireDateRBlock)(self, _cmd, d, ti, rep, blk);
    gTS_tmDepth++;
    id r = ((TS_initFDateRBlock_IMP)o_tm_initFireDateRBlock)(self, _cmd, d, ts_scaled_interval(ti), rep, blk);
    gTS_tmDepth--;
    return r;
}

typedef id (*TS_cTimerRBlock_IMP)(Class, SEL, NSTimeInterval, BOOL, dispatch_block_t);
static id ts_tm_cTimerRBlock(Class c, SEL _cmd, NSTimeInterval ti, BOOL rep, dispatch_block_t blk) {
    if (gTS_tmDepth > 0)
        return ((TS_cTimerRBlock_IMP)o_tm_cTimerRBlock)(c, _cmd, ti, rep, blk);
    gTS_tmDepth++;
    id r = ((TS_cTimerRBlock_IMP)o_tm_cTimerRBlock)(c, _cmd, ts_scaled_interval(ti), rep, blk);
    gTS_tmDepth--;
    return r;
}
static id ts_tm_cSchedRBlock(Class c, SEL _cmd, NSTimeInterval ti, BOOL rep, dispatch_block_t blk) {
    if (gTS_tmDepth > 0)
        return ((TS_cTimerRBlock_IMP)o_tm_cSchedRBlock)(c, _cmd, ti, rep, blk);
    gTS_tmDepth++;
    id r = ((TS_cTimerRBlock_IMP)o_tm_cSchedRBlock)(c, _cmd, ts_scaled_interval(ti), rep, blk);
    gTS_tmDepth--;
    return r;
}

typedef id (*TS_cTimerTSUR_IMP)(Class, SEL, NSTimeInterval, id, SEL, id, BOOL);
static id ts_tm_cTimerTSUR(Class c, SEL _cmd, NSTimeInterval ti, id t, SEL s, id u, BOOL r) {
    if (gTS_tmDepth > 0)
        return ((TS_cTimerTSUR_IMP)o_tm_cTimerTSUR)(c, _cmd, ti, t, s, u, r);
    gTS_tmDepth++;
    id r = ((TS_cTimerTSUR_IMP)o_tm_cTimerTSUR)(c, _cmd, ts_scaled_interval(ti), t, s, u, r);
    gTS_tmDepth--;
    return r;
}
static id ts_tm_cSchedTSUR(Class c, SEL _cmd, NSTimeInterval ti, id t, SEL s, id u, BOOL r) {
    if (gTS_tmDepth > 0)
        return ((TS_cTimerTSUR_IMP)o_tm_cSchedTSUR)(c, _cmd, ti, t, s, u, r);
    gTS_tmDepth++;
    id r = ((TS_cTimerTSUR_IMP)o_tm_cSchedTSUR)(c, _cmd, ts_scaled_interval(ti), t, s, u, r);
    gTS_tmDepth--;
    return r;
}

typedef id (*TS_cTimerInv_IMP)(Class, SEL, NSTimeInterval, NSInvocation *, BOOL);
static id ts_tm_cTimerInv(Class c, SEL _cmd, NSTimeInterval ti, NSInvocation *inv, BOOL r) {
    if (gTS_tmDepth > 0)
        return ((TS_cTimerInv_IMP)o_tm_cTimerInv)(c, _cmd, ti, inv, r);
    gTS_tmDepth++;
    id r = ((TS_cTimerInv_IMP)o_tm_cTimerInv)(c, _cmd, ts_scaled_interval(ti), inv, r);
    gTS_tmDepth--;
    return r;
}
static id ts_tm_cSchedInv(Class c, SEL _cmd, NSTimeInterval ti, NSInvocation *inv, BOOL r) {
    if (gTS_tmDepth > 0)
        return ((TS_cTimerInv_IMP)o_tm_cSchedInv)(c, _cmd, ti, inv, r);
    gTS_tmDepth++;
    id r = ((TS_cTimerInv_IMP)o_tm_cSchedInv)(c, _cmd, ts_scaled_interval(ti), inv, r);
    gTS_tmDepth--;
    return r;
}

// 本文件的极简 swizzle（与主文件 SIO_swizzleInstance 同规则：幂等、缺方法静默跳过）
static void ts_swizzle(Class c, SEL sel, IMP newImp, IMP *orig, BOOL isClass) {
    Method m = isClass ? class_getClassMethod(c, sel) : class_getInstanceMethod(c, sel);
    if (!m) return;                       // 选择器不存在 → 静默跳过（低版本兼容）
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;            // 幂等：绝不把自己的 IMP 存进 orig（防自递归）
    *orig = cur;
    method_setImplementation(m, newImp);
}

static void ts_install_objc(void) {
    Class dl  = objc_getClass("CADisplayLink");
    if (dl) {
        ts_swizzle(dl, @selector(timestamp),       (IMP)ts_DL_timestamp,       &o_DL_timestamp,       NO);
        ts_swizzle(dl, @selector(targetTimestamp), (IMP)ts_DL_targetTimestamp, &o_DL_targetTimestamp, NO);
        ts_swizzle(dl, @selector(duration),        (IMP)ts_DL_duration,        &o_DL_duration,        NO);
    }
    Class tm = objc_getClass("NSTimer");
    if (tm) {
        ts_swizzle(tm, @selector(initWithFireDate:interval:target:selector:userInfo:repeats:),
                   (IMP)ts_tm_initFireDateTRSUR, &o_tm_initFireDateTRSUR, NO);
        ts_swizzle(tm, @selector(initWithFireDate:interval:repeats:block:),
                   (IMP)ts_tm_initFireDateRBlock, &o_tm_initFireDateRBlock, NO);
        ts_swizzle(tm, @selector(timerWithTimeInterval:repeats:block:),
                   (IMP)ts_tm_cTimerRBlock, &o_tm_cTimerRBlock, YES);
        ts_swizzle(tm, @selector(scheduledTimerWithTimeInterval:repeats:block:),
                   (IMP)ts_tm_cSchedRBlock, &o_tm_cSchedRBlock, YES);
        ts_swizzle(tm, @selector(timerWithTimeInterval:target:selector:userInfo:repeats:),
                   (IMP)ts_tm_cTimerTSUR, &o_tm_cTimerTSUR, YES);
        ts_swizzle(tm, @selector(scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:),
                   (IMP)ts_tm_cSchedTSUR, &o_tm_cSchedTSUR, YES);
        ts_swizzle(tm, @selector(timerWithTimeInterval:invocation:repeats:),
                   (IMP)ts_tm_cTimerInv, &o_tm_cTimerInv, YES);
        ts_swizzle(tm, @selector(scheduledTimerWithTimeInterval:invocation:repeats:),
                   (IMP)ts_tm_cSchedInv, &o_tm_cSchedInv, YES);
    }
}

// ===========================================================================
// 公共入口
// ===========================================================================

void SIO_TS_install(void) {
    BOOL expected = NO;
    if (!atomic_compare_exchange_strong(&gTS_installed, &expected, YES)) return;   // 幂等

    struct mach_timebase_info tb;
    if (mach_timebase_info(&tb) == KERN_SUCCESS && tb.denom != 0) {
        gTS_tbNum = (double)tb.numer;
        gTS_tbDen = (double)tb.denom;
    }
    // 初始恒等态：factor=1（ts_scale 快路径直接放行）
    atomic_store_explicit(&gTS_factor, 1.0, memory_order_relaxed);

    struct rebinding rb[] = {
        { "mach_absolute_time",      (void *)ts_mach_absolute_time,      (void **)&o_mach_absolute_time      },
        { "mach_continuous_time",    (void *)ts_mach_continuous_time,    (void **)&o_mach_continuous_time    },
        { "clock_gettime",           (void *)ts_clock_gettime,           (void **)&o_clock_gettime           },
        { "clock_gettime_nsec_np",   (void *)ts_clock_gettime_nsec_np,   (void **)&o_clock_gettime_nsec_np   },
        { "CACurrentMediaTime",      (void *)ts_CACurrentMediaTime,      (void **)&o_CACurrentMediaTime      },
        { "dispatch_time",           (void *)ts_dispatch_time,           (void **)&o_dispatch_time           },
        { "usleep",                  (void *)ts_usleep,                  (void **)&o_usleep                  },
        { "nanosleep",               (void *)ts_nanosleep,               (void **)&o_nanosleep               },
        { "sleep",                   (void *)ts_sleep,                   (void **)&o_sleep                   },
    };
    // 任何一步失败都只丢功能：rebind_symbols 返回值不致命（符号可能本就不存在）
    rebind_symbols(rb, sizeof(rb) / sizeof(rb[0]));
    // fishhook 只能重绑「目标镜像自身 GOT 里存在的符号」；App 若从未直接引用
    // 某符号，对应 orig 会保持 NULL —— wrapper / SIO_TS_apply 一调用就崩。
    // 用 dlsym 兜底填原始实现（该符号只是失去拦截，绝不崩）。
    struct { const char *n; void **p; } fb[] = {
        { "mach_absolute_time",      (void **)&o_mach_absolute_time      },
        { "mach_continuous_time",    (void **)&o_mach_continuous_time    },
        { "clock_gettime",           (void **)&o_clock_gettime           },
        { "clock_gettime_nsec_np",   (void **)&o_clock_gettime_nsec_np   },
        { "CACurrentMediaTime",      (void **)&o_CACurrentMediaTime      },
        { "dispatch_time",           (void **)&o_dispatch_time           },
        { "usleep",                  (void **)&o_usleep                  },
        { "nanosleep",               (void **)&o_nanosleep               },
        { "sleep",                   (void **)&o_sleep                   },
    };
    for (size_t i = 0; i < sizeof(fb) / sizeof(fb[0]); i++) {
        if (!*fb[i].p) *fb[i].p = dlsym(RTLD_DEFAULT, fb[i].n);
    }
    ts_install_objc();
}

void SIO_TS_apply(BOOL enabled, double factor, BOOL scaleSleep, BOOL foreground) {
    if (!atomic_load_explicit(&gTS_installed, memory_order_relaxed)) return;
    if (factor < 1.0) factor = 1.0;
    if (factor > 2.0) factor = 2.0;   // 封顶：联网超时 / 反作弊 / 音画同步风险
    double eff = (enabled && foreground) ? factor : 1.0;

    os_unfair_lock_lock(&gTSApplyLock);
    // 用「旧参数」算出当前映射值作为新锚点 → 倍率切换前后缩放时间连续、单调不减
    uint64_t rAn = ts_ticks_to_ns(o_mach_absolute_time());
    uint64_t rCn = ts_ticks_to_ns(o_mach_continuous_time());
    uint64_t sAn = ts_scale(TS_DOMAIN_ABS,  rAn);
    uint64_t sCn = ts_scale(TS_DOMAIN_CONT, rCn);

    uint64_t seq = atomic_load_explicit(&gTS_seq, memory_order_relaxed);
    atomic_store_explicit(&gTS_seq, seq + 1, memory_order_relaxed);            // 进写区（奇）
    atomic_store_explicit(&gTS_factor,        eff,  memory_order_relaxed);
    atomic_store_explicit(&gTS_aReal[TS_DOMAIN_ABS],    rAn, memory_order_relaxed);
    atomic_store_explicit(&gTS_aScaled[TS_DOMAIN_ABS],  sAn, memory_order_relaxed);
    atomic_store_explicit(&gTS_aReal[TS_DOMAIN_CONT],   rCn, memory_order_relaxed);
    atomic_store_explicit(&gTS_aScaled[TS_DOMAIN_CONT], sCn, memory_order_relaxed);
    atomic_store_explicit(&gTS_seq, seq + 2, memory_order_release);            // 出写区（偶）

    atomic_store_explicit(&gTSSleepOn, (scaleSleep && eff > 1.000001), memory_order_relaxed);
    os_unfair_lock_unlock(&gTSApplyLock);
}
