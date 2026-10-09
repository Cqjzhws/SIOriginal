// ============================================================================
//  hooks/SIOCoreAnimation — CoreAnimation 层（引擎真正的心脏）
// ============================================================================
//  这一族是唯一在「构造期（pre-main）」就装的 hook：
//    · CAAnimation setDuration: / setSpeed:
//    · CATransaction set/getAnimationDuration:
//  · CALayer addAnimation:forKey: / setSpeed: / actionForKey:
//  · CASpringAnimation 四参数
//  理由：App 首屏最常见的卡顿观感来自「转圈」与「首个隐式动画」，
//  这两者都在 didFinishLaunching 之前就可能出现。把它们排到启动之后，
//  用户看到的会是「打开 App 的前 0.3 秒不加速」—— 恰好是最显眼的时段。
//  其余全部 hook 都已经移出 pre-main（见 SIOInstaller 的 stage 表）。
//
//  【为什么 setSpeed: 与 setDuration: 必须互斥】v2.1.0 引入速率模式时的关键约束：
//  同时改两者 ⇒ 实际倍率 = 时长倍率 × 速率倍率（用户设 ×5 实际 ×25），
//  而且双重下限钳制会失真。互斥由 SIO_speedModeActive() 统一短路保证。
// ============================================================================

#import "SIOInternal.h"

#pragma mark - 交易包裹（全项目唯一实现）

void SIOWrapDuration(void (^block)(void), double duration) {
    // 恒等快速路径：加速 ×1 时 42 个包裹点的 begin/set/commit 是纯开销，
    // 且会把上下文时长强行改成 0.25 —— 比系统原生行为还多一层干预。
    if (gSIOAnimNoop || SIO_speedModeActive() || SIO_blocked()) { block(); return; }
    @try {
        [CATransaction begin];
        SIO_setTransactionDuration(duration);   // 走 TLS 抑制 set→get 二次缩放
        block();
        [CATransaction commit];
    } @catch (__unused NSException *e) {
        // begin 成功但 commit 抛异常的可能极低；兜住直接放行，绝不崩 App（红线 #3）
        @try { [CATransaction commit]; } @catch (__unused NSException *e2) { }
    }
}

void SIOWrapDefault(void (^block)(void)) {
    SIOWrapDuration(block, gSIOImplicitDur);   // 0.25s 的换算结果，早已预算好
}

void SIOWrapTransition(void (^block)(void)) {
    if (!gSIOCfg.extra) { block(); return; }   // 进阶转场开关门控
    SIOWrapDuration(block, SIO_transitionBase());
}

#pragma mark - 原时长盒子（POD）

// v2.1.0：原时长不能用 @(d) 装箱 —— 每次显式动画的每次 setDuration: 都会
// 堆分配一个 NSNumber + 一次关联对象写，是热路径上的稳定分配来源。
// ARC 下也不能直接把 malloc 的 double* 当 id 存取（RETAIN 策略会对非对象指针
// 发 retain ⇒ 崩溃），所以必须用一个极小的 ObjC 类承载。
//
// v2.5.0：把「已缩放」标记并进同一个盒子，调用点从「三次关联对象访问」
// 降到「一次读 + 一次写」。objc_get/setAssociatedObject 走的是全局
// AssociationsManager（自旋锁保护的哈希表），多线程同时播动画时会形成真实锁竞争。
@interface SIODurBox : NSObject { @public double value; BOOL scaled; }
@end
@implementation SIODurBox
@end

static const void *kSIODurBoxKey = &kSIODurBoxKey;

