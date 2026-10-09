// ============================================================================
//  SIOriginal v3.0.0 — 统一内部头文件（全模块唯一契约）
// ============================================================================
//  v2.5.0 的全部能力都在一个 4772 行的 SIOriginal.m 里：配置变量、版本判定、
//  hook 实现、安装逻辑互相穿插，导致「同一件事有三个说法」（黑名单两套匹配语义、
//  启动期 hook 有两个安装点、plist 被解析两次）。
//
//  v3.0 的改造原则：**跨模块共享的一切，必须在本文件里只有一处声明**。
//    · 配置状态收敛成一个结构体 gSIOCfg（单一入口），不再是一堆散落全局 BOOL；
//    · TLS 槽位收敛成一个数组 + 枚举，不再是一组 ad-hoc pthread_key_t；
//    · 时长换算引擎在这里以 static inline 给出（保持热路径零调用开销），
//      但输入只读 gSIOCfg —— 各 hook 不再自己算一遍；
//    · 版本能力由 SIOPlatform 一次性探测成位图，hook 只做 `if (caps & ...)`。
//
//  每个走到这里的 hook 都只需要回答两个问题：
//    1. 我要不要旁路？（SIO_blocked / SIO_gated）
//    2. 目标时长是多少？（SIO_targetDuration / SIO_targetDelay / ...）
// ============================================================================

#ifndef SIO_INTERNAL_H
#define SIO_INTERNAL_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <pthread.h>
#import <dlfcn.h>
#import <notify.h>
#import <os/lock.h>

#pragma mark - 版本

#define SIO_VER_MAJOR 3
#define SIO_VER_MINOR 0
#define SIO_VER_PATCH 0
#define SIO_VER_STRING "3.0.0"

#pragma mark - 配置存储（与 v2.x 保持路径兼容）

#define kSIOPrefDomain  @"com.apple.UIKit"
#define kSIOPrefPath    @"/var/Managed Preferences/mobile/com.apple.UIKit.plist"
#define kSIONotifyName  @"com.local.sioriginal.settingschanged"

// v3.0 新增：系统级参数键（写入同一个 com.apple.UIKit 域）。
// UIAnimationDragCoefficient 是 UIKit 原生读取的全局动画时长系数：
//   <1 变快、>1 变慢，1.0 或无此键 = 原生。
// 与 dylib 的 hook 完全解耦 —— 连没被注入的 App 也会生效（需注销/重启）。
// 代价：新值要等下一次 App 启动（或 respring）才被 UIKit 读到。
// 这正是「非巨魔/未注入环境下的安全降级手段」：够不着 hook，就用系统参数。
extern NSString *const kSIOSysKeyDragCoefficient;   // @"UIAnimationDragCoefficient"

#pragma mark - 配置键的三类契约（改动配置前必读）
// plist 里的键按「谁来写」分为三类，混用会导致「界面有开关但无效」的假功能，
// 或者「dylib 永远读不到的键」。新增任何键前先确认它属于哪一类。
//
//  A. 双向键（配置 App 有 UI 开关 ↔ dylib 读取）
//     必须同时出现在三处，缺一处就是假功能：
//       ① App/main.m 的 `NSArray *sioKeys` 白名单（否则保存时被静默丢弃）
//       ② dylib 侧 SIOApply() 里读它
//     例：Enabled / Mode / Speed / MemoryGuard / SchedulingBoost ...
//     ⇒ `tools/check_config_keys.py` 会机械校验这两侧的闭环。
//
//  B. 单侧写入键（只有配置 App 写，dylib 不读或只读同名异源）
//     · AppOverrides / Blacklist / FUBGExcludeApps：dylib 用**专用代码路径**读取
//       （不是 SIOBool），不适用通用白名单校验，已由 checker 显式豁免。
//     · UIAnimationDragCoefficient（= kSIOSysKeyDragCoefficient）：App 写、
//       dylib 只读来做预除补偿 —— 见下方 §系统级参数键。
//
//  C. dylib 内部高级键（App 无 UI，带安全默认值，属预留/调参入口）
//     systemSpeedCompensate(YES) / fastColdStart(YES) / legacyKitMode(0)
//     / swapBudget(0) / privilegeGated(NO)
//     这些键**故意不暴露 UI**：默认值即最优，暴露出去只会让用户把配置调坏。
//     若要新增同类键，同样登记进本清单，checker 会要求它出现在这里。

