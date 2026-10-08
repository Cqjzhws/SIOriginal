# OpenSpeedy 加速原理研究 & 对 SIOriginal v2.5.0（iOS 16.2）的可移植性分析

研究对象：<https://github.com/game1024/OpenSpeedy>（Windows 开源游戏变速工具）
核心实现：`src-bridge/speedpatch/speedpatch.cpp`（733 行，已下载通读）

> **状态更新（v2.6.0）**：本文第七节推荐的「折中路线」**已落地为代码**，
> 见 `Tweak/SIOriginal.m` 文件头 v2.6.0 段落与 `README.md` 的 v2.6.0 章节。
> 落地范围严格等于本文建议：`CACurrentMediaTime` 单点重绑定、fishhook 机制、
> 默认关 + Bundle ID 白名单、接 `SIO_blocked()` 门控、不碰墙钟时间源。
> 本文分析的其余部分（完整 TimeMode 需要的内联 hook + arm64e PAC 方案）**未实现**，
> 仍是建议，不是代码。

---

## 一、OpenSpeedy 到底做了什么

### 1.1 一句话原理

**它不修改任何动画的时长，它让进程的"时间"本身跑得更快。**

这是与 SIOriginal 根本不同的路径。SIOriginal 是"把 0.3s 的动画改成 0.06s"；
OpenSpeedy 是"让 App 以为 0.3 秒已经过去了，而真实世界只过了 0.06 秒"。

后者的威力在于：**它不需要知道世界上有哪些动画**。
任何按时间推进的东西都会自动变快 —— 动画、物理积分、技能冷却、
AI 计时器、粒子系统，无一例外，也无需为它们各写一个 hook。

### 1.2 核心算法：基线重锚 + 增量缩放

这是整个实现里最值得学的一段。以 `QueryPerformanceCounter` 为例（原文 399–429 行）：

```cpp
// 倍率变了 → 打标记，等下一次调用时重新锚定基线
if (pre_factor != SpeedFactor()) { pre_factor = SpeedFactor(); shouldUpdateAll(); }

if (shouldUpdateQueryPerformanceCounter.compare_exchange_weak(expected, false)) {
    baseReal_...store(lastReal_...load());   // 真实时钟锚点 ← 上次读到的真实值
    baseHook_...store(lastHook_...load());   // 虚拟时钟锚点 ← 上次返回的虚拟值
}
now = Real_QueryPerformanceCounter();
lastReal_...store(now);
delta = SpeedFactor() * (now - baseReal);   // 只缩放「增量」
result = baseHook + delta;                  // 加回虚拟锚点
lastHook_...store(result);
return result;
```

即：

```
virtual(t) = baseVirtual + f × (t − baseReal)
```

**为什么要"重锚"而不是直接乘？**

如果直接 `virtual = f × t`，那么每次用户改倍率，虚拟时钟都会**跳变**：
从 3.0 调到 1.0 时，虚拟时间会瞬间倒退一大截。所有基于时间差的东西
（动画进度、冷却剩余、超时判断）都会在这一刻算出一个负数或巨大值。

重锚做的是：倍率变化时，把锚点挪到"上一次读到的真实值 / 上一次返回的虚拟值"
这对坐标上。于是虚拟时钟**在新倍率下从上一次的位置继续往前走** ——
值连续、单调、不跳变。这是该实现真正的巧思所在。

配套还有一处：所有基线在 `DllMain` 里**先预置再开 hook**（原文 616–666 行），
保证 hook 生效的第一刻就是连续的，而不是从 0 开始。

### 1.3 三类 API，三种处理

| 类别 | 例子 | 处理 |
|---|---|---|
| **单调时钟（读数）** | `QueryPerformanceCounter`、`GetTickCount(64)`、`timeGetTime`、`GetMessageTime` | 基线重锚 + 增量缩放 |
| **等待/定时器（入参）** | `Sleep`、`SleepEx`、`WaitForSingleObject(Ex)`、`WaitForMultipleObjects(Ex)`、`SetTimer`、`timeSetEvent`、`SetWaitableTimer(Ex)` | 入参 **除以** 倍率 |
| **墙上时钟** | `GetSystemTimeAsFileTime`、`GetSystemTimePreciseAsFileTime` | 同样用基线重锚 + 增量缩放 |