static inline SIODurBox *SIODurBoxFor(id anim, BOOL create) {
    if (!anim) return nil;
    SIODurBox *box = (SIODurBox *)objc_getAssociatedObject(anim, kSIODurBoxKey);
    if (box || !create) return box;
    box = [SIODurBox new];
    box->value  = -1.0;
    box->scaled = NO;
    objc_setAssociatedObject(anim, kSIODurBoxKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return box;
}
static inline BOOL SIOAnimScaled(id anim) {
    SIODurBox *b = SIODurBoxFor(anim, NO);
    return b ? b->scaled : NO;
}

#pragma mark - 转圈判定（两次 O(1) 前置筛）

// v2.1.0：从「每个 delegate 一次 NSStringFromClass + 两次 containsString:」
// 降到 isSubclassOfClass: + 16 槽直映缓存 + 深度上限（8 层）。
// v2.5.0：再加一道 O(1) 前置筛 —— 代价结构原本反直觉：
//   「判定不是转圈」才是最贵的情况（要走完整条图层树），
//   而列表滚动时每秒几十次 addAnimation: **全部不是转圈**。
static BOOL SIODelegateIsSpinnerCandidate(Class dc, BOOL *outNeedString) {
    *outNeedString = NO;
    if ([dc isSubclassOfClass:[UIActivityIndicatorView class]]) return YES;
    static Class   cacheCls[16];
    static uint8_t cacheVal[16];       // 0 未知 / 1 是候选 / 2 否
    // 直映缓存用静态数组而不是字典：类指针auit指向的对象生命周期与进程等长，
    // 不存在悬垂；命中时零消息发送、零分配。
    uintptr_t key  = (uintptr_t)dc;
    uintptr_t slot = ((key >> 4) ^ (key >> 20) ^ (key >> 36)) & 15;
    if (cacheCls[slot] == dc) {
        if (cacheVal[slot] == 1) return YES;
        if (cacheVal[slot] == 2) { *outNeedString = YES; return NO; }
    }
    BOOL hit = NO;
    const char *cn = class_getName(dc);
    if (cn && strstr(cn, "ActivityIndicator") != NULL) hit = YES;
    cacheCls[slot] = dc;
    cacheVal[slot] = hit ? 1 : 2;
    if (!hit) *outNeedString = YES;    // 仍可能 superview 链上有转圈
    return hit;
}

// 前置筛：**只做否定，不做肯定**。
// 唯一风险是漏判（某个非典型转圈没被加速），不会误判
// （不会把普通动画当成转圈去套 0.4s 下限而变慢）。漏判的后果远轻于误判。
static inline BOOL SIOAnimMayBeSpinner(CAAnimation *anim) {
    if (![anim isKindOfClass:[CAPropertyAnimation class]]) return NO;   // CATransition/Group 不是转圈本身
    float rc = anim.repeatCount;
    // UIKit 写死的是 1e100f（溢出为 +inf）；也有 App 写 FLT_MAX。
    // 用「极大值」而非等值比较，避免不同写法的浮点表示差异。
    BOOL forever = (rc == INFINITY) || (rc >= 1.0e6f) || (anim.repeatDuration > 0.0);
    if (!forever) return NO;
    NSString *kp = ((CAPropertyAnimation *)anim).keyPath;
    if (kp.length == 0) return NO;
    // 只认旋转：无限重复的 opacity/position 抖动不是转圈，
    // 套 0.4s 下限会让它**变慢**，与加速目的相反。
    return [kp rangeOfString:@"rotation"].location != NSNotFound ||
           [kp isEqualToString:@"transform"];
}

#pragma mark - 原 IMP 槽位

static void   (*o_caAnim_setDuration)(id, SEL, double);
static void   (*o_caAnim_setSpeed)(id, SEL, float);
static void   (*o_catx_setDur)(id, SEL, double);
static NSTimeInterval (*o_catx_getDur)(id, SEL);
static void   (*o_layer_addAnim)(id, SEL, id, NSString *);
static void   (*o_layer_setSpeed)(id, SEL, float);
static id     (*o_layer_actionForKey)(id, SEL, NSString *);
static void   (*o_spring_mass)(id, SEL, double);
static void   (*o_spring_stiff)(id, SEL, double);
static void   (*o_spring_damp)(id, SEL, double);
static void   (*o_spring_velocity)(id, SEL, double);
static void   (*o_indicator_start)(id, SEL);
static void   (*o_refresh_begin)(id, SEL);
static void   (*o_refresh_end)(id, SEL);
static void   (*o_refresh_didMove)(id, SEL);

#pragma mark - CAAnimation

static void sio_caAnim_setDuration(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_caAnim_setDuration);
    if (SIO_blocked() || SIO_speedModeActive()) { o_caAnim_setDuration(self, _cmd, d); return; }
    double nd = SIO_targetDurationLayer(d);
    if (nd == d) { o_caAnim_setDuration(self, _cmd, d); return; }   // 恒等：零额外开销
    SIODurBox *box = SIODurBoxFor(self, YES);
    if (box) box->value = d;
    o_caAnim_setDuration(self, _cmd, nd);
    // 标记必须在调用原 IMP **之后**设置：原 IMP 抛异常时不应留下「已处理」标记，
    // 否则 addAnimation: 的兜底分支会误以为已缩放而跳过。
    if (box) box->scaled = YES;
}

