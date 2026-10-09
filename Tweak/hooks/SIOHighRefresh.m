// ============================================================================
//  SIOHighRefresh — 120Hz 高刷解锁（ProMotion 机型）
// ============================================================================
//  源自 v2.5.1，v3.0 只做结构适配（gate / stage / entries 声明式），逻辑不变。
//
//  原理：App 的动画/滚动帧率由两条「申请」路径决定 ——
//    1. CADisplayLink（游戏/自绘/滚动惯性）：preferredFramesPerSecond（iOS 10+）
//       与 preferredFrameRateRange（iOS 15+）决定回调频率上限；
//    2. CAAnimation.preferredFrameRateRange（iOS 15+）：决定该动画提请的渲染帧率。
//  系统默认把普通 App 的申请压到 60Hz；ProMotion 机型（iPhone 13 Pro 起）硬件
//  支持 120Hz。这里把申请值抬到屏幕硬件上限
//  （UIScreen.mainScreen.maximumFramesPerSecond，60Hz 屏 = 60 → 恒等零影响）。
//
//  **不改任何时长、不强制硬件输出** —— 只是不拦 App 的高帧率申请，
//  最终输出仍由系统合成器按电量/温控调度，因此零崩溃风险。
//
//  装设成本：三个 hook 全部走运行时选择器探测 —— iOS 15 以下
//  preferredFrameRateRange 选择器不存在 ⇒ SIOExchange 内部直接跳过，
//  不会给旧系统凭空添加方法（这正是 v3.0 的 minOS/能力位机制要解决的问题）。
// ============================================================================

#import "SIOInternal.h"

#pragma mark - 硬件上限（惰性求值）

// 注意不能放在 pre-main 求值：首次访问 [UIScreen mainScreen] 会带动
// UIScreen 单例与显示链路初始化（v2.5.0 踩过的坑）。
// 这里用函数内 static 惰性求值，且只在真正需要（开关打开）时才被调用。
static int SIO_maxFPS(void) {
    static int s_fps = 0;
    if (s_fps <= 0) {
        int f = 60;
        @try {
            f = (int)[[UIScreen mainScreen] maximumFramesPerSecond];
        } @catch (__unused NSException *e) {}
        if (f <= 0) f = 60;
        s_fps = f;
    }
    return s_fps;
}

// 门控：只有「总开关开 + 高刷开关开」才接管。
// 两个条件都关时 hook 直接透传 —— 因此即使装了也零行为影响。
static BOOL SIOHighRefreshGate(void) {
    return gSIOCfg.highRefresh;
}

#pragma mark - CAFrameRateRange 抬升（共用逻辑）

// iOS 15+ 的三字段结构体按值传参。arm64 HFA 约定下走 s0–s2 浮点寄存器，
// 因此 hook 的函数签名必须与真实 ABI 精确匹配（float × 3）。
// 这也是为什么不能统一写成 void*(id,SEL,...) 可变参形式。
static CAFrameRateRange SIO_raiseRange(CAFrameRateRange r) {
    if (!SIOHighRefreshGate() || !gSIOCfg.enabled) return r;
    float maxf = (float)SIO_maxFPS();
    if (maxf <= 60.0f) return r;              // 60Hz 屏：恒等
    if (r.maximum   < maxf) r.maximum   = maxf;
    if (r.preferred < maxf) r.preferred = maxf;
    // 防御非法区间：minimum 不得大于 preferred（否则 CoreAnimation 会告警）
    if (r.minimum > r.preferred) r.minimum = r.preferred;
    return r;
}

#pragma mark - CADisplayLink

static void (*o_dl_setFPS)(id, SEL, NSInteger);

static void sio_dl_setFPS(id self, SEL _cmd, NSInteger fps) {
    SIO_REQUIRE_ORIG(o_dl_setFPS);
    if (SIOHighRefreshGate() && gSIOCfg.enabled) {
        int maxf = SIO_maxFPS();
        // 只在「屏幕确实支持 >60」且「App 申请低于上限」时提升。
        // 若 App 主动申请更低的帧率（例如省电模式的自绘），我们也会抬高 ——
        // 这是本功能的语义，用户显式打开即表示接受。
        if (maxf > 60 && fps > 0 && fps < maxf) fps = maxf;
    }
    o_dl_setFPS(self, _cmd, fps);
}

static void (*o_dl_setRange)(id, SEL, CAFrameRateRange);

static void sio_dl_setRange(id self, SEL _cmd, CAFrameRateRange r) {
    SIO_REQUIRE_ORIG(o_dl_setRange);
    o_dl_setRange(self, _cmd, SIO_raiseRange(r));
}

#pragma mark - CAAnimation

static void (*o_caanim_setRange)(id, SEL, CAFrameRateRange);

static void sio_caanim_setRange(id self, SEL _cmd, CAFrameRateRange r) {
    SIO_REQUIRE_ORIG(o_caanim_setRange);
    o_caanim_setRange(self, _cmd, SIO_raiseRange(r));
}

#pragma mark - 安装表

// 全部 PostLaunch 档：高刷与「首屏正确性」无关，放 pre-main 只会白担启动成本。
// needCaps 不用设置 —— 选择器探测由 SIOExchange 自动完成：
// iOS 15 以下没有 setPreferredFrameRateRange:，条目会被静默跳过。
// 这比写 minOS=15 更准确（同一个小版本在不同设备上 API 可用性可能不同）。
extern const SIOHookEntry *SIOHighRefreshEntries(NSUInteger *count);

static const SIOHookEntry kSIOHighRefreshEntries[] = {
    { "CADisplayLink", "setPreferredFramesPerSecond:", NO,
      (IMP)sio_dl_setFPS, (IMP *)&o_dl_setFPS,
      kSIOStagePostLaunch, SIOHighRefreshGate, 0, 0, 0, YES },
    { "CADisplayLink", "setPreferredFrameRateRange:", NO,
      (IMP)sio_dl_setRange, (IMP *)&o_dl_setRange,
      kSIOStagePostLaunch, SIOHighRefreshGate, 0, 0, 0, YES },
    { "CAAnimation", "setPreferredFrameRateRange:", NO,
      (IMP)sio_caanim_setRange, (IMP *)&o_caanim_setRange,
      kSIOStagePostLaunch, SIOHighRefreshGate, 0, 0, 0, YES },
};

const SIOHookEntry *SIOHighRefreshEntries(NSUInteger *count) {
    if (count) *count = sizeof(kSIOHighRefreshEntries) / sizeof(kSIOHighRefreshEntries[0]);
    return kSIOHighRefreshEntries;
}
