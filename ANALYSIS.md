# ANALYSIS — SIOriginal v3.1 架构分析

> 本文记录 v2.x → v3.0 的**为什么**：每个结构性问题是什么、怎么发现的、
> v3.0 用什么机制消除、以及残留的已知限制。
> 与 `OPTIMIZATIONS.md` 的区别：那份讲「优化项与验证」，这份讲「设计决策与取舍」。

---

## 1. v2.x 的结构性问题（按严重度排序）

### 1.1 三套安装点，互不知道对方存在

**现象**：`SIOriginalInit()`（构造期）装核心两族并顺手装了约 55 个本可延后的 hook；
`SIO_installiOS16Extras()` 装在哪取决于调用方；列表/按需安装又在第三处。

**后果**：
- pre-main 交换数远超必要（约 55 次），每次交换都是方法表改动 + 一次
  `objc_getClass` + `class_getInstanceMethod`。
- 「开关关了也只是 hook 里判断一下就 return」—— 方法表照改不误，
  白白承担了交换的启动成本与继承风险。
- v2.2.0 声称把启动期交换从 53 降到 26，实际仍有 55 次没搬走（人肉清点不可靠）。

**v3.0 的消除机制**：`SIOHookEntry[]` 声明式安装表 + `SIOInstaller` 单一编排。
每个条目自声明 `stage/gate/minOS/maxOS/needCaps`，编排器不做任何业务判断。
`gSIOEntryAttempts[]` / `gSIOEntrySkipped[]` / `gSIOEntryFailed[]` 三个计数器
让「是否真装上了」变成可观测指标，而不是靠人肉清点。

### 1.2 黑名单两套匹配语义

**现象**：动画侧 `SIO_bundleMatches()` 用 `isEqualToString:`（精确）；
保活侧 `_fbg_isExcluded()` 用 `hasPrefix:`（前缀）。

**后果**（v2.1.0 修的真实 bug）：配置 App 默认写入 `com.tencent.wework`，
保活侧用前缀匹配会连带排除 `com.tencent.weworkhelper` 等一串无关 App ——
用户只想排除企业微信，实际排除了一片。

**v3.0 的消除机制**：唯一实现 `SIOBundleMatches()`（精确 + 尾 `*` 前缀，
即 `com.tencent.wework*` 才做前缀匹配）。保活侧直接复用同一函数，
不再有第二个判定实现。`check_v300.py` 断言「无重复的前缀匹配实现」。

### 1.3 保活生命周期回调注册在错误的通知中心

**现象**：`UIApplicationDidEnterBackgroundNotification` 注册到
`CFNotificationCenterGetDarwinNotifyCenter()`。

**后果链**（这是本项目最严重的一次事故）：
```
Darwin 中心只投递 notify_post() 的名字，NSNotification 名字从不到达
  → 回调从未触发
  → gPhysBg 永远 NO
  → _fbg_startAudio 永不调用（音频断言保活完全不启动）
  → _fbg_appState 的 `gUseScene && gPhysBg` 恒假（场景伪装也不启动）
  → _fbg_watchdogFire 首行 `if (!gUseAudio || !gPhysBg) return` 恒 return（自愈轮询也不跑）
```
即「场景伪装 / 音频断言兜底 / 真后台保活」**三个功能从未执行过一行代码**。

**v3.0 的消除机制**：只用 `NSNotificationCenter` 一条生命周期路径，
并在注释里写明「Darwin 中心只投递 notify_post 的名字，两套系统互不相通」，
防止后人再次改回。同时移除了两套并存的重复观察者。

### 1.4 plist 被解析两遍

**现象**：动画侧 `SIO_reload()` 读一次，保活侧 `_fbg_loadPref()` 再读一次；
两边还各自跑一遍 trim + 清洗黑名单。

**后果**：每次配置读取多一次 `dictionaryWithContentsOfFile:`（含磁盘 IO）；
更麻烦的是**顺序依赖** —— 若保活侧先跑，`gBlacklistItems` 还是 nil，
排除表静默变空（黑名单对保活失效）。v2.5.0 为此加了一个「没跑过就自己跑一遍」的兜底，
但这只是把症状藏起来。