### 1.4 值得注意的工程细节

- **`0` 与 `INFINITE` 原样透传**（原文 196–199 行等）：
  ```cpp
  if (dwMilliseconds == 0 || dwMilliseconds == INFINITE) return Real_...(h, dwMilliseconds);
  ```
  这条看似不起眼，实则是必需的：`0` 是"非阻塞轮询"，除以倍率还是 0，
  但一旦走浮点除法再截断就可能变负或溢出；`INFINITE` 是 `0xFFFFFFFF`，
  除以 5 会变成一个有限值 —— 那等于把一个"永远等待"改成"等 13 分钟"，
  语义完全崩坏。**这类哨兵值必须显式排除。**

- **`QueryPerformanceFrequency` 不 hook**：只缩放计数值、不改频率。
  这样 `delta / frequency` 自然得到缩放后的秒数。改频率反而是错的。

- **倍率是 `std::atomic<double>`**（原文 30 行），GUI 通过
  `OpenSpeedy.<pid>` 命名的共享内存（`CreateFileMapping`）翻转 enabled 开关，
  实现运行中改倍率。`SpeedFactor()` 在 disabled 时直接返回 1.0，
  hook 退化成透传。

- **hook 机制是 MinHook**（inline patching / trampoline），Ring-3，不碰内核。
  这是它能拦住**系统 DLL 内部调用**的前提 —— 见第三节，这一点在 iOS 上是最大的坎。

- **DllMain 里不能弹窗**（原文 611 行注释）：持有 loader lock，
  只能 `OutputDebugStringA` 后返回 FALSE 让加载干净失败。

### 1.5 它已知会破坏什么（对 iOS 的预警）

OpenSpeedy 自己的定位是"游戏变速"，破坏面可以接受（游戏崩了重开即可）。
它连**墙上时钟**一起缩放 —— 在游戏里通常没问题，但放到 iOS 的日常 App 上
就是另一回事了（见 4.2）。

---

## 二、与 SIOriginal 现有方案的对比

SIOriginal 目前有两套引擎，OpenSpeedy 代表第三套：

| | 时长模式（v2.0–v2.4） | 速率模式（v2.1.0 SpeedMode） | **时间膨胀（OpenSpeedy）** |
|---|---|---|---|
| 手段 | 改 `duration` | 改 `CAAnimation.speed` | 改**时钟读数** |
| 覆盖面 | 已知的所有动画 API（100+ hook） | 同左，但物理/插值不失真 | **不需要知道有哪些动画** |
| 撞下限 | 会（故有 `gFloor`） | 不会 | 不会 |
| 关键帧/物理失真 | 会（duration 极小时） | 不会 | 不会 |
| 自驱渲染循环 | ❌ 覆盖不到 | ❌ 覆盖不到 | ✅ 自动生效 |
| 非动画的定时任务 | ❌ | ❌ | ✅（定时器/冷却/轮询一起变快） |
| 需要 inline hook | 不需要（纯 ObjC runtime） | 不需要 | **需要**（见第三节） |
| 全局副作用 | 小 | 小 | **大** |

### 关键收益：正好补上 SIOriginal 自己承认的无能为力区

SIOriginal 源码末尾的「拆包证据 [7]」原文写着：

```
// [7] 无法用「改时长」加速的动画引擎（做了也没用，不要承诺）：
//     SVGA（SVGAPlayer / SVGAVideoEntity，CADisplayLink 自驱）、
//     Ugen 动态 UI 引擎（UgenAnimation* 自有渲染循环）、
//     CSJRWLottie*（穿山甲广告 SDK 自带 Lottie）、RN Reanimated。
```