static void sio_caAnim_setSpeed(id self, SEL _cmd, float sp) {
    SIO_REQUIRE_ORIG(o_caAnim_setSpeed);
    if (SIO_blocked() || !SIO_speedModeActive()) { o_caAnim_setSpeed(self, _cmd, sp); return; }
    // 只接管系统默认 1.0。App 显式设的非 1.0 是刻意的节奏控制（音画同步/慢动作），
    // 与长按时长「只替换系统默认」同一口径。
    if (fabs((double)sp - 1.0) > 1e-4) { o_caAnim_setSpeed(self, _cmd, sp); return; }
    double m = SIO_speedScale();
    if (m <= 0.0) { o_caAnim_setSpeed(self, _cmd, sp); return; }
    o_caAnim_setSpeed(self, _cmd, (float)m);
    SIODurBox *box = SIODurBoxFor(self, YES);
    if (box) box->scaled = YES;
}

// 弹簧四参数：保持物理一致性。
// 只缩放在 App 看来「还没被动过」的默认值附近是不够的 —— App 显式给的是设计意图，
// 这里统一按同一比例缩放，让「快」的同时形态不变。
static void sio_spring_mass(id self, SEL _cmd, double v) {
    SIO_REQUIRE_ORIG(o_spring_mass);
    if (!gSIOCfg.spring || SIO_blocked()) { o_spring_mass(self, _cmd, v); return; }
    o_spring_mass(self, _cmd, v);   // mass 是质量，不随倍率缩放
}
static void sio_spring_stiff(id self, SEL _cmd, double v) {
    SIO_REQUIRE_ORIG(o_spring_stiff);
    if (!gSIOCfg.spring || SIO_blocked()) { o_spring_stiff(self, _cmd, v); return; }
    double s = SIO_springScale();
    o_spring_stiff(self, _cmd, s > 0.0 ? v * s * s : v);   // stiffness ∝ 1/t²
}
static void sio_spring_damp(id self, SEL _cmd, double v) {
    SIO_REQUIRE_ORIG(o_spring_damp);
    if (!gSIOCfg.spring || SIO_blocked()) { o_spring_damp(self, _cmd, v); return; }
    double s = SIO_springScale();
    o_spring_damp(self, _cmd, s > 0.0 ? v * s : v);        // damping ∝ 1/t
}
static void sio_spring_velocity(id self, SEL _cmd, double v) {
    SIO_REQUIRE_ORIG(o_spring_velocity);
    if (!gSIOCfg.spring || SIO_blocked()) { o_spring_velocity(self, _cmd, v); return; }
    double s = SIO_springScale();
    o_spring_velocity(self, _cmd, s > 0.0 ? v * s : v);
}

#pragma mark - CATransaction

// v2.0.7：记录本线程最近一次经我们写入的事务时长。CATransaction 状态线程私有，
// 写入与隐式动画的读取必然同线程，因此线程局部变量可以精确对齐
// 「这个值是不是我们刚写进去的」。
static __thread double gSIOTxLastSet = -1.0;

static void sio_catx_setDur(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_catx_setDur);
    if (SIO_tlsGet(kSIOTlsTxDur) || SIO_blocked()) {
        // SIO_setTransactionDuration 走这里：d 已是调用方算好的终值，原样写入
        gSIOTxLastSet = d;
        o_catx_setDur(self, _cmd, d);
        return;
    }
    double nd = SIO_targetDuration(d);
    gSIOTxLastSet = nd;
    o_catx_setDur(self, _cmd, nd);
}

