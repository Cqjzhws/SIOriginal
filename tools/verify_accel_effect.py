# -*- coding: utf-8 -*-
"""
疯狂加速效果验证 —— 用真实的换算引擎公式计算「开启前后动画时长对比」

复刻 SIOInternal.h 里的 inline 引擎：
    SIO_targetDuration(orig) = max(floor, orig / speed) 且永不 > orig
再叠加 LayerBoost / TransitionBoost（显式动画与转场的额外倍率）。
"""

def frame_period(fps):
    return 1.0 / fps


def align(t, fps):
    """向下对齐到帧周期整数倍（不足一帧保持原值）"""
    if t <= 0:
        return t
    fp = frame_period(fps)
    n = int(t / fp)
    if n < 1:
        return t
    return n * fp


def target(orig, speed, floor):
    d = orig / speed
    if d < floor:
        d = floor
    if d > orig:          # 红线：永不比原时长更长
        d = orig
    return d


def accel(orig, speed, floor, boost, fps):
    d = target(orig, speed, floor)
    if boost > 1.0:
        d = d / boost
        if d < floor:
            d = floor
        if d > orig:
            d = orig
    return align(d, fps)


# 典型真实动画时长
CASES = [
    ("导航 push/pop 转场", 0.35),
    ("模态 present/dismiss", 0.35),
    ("UIView 默认动画", 0.25),
    ("键盘弹出", 0.25),
    ("Tab 切换", 0.30),
    ("Alert 弹出", 0.30),
    ("Spring 动画", 0.50),
]

CONFIGS = [
    ("安装默认（均衡 ×8）", 8.0, 0.01, 2.0),
    ("极速 ×20", 20.0, 0.005, 5.0),
    ("疯狂 ×50", 50.0, 0.005, 10.0),
]

FPS = 60

print("=" * 78)
print("疯狂加速效果验证（60Hz 屏，含帧对齐）")
print("=" * 78)

for name, sp, fl, bo in CONFIGS:
    print("\n【%s】  倍率 ×%g / 下限 %.3fs / 增强 ×%g" % (name, sp, fl, bo))
    print("  %-22s %10s %12s %10s" % ("动画场景", "原生", "加速后", "提升"))
    print("  " + "-" * 60)
    for label, orig in CASES:
        after = accel(orig, sp, fl, bo, FPS)
        gain = orig / after if after > 0 else 0
        print("  %-22s %8.0fms %10.0fms %8.1f×" % (label, orig * 1000, after * 1000, gain))

print("\n" + "=" * 78)
print("红线校验：加速后时长必须 ≤ 原时长（只快不慢）")
print("=" * 78)
bad = 0
for name, sp, fl, bo in CONFIGS:
    for label, orig in CASES:
        a = accel(orig, sp, fl, bo, FPS)
        if a > orig + 1e-12:
            print("  [FAIL] %s / %s : %.6f > %.6f" % (name, label, a, orig))
            bad += 1
print("  违规项: %d  %s" % (bad, "OK" if bad == 0 else "!! 需修"))

print("\n" + "=" * 78)
print("对比：改动前 vs 改动后（同一场景）")
print("=" * 78)
OLD = (5.0, 0.02, 1.0)   # 旧默认：×5 / 0.02s / 增强 ×1
NEW = (8.0, 0.01, 2.0)   # 新默认：×8 / 0.01s / 增强 ×2
print("  %-22s %10s %12s %12s" % ("动画场景", "原生", "改动前", "改动后"))
print("  " + "-" * 60)
for label, orig in CASES:
    o = accel(orig, *OLD, FPS)
    n = accel(orig, *NEW, FPS)
    print("  %-22s %8.0fms %10.0fms %10.0fms" % (label, orig * 1000, o * 1000, n * 1000))