#pragma mark - 红色警戒：绝不允许被打破的四条不变量
//  1. 加速只能让动画变快，绝不能变慢（时长换算结果 ≤ 原值）
//  2. 注入库自身不得拖慢 App 启动（pre-main 只装最少的东西）
//  3. hook 失败必须优雅降级，绝不崩目标 App
//  4. 不用保活的 App，启动路径上不得出现 AVFoundation / UserNotifications

#pragma mark - 配置状态（唯一入口）

typedef struct {
    // ---- 基础 ----
    BOOL   enabled;              // 总开关
    int    mode;                 // 0=加速 1=慢放 2=瞬切
    double speed;                // 加速倍率（时长 ÷ 倍率）1.0–50.0
    double slowFactor;           // 慢放倍率（时长 × 因子）1.0–10.0
    double floorSec;             // 动画时长下限（秒）
    // ---- 分项开关 ----
    BOOL   spring;               // CASpringAnimation 参数缩放
    BOOL   extra;                // 导航/模态进阶转场
    BOOL   listAccel;            // TV/CV 列表全家桶（高危，默认关）
    BOOL   zoomAccel;            // UIScrollView 缩放动画（实验，默认关）
    BOOL   fastScroll;           // 滑行惯性加急
    BOOL   fastTap;              // 点击零延迟（delaysContentTouches=NO）
    BOOL   longPress;            // 长按手势加速
    double longPressDuration;    // 长按触发时长
    BOOL   layoutAccel;          // layoutIfNeeded 隐式布局动画（实验，默认关）
    BOOL   speedMode;            // 速率引擎（改 speed 而非 duration）
    BOOL   respectReduceMotion;  // 尊重系统「减弱动态效果」
    BOOL   frameAlign;           // 帧对齐引擎
    BOOL   notify;               // 保存配置后弹提示
    // ---- 倍率增强 ----
    double layerBoost;           // 显式动画额外倍率 1.0–10.0
    double transitionBoost;      // 转场独立额外倍率 1.0–10.0
    // ============ v3.0 新增：系统级 / 内存 / 调度 ============
    // 系统 UIKit 全局动画系数。0 表示「不写入」；>0 由配置 App 落盘，
    // dylib 侧只做**补偿**（见 SIO_compensatedDivisor）——避免与 hook 双重加速。
    double systemSpeed;
    BOOL   systemSpeedCompensate;// 是否补偿系统系数（默认 YES）
    BOOL   memoryGuard;          // 内存压力/告警时自动降级关键优化（默认 YES）
    BOOL   schedulingBoost;      // 内部队列 QoS 调优 + 后台任务避让（默认 YES）
    BOOL   fastColdStart;        // 冷启动最小 footprint（延迟安装，默认 YES）
    int    legacyKitMode;        // 0=自动探测 1=强制低版本路径 2=强制高版本路径
    int    swapBudget;           // 方法交换预算上限，0=不限（防御：极低概率下的方法表爆炸）
    BOOL   privilegeGated;       // 高危能力（场景伪装等）仅在沙箱外/巨魔环境启用
} SIOConfigState;

// 全局唯一的配置实例。所有 hook 只读它；写入只允许发生在 SIOConfig 模块
// （且必须在 os_unfair_lock 保护下的重载路径，见 SIOConfigReload 注释）。
extern SIOConfigState gSIOCfg;

// ---------- 派生态（SIOEnginePrepare 在配置变化后一次性算好） ----------
// 这几项放在这里而不是结构体里，是因为它们属于「引擎内部派生量」：
// hook 侧永远不该去写它们，也不该绕过 SIOEnginePrepare 自己算。
extern BOOL   gSIOAnimNoop;        // 加速 ×1 ⇒ 所有换算退化为恒等
extern double gSIOFramePeriod;     // 帧周期（秒），惰性求值后缓存
extern double gSIOImplicitDur;     // 0.25s（系统默认隐式动画时长）的换算结果，预计算

#pragma mark - 进程级标记

extern NSString *gSIOBundleID;      // 当前进程 Bundle ID（构造期算一次）
extern BOOL      gSIOSelfBlacklisted;// 当前进程命黑名单
extern NSArray  *gSIOBlacklistItems; // 清洗后的黑名单条目（动画侧与保活侧共用一份）
extern BOOL      gSIOHasOverride;    // 是否命中 App 专属覆盖
extern BOOL      gSIOListHardGuarded;// 是否被列表 hook 硬保护
extern BOOL      gSIOEditing;        // SpringBoard 桌面/Switcher 编辑态护栏