这四类 —— 加上 Unity / Unreal / Cocos 游戏引擎、自绘 CADisplayLink 动画 ——
**恰好是时间膨胀能覆盖而改时长永远覆盖不到的部分**。
它们是"自己读时钟、自己推进进度"，压根不经过 UIKit 的 duration 入口。

所以答案是明确的：**有价值，而且这是目前 SIOriginal 唯一能拿到这块覆盖面的路径。**

---

## 三、iOS 16.2 上的可行性：逐项拆解

### 3.1 时间 API 映射

| Windows | iOS / Darwin | 备注 |
|---|---|---|
| `QueryPerformanceCounter` | **`mach_absolute_time()`** / `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)` | 单调，**iOS 的时间根** |
| `timeGetTime` | **`CACurrentMediaTime()`** | 单调；CoreAnimation 与 App 的主用时入口 |
| `GetTickCount(64)` | 无直接对应；≈ `clock_gettime(CLOCK_MONOTONIC)` | |
| `GetSystemTimeAsFileTime` | `gettimeofday()` / `NSDate.timeIntervalSince1970` / `CFAbsoluteTimeGetCurrent()` | ⚠️ **墙上时钟，不该动** |
| `Sleep` | `usleep` / `nanosleep` | |
| `SetTimer` | `NSTimer` / `dispatch_source_set_timer` / `CADisplayLink` | |
| `WaitForSingleObject` | `dispatch_semaphore_wait` / `pthread_cond_timedwait` | |

好消息：**iOS 的收敛度远高于 Windows**。
Windows 需要 hook 十几个函数才能覆盖主流引擎，而 Darwin 上
`mach_absolute_time()` 是近乎唯一的根 ——
`CACurrentMediaTime` → `CFAbsoluteTimeGetCurrent` → `NSDate` → `dispatch_time` →
`std::chrono::steady_clock` 基本都从它派生。**理论上 hook 一两个点即可全局生效。**

### 3.2 最大的坎：hook 机制（这是 MinHook 不可替代的地方）

`mach_absolute_time()` 的调用分三种情况，而 **fishhook 只能处理第一种**：

| 调用来源 | 走符号桩？ | fishhook 能拦？ | inline hook 能拦？ |
|---|---|---|---|
| 你的 dylib → libSystem | ✅ 走 `__la_symbol_ptr` | ✅ | ✅ |
| **App 主二进制 → libSystem** | ✅ 走桩 | ✅ | ✅ |
| **CoreAnimation / 系统库内部 → libSystem** | ❌ 同镜像内直接分支 | ❌ **不能** | ✅ |
| 通过 commpage 直接读时（arm64 上部分代码这么做） | ❌ 不是函数调用 | ❌ | ❌ |

**结论：想让核心动画系统（CoreAnimation 内部）的时间感被改变，必须用 inline hook。**
fishhook（Facebook 的符号重绑定）在这里不够用 —— 它只改写符号表指针，
拦不到系统库内部的直接调用。

这意味着：

- 需要引入 **Dobby** / **Substrate** / **ElleKit** 之类的 inline hook 库
- **SIOriginal 目前是零外部依赖**（纯 ObjC runtime + `method_setImplementation`），
  这是它"TrollFools 友好、体积小、启动快"的基础。引入 Dobby 会：
  - 增加 dylib 体积（Dobby 约 100–200KB）
  - 增加启动期的 hook 安装成本（与 v2.5.0 刚做的启动优化形成张力）
  - 引入一个新的失效模式：inline patch 失败的架构/系统版本
- 这**不是一个可以顺手加的小功能**，是一次架构层面的取舍

### 3.3 arm64e / PAC

iOS 16.2 的设备（A12+）系统库是 arm64e，带指针认证（PAC）。
Inline hook 需要能正确处理 `PACIBSP` / `BLAA` 指令并生成合法 trampoline。
Dobby 与 ElleKit 支持，但：

- 必须同时构建 arm64 与 arm64e 切片（SIOriginal 的 `Makefile` 目前写的是
  `ARCHS := arm64`，v2.0.2 才补的双架构，需要确认 CI 是否仍在产 arm64e）
