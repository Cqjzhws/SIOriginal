// ============================================================================
//  SIOEngine — 派生量 + 门控（「该不该旁路」的唯一实现）
// ============================================================================
//  v2.x 里「该不该旁路」的判断在 40 多个 hook 里各写一遍，且条件不一致：
//  有的查 gEnabled、有的忘了查黑名单、有的额外查了 editorial、还有的查了一次
//  NSStringFromClass。不一致的结果是「同一个 App 里一部分 hook 生效、一部分不生效」，
//  这类 bug 极难定位。v3.0 收敛为三个函数，hook 只调用它们。
//
//  门控分成三层，语义清晰：
//    SIO_blockedBase : 纯配置级（总开关 / 黑名单 / 倍率恒等）
//    SIO_blocked     : 完整门控（+ 自绘 UI / 桌面编辑态 / 无障碍意图 / 内存压力）
//    SIO_listOK 等   : 高危功能专属门控（+ 该功能开关 + 硬保护）
// ============================================================================

#import "SIOInternal.h"

BOOL   gSIOAnimNoop      = NO;
double gSIOFramePeriod   = 0.0;
double gSIOImplicitDur   = 0.25;
const double kSIOSpinnerFloorSec = 0.4;

#pragma mark - 减弱动态效果（惰性 + TTL 缓存）

// v2.1.0 引入「辅助功能让位」：用户开启系统「减弱动态效果」即表达了「少动效」意图，
// 加速工具不该覆盖它。
//
// 惰性求值的原因不是它慢，而是它可能触发辅助功能框架的初始化：
// v2.5.0 正是因为一行 NSLog 在 pre-main 里调用了它，把三个版本的启动提速成果抵消掉。
// 所以这里既做缓存、又做 TTL（5 秒）—— 用户中途改设置也能被感知，
// 但绝不会成为每次动画的固定开销。
static int      gSIORMValue   = -1;    // -1 = 尚未求值
static CFTimeInterval gSIORMStamp = 0.0;
static const CFTimeInterval kSIORMTTL = 5.0;

BOOL SIO_reduceMotionOn(void) {
    if (!gSIOCfg.respectReduceMotion) return NO;
    CFTimeInterval now = CACurrentMediaTime();
    if (gSIORMValue >= 0 && (now - gSIORMStamp) < kSIORMTTL) return (gSIORMValue == 1);
    BOOL on = NO;
    @try {
        // UIAccessibilityIsReduceMotionEnabled 是公开 API（iOS 8+），
        // 比 v2.x 用的 AccessibilityUtilities 私有符号安全得多（后者在新系统改名就会失效）。
        void *sym = dlsym(RTLD_DEFAULT, "UIAccessibilityIsReduceMotionEnabled");
        if (sym) {
            on = ((BOOL (*)(void))sym)();
        }
    } @catch (__unused NSException *e) { on = NO; }
    gSIORMValue  = on ? 1 : 0;
    gSIORMStamp  = now;
    return on;
}

#pragma mark - 派生量重算

void SIOEngineInvalidateFrame(void) { gSIOFramePeriod = 0.0; }

void SIOEnginePrepare(void) {
    // 恒等快速路径：加速 ×1 时所有换算都是恒等变换，
    // 42 个 CATransaction 包裹点（触控高亮/单元格选中/滚动偏移…）可以完全透传，
    // 恢复系统原生行为 —— 这是 v2.0.7 里收益最明确的优化之一。
    gSIOAnimNoop = (gSIOCfg.mode == 0 && gSIOCfg.speed <= 1.0001);

    // 最热的 hook（CALayer actionForKey:）每次可动画属性赋值都会过一遍，
    // 而它的输入恒为系统默认隐式动画时长 0.25s —— 结果只随配置变化，
    // 不随调用变化。预计算后热路径退化成一次 double 读取。
    gSIOImplicitDur = SIO_targetDuration(0.25);
    double c = SIO_compensatedDivisor();
    if (c != 1.0) gSIOImplicitDur = gSIOImplicitDur / c;

    // 帧周期可在配置变化时失效（例如用户换了外接显示器），这里不做惰性求值，
    // 只置零 —— 下一次真正用到时才重新读 UIScreen。
    SIOEngineInvalidateFrame();
}

#pragma mark - 门控

BOOL SIO_blockedBase(void) {
    if (!gSIOCfg.enabled) return YES;
    if (gSIOSelfBlacklisted) return YES;      // 用户在黑名单里明确排除了这个 App
    return NO;
}

BOOL SIO_blocked(void) {
    if (SIO_blockedBase()) return YES;
    // 自绘 UI（toast / 悬浮球）全程旁路 —— 否则自己的淡入淡出被自己加速到 0.0125s，
    // 「设置已生效」一闪而过，用户看不到。
    if (SIO_tlsGet(kSIOTlsOwnUI)) return YES;
    // SpringBoard 桌面/Switcher 编辑态：用户拖动图标时需要正常的动画速度才能准确定位。
    if (gSIOEditing) return YES;
    if (gSIOCfg.respectReduceMotion && SIO_reduceMotionOn()) return YES;
    // v3.0：内存压力达到「严重」时整体旁路 —— 此时任何额外工作都是在往火上加柴。
    if (gSIOCfg.memoryGuard && SIOMemoryPressureLevel() >= 2) return YES;
    return NO;
}

BOOL SIO_listOK(void)  { return gSIOCfg.listAccel  && !SIO_blocked(); }
BOOL SIO_zoomOK(void)  { return gSIOCfg.zoomAccel  && !SIO_blocked(); }
BOOL SIO_scrollOK(void){ return (gSIOCfg.fastScroll || gSIOCfg.listAccel) && !SIO_blocked(); }

#pragma mark - CATransaction 写时长的唯一入口

// 凡是本项目自己构造 CATransaction 时长的地方，都必须走这里：
// `[CATransaction setAnimationDuration:]` 会再次进入已经被交换过的 setter，
// 于是同一个值被缩放两次（期望 0.07s 实际 0.014s）。
// 这里借 TLS 标记抑制这一层，嵌套时原样恢复。
void SIO_setTransactionDuration(double d) {
    SIOTlsGuard g = SIO_tlsBegin(kSIOTlsTxDur);
    @try { [CATransaction setAnimationDuration:d]; }
    @catch (__unused NSException *e) { }
    SIO_tlsEnd(g);
}

// 读取事务时长（getter 已被引擎接管时的安全读取）：v2.0.7 修过双重缩放 bug，
// 本函数保证「读到的就是刚才写进去的」。
double SIO_getTransactionDuration(void) {
    return [CATransaction animationDuration];
}