// 转圈（UIActivityIndicatorView）专属时长下限。
// 低于此值会因帧率采样混叠出现频闪/视觉倒转（越加速看起来越慢）。
// 0.4s ≈ 每秒 2.5 圈，60Hz 下每圈约 24 帧。
extern const double kSIOSpinnerFloorSec;

#pragma mark - TLS 槽位（统一）

typedef NS_ENUM(NSUInteger, SIOTlsSlot) {
    kSIOTlsTxDur    = 0,   // CATransaction set→get 去抖（防二次缩放）
    kSIOTlsPAInit   = 1,   // UIViewPropertyAnimator 初始化重入保护
    kSIOTlsOwnUI    = 2,   // 自绘 UI（toast/悬浮球）旁路，防被自己加速
    kSIOTlsProbe    = 3,   // v3.0：昂贵探测（如 WeChat 放大态）的重入保护
    kSIOTlsCount    = 4
};
extern pthread_key_t SIOTlsKeys[kSIOTlsCount];
extern BOOL          SIOTlsReady;   // key 创建是否全部成功；失败则所有 getter 返回 NO

static inline BOOL SIO_tlsGet(SIOTlsSlot slot) {
    if (!SIOTlsReady) return NO;
    return (BOOL)(intptr_t)pthread_getspecific(SIOTlsKeys[slot]);
}
static inline void SIO_tlsSet(SIOTlsSlot slot, BOOL v) {
    if (!SIOTlsReady) return;
    pthread_setspecific(SIOTlsKeys[slot], (void *)(intptr_t)(v ? 1 : 0));
}
// 作用域守卫：{ SIOTlsGuard g(kSIOTlsOwnUI); ... } 自动恢复原值。
typedef struct { SIOTlsSlot slot; BOOL was; } SIOTlsGuard;
static inline SIOTlsGuard SIO_tlsBegin(SIOTlsSlot slot) {
    SIOTlsGuard g; g.slot = slot; g.was = SIO_tlsGet(slot); SIO_tlsSet(slot, YES); return g;
}
static inline void SIO_tlsEnd(SIOTlsGuard g) { SIO_tlsSet(g.slot, g.was); }

#pragma mark - 原 IMP 判空宏（红线规则 #4）

#define SIO_REQUIRE_ORIG(imp)      do { if (__builtin_expect((imp) == NULL, 0)) return; } while (0)
#define SIO_REQUIRE_ORIG_NIL(imp)  do { if (__builtin_expect((imp) == NULL, 0)) return nil; } while (0)
#define SIO_REQUIRE_ORIG_ZERO(imp) do { if (__builtin_expect((imp) == NULL, 0)) return 0; } while (0)
#define SIO_REQUIRE_ORIG_VAL(imp, v) do { if (__builtin_expect((imp) == NULL, 0)) return (v); } while (0)

#pragma mark - ==================== 时长换算引擎（热路径，全 inline） ====================
// v2.x 的换算逻辑本身是对的（三条安全边界 + 帧对齐），v3.0 只做三件事：
//   1. 抽到头文件让所有模块共用同一份实现（此前散落在 40 多个 hook 里重复判断）；
//   2. 输入统一为 gSIOCfg；
//   3. 归一化不可见收益：除以系统 drag coefficient 做补偿，避免「系统级 + hook」双重加速。
// =====================================================================================

// 帧周期（秒）。惰性求值 —— maximumFramesPerSecond 在 iOS 10.3+ 可用，
// 且首次访问 [UIScreen mainScreen] 会带动 UIScreen 单例与显示链路初始化，
// 属于「绝不能在 pre-main 触发」的动作（v2.5.0 踩过：被一行 NSLog 拖进 dyld 期）。
static inline double SIO_framePeriod(void) {
    double p = gSIOFramePeriod;
    if (__builtin_expect(p > 0.0, 1)) return p;
    @try {
        NSInteger fps = [[UIScreen mainScreen] maximumFramesPerSecond];
        if (fps <= 0) fps = 60;
        p = 1.0 / (double)fps;
    } @catch (__unused NSException *e) {
        p = 1.0 / 60.0;
    }
    if (p <= 0.0) p = 1.0 / 60.0;
    gSIOFramePeriod = p;
    return p;
}