// getter：SwiftUI / CALayer 隐式动画读取「此刻的默认时长」时也要缩放，
// 否则所有依赖 transaction 默认值的地方会漏掉（v2.0.4 补的盲区）。
// 但必须对「我们刚写进去的值」原样返回 —— v2.0.7 修的就是这个双重缩放
// （0.5 → 0.1 → 0.02，凭空把动画再快十几倍）。
static NSTimeInterval sio_catx_getDur(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG_ZERO(o_catx_getDur);
    NSTimeInterval d = o_catx_getDur(self, _cmd);
    if (SIO_blocked()) return d;
    if (gSIOTxLastSet >= 0.0 && fabs(d - gSIOTxLastSet) < 1e-9) return d;
    return SIO_targetDuration(d);
}

#pragma mark - CALayer

static void sio_layer_setSpeed(id self, SEL _cmd, float sp) {
    SIO_REQUIRE_ORIG(o_layer_setSpeed);
    if (SIO_blocked() || !SIO_speedModeActive()) { o_layer_setSpeed(self, _cmd, sp); return; }
    // 图层树自带的播放速率。动画加入图层后按 layer.speed 播放，
    // 速率模式下若不接管，会与 CAAnimation.speed 相乘。
    if (fabs((double)sp - 1.0) > 1e-4) { o_layer_setSpeed(self, _cmd, sp); return; }
    double m = SIO_speedScale();
    o_layer_setSpeed(self, _cmd, (float)(m > 0.0 ? m : 1.0));
}

// v2.4.0 补的隐式动画盲区：可动画属性在没有 animate 块包裹时被改变时，
// CoreAnimation 调 actionForKey: 取默认 CABasicAnimation。该动画的 duration
// 通常已被 getter hook 缩放，但存在绕过 getter 的路径（layer.actions 预存、
// 子类覆写 defaultActionForKey: 返回硬编码 0.25 的动画）。这里再兜一次。
// 这是本项目**最热**的 hook（每次属性赋值都会过一遍），故所有常量都预计算。
static id sio_layer_actionForKey(id self, SEL _cmd, NSString *key) {
    SIO_REQUIRE_ORIG_NIL(o_layer_actionForKey);
    id action = o_layer_actionForKey(self, _cmd, key);
    if (!action || gSIOAnimNoop || SIO_speedModeActive()) return action;
    if (key.length > 32) return action;                             // 非属性类 key 快速否定
    if (![action isKindOfClass:[CAAnimation class]]) return action;
    if (SIO_blocked()) return action;
    CAAnimation *anim = (CAAnimation *)action;
    double d = anim.duration;
    if (d <= 0.0 || fabs(d - 0.25) > 1e-6) return action;           // 只兜系统默认 0.25s
    double nd = gSIOImplicitDur;
    if (nd != d && o_caAnim_setDuration) {
        o_caAnim_setDuration(anim, @selector(setDuration:), nd);    // 绕开自己的 setDuration hook
    }
    return action;
}

