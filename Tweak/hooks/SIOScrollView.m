// ============================================================================
//  hooks/SIOScrollView — 滚动 / 缩放 / 交互手感 / 长按
// ============================================================================
//  这一模块有两条彼此看似矛盾的历史教训，必须同时遵守：
//
//  教训 A（v1.8.3 / v1.8.15）：**绝不能改写 animated: 的语义**。
//    微信图片预览卡死的根因就是把 `animated:NO` 强行改成了 YES。
//    所以这里永远保留 App 传进来的 animated 值，只压缩事务时长。
//
//  教训 B（v2.0.1）：**setter 强黏**。
//    FastScroll / FastTap 早期实现只在 didMoveToWindow 里设一次值，
//    App 任何时候写回都会覆盖掉我们设的值 ⇒ 开关形同虚设。
//    因此追加 setDecelerationRate: / setDelaysContentTouches: 的 hook：
//    App 写回什么都被拦成我们要的值。
//
//  两者并不冲突：A 说的是「不改 App 的意图」，B 说的是「用户显式开启的优化要粘住」。
// ============================================================================

#import "SIOInternal.h"

#pragma mark - 微信图片预览放大态探测

// 微信的预览器在**放大态**下会把 setContentOffset: 当作「拖动可视区」来用，
// 此时任何干预都会让手势状态机错位 ⇒ 预览页卡死。
// 判据：存在 zoomScale > 1 且正在被交互（拖动/缩放/惯性）的 UIScrollView。
//
// 探测要读视图树、有成本，因此做两级节流：
//   · 0.25s 内不重复探测；连续 4 次未命中后把间隔放宽到 2.0s。
// v2.x 已验证这套节律可行，v3.0 只把原先散落的静态变量整理到一处。
static NSTimeInterval gSIOZoomProbeAt = 0;
static BOOL           gSIOZoomCached  = NO;
static __weak UIScrollView *gSIOZoomSV = nil;
static int            gSIOZoomMiss    = 0;
static const NSTimeInterval kSIOZoomMin = 0.25;
static const NSTimeInterval kSIOZoomMax = 2.0;

// v3.0：只在 UIScrollView 自身的 hook 里调用，**不进通用门控**。
// SIO_blocked 每秒被调用数千次，那里哪怕多一次 CACurrentMediaTime 都是乘数效应。
BOOL SIOWeChatZoomPreviewActive(id self) {
    NSString *bid = SIOBundleID();
    if (![bid isEqualToString:@"com.tencent.xin"]) return NO;

    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval gap = gSIOZoomMiss >= 4 ? kSIOZoomMax : kSIOZoomMin;
    if ((now - gSIOZoomProbeAt) < gap) return gSIOZoomCached;
    gSIOZoomProbeAt = now;

    BOOL engaged = NO;
    @try {
        UIScrollView *sv = gSIOZoomSV;
        if (!sv && [self isKindOfClass:[UIScrollView class]]) sv = (UIScrollView *)self;
        if (sv) {
            gSIOZoomSV = sv;
            engaged = (sv.zoomScale > 1.001) && (sv.isDragging || sv.isZooming || sv.isDecelerating);
        }
    } @catch (__unused NSException *e) { engaged = NO; }

    if (engaged) { gSIOZoomMiss = 0; } else if (gSIOZoomMiss < 8) { gSIOZoomMiss++; }
    gSIOZoomCached = engaged;
    return engaged;
}

#pragma mark - 原 IMP 槽位

static void (*o_sv_setContentOffset)(id, SEL, CGPoint, BOOL);
static void (*o_sv_scrollRect)(id, SEL, CGRect, BOOL);
static void (*o_sv_setZoomScale)(id, SEL, CGFloat, BOOL);
static void (*o_sv_zoomToRect)(id, SEL, CGRect, BOOL);
static void (*o_sv_didMoveToWindow)(id, SEL);
static void (*o_sv_setDecelRate)(id, SEL, CGFloat);
static void (*o_sv_setDelaysTouches)(id, SEL, BOOL);
static id   (*o_lpr_init)(id, SEL, id, SEL);
static id   (*o_lpr_initCoder)(id, SEL, id);
static void (*o_lpr_setMinDur)(id, SEL, double);