// 速率模式是否启用。启用后所有「改 duration」的路径必须退化为恒等 ——
// 否则时长与速率同时被改 ⇒ 实际倍率相乘，且与双重下限钳制叠加后失真。
static inline double SIO_speedScale(void) {
    if (!gSIOCfg.enabled || !gSIOCfg.speedMode) return 1.0;
    if (gSIOCfg.mode == 2) return 20.0;                                    // 瞬切
    if (gSIOCfg.mode == 1) return (gSIOCfg.slowFactor > 1.0) ? (1.0 / gSIOCfg.slowFactor) : 1.0;
    return (gSIOCfg.speed <= 1.0001) ? 1.0 : gSIOCfg.speed;                // 加速
}
static inline BOOL SIO_speedModeActive(void) {
    return gSIOCfg.enabled && gSIOCfg.speedMode && (fabs(SIO_speedScale() - 1.0) > 1e-6);
}

// ============================ 帧对齐引擎 =============================
// CoreAnimation 按「时间」推进动画，设备每 P 秒刷新一帧。若时长 D 不是 P 的整数倍，
// 最后一帧显示不足 P 就被提交、随后空等 P —— 这一个「不足一帧 + 空等一帧」的周期
// 就是肉眼看到的顿挫。本项目尤其容易制造余数：加速就是拿时长除以倍率，
// 0.3s ÷ 5 = 0.06s，在 60Hz 下是 3.6 帧。
// 修法：向下取整到帧边界的整数倍（3 × 16.67ms = 0.05s）。
// [安全边界 1] 只能缩短、不能延长；[安全边界 2] 不足一帧保持原值
//             （强制拉到 1 帧会把 0.005s 变 0.0167s，慢 3 倍）；
// [安全边界 3] 慢放与速率模式不参与（语义冲突 / 时间轴本就原生）。
static inline double SIO_alignToFrameBoundary(double d) {
    if (!gSIOCfg.enabled || !gSIOCfg.frameAlign) return d;
    if (d <= 0.0) return d;
    if (gSIOCfg.mode == 1) return d;          // 慢放
    if (SIO_speedModeActive()) return d;      // 速率模式
    double P = SIO_framePeriod();
    if (P <= 0.0) return d;
    double n = floor(d / P);
    if (n < 1.0) return d;                    // 不足一帧
    double aligned = n * P;
    if (aligned >= d) return d;               // 浮点边界保险
    return aligned;
}

// v3.0：系统 drag coefficient 的补偿除数。
// 配置 App 把 UIAnimationDragCoefficient 写成 0.58 时，UIKit 会把自己内部
// 生成的动画时长再乘 0.58。但 hook 拦截到的是 **App 传入的、尚未乘系数的值**，
// 于是「hook 缩放 × 系统系数」会连乘两次 —— 用户设 ×5 实际变成 ≈×8.6。
// 补偿办法：我们给出的目标时长先除以该系数，
//   hook 给出 T/c → UIKit 内部再 ×c → 最终 T。
// 无系统系数时 c = 1，退化为恒等，零成本。
static inline double SIO_compensatedDivisor(void) {
    double c = gSIOCfg.systemSpeed;
    if (!gSIOCfg.systemSpeedCompensate) return 1.0;
    if (c <= 0.0 || fabs(c - 1.0) < 1e-6) return 1.0;   // 未设置或原生
    if (c < 0.05) c = 0.05;                              // 防御极端输入
    return c;
}

// ---------- 主换算：所有「时长」 hook 的唯一出口 ----------
static inline double SIO_targetDuration(double orig) {
    if (!gSIOCfg.enabled) return orig;
    double d;
    switch (gSIOCfg.mode) {
        case 1:  d = orig * gSIOCfg.slowFactor; break;                 // 慢放
        // 瞬切：绝不无条件换成 floor —— 当原时长比下限还短时会把动画**拉长**
        // （0.005s → 0.02s = 慢 4 倍），与「加速」语义完全相反。
        case 2:  d = (gSIOCfg.floorSec < orig) ? gSIOCfg.floorSec : orig; break;
        default:
            if (gSIOCfg.speed <= 1.0001) return orig;
            d = orig / gSIOCfg.speed; break;                           // 加速
    }
    // 下限：目标是 min(floor, orig)。注意不是 `d = floor` —— 那会让比 floor 更短的
    // 微动画被抬长，凭空造出卡顿。加速器的语义是「更快」，不是「统一到某个长度」。
    if (d > 0.0) {
        double lo = (gSIOCfg.floorSec < orig) ? gSIOCfg.floorSec : orig;
        if (d < lo) d = lo;
    }
    // 顺序不可颠倒：必须在下限钳制**之后**对齐，否则下限会把已对齐的值重新抬高。
    d = SIO_alignToFrameBoundary(d);
    return d;
}