- 宿主 App 自身可能是 arm64（非 PAC），此时系统库调用仍走 arm64e 路径

### 3.4 共享缓存与代码签名

系统库位于 dyld shared cache。Patch 它们需要把对应页改成可写再重映射。
在 TrollStore / TrollFools 环境下通常可行，但：

- 部分配置下 AMFI 可能拦截对共享缓存页的修改，**需要真机实测确认**
- 更稳妥的路线：**只 hook App 自己的 `CACurrentMediaTime` 调用 + 你 dylib 内的调用**，
  不去动系统库内部。覆盖面小一些，但风险低一个数量级

### 3.5 反作弊检测

Inline hook 会留下 trampoline，游戏反外挂（以及部分金融类 App 的防篡改）
**能检测到**。这比 SIOriginal 现有的 ObjC swizzle 风险高得多 ——
ObjC swizzle 改的是方法表，相对隐蔽；改函数前几字节是经典的被检测特征。

---

## 四、可移植性分级清单

### ✅ 可以直接照搬（纯算法，零风险）

| 项 | 说明 |
|---|---|
| **基线重锚 + 增量缩放公式** | `v = baseV + f×(t − baseT)`，倍率变化时重锚。已用 `tools/test_time_dilation.py` 验证三条不变量 |
| **`0` / `INFINITE` 哨兵值透传** | 应成为 SIOriginal 的一条通用纪律（现有 `if (d > 0.0)` 是同思路，但 `dispatch_time(DISPATCH_TIME_FOREVER)` 这类也需显式排除） |
| **倍率变更时的连续性保证** | SIOriginal 目前改倍率只是换 `gSpeed`，在飞行中的动画保持原时长 —— 时长模式下无连续性风险；若加时间膨胀模式则必须引入重锚 |
| **`std::atomic<double>` 倍率 + enabled 时返回 1.0** | 对应 SIExisting 的 `gSpeed` + `SIO_blocked()`；enabled=OFF 时 hook 透传的写法应沿用 |
| **DllMain 预置基线** | 对应到 iOS：在 constructor 里预置所有基线，再装 hook |

### ⚠️ 可移植但需要 iOS 侧重新设计

| 项 | 需要的改造 |
|---|---|
| hook 机制 | MinHook → **Dobby**（inline hook）。需 arm64 + arm64e 双架构 |
| 目标函数 | Windows 十几个 → iOS 集中在 `mach_absolute_time` / `CACurrentMediaTime` |
| 配置传递 | 共享内存 → 沿用 SIOriginal 已有的 Darwin 通知 + plist |
| `Sleep` 类 | `usleep`/`nanosleep` 在 iOS 上被网络与 IO 线程大量使用，全局缩短可能致忙等与耗电。**建议仅主线程、或干脆不 hook** |
| `WaitFor*` 类 | `dispatch_semaphore_wait` 语义差异大，建议不动 |

### ❌ 明确不应照搬

**缩放墙上时钟 —— 这是 OpenSpeedy 在 iOS 上最危险的一处。**

它 hook 了 `GetSystemTimeAsFileTime` / `GetSystemTimePreciseAsFileTime`。
在 Windows 游戏里通常没事，但在 iOS 上，墙上时钟被改动会直接影响：

- **TLS 证书有效期校验**（`SecTrustEvaluate` 依赖当前时间 → 证书可能被判过期/未生效）
- **JWT / OAuth token 过期判断**（金融、支付类 App）
- **HTTP 缓存**（`Cache-Control` / `Date` 头基于墙上时间）
- **FairPlay DRM**（视频类 App）
- **自动锁屏 / 屏幕使用时间 / 勿扰时段**

后果不是"动画怪"，而是**静默的安全与功能失效**，且极难归因。

> **结论：只缩放单调时钟（`mach_absolute_time` / `CACurrentMediaTime`），
> 绝不碰 `gettimeofday` / `NSDate` / `CFAbsoluteTimeGetCurrent`。
> 这一点必须主动偏离 OpenSpeedy 的设计。**
>
> 附带好处：SIOriginal 自己用 `CFAbsoluteTimeGetCurrent()` 测 `bootMs`，
> 只要不动墙上时钟，这个测量就始终可信。

