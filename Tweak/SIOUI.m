// ============================================================================
//  SIOUI — 自绘提示（toast）
// ============================================================================
//  这是本项目唯一「自己画 UI」的地方，因此也是唯一会撞到自己 hook 的地方。
//  三条约束，缺一不可：
//   1. 全程置位 kSIOTlsOwnUI —— 否则 toast 的淡入淡出会命中自己的
//      animateWithDuration: hook，×20 预设下 0.25s → 0.0125s，
//      「设置已生效」一闪而过，用户根本看不清（v2.1.0 修过的真 bug）。
//   2. userInteractionEnabled = NO —— 不拦触摸、不抢状态栏。
//      历史教训：v1.8.10 的悬浮球曾被全局禁用，就是因为抢了触摸。
//   3. 只在 App 处于 Active 时显示；1.5s 节流，避免连续保存时堆叠。
// ============================================================================

#import "SIOInternal.h"

static NSTimeInterval gSIOToastLastAt = 0;

BOOL SIOShowToast(NSString *text, BOOL throttle) {
    @try {
        SIOTlsGuard guard = SIO_tlsBegin(kSIOTlsOwnUI);
        BOOL result = NO;
        if (!SIOAppIsActive()) { SIO_tlsEnd(guard); return NO; }

        NSTimeInterval now = CACurrentMediaTime();
        if (throttle && (now - gSIOToastLastAt) < 1.5) { SIO_tlsEnd(guard); return NO; }
        gSIOToastLastAt = now;

        UIWindow *kw = SIOForegroundWindow();
        if (!kw) { SIO_tlsEnd(guard); return NO; }

        UIView *toast = [[UIView alloc] init];
        toast.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
        toast.layer.cornerRadius = 22;
        toast.layer.masksToBounds = YES;
        toast.userInteractionEnabled = NO;
        toast.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *label = [[UILabel alloc] init];
        label.text = text;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.textAlignment = NSTextAlignmentCenter;
        label.userInteractionEnabled = NO;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [toast addSubview:label];
        [kw addSubview:toast];

        // iOS 11+ 全套 NSLayoutAnchor 都可用
        [NSLayoutConstraint activateConstraints:@[
            [label.topAnchor constraintEqualToAnchor:toast.topAnchor constant:10],
            [label.bottomAnchor constraintEqualToAnchor:toast.bottomAnchor constant:-10],
            [label.leadingAnchor constraintEqualToAnchor:toast.leadingAnchor constant:18],
            [label.trailingAnchor constraintEqualToAnchor:toast.trailingAnchor constant:-18],
            [toast.centerXAnchor constraintEqualToAnchor:kw.centerXAnchor],
            [toast.widthAnchor constraintLessThanOrEqualToAnchor:kw.widthAnchor constant:-48],
        ]];
        // 顶部：优先用 safeArea（iOS 11+），拿不到退到 statusBarFrame
        if (@available(iOS 11.0, *)) {
            [NSLayoutConstraint activateConstraints:@[
                [toast.topAnchor constraintEqualToAnchor:kw.safeAreaLayoutGuide.topAnchor constant:8]
            ]];
        } else {
            [NSLayoutConstraint activateConstraints:@[
                [toast.topAnchor constraintEqualToAnchor:kw.topAnchor constant:28]
            ]];
        }

        CGRect f = toast.frame;
        toast.alpha = 0.0;
        toast.transform = CGAffineTransformMakeTranslation(0, -12);
        [UIView animateWithDuration:0.22 animations:^{
            toast.alpha = 1.0;
            toast.transform = CGAffineTransformIdentity;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.28
                                  delay:1.2
                                options:UIViewAnimationOptionCurveEaseIn
                             animations:^{ toast.alpha = 0.0; }
                             completion:^(BOOL fin) {
                [toast removeFromSuperview];
            }];
        }];
        (void)f;
        result = YES;
        SIO_tlsEnd(guard);
        return result;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

void SIOShowSettingsToast(void) {
    SIOShowToast(@"SIOriginal 配置已生效", YES);
}

// v2.0.2～v2.0.6：注入确认 toast 的指数退避重试。
// 固定 0.6s × 5 次全挤在头 3 秒，而失败主因是「App 未起完」（秒级事件）⇒
// 必然全部落空等于没重试。改为 0.5→0.75→1.1→1.7→2.5s 累计约 6.5s。
// v2.5.0 起默认不弹（用户反馈：每次开 App 都弹太吵），保留实现供诊断用。
void SIOShowInjectToast(void) {
    static const double delays[5] = { 0.5, 0.75, 1.1, 1.7, 2.5 };
    __block int attempt = 0;
    dispatch_block_t (^next)(void) = ^dispatch_block_t {
        return (dispatch_block_t)^{
            if (attempt >= 5) return;
            double d = delays[attempt];
            attempt++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (SIOShowToast(@"SIOriginal 已注入", NO)) return;
                dispatch_block_t nx = next();
                if (nx) nx();
            });
        };
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SIOShowToast(@"SIOriginal 已注入", NO); });
}
