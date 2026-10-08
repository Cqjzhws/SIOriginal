#!/usr/bin/env python3
"""
时间膨胀（Time Dilation）算法验证
=================================
来源：OpenSpeedy（https://github.com/game1024/OpenSpeedy）
      src-bridge/speedpatch/speedpatch.cpp 的基线重锚 + 增量缩放算法
用途：为 SIOriginal v2.6.0 拟新增的 TimeMode 做移植前验证

为什么要在没有设备的情况下先做这件事：
   时间膨胀一旦上真机，出错的表现是「整个 App 行为不对」——
   动画乱、超时乱、状态机错乱，而从这些现象反推"是时钟算法错了"极其困难。
   算法本身是纯数学，可以在这里一次性证明它是对的，
   真机阶段就只需要验证"hook 有没有装上"和"副作用是否可接受"。

核心算法（等价于 OpenSpeedy 的 Hook_QueryPerformanceCounter）：

    virtual(t) = baseVirtual + f × (t − baseReal)

    倍率 f 变化时，在下一次调用时重锚：
        baseReal    ← lastReal      （上次读到的真实值）
        baseVirtual ← lastVirtual   （上次返回的虚拟值）
    从而保证虚拟时钟在新倍率下从上次的位置继续走，不跳变。

验证的三条不变量：
    I1  恒等性  —— f == 1.0 时，虚拟时钟 == 真实时钟
    I2  单调性  —— 虚拟时钟永不回退（回退会让所有时间差变负）
    I3  连续性  —— 倍率变化时无跳变（跳变会让动画进度/冷却瞬间突变）

另外附带测量：
    R1  速率正确性 —— 稳定倍率下，虚拟时钟速率 ≈ f × 真实速率
    R2  已知偏差   —— 倍率变化后到下一次调用之间的那段真实时间，
                      会被按"新倍率"计算而非旧倍率（OpenSpeedy 亦有此特性）

用法：
    python3 tools/test_time_dilation.py
退出码 0 = 全部通过，1 = 有不变量被违反
"""
import random
import sys

FAILURES = []


def check(cond, msg):
    if not cond:
        FAILURES.append(msg)
    return cond


# ---------------------------------------------------------------------------
# 被验证的对象：OpenSpeedy 算法的等价 Python 复刻
# ---------------------------------------------------------------------------
class Clock:
    """复刻 speedpatch.cpp 里单个时钟的状态机（lastReal/lastHook/base*/pending）。"""

    def __init__(self, t0):
        self.base_real = t0
        self.base_virtual = t0
        self.last_real = t0
        self.last_virtual = t0
        self.pre_factor = 1.0
        self.pending_reanchor = False

    def __call__(self, real_now, factor):
        # 倍率变了 → 标记，等本次调用重锚（与 C++ 中 shouldUpdateAll() 等价）
        if factor != self.pre_factor:
            self.pre_factor = factor
            self.pending_reanchor = True

        if self.pending_reanchor:
            self.base_real = self.last_real
            self.base_virtual = self.last_virtual
            self.pending_reanchor = False

        self.last_real = real_now
        delta = factor * (real_now - self.base_real)
        v = self.base_virtual + delta
        self.last_virtual = v
        return v


# ---------------------------------------------------------------------------
# I1 恒等性
# ---------------------------------------------------------------------------
def test_identity():
    clk = Clock(1_000_000)
    t = 1_000_000
    for i in range(500):
        t += random.randint(1, 5000)
        v = clk(t, 1.0)
        check(v == t, f"I1 恒等性被违反：f=1.0 时 virtual={v} != real={t} (step {i})")


# ---------------------------------------------------------------------------
# I2 单调性 + I3 连续性：在倍率随机跳变的压力下
# ---------------------------------------------------------------------------
def test_monotonic_and_continuous():
    """
    压力场景：倍率在 0.5×–50× 之间随机跳变，采样间隔不均匀
    （模拟真实调用：有的地方每帧调，有的地方几百毫秒才调一次）。
    """
    clk = Clock(0)
    t = 0
    prev_v = 0
    worst_jump_ratio = 0.0

    factors = [0.5, 1.0, 2.0, 3.0, 5.0, 8.0, 13.0, 20.0, 33.0, 50.0]
    f = 1.0
    for i in range(5000):
        # 每若干步换一次倍率（模拟用户在配置 App 里改档）
        if i % 37 == 0:
            f = random.choice(factors)
        dt = random.choice([1, 16, 33, 100, 250, 1000, 3000])  # ns 级到 ms 级
        t += dt
        v = clk(t, f)

        # I2 单调
        check(v >= prev_v,
              f"I2 单调性被违反：step {i} f={f} virtual 从 {prev_v} 回退到 {v}")

        # I3 连续：这一步的增量不得超过「真实增量 × 新倍率」再加一点浮点余量
        #
        # 这里正是本算法的关键性质：重锚后 v = lastVirtual + f*(t - lastReal)，
        # 因此任意一步的增量 = f × 真实增量（含倍率刚变化的那一步）。
        # 若不重锚（直接 v = f*t），倍率下降时这一步会变成巨大的负数。
        step = v - prev_v
        allowed = f * dt * 1.001 + 1.0
        if step > allowed:
            check(False,
                  f"I3 连续性被违反：step {i} f={f} 增量 {step} > 允许 {allowed:.1f}")
        ratio = step / allowed if allowed > 0 else 0
        worst_jump_ratio = max(worst_jump_ratio, ratio)
        prev_v = v

    return worst_jump_ratio