// 显式动画（CAAnimation / CALayer）专用：在全局之上再叠加 LayerBoost。
// 因为 LayerBoost 又除了一次，对齐必须**重做**（余数变了）。
static inline double SIO_targetDurationLayer(double orig) {
    if (!gSIOCfg.enabled) return orig;
    double d = SIO_targetDuration(orig);
    if (gSIOCfg.mode == 1) return d;
    if (gSIOCfg.layerBoost > 1.0001 && d > 0.0) {
        d = d / gSIOCfg.layerBoost;
        double lo = (gSIOCfg.floorSec < orig) ? gSIOCfg.floorSec : orig;
        if (d < lo) d = lo;
        d = SIO_alignToFrameBoundary(d);
    }
    return d;
}

// 系统 drag coefficient 生效时，App 传入值尚未乘系数、但 UIKit 最终会乘。
// 因此 hook 侧要把目标时长「预除以」系数。非 set 场景（UIKit 内部自生成的
// 隐式动画）不受 hook 影响，直接由系统系数处理 —— 两边都恰好得到目标时长。
static inline double SIO_targetDurationUIKit(double orig) {
    double d = SIO_targetDuration(orig);
    double c = SIO_compensatedDivisor();
    if (c != 1.0 && d > 0.0) d = d / c;
    return d;
}

// 延迟同比缩放：0 延迟保持 0（避免给「立刻执行」凭空加延迟）。
static inline double SIO_targetDelay(double delay) {
    if (!gSIOCfg.enabled || delay <= 0.0) return delay;
    double orig = delay;
    double d;
    switch (gSIOCfg.mode) {
        case 1:  d = delay * gSIOCfg.slowFactor; break;
        case 2:  d = (gSIOCfg.floorSec < delay) ? gSIOCfg.floorSec : delay; break;
        default: d = (gSIOCfg.speed <= 1.0001) ? delay : delay / gSIOCfg.speed; break;
    }
    if (d < 0.0) d = 0.0;
    if (d > orig) d = orig;      // 同样遵守「不许变慢」
    return d;
}

// 弹簧时间缩放（mass/stiffness/damping/velocity 同族）
static inline double SIO_springScale(void) {
    if (!gSIOCfg.enabled) return 1.0;
    if (gSIOCfg.mode == 1) return gSIOCfg.slowFactor;
    if (gSIOCfg.mode == 2) return 20.0;
    return (gSIOCfg.speed <= 1.0001) ? 1.0 : gSIOCfg.speed;
}

// 转场：UIKit 导航/模态转场的默认时长是 0.35s。
// v2.1.0 在这里修过一个「假功能」bug：0.35 经「全局倍率 + 转场倍率」两次除法后
// 很容易落到 floor 以下（×20 + 转场 ×3 → 0.0058 < 0.02），此时
// **下限**会把结果抬回 0.02，转场额外倍率被完全抵消 —— 用户调了档位却
// 看不到任何变化。修法是沿用 SIO_targetDuration 的同一口径：
// **下限只在原值本就 ≥ 下限时才允许钳制**，绝不反向拉长。
static inline double SIO_transitionBase(void) {
    double d = SIO_targetDurationUIKit(0.35);
    if (!gSIOCfg.enabled || gSIOCfg.mode == 1) return d;
    if (gSIOCfg.transitionBoost > 1.0001 && d > 0.0) {
        d = d / gSIOCfg.transitionBoost;
        double lo = (gSIOCfg.floorSec < 0.35) ? gSIOCfg.floorSec : 0.35;
        if (d < lo) d = lo;
        d = SIO_alignToFrameBoundary(d);
    }
    return d;
}

#pragma mark - 门控（「该不该旁路」的唯一实现）

