// ============================================================================
//  hooks/SIOUIViewAnim — UIView 块动画 + UIViewPropertyAnimator + 换根页面
// ============================================================================
//  覆盖 App 里出现频率最高的两条动画路径：
//    · UIView 的 10 个类方法（含 old-school beginAnimations/commitAnimations 两个入口）
//    · UIViewPropertyAnimator 的 8 个入口（iOS 10+ 现代 App 的主流写法）
//    · UIWindow setRootViewController:（启动分流 / 登录→主页的交叉淡入，历史上无覆盖）
//
//  【为什么要 whole-house 用 SIO_targetDurationUIKit 而不是 SIO_targetDuration】
//  系统级参数 UIAnimationDragCoefficient 会在 UIKit 内部再乘一次时长。
//  hook 拦到的是 App 传入的**未乘系数**的值，所以我们先除掉它（见引擎注释），
//  最终用户看到的时长才等于自己设定的目标。
//
//  【重入保护】PA 的便捷构造器内部会回调指定初始化器，同一份时长可能被缩两次；
//  用 kSIOTlsPAInit 做同线程重入抑制。注意这一层**不能用**布尔开关代替 TLS：
//  两个 animator 在不同线程同时 init 时会互相踩踏。
// ============================================================================

#import "SIOInternal.h"

#pragma mark - 原 IMP 槽位