#pragma mark - 滚动 / 缩放

static void sio_sv_setContentOffset(id self, SEL _cmd, CGPoint p, BOOL animated) {
    SIO_REQUIRE_ORIG(o_sv_setContentOffset);
    if (SIO_blocked() || !animated || SIOWeChatZoomPreviewActive(self)) {
        o_sv_setContentOffset(self, _cmd, p, animated); return;
    }
    SIOWrapDefault(^{ o_sv_setContentOffset(self, _cmd, p, animated); });
}
static void sio_sv_scrollRect(id self, SEL _cmd, CGRect r, BOOL animated) {
    SIO_REQUIRE_ORIG(o_sv_scrollRect);
    if (SIO_blocked() || !animated || SIOWeChatZoomPreviewActive(self)) {
        o_sv_scrollRect(self, _cmd, r, animated); return;
    }
    SIOWrapDefault(^{ o_sv_scrollRect(self, _cmd, r, animated); });
}
static void sio_sv_setZoomScale(id self, SEL _cmd, CGFloat s, BOOL animated) {
    SIO_REQUIRE_ORIG(o_sv_setZoomScale);
    if (!SIO_zoomOK() || !animated || SIOWeChatZoomPreviewActive(self)) {
        o_sv_setZoomScale(self, _cmd, s, animated); return;
    }
    SIOWrapDefault(^{ o_sv_setZoomScale(self, _cmd, s, animated); });
}
static void sio_sv_zoomToRect(id self, SEL _cmd, CGRect r, BOOL animated) {
    SIO_REQUIRE_ORIG(o_sv_zoomToRect);
    if (!SIO_zoomOK() || !animated || SIOWeChatZoomPreviewActive(self)) {
        o_sv_zoomToRect(self, _cmd, r, animated); return;
    }
    SIOWrapDefault(^{ o_sv_zoomToRect(self, _cmd, r, animated); });
}

#pragma mark - 交互手感（setter 强黏）

static void sio_sv_didMoveToWindow(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_sv_didMoveToWindow);
    o_sv_didMoveToWindow(self, _cmd);
    // 第一次贴窗口时设一次；之后 App 写回由下面两个 setter hook 拦住。
    @try {
        if (gSIOCfg.fastScroll && [self respondsToSelector:@selector(setDecelerationRate:)]) {
            [self setDecelerationRate:UIScrollViewDecelerationRateFast];
        }
        if (gSIOCfg.fastTap && [self respondsToSelector:@selector(setDelaysContentTouches:)]) {
            [self setDelaysContentTouches:NO];
        }
    } @catch (__unused NSException *e) { }
}

// v2.0.1「setter 强黏」：App 在任何时刻写回都会被拉回我们要的值。
// 但不能无条件拦 —— 用户关掉开关时必须完全放行，
// 否则「开关关不掉」本身就是又一个假设置。
static void sio_sv_setDecelRate(id self, SEL _cmd, CGFloat rate) {
    SIO_REQUIRE_ORIG(o_sv_setDecelRate);
    if (gSIOCfg.fastScroll && !SIO_blocked()) {
        CGFloat fast = UIScrollViewDecelerationRateFast;
        if (rate != fast) { o_sv_setDecelRate(self, _cmd, fast); return; }
    }
    o_sv_setDecelRate(self, _cmd, rate);
}
static void sio_sv_setDelaysTouches(id self, SEL _cmd, BOOL delays) {
    SIO_REQUIRE_ORIG(o_sv_setDelaysTouches);
    if (gSIOCfg.fastTap && !SIO_blocked() && delays) { o_sv_setDelaysTouches(self, _cmd, NO); return; }
    o_sv_setDelaysTouches(self, _cmd, delays);
}

#pragma mark - 长按手势加速

// 只替换系统默认的 0.5s；App 自定义时长一律透传。
static inline BOOL SIOIsDefaultLongPressDur(double d) { return d >= 0.45 && d <= 0.55; }

