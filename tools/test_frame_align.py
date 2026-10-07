#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
帧对齐引擎的算法验证。

为什么单独写测试：
  帧对齐的核心不变量有三条，且都无法靠肉眼在真机上确认：
   ① 对齐后时长必然是帧周期的整数倍；
   ② 对齐只缩短、不延长（绝不能让动画变慢）；
   ③ 时长不足一帧时保持原值（否则对齐会把 0.005s 拉成 0.0167s，慢 3 倍）。
  这三条任一破坏都会直接损害用户体验，而代码里它们只是几行算术。

用法：python3 tools/test_frame_align.py
"""
import math

# 复刻 SIO_alignToFrameBoundary 的算法（与 Tweak/SIOriginal.m 保持一致）
def align(d, frame_period, enabled=True, mode=0, speed_mode=False):
    if not enabled:
        return d
    if d <= 0.0:
        return d
    if mode == 1:          # 慢放：不打断
        return d
    if speed_mode:         # 速率模式：时间轴原生
        return d
    P = frame_period
    if P <= 0.0:
        return d
    n = math.floor(d / P)
    if n < 1.0:            # 不足一帧：保持原值
        return d
    aligned = n * P
    if aligned >= d:       # 浮点边界保险：绝不变慢
        return d
    return aligned


FAILURES = []


def check(cond, msg):
    if not cond:
        FAILURES.append(msg)


def test_invariants(P, name):
    """对一组覆盖各量级的时长验证三条不变量。"""
    cases = [
        0.005, 0.008, 0.01, 0.0166, 0.0167, 0.02, 0.025, 0.03, 0.05,
        0.06, 0.1, 0.125, 0.15, 0.2, 0.25, 0.3, 0.35, 0.5, 0.75, 1.0, 2.5,
    ]
    for d in cases:
        a = align(d, P)

        # ① 结果必须是帧周期的整数倍（允许 1e-9 浮点容差）
        if a < d:   # 只有真的发生了缩短才检查对齐性
            k = a / P
            check(abs(k - round(k)) < 1e-6,
                  f"[{name}] {d}s → {a}s 不是帧周期({P*1000:.2f}ms)的整数倍 (k={k})")

        # ② 只能缩短或保持，绝不能延长
        check(a <= d + 1e-12,
              f"[{name}] {d}s → {a}s 被延长了（违反「加速只能变快」原则）")

        # ③ 不足一帧时必须保持原值
        if d < P:
            check(a == d,
                  f"[{name}] {d}s < 一帧({P*1000:.2f}ms)，却对齐成 {a}s（会被拉慢）")

        #④ 至少一帧：非零时长对齐后不得为 0
        check(a > 0.0, f"[{name}] {d}s 对齐成了 0（动画完全消失）")


def test_scenario():
    """真实场景：0.3s ÷ 5 倍速 = 0.06s，在 60Hz 下应从 3.6 帧对齐到 3 帧。"""
    P60 = 1.0 / 60.0
    d = 0.3 / 5.0
    a = align(d, P60)
    # 0.06 / 0.016667 = 3.6 → 向下取整 3 帧 = 0.05s
    check(abs(a - 0.05) < 1e-6,
          f"60Hz 下 0.3s÷5 应从 {d:.4f}s 对齐到 0.05s，实际得到 {a:.4f}s")
    print(f"  60Hz  0.3s ÷5  →  {d*1000:6.2f}ms ({d/P60:.2f} 帧) → {a*1000:6.2f}ms ({a/P60:.2f} 帧)")

    # 120Hz 下同样场景：0.06 / 0.008333 = 7.2 → 7 帧 = 0.0583s
    P120 = 1.0 / 120.0
    a120 = align(d, P120)
    check(abs(a120 - 7 * P120) < 1e-6,
          f"120Hz 下 0.3s÷5 应对齐到 7 帧({7*P120*1000:.2f}ms)，实际 {a120*1000:.2f}ms")
    print(f"  120Hz 0.3s ÷5  →  {d*1000:6.2f}ms ({d/P120:.2f} 帧) → {a120*1000:6.2f}ms ({a120/P120:.2f} 帧)")

    # 关闭开关时必须是恒等变换
    for d in (0.06, 0.3, 0.05, 1.0):
        check(align(d, P60, enabled=False) == d,
              f"FrameAlign=关闭时 {d}s 被改动了")

    # 慢放模式必须不参与
    for d in (0.06, 0.3):
        check(align(d, P60, mode=1) == d,
              f"慢放模式下 {d}s 被对齐了（与慢放语义冲突）")

    # 速率模式必须不参与
    for d in (0.06, 0.3):
        check(align(d, P60, speed_mode=True) == d,
              f"速率模式下 {d}s 被对齐了（时间轴应保持原生）")

    # 高倍率极端场景不应产生 0
    for speed in (5, 10, 20, 50):
        for orig in (0.25, 0.3, 0.35, 0.5):
            d = orig / speed
            a = align(d, P60)
            check(a > 0.0, f"×{speed} 下 {orig}s → {d}s 对齐成了 0")
            if a < d:
                check(a > 0.0 and abs(a / P60 - round(a / P60)) < 1e-6,
                      f"×{speed} 下 {orig}s 对齐结果 {a}s 非整数帧")


def main():
    print("帧对齐引擎算法验证")
    print("=" * 56)
    P60 = 1.0 / 60.0
    P120 = 1.0 / 120.0

    print("\n[不变量验证] 覆盖 60Hz / 120Hz / 90Hz 三种帧率：")
    for P, name in ((P60, "60Hz"), (P120, "120Hz"), (1.0 / 90.0, "90Hz")):
        test_invariants(P, name)
        print(f"  {name}: 通过" if not FAILURES else f"  {name}: 有失败")

    print("\n[真实场景验证]")
    test_scenario()

    print("\n" + "=" * 56)
    if FAILURES:
        print(f"✗ 失败 {len(FAILURES)} 项：")
        for f in FAILURES:
            print("  ✗ " + f)
        return 1
    print("✓ 全部通过：帧对齐的三条不变量在各种帧率与倍率下均成立")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())