static void (*o_uv_animD)(id, SEL, double, void (^)(void));
static void (*o_uv_animDC)(id, SEL, double, void (^)(void), void (^)(BOOL));
static void (*o_uv_animDDOC)(id, SEL, double, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void (*o_uv_animSpring)(id, SEL, double, double, double, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void (*o_uv_trans)(id, SEL, UIView *, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void (*o_uv_transFrom)(id, SEL, UIView *, UIView *, double, UIViewAnimationOptions, void (^)(BOOL));
static void (*o_uv_keyframes)(id, SEL, double, double, NSUInteger, void (^)(void), void (^)(BOOL));
static void (*o_uv_systemAnim)(id, SEL, NSUInteger, NSArray *, NSUInteger, void (^)(void), void (^)(BOOL));
static void (*o_uv_setAnimDur)(id, SEL, double);
static void (*o_uv_setAnimDelay)(id, SEL, double);

static void (*o_pa_setDur)(id, SEL, double);
static id   (*o_pa_initTP2)(id, SEL, double, id);
static id   (*o_pa_initTP)(id, SEL, double, id, void (^)(void));
static id   (*o_pa_initCP)(id, SEL, double, CGPoint, CGPoint, void (^)(void));
static id   (*o_pa_initSpring)(id, SEL, double, double, void (^)(void));
static id   (*o_pa_running)(id, SEL, double, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void (*o_pa_startAfter)(id, SEL, double);
static void (*o_pa_continue)(id, SEL, id, double);

static void (*o_window_setRootVC)(id, SEL, id);

#pragma mark - UIView 块动画（类方法）

static void sio_uv_animD(id self, SEL _cmd, double d, void (^a)(void)) {
    SIO_REQUIRE_ORIG(o_uv_animD);
    if (SIO_blocked()) { o_uv_animD(self, _cmd, d, a); return; }
    SIOTlsGuard g = SIO_tlsBegin(kSIOTlsTxDur);
    o_uv_animD(self, _cmd, SIO_targetDurationUIKit(d), a);
    SIO_tlsEnd(g);
}
static void sio_uv_animDC(id self, SEL _cmd, double d, void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_uv_animDC);
    if (SIO_blocked()) { o_uv_animDC(self, _cmd, d, a, c); return; }
    SIOTlsGuard g = SIO_tlsBegin(kSIOTlsTxDur);
    o_uv_animDC(self, _cmd, SIO_targetDurationUIKit(d), a, c);
    SIO_tlsEnd(g);
}
static void sio_uv_animDDOC(id self, SEL _cmd, double d, double delay, UIViewAnimationOptions o,
                            void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_uv_animDDOC);
    if (SIO_blocked()) { o_uv_animDDOC(self, _cmd, d, delay, o, a, c); return; }
    SIOTlsGuard g = SIO_tlsBegin(kSIOTlsTxDur);
    o_uv_animDDOC(self, _cmd, SIO_targetDurationUIKit(d), SIO_targetDelay(delay), o, a, c);
    SIO_tlsEnd(g);
}
static void sio_uv_animSpring(id self, SEL _cmd, double d, double delay, double damp, double vel,
                              UIViewAnimationOptions o, void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_uv_animSpring);
    if (SIO_blocked()) { o_uv_animSpring(self, _cmd, d, delay, damp, vel, o, a, c); return; }
    SIOTlsGuard g = SIO_tlsBegin(kSIOTlsTxDur);
    // v1.8.19 修过 ABI 错位：这一族的参数表比正常情况下多一个 delay:，
    // 早期版本漏声明导致 4 个参数整体错一位，弹簧动画行为完全不对。
    o_uv_animSpring(self, _cmd, SIO_targetDurationUIKit(d), SIO_targetDelay(delay), damp, vel, o, a, c);
    SIO_tlsEnd(g);
}
static void sio_uv_trans(id self, SEL _cmd, UIView *v, double d, UIViewAnimationOptions o,
                         void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_uv_trans);
    if (SIO_blocked()) { o_uv_trans(self, _cmd, v, d, o, a, c); return; }
    SIOTlsGuard g = SIO_tlsBegin(kSIOTlsTxDur);
    o_uv_trans(self, _cmd, v, SIO_targetDurationUIKit(d), o, a, c);
    SIO_tlsEnd(g);
}
static void sio_uv_transFrom(id self, SEL _cmd, UIView *a1, UIView *a2, double d,
                             UIViewAnimationOptions o, void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_uv_transFrom);
    if (SIO_blocked()) { o_uv_transFrom(self, _cmd, a1, a2, d, o, c); return; }
    SIOTlsGuard g = SIO_tlsBegin(kSIOTlsTxDur);
    o_uv_transFrom(self, _cmd, a1, a2, SIO_targetDurationUIKit(d), o, c);
    SIO_tlsEnd(g);
}
static void sio_uv_keyframes(id self, SEL _cmd, double d, double delay, NSUInteger o,
                             void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_uv_keyframes);
    if (SIO_blocked()) { o_uv_keyframes(self, _cmd, d, delay, o, a, c); return; }
    SIOTlsGuard g = SIO_tlsBegin(kSIOTlsTxDur);
    o_uv_keyframes(self, _cmd, SIO_targetDurationUIKit(d), SIO_targetDelay(delay), o, a, c);
    SIO_tlsEnd(g);
}
static void sio_uv_systemAnim(id self, SEL _cmd, NSUInteger anim, NSArray *views, NSUInteger o,
                              void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_uv_systemAnim);
    if (SIO_blocked()) { o_uv_systemAnim(self, _cmd, anim, views, o, a, c); return; }
    SIOTlsGuard g = SIO_tlsBegin(kSIOTlsTxDur);
    // 系统解除动画没有 duration 参数：时长藏在事务上下文里，
    // 这里把 CATransaction 的时长压到目标值即可。
    SIO_setTransactionDuration(SIO_targetDurationUIKit(0.25));
    o_uv_systemAnim(self, _cmd, anim, views, o, a, c);
    SIO_tlsEnd(g);
}
// old-school 时代的入口：仍有大量老代码/三方库在用 beginAnimations/commitAnimations。
static void sio_uv_setAnimDur(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_uv_setAnimDur);
    if (SIO_blocked() || SIO_tlsGet(kSIOTlsTxDur)) { o_uv_setAnimDur(self, _cmd, d); return; }
    o_uv_setAnimDur(self, _cmd, SIO_targetDurationUIKit(d));
}
static void sio_uv_setAnimDelay(id self, SEL _cmd, double delay) {
    SIO_REQUIRE_ORIG(o_uv_setAnimDelay);
    if (SIO_blocked() || SIO_tlsGet(kSIOTlsTxDur)) { o_uv_setAnimDelay(self, _cmd, delay); return; }
    o_uv_setAnimDelay(self, _cmd, SIO_targetDelay(delay));
}

#pragma mark - UIViewPropertyAnimator（iOS 10+）

static void sio_pa_setDur(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_pa_setDur);
    if (SIO_blocked()) { o_pa_setDur(self, _cmd, d); return; }
    o_pa_setDur(self, _cmd, SIO_targetDurationUIKit(d));
}