static void sio_lpr_setMinDur(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_lpr_setMinDur);
    if (!gSIOCfg.longPress || SIO_blocked() || !SIOIsDefaultLongPressDur(d)) {
        o_lpr_setMinDur(self, _cmd, d); return;
    }
    o_lpr_setMinDur(self, _cmd, gSIOCfg.longPressDuration);
}
static id sio_lpr_init(id self, SEL _cmd, id target, SEL action) {
    SIO_REQUIRE_ORIG_NIL(o_lpr_init);
    id r = o_lpr_init(self, _cmd, target, action);
    @try {
        if (gSIOCfg.longPress && !SIO_blocked() && [r respondsToSelector:@selector(minimumPressDuration)]) {
            id v = [r valueForKey:@"minimumPressDuration"];
            if ([v respondsToSelector:@selector(doubleValue)] &&
                SIOIsDefaultLongPressDur([(NSNumber *)v doubleValue])) {
                [r setValue:@(gSIOCfg.longPressDuration) forKey:@"minimumPressDuration"];
            }
        }
    } @catch (__unused NSException *e) { }
    return r;
}
static id sio_lpr_initCoder(id self, SEL _cmd, id coder) {
    SIO_REQUIRE_ORIG_NIL(o_lpr_initCoder);
    id r = o_lpr_initCoder(self, _cmd, coder);
    @try {
        if (gSIOCfg.longPress && !SIO_blocked() && [r respondsToSelector:@selector(minimumPressDuration)]) {
            id v = [r valueForKey:@"minimumPressDuration"];
            if ([v respondsToSelector:@selector(doubleValue)] &&
                SIOIsDefaultLongPressDur([(NSNumber *)v doubleValue])) {
                [r setValue:@(gSIOCfg.longPressDuration) forKey:@"minimumPressDuration"];
            }
        }
    } @catch (__unused NSException *e) { }
    return r;
}

#pragma mark - 安装表

extern const SIOHookEntry *SIOScrollViewEntries(NSUInteger *count);
static const SIOHookEntry kSIOScrollViewEntries[] = {
    { "UIScrollView", "setContentOffset:animated:", NO, (IMP)sio_sv_setContentOffset, (IMP *)&o_sv_setContentOffset, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIScrollView", "scrollRectToVisible:animated:", NO, (IMP)sio_sv_scrollRect, (IMP *)&o_sv_scrollRect, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIScrollView", "didMoveToWindow", NO, (IMP)sio_sv_didMoveToWindow, (IMP *)&o_sv_didMoveToWindow, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    // 缩放族：**按需**（ZoomAccel 默认关）。这两个 hook 历史上出过微信预览卡死，
    // 默认不安装，用户显式打开才装。
    { "UIScrollView", "setZoomScale:animated:", NO, (IMP)sio_sv_setZoomScale, (IMP *)&o_sv_setZoomScale, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UIScrollView", "zoomToRect:animated:", NO, (IMP)sio_sv_zoomToRect, (IMP *)&o_sv_zoomToRect, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UILongPressGestureRecognizer", "initWithTarget:action:", NO, (IMP)sio_lpr_init, (IMP *)&o_lpr_init, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UILongPressGestureRecognizer", "initWithCoder:", NO, (IMP)sio_lpr_initCoder, (IMP *)&o_lpr_initCoder, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UILongPressGestureRecognizer", "setMinimumPressDuration:", NO, (IMP)sio_lpr_setMinDur, (IMP *)&o_lpr_setMinDur, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    // setter 强黏：只有开关打开时才需要装（否则是纯开销）
    { "UIScrollView", "setDecelerationRate:", NO, (IMP)sio_sv_setDecelRate, (IMP *)&o_sv_setDecelRate, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UIScrollView", "setDelaysContentTouches:", NO, (IMP)sio_sv_setDelaysTouches, (IMP *)&o_sv_setDelaysTouches, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
};
const SIOHookEntry *SIOScrollViewEntries(NSUInteger *count) {
    if (count) *count = sizeof(kSIOScrollViewEntries) / sizeof(kSIOScrollViewEntries[0]);
    return kSIOScrollViewEntries;
}