extern BOOL SIO_blockedBase(void);   // 不含 GUI 环境判断的纯配置门控
extern BOOL SIO_blocked(void);       // 完整门控（含自绘 UI / 编辑态 / 无障碍）
extern BOOL SIO_listOK(void);        // 列表 hook 是否可用
extern BOOL SIO_scrollOK(void);      // UIScrollView 滚动/偏移动画是否接管
extern BOOL SIO_zoomOK(void);        // 缩放动画是否可用

#pragma mark - 平台 / 版本能力（SIOPlatform）

typedef NS_OPTIONS(NSUInteger, SIOCaps) {
    kSIOCapNone            = 0,
    // ---- 版本演进带来的 API 可用性 ----
    kSIOCapWindowScene     = 1 << 0,   // iOS 13+ UIScene / UIWindowScene
    kSIOCapMultiScene     = 1 << 1,   // iOS 13+ 同进程存在多个 UIScene（iPad 分屏）
    kSIOCapSpringVelocity  = 1 << 2,   // iOS 10+ CASpringAnimation setVelocity:
    kSIOCapRefreshPkgChg   = 1 << 3,   // iOS 17+ UIRefreshControl pkg 变动（探测式启用）
    kSIOCapSwiftUIHosting  = 1 << 4,   // iOS 13.1+ SwiftUI UIHostingController 存在
    kSIOCapMaxFPSReadable  = 1 << 5,   // iOS 10.3+ UIScreen.maximumFramesPerSecond
    kSIOCapOsProcMem       = 1 << 6,   // iOS 13+ os_proc_available_memory
    kSIOCapBlurHosting    = 1 << 7,   // iOS 15+ 新版模糊/材质栈（UIBlurEffect 归属变化）
    // ---- 运行环境 ----
    kSIOCapInjected       = 1 << 10,  // 本 dylib 是被 TrollFools 注入的（非主 App 链接）
    kSIOCapTrollStore     = 1 << 11,  // 设备装了 TrollStore
    kSIOCapRootHelper     = 1 << 12,  // 巨魔 RootHelper 可用（iOS 17.6+/18 可能失效）
    kSIOCapUnsandboxed    = 1 << 13,  // 本进程无沙箱（platform-application / no-sandbox）
    kSIOCapWriteManagedPrefs = 1 << 14, // 可写 /var/Managed Preferences
    kSIOCapJIT             = 1 << 15,  // 本进程可被 enable-jit（巨魔 2.0.12+）
};

extern SIOCaps  gSIOCaps;
extern NSInteger gSIOMajor;    // 主版本号，如 18
extern NSInteger gSIOMinor;    // 次版本号

extern void      SIOProbePlatform(void);                 // 构造期调用一次
extern BOOL      SIOAtLeast(NSInteger major);            // >= iOS major
extern BOOL      SIOBelow(NSInteger major);              // <  iOS major
extern NSString *SIOPlatformSummary(void);               // 诊断字符串

#pragma mark - 安装器（v3.0 统一入口）

typedef NS_ENUM(NSUInteger, SIOStage) {
    kSIOStageBoot       = 0,   // 构造期必须装（核心动画两族，首屏正确性依赖）
    kSIOStagePostLaunch = 1,   // didFinishLaunching 之后（默认再延后一档）
    kSIOStageOnDemand   = 2,   // 仅当功能开关为 YES 时才装（默认关闭项）
};

typedef struct {
    const char *className;      // 目标类（objc_getClass 惰性取，不存在自动跳过）
    const char *selectorName;   // 方法名（C 字符串，编译期常量；安装时 sel_registerName 解析）
    BOOL        isClassMethod;
    IMP         newImp;
    IMP        *origSlot;
    SIOStage    stage;
    BOOL      (*gate)(void);    // 返回 NO ⇒ 完全不安装（连装都不装）
    NSInteger   minOS;          // 最低版本，0 = 不限
    NSInteger   maxOS;          // 最高版本，0 = 不限
    SIOCaps     needCaps;       // 需要的运行能力，0 = 不限
    BOOL        optional;       // YES ⇒ 找不到原实现不算失败
} SIOHookEntry;

extern int  gSIOHookSwapCount;   // 已发生的 method_setImplementation 次数
extern void SIOInstall(void);    // 安装全部三档（内部按 stage 分派）
extern void SIOInstallStage(SIOStage stage);
extern void SIOExchange(const char *cls, SEL sel, IMP newImp, IMP *orig, BOOL isMeta);

#pragma mark - 调度器（启动栅栏 / 延后安装 / QoS）