**v3.0 的消除机制**：唯一读盘出口 `SIOPrefSnapshot()`（带 `os_unfair_lock` 缓存），
保活侧直接复用 `gSIOBlacklistItems` + `SIOAppOverrideLookup()`。
构造顺序不再影响正确性。`check_v300.py` 断言「plist 读取只在 SIOConfig.m」。

### 1.5 继承污染（v1.8.19 崩溃）

**现象**：直接 `method_setImplementation(m, newImp)` 而不先尝试 `class_addMethod`。

**后果**：若本类没有该方法的自有实现（实现来自父类），
改的就是**父类**的实现 —— 所有子类都被动改写。
例如把 `setContentOffset:animated:` 直接换到父类，会让所有 UIView 都进入
UIScrollView 的判断分支 → 崩溃。

**v3.0 的消除机制**：`SIOExchange()` 内建该防护：
`class_addMethod` 成功 ⇒ `*orig` 指向**父类**实现；
失败（本类已有实现）⇒ 才 `method_setImplementation` 并 `*orig = cur`。
`check_v300.py` 断言「无未标注的裸 method_setImplementation」。

### 1.6 时长下限的反向拉长（v2.1.0 的「假功能」）

**现象**：`d = floor`（无条件把结果设为下限）。

**后果**：比下限更短的微动画会被**抬长**：0.005s → 0.02s，慢 4 倍 ——
与「加速」语义完全相反。同时导致转场额外倍率被完全抵消
（0.35 经两级除法落到 0.0058 < floor 0.02，被抬回 0.02，用户调档位看不到变化）。

**v3.0 的消除机制**：下限口径固定为 `min(floor, orig)` ——
只在原值本就 ≥ 下限时才允许钳制。且顺序不可颠倒：
必须在下限钳制**之后**做帧对齐，否则下限会把已对齐的值重新抬高。
`check_v300.py` 与 `test_frame_align.py` 双重断言。

### 1.7 pre-main 的隐性开销

**现象（多个，v2.5.0 集中修）**：
- 一段 `NSLog` 把 UIKit 初始化与私有框架 `dlopen` 拖进 dyld 期；
- `_fbg_loadPref()` 二次 `dictionaryWithContentsOfFile:`；
- 保活 watchdog 在构造期起一个 1.5s 重复定时器并挂 `CommonModes`，
  而回调首行就是 `if (!gUseAudio || !gPhysBg) return` —— 前台期 100% 空转；
- `[arg2 description]` 在**调用方**无条件生成（可能数 KB），随后 7 次全串扫描。

**v3.0 的消除机制**：
- pre-main 收敛到四步（TLS → 平台探测 → 配置 → Boot 档），完整指纹延后输出；
- watchdog 随前后台生命周期启停；
- `SIOBgIsBackgroundingDiff` 把下游扫描从「7 次独立全串扫描」降到
  「1 次定位 + 局部比较」（4 条 foreground 判据都以同一前缀开头）；
- 昂贵 IO 探测（`stat` 外部路径、`access` 可写性）延后到 `SIOAfterBoot`。

### 1.8 并发崩溃（v2.5.0 的 EXC_BAD_ACCESS）

**现象**：ARC 下给 `__strong` 静态变量赋值会 release 旧值；
写入方是 Darwin 通知线程，读取方是任意动画线程 ⇒ 悬垂指针。

**v3.0 的消除机制**：`gSIOPrefCache` 用 `os_unfair_lock` 保护；
磁盘 IO 在锁外做（否则所有动画 hook 会在重载瞬间一起阻塞）；
重载路径整体走 serial queue。

---

## 2. v3.1 的核心抽象

### 2.1 唯一契约：`SIOInternal.h`