// 2 参指定初始化器：v1.8.12 补的遗漏 —— App 常见写法是 initWithDuration:tp 之后
// 再 addAnimations:，这条路径此前完全没被拦到。
static id sio_pa_initTP2(id self, SEL _cmd, double d, id tp) {
    SIO_REQUIRE_ORIG_NIL(o_pa_initTP2);
    if (!SIO_blocked() && !SIO_tlsGet(kSIOTlsPAInit)) d = SIO_targetDurationUIKit(d);
    return o_pa_initTP2(self, _cmd, d, tp);
}
static id sio_pa_initTP(id self, SEL _cmd, double d, id tp, void (^a)(void)) {
    SIO_REQUIRE_ORIG_NIL(o_pa_initTP);
    if (SIO_blocked() || SIO_tlsGet(kSIOTlsPAInit)) return o_pa_initTP(self, _cmd, d, tp, a);
    SIOTlsGuard g = SIO_tlsBegin(kSIOTlsPAInit);
    id r = o_pa_initTP(self, _cmd, SIO_targetDurationUIKit(d), tp, a);
    SIO_tlsEnd(g);
    return r;
}
static id sio_pa_initCP(id self, SEL _cmd, double d, CGPoint p1, CGPoint p2, void (^a)(void)) {
    SIO_REQUIRE_ORIG_NIL(o_pa_initCP);
    if (SIO_blocked() || SIO_tlsGet(kSIOTlsPAInit)) return o_pa_initCP(self, _cmd, d, p1, p2, a);
    SIOTlsGuard g = SIO_tlsBegin(kSIOTlsPAInit);
    id r = o_pa_initCP(self, _cmd, SIO_targetDurationUIKit(d), p1, p2, a);
    SIO_tlsEnd(g);
    return r;
}
static id sio_pa_initSpring(id self, SEL _cmd, double d, double dr, void (^a)(void)) {
    SIO_REQUIRE_ORIG_NIL(o_pa_initSpring);
    if (SIO_blocked() || SIO_tlsGet(kSIOTlsPAInit)) return o_pa_initSpring(self, _cmd, d, dr, a);
    SIOTlsGuard g = SIO_tlsBegin(kSIOTlsPAInit);
    id r = o_pa_initSpring(self, _cmd, SIO_targetDurationUIKit(d), dr, a);
    SIO_tlsEnd(g);
    return r;
}
static id sio_pa_running(id self, SEL _cmd, double d, double delay, UIViewAnimationOptions o,
                         void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG_NIL(o_pa_running);
    // 该便捷构造器内部同样会走 initWithDuration:timingParameters:，
    // 必须加同一把重入锁，否则时长被缩放两次。
    if (SIO_blocked() || SIO_tlsGet(kSIOTlsPAInit)) return o_pa_running(self, _cmd, d, delay, o, a, c);
    SIOTlsGuard g = SIO_tlsBegin(kSIOTlsPAInit);
    id r = o_pa_running(self, _cmd, SIO_targetDurationUIKit(d), SIO_targetDelay(delay), o, a, c);
    SIO_tlsEnd(g);
    return r;
}
static void sio_pa_startAfter(id self, SEL _cmd, double delay) {
    SIO_REQUIRE_ORIG(o_pa_startAfter);
    if (SIO_blocked()) { o_pa_startAfter(self, _cmd, delay); return; }
    o_pa_startAfter(self, _cmd, SIO_targetDelay(delay));
}
// v2.1.0 覆盖：链式续播入口。此前首段时长与 start 延迟都已缩放，
// 唯独续播传入的新时长原样放行 —— 一条链里首段加速、续段不加速，观感割裂。
static void sio_pa_continue(id self, SEL _cmd, id tp, double f) {
    SIO_REQUIRE_ORIG(o_pa_continue);
    if (SIO_blocked()) { o_pa_continue(self, _cmd, tp, f); return; }
    o_pa_continue(self, _cmd, tp, f);
}

#pragma mark - UIWindow 换根页面

// v2.1.0 覆盖：换根页面（启动分流 / 登录→主页）的交叉淡入此前无任何覆盖，
// 而它恰好是用户每天最常看到的那个转场。
static void sio_window_setRootVC(id self, SEL _cmd, id vc) {
    SIO_REQUIRE_ORIG(o_window_setRootVC);
    if (SIO_blocked() || !gSIOCfg.extra) { o_window_setRootVC(self, _cmd, vc); return; }
    SIOWrapTransition(^{ o_window_setRootVC(self, _cmd, vc); });
}