---

## 五、v2.6.0 「TimeMode」设计提案

### 5.1 定位

新增**第三种**引擎模式，与时长模式、速率模式**三选一**（互斥，避免倍率相乘 ——
v2.1.0 已经为速率模式确立了这个原则）。

```
Mode = 0  时长（现有，默认）
Mode = 1  慢放（现有）
Mode = 2  瞬切（现有）
TimeMode = 0/1（新，独立开关，默认 0）
```

**默认关闭**，且必须是**按 App 显式开启** —— 见 5.4。

### 5.2 目标函数（最小可用集）

| 函数 | 库 | 单调？ | 处理 |
|---|---|---|---|
| `mach_absolute_time` | libSystem | ✅ | 基线重锚 + 增量缩放 |
| `CACurrentMediaTime` | QuartzCore | ✅ | 同上（它本就派生自前者，二者取一即可，建议先只做它） |
| `usleep` / `nanosleep` | libSystem | — | 入参 ÷ 倍率，**仅主线程** |

**先只做 `CACurrentMediaTime` 一个**：它是 App 与 CoreAnimation 客户端的公共入口，
覆盖面已经足够大，而风险远小于 patch `mach_absolute_time`（后者会波及
网络栈、GCD、所有系统框架的内部计时）。

### 5.3 算法（移植 OpenSpeedy 的重锚逻辑）

```c
// 每个时钟一份状态
typedef struct { uint64_t baseReal, baseVirtual, lastReal, lastVirtual;
                 double  preFactor; BOOL pendingReanchor; } SIOClock;

static inline uint64_t SIO_scaledNow(SIOClock *c, uint64_t realNow, double f) {
    if (f != c->preFactor) { c->preFactor = f; c->pendingReanchor = YES; }
    if (c->pendingReanchor) {
        c->baseReal    = c->lastReal;      // 锚到上一次读到的真实值
        c->baseVirtual = c->lastVirtual;   // 锚到上一次返回的虚拟值
        c->pendingReanchor = NO;
    }
    c->lastReal    = realNow;
    uint64_t v = c->baseVirtual + (uint64_t)((double)(realNow - c->baseReal) * f);
    c->lastVirtual = v;
    return v;
}
```

三条必须成立的不变量（已写成回归测试 `tools/test_time_dilation.py`）：

1. **恒等**：`f == 1.0` 时返回真实值
2. **单调**：虚拟时钟永不回退
3. **连续**：倍率变化时无跳变（跳变量 ≤ 该步真实增量 × 新倍率）

### 5.4 安全边界（复用 SIOriginal 已有的门控体系）

SIOriginal 已经有一套成熟的安全基础设施，这正是加危险功能的合适土壤：

- `SIO_blocked()`：总开关 / 黑名单 / 减弱动态效果 / 自绘 UI 旁路 —— **全部继续生效**
- `SIO_listHardBlocked()`：**SpringBoard 必须硬保护**（桌面进程时间被加速 = 全系统错乱）
- `AppOverrides`：按 Bundle ID 单独开关
- **新增：TimeMode 采用白名单制** —— 默认对所有 App 关闭，
  只对用户在配置 App 里显式加入的 App 生效。
  这与现有"默认关、按需安装 hook"的 fail-safe 口径一致，
  但更严格一层：因为它影响的是整个进程的时间感，不是某几个动画。
- **新增硬保护名单**：SpringBoard、以及常见金融/支付类 App
  （时间膨胀可能干扰证书校验与 OTP 计时）

### 5.5 风险清单