把「跨模块共享的一切」集中到一个文件：配置状态、派生量、进程标记、TLS 槽位、
时长换算引擎（`static inline`）、门控、能力位图、安装表类型、调度器接口、
配置接口、Toast 接口、保活接口、事务包裹。

**设计取舍**：时长换算用 `static inline` 放在头文件而不是独立 `.m`。
理由：这是热路径（每次动画创建都会走），函数调用开销不可接受；
统一输入为 `gSIOCfg` 保证「全项目只有一份实现」。

### 2.2 三档安装栅栏

| 档位 | 时机 | 内容 | 数量 |
|---|---|---|---|
| `Boot` | `__attribute__((constructor))` | 核心两族（CAAnimation / UIView 动画） | 19 |
| `PostLaunch` | `didFinishLaunching` 后（或 0.35s 超时） | 转场、控件、滚动、长按、SB 护栏 | ~40 |
| `OnDemand` | `PostLaunch` 之后，且 `gate()` 为真 | 列表、缩放、布局、长按 setter | 0–32 |

**0.35s 超时兜底的必要性**：若某个 App 不投递
`UIApplicationDidFinishLaunchingNotification`，延后安装会退化为「永不安装」。
超时兜底把「延后」与「丢失」区分开。

### 2.3 能力位图而非版本号

`SIOCaps` 全部用 `objc_getClass` / `respondsToSelector` / `dlsym` 运行时探测。
理由：**版本号与 API 可用性不是一一对应关系**（同一个 API 可能在某个小版本被
改归属，或仅在特定设备上存在）。版本号只作为最后的 fallback，
且必须配 `@available` 编译守卫（如 `UIWindowScene.windows` 需 iOS 15）。

### 2.4 时长换算的四层结构

```
SIO_targetDuration          ← 基础：模式分派 + 下限钳制 + 帧对齐
  ├─ SIO_targetDurationLayer    ← 叠加 LayerBoost（需重做帧对齐）
  ├─ SIO_targetDurationUIKit    ← 叠加系统系数预除补偿
  └─ SIO_transitionBase         ← 固定 0.35s 输入 + TransitionBoost
SIO_targetDelay             ← 延迟同比缩放（0 延迟保持 0）
```

**为什么 `SIO_compensatedDivisor` 要「预除」而不是「结果校正」**：
hook 拦截到的是 App 传入的、**尚未**乘系统系数的值；
UIKit 会在内部创建动画时再乘一次。因此 hook 侧必须**先除**，
让 UIKit 乘回来正好等于目标值：`hook 给出 T/c → UIKit 内部再 ×c → 最终 T`。

### 2.5 系统系数（`UIAnimationDragCoefficient`）的单侧写入设计

v2.5.1 的写法是**双侧写入**：配置 App 写 Managed Preferences，同时 dylib 也向被注入
App 自己的 `NSUserDefaults` 写一份系数。这带来两个问题：

1. **覆盖缺口**：未被注入的 App 拿不到 dylib 写入的那份；而用户开启「全局兜底」
   的初衷恰恰是覆盖 hook 够不到的地方（SwiftUI 内部动画、私有路径）。
2. **双写竞争**：两条写入源在同一语义上互相干扰，且 dylib 侧写入发生在每个目标
   App 的启动路径上（红线 #2 的边界）。

v3.0 收敛为**单侧写入 + 只读补偿**：

| 侧 | 职责 | 位置 |
|---|---|---|
| 配置 App | **唯一写入者**。写 `/var/Managed Preferences/mobile/com.apple.UIKit.plist` 的 `UIAnimationDragCoefficient` | `App/main.m` → `WriteConfig(cfg, dragCoeff)`（同一 plist 只写一次） |
| dylib | **只读者**。读该键 → `c->systemSpeed`，仅用于 `SIO_compensatedDivisor()` 预除补偿 | `Tweak/SIOConfig.m` → `SIOInternal.h` 的 `SIO_targetDurationUIKit()` |

收益：写入源唯一、覆盖面扩大到全系统（含未被注入的 App）、dylib 启动路径零写入副作用、
结构上不可能出现「hook 侧再写一份」导致的二次连乘。