extern void      SIOAfterBoot(void (^block)(void));   // 排到「App 启动完成之后」
extern void      SIODeferPostLaunch(void);            // 内部：触发 postLaunch 档安装
extern BOOL      SIOPostLaunchDone(void);
// v3.0：内存与调度。两级降级依次为「关增强项」→「关列表/布局」→「整体只读」。
extern int       SIOMemoryPressureLevel(void);        // 0 正常 / 1 告警 / 2 严重
extern void      SIOSetupResourceWatchdog(void);      // 注册内存压力源 + 内存告警通知
extern void      SIOApplyQoSPolicy(void);             // 内部队列 QoS（避免在首屏抢主线程）

#pragma mark - 配置（SIOConfig）

extern void SIOConfigLoad(void);          // 首次加载 + 失败回落默认值
extern void SIOConfigReload(void);        // Darwin 通知触发的热重载（主线程串行）
extern BOOL SIOConfigReadable(void);      // plist 是否可读（诊断用）
extern BOOL SIOBundleMatches(NSString *entry);  // 黑名单唯一匹配实现（精确 + 尾 `*` 前缀）
extern BOOL SIOSelfBlacklisted(void);
extern BOOL SIOSceneFakingAllowed(void);  // 是否允许场景伪装（需沙箱外能力）
// v3.0：App 级覆盖查找（保活模块也要用同一套覆盖语义，故提升为公开接口）。
// 内部走 SIOPrefSnapshot 的唯一缓存，不额外读盘。
extern NSDictionary *SIOAppOverrideLookup(NSDictionary *root);
extern NSDictionary *SIOPrefSnapshot(void);     // 唯一磁盘读取出口（带锁缓存）

#pragma mark - 引擎派生量重算（配置变化后调用）

extern void SIOEnginePrepare(void);       // 算 gSIOAnimNoop / gSIOImplicitDur / 缓存
extern void SIOEngineInvalidateFrame(void);

#pragma mark - Toast / 提示（SIOUI）

extern BOOL SIOShowToast(NSString *text, BOOL throttle);
extern void SIOShowSettingsToast(void);

#pragma mark - 保活（SIOBackground）

// v3.0：由 SIOInstaller 在「启动完成之后」统一编排调用 —— 不再有自己的 constructor。
// 原因：本模块要动 UIApplication / AVAudioSession，而 constructor 跑在非主线程，
// v2.x 正是在这里踩过 UIKit 主线程约束的坑。
extern void SIOSetupBackground(void);
extern void SIOBackgroundReload(void);   // 配置热重载时由 SIOConfig 调用（幂等）

#pragma mark - 共用工具

extern NSString *SIOBundleID(void);
extern void      SIOLogBrand(void);       // 延后到启动完成之后打的完整指纹

#pragma mark - 事务包裹（控件/栏/单元格三族的共用形态）

// 用一个自定义时长包住 block —— 全项目只有这里会 begin/set/commit。
// v2.x 里同样的四行在 42 个 hook 里各写一遍（还各自记得/忘了设重入标记），
// 于是出现「同一类事情三种行为」。v3.0 收敛成三个入口。
extern void SIOWrapDuration(void (^block)(void), double duration);
extern void SIOWrapDefault (void (^block)(void));   // 包装系统默认 0.25s
extern void SIOWrapTransition(void (^block)(void)); // 包装转场默认 0.35s（受 Extra 门控）

#pragma mark - 其他模块接口（跨文件使用）

extern BOOL      SIOTlsInit(void);
extern void      SIOProbeEnvironmentDeferred(void);
extern UIWindow *SIOForegroundWindow(void);
extern BOOL      SIOAppIsActive(void);
extern void      SIOConfigReloadItems(void);
extern void      SIOConfigRegisterObserver(void);
extern void      SIOConfigNotifyCallback(CFNotificationCenterRef center, void *observer,
                                         CFStringRef name, const void *object,
                                         CFDictionaryRef userInfo);
extern void      SIOMarkBootStart(void);
extern double    SIOMarkBootCost(void);
extern dispatch_queue_t SIOWorkQueue(void);
extern BOOL      SIO_reduceMotionOn(void);
extern void      SIO_setTransactionDuration(double d);
extern double    SIO_getTransactionDuration(void);
extern int       SIOHookSwapCount(void);

#endif /* SIO_INTERNAL_H */