# ---------------------------------------------------------------------------
# R1 速率正确性
# ---------------------------------------------------------------------------
def test_rate():
    """稳定倍率下，虚拟时钟的推进速率应 ≈ f × 真实速率。"""
    rows = []
    for f in (0.5, 1.0, 2.0, 5.0, 10.0, 50.0):
        clk = Clock(0)
        t = 0
        steps = 2000
        dt = 1000
        for _ in range(steps):
            t += dt
            clk(t, f)
        real_elapsed = t
        virtual_elapsed = clk.last_virtual
        measured = virtual_elapsed / real_elapsed
        ok = abs(measured - f) < 0.01 * max(f, 1.0)
        check(ok, f"R1 速率错误：f={f} 实测速率 {measured:.4f}")
        rows.append((f, measured))
    return rows


# ---------------------------------------------------------------------------
# R2 已知偏差（记录，不作为失败）
# ---------------------------------------------------------------------------
def test_known_skew():
    """
    已知特性，不是 bug，但必须知道：
    倍率变化发生在两次调用之间时，那段真实时间会被按**新倍率**折算，
    而不是按变化前的旧倍率。调用越稀疏，这个偏差越大。
    OpenSpeedy 同样有此特性。
    """
    clk = Clock(0)
    clk(0, 1.0)          # 起步，f=1
    clk(1000, 1.0)       # 真实推进 1000，虚拟也推进 1000
    v_before = clk.last_virtual
    # 倍率改成 5，但下一次调用发生在很久之后
    clk(1000 + 10000, 5.0)
    v_after = clk.last_virtual
    # 这 10000 全部按新倍率 5 折算
    expected = v_before + 5.0 * 10000
    check(abs(v_after - expected) < 1e-6,
          f"R2 偏差模型不符：期望 {expected} 实得 {v_after}")
    return (v_after - v_before) / 10000.0


# ---------------------------------------------------------------------------
def _fmt(ns):
    return f"{ns/1e6:8.2f} ms" if ns >= 1e5 else f"{ns:8.0f} ns"


def main() -> int:
    random.seed(20261008)
    print()
    print("=" * 74)
    print(" 时间膨胀算法验证（移植自 OpenSpeedy speedpatch.cpp）")
    print("=" * 74)

    print("\n[I1] 恒等性：f = 1.0 时虚拟时钟必须等于真实时钟")
    test_identity()
    print("     500 次随机步长调用 —— 完成")

    print("\n[I2/I3] 单调性与连续性：倍率在 0.5×–50× 间随机跳变，5000 步")
    worst = test_monotonic_and_continuous()
    print(f"     最大单步增量 / 允许上限 = {worst:.4f}（≤1.0 即无跳变）")

    print("\n[R1] 速率正确性：虚拟速率应 ≈ f × 真实速率")
    print(f"     {'倍率':>6}  {'实测速率':>10}")
    for f, m in test_rate():
        print(f"     {f:>6.1f}  {m:>10.4f}")

    print("\n[R2] 已知偏差：倍率变化到下次调用之间的时间按新倍率折算")
    skew = test_known_skew()
    print(f"     实测该段折算倍率 {skew:.2f}（期望 5.00 —— 即按新倍率）")
    print("     记为已知特性，不作为失败项；调用越稀疏偏差越大。")

    print()
    print("=" * 74)
    if FAILURES:
        print(f" ✗ {len(FAILURES)} 项不变量被违反：")
        for m in FAILURES[:10]:
            print("   - " + m)
        if len(FAILURES) > 10:
            print(f"   ... 另有 {len(FAILURES)-10} 条")
        print("=" * 74)
        return 1

    print(" ✓ 全部通过：恒等性 / 单调性 / 连续性 / 速率正确性 均成立")
    print("   算法可移植到 SIOriginal v2.6.0 TimeMode。")
    print("=" * 74)
    return 0


if __name__ == "__main__":
    sys.exit(main())