---

## 3. 已知限制与残留风险

| 限制 | 说明 | 缓解 |
|---|---|---|
| 私有类依赖 | 场景伪装依赖 `FBSWorkspaceScenesClient`；iOS 18 可能改名 | 全部走 `objc_getClass` 探测，拿不到只少一层保护，不崩 |
| `RootHelper` 在 17.6+/18 失效 | XNU 禁止非 root 二进制 spawn root | `kSIOCapRootHelper` 仅表示「形态上存在」，不作为功能前提 |
| 列表 hook 的本质风险 | 改写动画时长可能破坏变更状态机 | 默认关 + SpringBoard 硬保护 + 缺键 fail-safe |
| 内存护栏的还原依赖快照 | 若 `gSIOCfgPristine` 未同步更新，还原会写回旧配置 | 每次 `SIOConfigReload` 后重建快照 |
| 系统系数需重启生效 | `UIAnimationDragCoefficient` 写入后 UIKit 要下次启动才读 | 属固有特性；hook 路径不受影响，可即时生效 |
| arm64e 需正确签名 | 单架构 dylib 在 A12+ 上被 dyld 拒绝加载 | CI 强制 `lipo -info` 校验双架构 |
| 无法在本地（Windows）编译 | 无 clang / iPhoneOS SDK / ldid / zip | 构建走 GitHub Actions（macOS runner） |

---

## 4. 从 v2.x 保留下来的「已验证正确」的部分

重构的边界是：**只动结构，不动已验证的算法**。以下逻辑逐字保留（仅换位置/换输入源）：

- `SIO_framePeriod` / `SIO_alignToFrameBoundary` 的三条安全边界；
- `SIO_targetDuration` 的模式分派与 `min(floor, orig)` 口径；
- `SIODurBox`（`double value; BOOL scaled;` 的 POD 盒子）把「原时长」与
  「已缩放标记」合并进同一个关联对象，减少 `AssociationsManager` 自旋锁竞争；
- `SIODelegateIsSpinnerCandidate`（16 槽直映缓存）与 `SIOAnimMayBeSpinner`
  （只做否定的 O(1) 前置筛：属性动画 + 无限重复 + keyPath 含 rotation/transform）；
- `sio_layer_actionForKey` 的最热路径优化：`key.length > 32` 先否定 →
  `isKindOfClass` → `fabs(d-0.25) <= 1e-6` 才用预计算的隐式时长经原 IMP 写回；
- 转圈专属下限 `kSIOSpinnerFloorSec = 0.4`（低于此值会因帧率采样混叠出现频闪/视觉倒转）；
- `sio_catx_getDur` 命中 `gSIOTxLastSet` 直接原样返回（修双重缩放）；
- 弹簧参数缩放关系：`stiffness ∝ s²`、`damping/velocity ∝ s`。

**唯一被替换的算法**：`SIO_reduceMotionOn()` 从 v2.x 的私有符号改为
公开 API `dlsym(RTLD_DEFAULT, "UIAccessibilityIsReduceMotionEnabled")`，
并加 5 秒 TTL 缓存（避免在动画热路径上反复查询无障碍状态）。

---

## 5. 代码规模对比

| | v2.5.0 | v3.0 |
|---|---|---|
| Tweak 源码 | 4772 行单文件 | 约 3400 行 / 15 个文件 |
| 最大单文件 | 4772 行 | 555 行（`SIOBackground.m`） |
| 安装点 | 3 处 | 1 处（`SIOInstaller`） |
| 黑名单实现 | 2 套语义 | 1 套 |
| plist 读取 | 2 处 | 1 处 |
| pre-main 交换 | 约 55 | 19 |
| 静态核查项 | 9（v2.5.0） | 14（v3.0）+ 沿用旧项 |

行数只略降（因为新增了内存护栏 / 调度策略 / 能力探测），
但**结构性重复被消除**，且新增能力都是可独立开关、可独立降级的。