| 风险 | 等级 | 说明 | 缓解 |
|---|---|---|---|
| 状态机错乱 | **高** | SIOriginal 历史上反复踩过：微信预览工具栏、顺丰同城骑士列表状态机。时间膨胀让"动画完成"与"业务回调"的相对关系整体改变，是新一整类故障 | 白名单 + 默认关 + 充分真机验证 |
| 网络超时/重试风暴 | **中高** | 若最终 hook 到 `mach_absolute_time`，网络栈的超时也一起加速 | 只 hook `CACurrentMediaTime`，不动 `mach_absolute_time` |
| 耗电 | 中 | 缩短 sleep 会提高唤醒频率 | 只主线程，或不动 sleep |
| 反作弊检测 | 中 | inline hook 特征明显 | 游戏类 App 自行承担；文档明确告知 |
| 共享缓存 patch 被 AMFI 拦 | 中 | 未实测 | 先做不动系统库内部的版本 |
| 启动耗时回退 | 低 | 引入 Dobby 增加 dylib 体积与安装成本 | 与 v2.5.0 一样走 `SIO_afterBoot()` 延后安装，且**默认不装** |

### 5.6 诚实的结论

**值得做，但它是 SIOriginal 有史以来风险最高的一个功能，且会打破项目
"零外部依赖、纯 ObjC runtime" 的立身之本。**

- 收益是真实的：能拿到当前明确覆盖不到的 SVGA / Lottie / Ugen /
  Reanimated / 游戏引擎这一整块
- 代价是真实的：引入 inline hook 依赖、检测风险、一整类新的状态机故障
- **它不是"在 v2.5.0 上打个补丁"，是一个需要单独版本（v2.6.0）来承载的特性**

如果只想要一部分收益且不愿承担架构代价，有一条**折中路线**：
只 hook `CACurrentMediaTime`（用 fishhook 即可，因为 App 主二进制对它的调用走符号桩），
不动 `mach_absolute_time`、不碰系统库内部、不引入 Dobby。
覆盖面小于完整方案，但能覆盖大多数用 `CACurrentMediaTime` 做自驱渲染循环的
SDK（相当一部分 Lottie / SVGA / 自绘动画走这条），而风险低一个数量级。

**建议先做折中路线，验证收益后再决定是否上完整方案。**

---

## 六、验证方式

### 6.1 算法层（无需设备）

```bash
python3 tools/test_time_dilation.py
```

复刻 OpenSpeedy 的重锚算法，验证三条不变量在
"倍率 0.5×～50× 随机跳变 + 不均匀采样间隔"压力下仍成立。
这是移植前的必要前置 —— 算法错了，真机上是调不出来的。

### 6.2 真机层（iOS 16.2）

| 指标 | 方法 |
|---|---|
| 目标 App 是否真的整体变快 | 找一个自驱渲染的动画（如某 Lottie 加载动画），倍率 ×5 下录制慢动作视频，对比帧数 |
| 现有 UIKit 动画是否仍正常 | 覆盖 SIExisting 的全部真机验证清单（转圈、列表、转场、微信预览） |
| 网络功能是否受影响 | 目标 App 内做一次登录 / 拉列表 / 上传，确认无超时异常 |
| 支付/金融类 App | **必须在硬保护名单内**，确认注入后功能完全不受影响 |
| 耗电 | Settings → Battery 对比 30 分钟前台使用 |
| 稳定性 | 连续运行 30 分钟无崩溃、无 UI 卡死；`swaps=` 与 `bootMs=` 不应因新 hook 明显上升 |

### 6.3 明确需要真人确认的

自驱动画的观感、以及"App 整体是否变得不对劲"这类主观判断 ——
自动化测试测不出来。

---

## 七、一句话总结

OpenSpeedy 的**算法**（基线重锚 + 增量缩放）可以直接搬，且是它最精华的部分；
它的**目标函数清单**在 iOS 上能收敛到一两个点（比 Windows 更省事）；
但它的 **hook 机制**（MinHook inline patch）在 iOS 上必须换成 Dobby 并直面
arm64e/PAC、共享缓存、反作弊三道坎；而它**缩放墙上时钟**这一条，
在 iOS 上必须主动弃用 —— 那会把"动画加速"变成"证书失效与支付异常"。