static void sio_layer_addAnim(id self, SEL _cmd, id anim, NSString *key) {
    SIO_REQUIRE_ORIG(o_layer_addAnim);
    // 恒等 / 速率模式：本函数的兜底与转圈钳制都算不出新值，直接透传。
    if (gSIOAnimNoop || SIO_speedModeActive()) { o_layer_addAnim(self, _cmd, anim, key); return; }

    BOOL isAnim  = (anim != nil) && [anim isKindOfClass:[CAAnimation class]];
    BOOL blocked = SIO_blocked();   // 只算一次：内部还挂着 WeChat 预览的节流探测

    // 旁路走「还原」快路径：语义等价于原实现，但代价从 O(图层树) 降到 O(1)。
    // 「有没有被我们缩过」看自己的标记与原值即可，与它是不是转圈无关。
    if (isAnim && blocked) {
        SIODurBox *box = SIODurBoxFor(anim, NO);
        double saved = box ? box->value : -1.0;
        if (saved > 0.0 && o_caAnim_setDuration) {
            double cur = ((CAAnimation *)anim).duration;
            if (cur != saved) o_caAnim_setDuration(anim, @selector(setDuration:), saved);
        }
        o_layer_addAnim(self, _cmd, anim, key);
        return;
    }

    if (isAnim && !blocked && SIOAnimMayBeSpinner((CAAnimation *)anim)) {
        BOOL isSpinner = NO;
        @try {
            CALayer *l = (CALayer *)self;
            int depth = 0;
            while (l && depth++ < 8) {
                id delegate = [l delegate];
                if (delegate) {
                    Class dc = object_getClass(delegate);
                    BOOL needStr = NO;
                    if (SIODelegateIsSpinnerCandidate(dc, &needStr) ||
                        [delegate isKindOfClass:[UIActivityIndicatorView class]]) {
                        isSpinner = YES; break;
                    }
                    // v2.0.1 崩溃修复：delegate 不保证是 UIView（AVPlayerLayer 附属、
                    // 第三方绘图图层会挂自定义 NSObject 代理），直接发 superview 会崩。
                    if (needStr && [delegate isKindOfClass:[UIView class]]) {
                        UIView *v = (UIView *)delegate;
                        int vd = 0;
                        while (v && vd++ < 24) {
                            if ([v isKindOfClass:[UIActivityIndicatorView class]]) { isSpinner = YES; break; }
                            v = v.superview;
                        }
                        if (isSpinner) break;
                    }
                }
                l = l.superlayer;
            }
        } @catch (__unused NSException *e) { isSpinner = NO; }   // 检测失败按非转圈处理：只损失加速

        if (isSpinner) {
            double cur   = ((CAAnimation *)anim).duration;
            SIODurBox *box = SIODurBoxFor(anim, YES);
            double saved = box ? box->value : -1.0;
            // 仅当盒子里存的值与当前值一致时才采信 —— 不一致说明中间被别处改过。
            double orig  = (saved > 0.0 && fabs(saved - cur) < 1e-9) ? saved : cur;
            if (orig > 0.0 && o_caAnim_setDuration) {
                if (box) box->scaled = YES;
                double nd;
                if (gSIOCfg.mode == 1)      nd = orig * gSIOCfg.slowFactor;
                else if (gSIOCfg.mode == 2) nd = (kSIOSpinnerFloorSec < orig) ? kSIOSpinnerFloorSec : orig;
                else                        nd = orig / (gSIOCfg.speed > 1.0001 ? gSIOCfg.speed : 1.0);
                // 下限不得反向拉长：目标时长永不超过 orig
                if (nd < kSIOSpinnerFloorSec) nd = (kSIOSpinnerFloorSec < orig) ? kSIOSpinnerFloorSec : orig;
                if (nd != cur) o_caAnim_setDuration(anim, @selector(setDuration:), nd);
            }
            o_layer_addAnim(self, _cmd, anim, key);
            return;
        }
    }

    // 通用兜底：App 从未调 setDuration:、动画保持类默认时长的情况。
    // 已打标的跳过 —— v1.8.15 修的就是「同一个值被缩两次」。
    if (isAnim && !blocked && o_caAnim_setDuration && !SIOAnimScaled(anim)) {
        @try {
            double origDur = ((CAAnimation *)anim).duration;
            if (origDur > 0) {
                SIODurBox *box = SIODurBoxFor(anim, YES);
                if (box) box->scaled = YES;
                double newDur = SIO_targetDurationLayer(origDur);
                if (newDur != origDur) o_caAnim_setDuration(anim, @selector(setDuration:), newDur);
            }
        } @catch (__unused NSException *e) { }
    }
    o_layer_addAnim(self, _cmd, anim, key);
}

#pragma mark - 转圈入口（UIActivityIndicatorView / UIRefreshControl）

// startAnimating 时要确保事务时长已经是缩放后的值：
// 转圈内部是 CABasicAnimation，不经过 App 侧任何 setDuration:。
static void sio_indicator_start(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_indicator_start);
    if (SIO_blocked()) { o_indicator_start(self, _cmd); return; }
    SIOWrapDuration(^{ o_indicator_start(self, _cmd); }, SIO_targetDuration(0.3));
}

static void sio_refresh_begin(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_refresh_begin);
    if (SIO_blocked()) { o_refresh_begin(self, _cmd); return; }
    SIOWrapDuration(^{ o_refresh_begin(self, _cmd); }, SIO_targetDuration(0.3));
}
static void sio_refresh_end(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_refresh_end);
    if (SIO_blocked()) { o_refresh_end(self, _cmd); return; }
    SIOWrapDuration(^{ o_refresh_end(self, _cmd); }, SIO_targetDuration(0.3));
}
// v2.0.5：下拉刷新转圈attach到窗口时也补一次，因为转圈在此后才创建。
static void sio_refresh_didMove(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_refresh_didMove);
    if (SIO_blocked()) { o_refresh_didMove(self, _cmd); return; }
    SIOWrapDuration(^{ o_refresh_didMove(self, _cmd); }, SIO_targetDuration(0.3));
}