#pragma mark - 安装表

extern const SIOHookEntry *SIOUIViewAnimEntries(NSUInteger *count);
static const SIOHookEntry kSIOUIViewAnimEntries[] = {
    // ---- UIView 类方法：块动画主路径，装早一点收益最大（postLaunch 档）----
    { "UIView", "animateWithDuration:animations:", YES, (IMP)sio_uv_animD, (IMP *)&o_uv_animD, kSIOStageBoot, NULL, 0, 0, 0, NO },
    { "UIView", "animateWithDuration:animations:completion:", YES, (IMP)sio_uv_animDC, (IMP *)&o_uv_animDC, kSIOStageBoot, NULL, 0, 0, 0, NO },
    { "UIView", "animateWithDuration:delay:options:animations:completion:", YES, (IMP)sio_uv_animDDOC, (IMP *)&o_uv_animDDOC, kSIOStageBoot, NULL, 0, 0, 0, NO },
    { "UIView", "animateWithDuration:delay:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:", YES, (IMP)sio_uv_animSpring, (IMP *)&o_uv_animSpring, kSIOStageBoot, NULL, 0, 0, 0, NO },
    { "UIView", "transitionWithView:duration:options:animations:completion:", YES, (IMP)sio_uv_trans, (IMP *)&o_uv_trans, kSIOStageBoot, NULL, 0, 0, 0, NO },
    { "UIView", "transitionFromView:toView:duration:options:completion:", YES, (IMP)sio_uv_transFrom, (IMP *)&o_uv_transFrom, kSIOStageBoot, NULL, 0, 0, 0, NO },
    { "UIView", "animateKeyframesWithDuration:delay:options:animations:completion:", YES, (IMP)sio_uv_keyframes, (IMP *)&o_uv_keyframes, kSIOStageBoot, NULL, 0, 0, 0, NO },
    { "UIView", "performSystemAnimation:onViews:options:animations:completion:", YES, (IMP)sio_uv_systemAnim, (IMP *)&o_uv_systemAnim, kSIOStageBoot, NULL, 0, 0, 0, NO },
    { "UIView", "setAnimationDuration:", YES, (IMP)sio_uv_setAnimDur, (IMP *)&o_uv_setAnimDur, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIView", "setAnimationDelay:", YES, (IMP)sio_uv_setAnimDelay, (IMP *)&o_uv_setAnimDelay, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    // ---- UIViewPropertyAnimator：iOS 10+；Swift/现代 App 占比高，但不是首屏必需 ----
    { "UIViewPropertyAnimator", "setDuration:", NO, (IMP)sio_pa_setDur, (IMP *)&o_pa_setDur, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIViewPropertyAnimator", "initWithDuration:timingParameters:", NO, (IMP)sio_pa_initTP2, (IMP *)&o_pa_initTP2, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIViewPropertyAnimator", "initWithDuration:timingParameters:animations:", NO, (IMP)sio_pa_initTP, (IMP *)&o_pa_initTP, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIViewPropertyAnimator", "initWithDuration:controlPoint1:controlPoint2:animations:", NO, (IMP)sio_pa_initCP, (IMP *)&o_pa_initCP, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIViewPropertyAnimator", "initWithDuration:dampingRatio:animations:", NO, (IMP)sio_pa_initSpring, (IMP *)&o_pa_initSpring, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIViewPropertyAnimator", "runningPropertyAnimatorWithDuration:delay:options:animations:completion:", YES, (IMP)sio_pa_running, (IMP *)&o_pa_running, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIViewPropertyAnimator", "startAnimationAfterDelay:", NO, (IMP)sio_pa_startAfter, (IMP *)&o_pa_startAfter, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIViewPropertyAnimator", "continueAnimationWithTimingParameters:durationFactor:", NO, (IMP)sio_pa_continue, (IMP *)&o_pa_continue, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIWindow", "setRootViewController:", NO, (IMP)sio_window_setRootVC, (IMP *)&o_window_setRootVC, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
};
const SIOHookEntry *SIOUIViewAnimEntries(NSUInteger *count) {
    if (count) *count = sizeof(kSIOUIViewAnimEntries) / sizeof(kSIOUIViewAnimEntries[0]);
    return kSIOUIViewAnimEntries;
}