#pragma mark - 安装表

// v3.0：本模块自己声明「我要装什么」，由 SIOInstaller 统一按 stage 编排。
// 好处：删除/新增一个 hook 只改这里，不必再同步「安装函数的三份调用点」。
extern const SIOHookEntry *SIOCoreAnimEntries(NSUInteger *count);
static const SIOHookEntry kSIOCoreAnimEntries[] = {
    { "CAAnimation",          "setDuration:",       NO, (IMP)sio_caAnim_setDuration, (IMP *)&o_caAnim_setDuration, kSIOStageBoot, NULL, 0, 0, 0, NO },
    { "CAAnimation",          "setSpeed:",          NO, (IMP)sio_caAnim_setSpeed,    (IMP *)&o_caAnim_setSpeed,    kSIOStageBoot, NULL, 0, 0, 0, NO },
    { "CATransaction",        "setAnimationDuration:", YES, (IMP)sio_catx_setDur,   (IMP *)&o_catx_setDur,        kSIOStageBoot, NULL, 0, 0, 0, NO },
    { "CATransaction",        "animationDuration",  YES, (IMP)sio_catx_getDur,       (IMP *)&o_catx_getDur,        kSIOStageBoot, NULL, 0, 0, 0, NO },
    { "CALayer",              "setSpeed:",          NO, (IMP)sio_layer_setSpeed,     (IMP *)&o_layer_setSpeed,     kSIOStageBoot, NULL, 0, 0, 0, NO },
    { "CALayer",              "actionForKey:",      NO, (IMP)sio_layer_actionForKey, (IMP *)&o_layer_actionForKey, kSIOStageBoot, NULL, 0, 0, 0, NO },
    { "CASpringAnimation",    "setMass:",           NO, (IMP)sio_spring_mass,        (IMP *)&o_spring_mass,        kSIOStageBoot, NULL, 0, 0, 0, YES },
    { "CASpringAnimation",    "setStiffness:",      NO, (IMP)sio_spring_stiff,       (IMP *)&o_spring_stiff,       kSIOStageBoot, NULL, 0, 0, 0, YES },
    { "CASpringAnimation",    "setDamping:",        NO, (IMP)sio_spring_damp,        (IMP *)&o_spring_damp,        kSIOStageBoot, NULL, 0, 0, 0, YES },
    { "CASpringAnimation",    "setVelocity:",       NO, (IMP)sio_spring_velocity,    (IMP *)&o_spring_velocity,    kSIOStageBoot, NULL, 0, 0, kSIOCapSpringVelocity, YES },
    // 转圈族：非首屏必需，排到启动后（构造期少 3 次交换）
    { "UIActivityIndicatorView", "startAnimating",  NO, (IMP)sio_indicator_start,    (IMP *)&o_indicator_start,    kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIRefreshControl",     "beginRefreshing",    NO, (IMP)sio_refresh_begin,      (IMP *)&o_refresh_begin,      kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIRefreshControl",     "endRefreshing",      NO, (IMP)sio_refresh_end,        (IMP *)&o_refresh_end,        kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIRefreshControl",     "didMoveToWindow",    NO, (IMP)sio_refresh_didMove,    (IMP *)&o_refresh_didMove,    kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    // addAnimation: 是「兜底 + 转圈判定」的宿主，且 srceng 首屏就要用 ⇒ 留在构造期
    { "CALayer",              "addAnimation:forKey:", NO, (IMP)sio_layer_addAnim,    (IMP *)&o_layer_addAnim,      kSIOStageBoot, NULL, 0, 0, 0, NO },
};
const SIOHookEntry *SIOCoreAnimEntries(NSUInteger *count) {
    if (count) *count = sizeof(kSIOCoreAnimEntries) / sizeof(kSIOCoreAnimEntries[0]);
    return kSIOCoreAnimEntries;
}
