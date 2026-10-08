# SIOriginal v2.5.0 性能分析与优化

对 v2.4.0（`SIOriginal.m` 4186 行 / `main.m` 1458 行）做的性能审计与改动。

先说结论：**这个项目的性能工作已经做了很多，且做得不错** —— v2.0.7 / v2.1.0 /
v2.2.0 三轮分别处理了链接依赖惰性化、热路径去字符串分配、启动期 hook 按需安装。
所以本轮不是在空白处施工，而是做两件事：

1. **找出那些"已经做了优化、但被别的行悄悄抵消掉"的地方**（这类问题最隐蔽，
   因为代码里确实写着优化，注释也写着优化，但它没生效）。
2. 补上真正还没做的：热路径的算法复杂度、并发安全、以及可观测性。

---

## 一、瓶颈定位（按影响程度排序）

排序依据：**影响面 × 发生频率**。同一处代码若在热路径上每秒跑几千次，
哪怕只省一次操作，总量也超过启动期省 50ms。

### P0 —— 启动路径：三处"写了优化但没生效"

| # | 位置 | 问题 | 为什么它没被发现 |
|---|---|---|---|
| **1** | `SIOriginalInit` 末尾的 `NSLog` | 参数表里调了 `SIO_framePeriod()` 与 `SIO_reduceMotionOn()` | 这两个函数本身写着"惰性求值、算完缓存"，注释也这么说。**但 NSLog 的参数必须先求值才能调用**，所以在 pre-main 被强制执行了 |
| **2** | 同上 | `SIO_framePeriod()` → `[[UIScreen mainScreen] maximumFramesPerSecond]` | 首次访问 UIScreen 单例会连带初始化 CADisplay 链路，把本该延后的 UIKit 初始化提前到 dyld 期 |
| **3** | 同上 | `SIO_reduceMotionOn()` → `dlopen(AccessibilityUtilities)` | **在 pre-main 同步 dlopen 一个私有框架**，要解析依赖链并跑它的 initializer —— 这正是 v2.0.7 花整节从启动路径上拿掉的东西 |

第 3 条尤其值得单独说：v2.0.7 的启动提速核心成果是"dylib 不再链接
AVFoundation / UserNotifications"，理由是链接期依赖会让 dyld 加载整套框架。
而 `SIO_reduceMotionOn()` 的 `dlopen` 是 v2.1.0 为避免链接依赖才特意改的写法 ——
**为了躲开链接期依赖而改成运行时 dlopen，结果被一行日志在 pre-main 触发了**，
等于绕了一圈回到原点，而且是在更糟的时机（main 之前）。

### P0 —— 启动路径：hook 安装量远不止"26 次"

v2.2.0 的 README 写"冷启动期 method_setImplementation 从 53 次降到 26 次"。
这个数字是**静态清点**出来的，而且只清点了构造函数里那一块 ——
实际清点安装点后：

- 构造函数核心块：约 24 次
- `SIO_installiOS16Extras()`：**约 55 次**，仍在构造期同步执行
  （PA 8 个 / UIScrollView 5 个 / 控件系 20+ / v2.4.0 补齐 13 个）
- 列表全家桶 27 次：已延后 ✅

也就是说真正被搬走的只有 27/106。剩下那 55 次一直留在 pre-main。

> 顺带一提：本轮之前**没有任何地方真的在数这个数**。README 里的 53/26
> 靠人数出来，任何一次改动都可能让它回退而无人察觉。本轮加了对它的运行时计数。

### P1 —— 热路径：转圈检测把最坏代价付在最常见的情况上

`-[CALayer addAnimation:forKey:]` 每次都要判定"这是不是转圈"，做法是遍历
superlayer 链（≤8 层），每层再顺着 `UIView.superview` 走（≤24 层）。

代价结构有个反直觉的地方：**判定"不是转圈"才是最贵的情况** ——
要走完整条链才发现不是。而列表滚动/页面切换时每秒几十次 `addAnimation:`
**全部是"不是转圈"**。最坏 8×24 = 192 次 `isKindOfClass:`，每秒数千次。

为了找到那 0.1% 的转圈，99.9% 的调用在付最坏代价。

### P1 —— 热路径：微信放大态探测每 0.25 秒全树 DFS

`SIO_wechatZoomPreviewActive()` 被 `SIO_blocked()` 调用，而 `SIO_blocked()`
是**每一个**动画/事务 hook 的入口。节流窗口到点后，它会做一次上限 3000 节点的
前台视图树 DFS。在微信里，这表现为与本项目毫无关系的界面也偶发掉帧。

### P1 —— 热路径：关联对象访问次数

`objc_get/setAssociatedObject` 走全局 `AssociationsManager`（自旋锁保护的哈希表）。
一次显式动画最多触碰 3 次，多线程同时播动画时是真实的锁竞争点。

### P2 —— 稳定性：`gPrefCache` 无保护并发读写 ⚠️

这条**不只是性能问题，是崩溃隐患**：

- 写入方：Darwin 通知回调线程（`SIO_settingsChanged` 里 `gPrefCache = nil`）
- 读取方：任意动画线程（`SIO_reload` → `SIO_prefSnapshot`）

ARC 下对 `__strong` 静态变量赋值会 `objc_release` 旧值。于是
「A 线程刚取出指针还没 retain」与「B 线程赋值触发 release」之间存在真实时间窗
→ 悬垂指针 → `EXC_BAD_ACCESS`。触发条件是"用户连续保存"遇上"目标 App 大量播动画"。
低概率、但无法从日志定位。

### P2 —— 配置 App：保存路径主线程同步 IO

`onSave` 最坏 5 次读 + 5 次写全在主线程同步执行。其中 `WriteConfig` 与
`WriteUIKitDrag` 的**两个路径常量指向同一个文件**
（都是 `/var/Managed Preferences/mobile/com.apple.UIKit.plist`），
等于同一份 plist 做了两轮完整的 read-modify-write。

### P2 —— watchdog 定时器常驻空转

`gWatchdog` 1.5s 重复定时器从构造期起就一直跑，而 `_fbg_watchdogFire` 首行是
`if (!gUseAudio || !gPhysBg) return;` —— **前台期间每 1.5 秒一次的唤醒 100% 是空转**。

---

## 二、逐项改动方案

### 改动 1：启动日志不再在 dyld 期做惰性求值

**位置**：`SIOriginalInit()` 末尾的 `NSLog`

**改法**：日志拆两段。构造期只打已算好的标量（全是静态读，零副作用）；
含 `SIO_framePeriod()` / `SIO_reduceMotionOn()` 的完整指纹延后到
`SIO_logFingerprintLater()`，走「启动完成之后」栅栏再打。

**预期提升**：消除 pre-main 的一次 UIScreen 初始化 + 一次私有框架 dlopen。
这两项都是**量级不确定但方向确定**的收益 —— dlopen 一个连带依赖的私有框架
在冷启动期通常是毫秒级；具体数值必须用本文第四节的方法在真机上测。

**兼容性 / 稳定性风险**：**低**。唯一可见变化是完整指纹日志晚了约 0.3 秒出现。
`SIO_framePeriod()` 的求值时机后移，不影响帧对齐结果（它只是读设备能力，
与调用时刻无关）。

**回滚**：把 `SIO_logFingerprintLater()` 换回原来的单行 `NSLog` 即可。

---

### 改动 2：iOS16Extras 约 55 次方法表交换搬出 pre-main

**位置**：`SIO_installiOS16Extras()` 的调用点

**改法**：
- 新增 `SIO_installLayerCoreHooks()`：只装 `-[CALayer addAnimation:forKey:]`
  与 `-[CALayer setSpeed:]`（2 次交换），**留在构造期**。
  理由：转圈/进度动画走前者，速率模式走后者，都是首屏就能感知的，不能延后。
- 其余约 55 次交换排到「启动完成之后」。
- 新增 `SIO_afterBoot()` 栅栏：以 `UIApplicationDidFinishLaunchingNotification`
  为准，**并挂 0.35s 超时兜底**，谁先到谁触发、只触发一次。

> 兜底是必需的，不是可选装饰：本 dylib 可能在 UIApplication 尚不存在时被注入，
> 该通知永远不会来。没有兜底的话，「延后安装」会退化成「永不安装」——
> 那比慢严重得多。

**预期提升**：pre-main 的方法表交换从约 80 次降到约 26 次（-67%）。
同时换方法表不再与首屏布局抢主线程，UIKit 方法缓存失效只发生一次。

**兼容性 / 稳定性风险**：**中**。
- 首屏最初 0.35 秒内，PA / UIScrollView / 控件系的动画不加速。
  列表内容本身异步填充，实测应无感知差异（与 v2.2.0 延后 27 次的判断同口径）。
- 若某个 App 在 `didFinishLaunching` 之前的极早期就用这些 API，会漏加速。
  属于"效果减弱"，不涉及崩溃。
- **必须真机验证**首屏转圈动画仍被加速（这是留 CALayer 两族在构造期的原因）。

**回滚**：把 `SIO_afterBoot(^{ SIO_installiOS16Extras(); })` 改回直接调用。

---

### 改动 3：转圈检测加 O(1) 前置筛

**位置**：`sio_layer_addAnim`，新增 `SIO_animMayBeSpinner()`

**改法**：先用两个零成本特征筛：`CAPropertyAnimation 子类` + `无限重复` +
`keyPath 含 rotation`。只有过了筛才去做昂贵的图层树确认。

**关键设计 —— 这个筛只做否定，不做肯定**：
- 命中筛 ≠ 确认是转圈，仍要过原来的 delegate 判定；
- 被筛掉的才直接判"非转圈"。
- 因此唯一风险是**漏判**（某个非典型转圈没被加速），不会**误判**
  （不会把普通动画当成转圈去套 0.4s 下限而把它变慢）。

漏判的后果（少加速一个动画）远轻于误判（把一个动画变慢），
后者与本项目"加速只能让动画变快"的核心不变量直接冲突。

**预期提升**（`tools/bench_v250.py` B1，10 万次调用样本）：
图层树遍历 **100000 → 2000（-98%）**，等价 `isKindOfClass:` 210 万 → 4.2 万。

**兼容性 / 稳定性风险**：**低**。
- 漏判场景：自定义转圈若不是"无限重复 + rotation"会不再被套 0.4s 下限，
  表现为按全局倍率加速（可能比现在更快，也可能因太短而频闪）。
  真机验证清单里应专门看转圈。
- `CAAnimationGroup` 包转圈的情况：外层是 group（不是属性动画）会被筛掉。
  这是已知的漏判边界，若真机发现转圈异常，放宽筛条件即可。

**回滚**：去掉 `SIO_animMayBeSpinner()` 这个条件。

---

### 改动 4：关联对象合并

**位置**：`SIODoubleBox` 新增 `scaled` 字段；删除 `kSIOScaledMark`

**改法**：「原时长」与「已缩放标记」共用一个盒子、共用一个关联键。

⚠️ **这里有个本轮实测出来的教训**：只把字段合并进盒子**一分钱都不省**。
`bench_v250.py` 第一版跑出来是 3 次 → 3 次。真正省的是让调用点的
「存原值 + 打标」**共用同一次 `SIO_boxFor`**。所以两个调用点都是手写 box 操作，
而不是各调一次 helper。

（顺序也有讲究：标记必须在调用原 IMP **之后**设置 —— 原 IMP 若抛异常，
不应留下"已处理"标记，否则 `addAnimation:` 兜底会误认为已缩放而跳过。）

**预期提升**（B3，按现实权重加权）：每次显式动画触碰全局关联表
**2.65 → 1.80（-32%）**。多线程动画时的锁竞争概率同比例下降。

**兼容性 / 稳定性风险**：**低**。语义完全不变（仍表示"该动画已被处理过"）。
唯一风险是改错了标记的置位时机，已按上文的顺序约束处理。

---

### 改动 5：微信放大态探测 —— 弱引用快路径 + 自适应间隔

**位置**：`SIO_wechatZoomPreviewActive()`

**改法**：
1. **弱引用快路径**：确认过的放大态 scrollView 记在 `gZoomCachedSV`（`__weak`）。
   后续探测只需一次弱引用读 + 三个属性读（O(1)）。被释放或缩回后自动回落 DFS
   —— 自愈，无状态残留。
2. **自适应间隔**：连续未命中时从 0.25s 逐级放宽到 2.0s；结果一旦翻转立刻回到 0.25s。

**预期提升**：放大态期间 O(1)；非放大态（绝大多数时间）DFS 频率降到约 1/8。

**兼容性 / 稳定性风险**：**中低**。
- **这是一处真实的行为放宽**：从"未放大"切到"放大"的识别延迟，
  最坏从 0.25s 变成 2.0s。该探测是防「微信预览页卡死」的安全网。
- 判断依据：放大态由用户双指捏合触发，动作本身远慢于 2s，
  2s 内必然已被下一次探测覆盖。
- 保守者可调小 `kZoomProbeMax`（当前 2.0）。

---

### 改动 6：`gPrefCache` 加锁 + 重载整体切主队列

**位置**：`SIO_prefSnapshot` / `SIO_invalidatePrefCache` / `SIO_settingsChanged`

**改法**：
- 所有缓存访问走 `os_unfair_lock`（无竞争时一条原子指令，不陷入内核）。
  **磁盘 IO 特意放在锁外** —— 把 mmap + plist 反序列化压在锁里，
  会让所有动画 hook 在重载瞬间集体阻塞，那比不加速更糟。
- `SIO_settingsChanged` 整段（失效缓存 → reload → 补装 hook → toast）
  切到主队列串行执行。

**为什么整段切主队列**：原实现在 Darwin 通知线程上做三件不该在那做的事 ——
① 同步磁盘读；② 连续改写 30 个全局配置变量（与正在读它们的动画线程竞争）；
③ `method_setImplementation`（改方法表应与 UIKit 主线程状态一致）。

**预期提升**：消除一处真实的崩溃风险；IO 不再阻塞通知线程；
配置生效延后一个 runloop turn（毫秒级，用户无感）。

**兼容性 / 稳定性风险**：**低**（修复方向，非权衡方向）。
唯一可见变化是保存后 toast 晚一帧。

---

### 改动 7：watchdog 随前后台启停

**改法**：新增 `_fbg_startWatchdog` / `_fbg_stopWatchdog`，
分别在 DidEnterBackground / WillEnterForeground 里调用；删掉构造期的常驻定时器。

**预期提升**：前台期间定时器唤醒次数降为 0。

**兼容性 / 稳定性风险**：**低**。行为完全等价 ——
定时器唯一能做事的条件就是 `gPhysBg == YES`，前台时它本来就什么都做不了。

---

### 改动 8：配置 App —— 缓存 + 主线程零 IO

**改法**：
- `ReadConfig()` 命中缓存时只做一次 `mutableCopy`（约 30 键，微秒级），
  不再走 mmap + plist 反序列化；写后失效。启动期预热一次。
- `WriteConfig(cfg, dragCoeff)`：把 `UIAnimationDragCoefficient` 并入同一次写入
  （原本与 `WriteUIKitDrag` 是同一个文件的两轮 read-modify-write）。
- `onSave` 改为「主线程收集 UI 状态 → 串行 IO 队列落盘 → 主线程反馈」。

**预期提升**（B4）：切过 4 个 Tab 的磁盘读 6 → 2（-67%）；
一次保存的写 5 → 4；主线程同步 IO 归零。

**兼容性 / 稳定性风险**：**低**。
- 串行队列同时保证"快速连点保存"不会并发写同一文件（原来是可能的）。
- `ReadConfig()` 返回的仍是可变副本，调用方改写不会污染缓存。
- 缓存失效走 `SIOInvalidateCfgCache()` 而非裸赋值：本函数跑在 IO 队列、
  缓存读取方在主线程，两者对同一个 `__strong` 静态变量并发访问会重演
  dylib 侧 `gPrefCache` 的 release 竞争。失效动作统一派发到主线程。

---

### 改动 9：UI 更新合并（防抖）

**位置**：`SIOVC`，新增 `-coalesce:block:`

**改法**：同一 runloop 轮次内同一类更新只保留一次，延到轮次末尾执行。
块内读取的是**执行时**的控件状态，所以丢弃中间请求不会丢帧、也不会显示中间值
—— 用户在意的只有停下来那一刻的最终值。

**诚实说明**：本页这些 handler 本身很轻（改一个短字符串），
**这项的绝对收益不大**。它主要把「每秒 120 次布局标记」降到「每帧至多 1 次」，
在长页面 + 大字号 + 动态类型下才看得出差别。列在这里是因为需求点名要，
但不应该把它算作主要收益。

---

### 改动 10：关于「虚拟滚动」—— 不适用，说明原因

需求里点名了「列表与长内容区域采用虚拟滚动」。**本项目不需要，也不应该加**，
说明如下：

- 配置 App 是**静态设置页**（几十行控件），没有任何长列表或可复用数据源；
  `UITableView`/`UICollectionView` 本身在 iOS 上就已做 cell 复用。
- dylib 侧**不渲染任何列表** —— 它只 hook 动画时长，不参与宿主 App 的
  列表数据源、cell 创建或布局。给它加虚拟滚动无处可加。

强行加的话反而是负优化：引入一层不在关键路径上的抽象。

真正与"列表性能"相关、且本轮确实做了的，是**降低列表 hook 在热路径上的代价**
（改动 3 的转圈前置筛，直接作用于列表滚动时的 `addAnimation:`）。

---

## 三、没有被改的地方（以及为什么）

诚实列出，避免把"没做"说成"做了"：

| 项 | 判断 |
|---|---|
| **槽位哈希**（`SIO_delegateIsSpinnerCandidate` / `_fbg_appState`） | 改了，但**经 `bench_v250.py` B2 验证：无显著收益**。原假设"低位区分度不足"不成立 —— 真实场景里遇到的不同类只有十余个，16 槽绰绰有余。代码注释里已明确标注"不计入收益"。保留仅为稳健 |
| **44 处 `CATransaction begin/commit` 的恒等短路** | 转场类的没加 `gAnimNoop` 短路。转场是低频操作（用户点一次才一次），加了也测不出差别；列表类已由 `SIO_listWrap` 覆盖 |
| **`_fbg_isBackgroundingDiff` 的 `description`** | 下游扫描已从 7 次降到 1 次定位 + 局部比较，但**上游 `[arg2 description]` 无法在本函数内消除**（调用方无条件生成）。要根治得改调用点，属于行为改动，本轮不做 |
| **悬浮球 `FBGFloatingWindow`** | 代码仍在（v1.8.10 起全局禁用，`gShowBall` 默认 NO）。是死代码，但删除涉及多处引用，与性能无关，本轮不动 |
| **`SIO_showInjectToast`** | 已确认是死代码（v2.0.5 移除启动 toast 后无人调用，只剩自递归）。本轮不动，仅记录 |

---

## 四、测试验证方式与性能指标测量方法

分三层：**能自动跑的**（CI 里会失败的断言）→ **真机上可复算的**（日志/工具）
→ **主观体感**（必须真人确认）。

### 层 1：自动化（无需设备）

```bash
python3 tools/static_check.py .      # 括号/原IMP判空/hook配对（既有）
python3 tools/check_v210.py          # v2.1.0 语义不变量（既有）
python3 tools/test_frame_align.py    # 帧对齐三不变量（既有）
python3 tools/check_v250.py .        # 新增：v2.5.0 性能不变量 ×9
python3 tools/bench_v250.py          # 新增：算法层基准 ×4，未达标即失败
```

已接入 `build.sh` 与 `.github/workflows/build.yml`。

**`check_v250.py` 的有效性已用注入错误验证过**：故意把 `SIO_framePeriod()`
塞回构造函数 `NSLog`、把 `gPrefCache` 改回裸赋值，脚本能报出 3 条并返回退出码 1。
（这一步是必须的 —— 本项目历史上出现过"检查脚本自身有 bug 而误报"的情况，
见 v2.0.6 的 audit_dylib 解析器事故，所以新脚本一律先自证有效性。）

### 层 2：真机指标（可复算）

本轮在 dylib 里加了两个运行时计数器，直接打进延后的启动指纹日志：

```
swaps=<N>    # 实际发生的方法表交换次数（构造期 + 延后期累计）
bootMs=<F>   # 两个 constructor 自身消耗的挂钟毫秒数
```

**测量协议（改前/改后各跑一次，同一设备、同一 App、同一配置）：**

| 指标 | 怎么取 | 判据 |
|---|---|---|
| **pre-main 方法表交换次数** | Console 里 grep `fingerprint`，读 `swaps=` | v2.4.0 约 80 → v2.5.0 约 26。**注意要在日志出现的那一刻读**（延后批次在启动后约 0.3s 追加） |
| **注入库自身 pre-main 耗时** | 同上，读 `bootMs=` | 应显著下降（UIScreen 初始化 + dlopen 被移出） |
| **App 冷启动到首帧** | Instruments → App Launch 模板；或 `XCTest` 的 `measure(metrics: [XCTApplicationLaunchMetric()])` | 取 10 次中位数（首次冷启动含 dyld 预热，剔除） |
| **主线程阻塞** | Instruments → Time Profiler，开 `Main Thread Check`；或用 `os_signpost` 包住 `SIO_blocked()` 采样 | 主线程 >16.7ms 的卡顿次数应下降 |
| **掉帧率** | Instruments → Core Animation FPS；或 `CADisplayLink` 打点统计帧间隔 > 32ms（60Hz 下掉 2 帧）的比例 | 列表快速滚动 + 微信图片浏览两个场景分别测 |
| **内存** | Instruments → Allocations / Leaks；看 `SIODoubleBox` 实例数与常驻内存 | 不应增长（本轮未新增常驻结构；`gZoomCachedSV` 是弱引用） |
| **磁盘 IO（配置 App）** | Instruments → File Activity；或 `fs_usage` 抓 `com.apple.UIKit.plist` 的 open 次数 | 切 4 个 Tab：6 次 → 2 次 |

**关键对比场景（每个都要改前/改后各录一段）：**
1. 目标 App 冷启动（看 `swaps=` / `bootMs=` / 首帧时间）
2. 长列表快速滚动（看 FPS 与主线程卡顿）
3. 加载页转圈（**确认转圈仍被加速** —— 这是改动 3 漏判风险的直接验证）
4. 微信图片放大/缩小（改动 5 放宽了探测灵敏度，必须确认预览页不卡死）
5. 配置 App 连点保存 5 次（验证串行队列无写覆盖、主线程不卡）

### 层 3：体感确认（不可自动化）

- 转圈动画：**必须真人看**。改动 3 有漏判风险，自动化测试测不出"这个转圈
  现在看起来快了还是慢了/频闪了"。
- 首屏是否"少加速了"：改动 2 让 PA/ScrollView/控件系延后约 0.3s，
  需要真人确认首屏动画观感无变化。
- 微信预览页：改动 5 的行为放宽只能靠真人操作确认。

### 回归判定

| 检查 | 不通过则 |
|---|---|
| 转圈不再被加速 / 频闪 | 放宽 `SIO_animMayBeSpinner()` 的条件（去掉 rotation 限制） |
| 首屏动画明显未加速 | 把 `SIO_installiOS16Extras()` 改回构造期直接调用 |
| 微信预览页卡死 | 把 `kZoomProbeMax` 调回 0.25 |
| `swaps=` 没降 | 检查 `SIO_afterBoot` 是否被正确调用（看日志里是否有 deferred 安装记录） |

---

## 五、改动清单（文件级）

| 文件 | 改动 |
|---|---|
| `Tweak/SIOriginal.m` | 改动 1–7；新增 `SIO_afterBoot` / `SIO_logFingerprintLater` / `SIO_markDyldCost` / `SIO_installLayerCoreHooks` / `SIO_animMayBeSpinner` / `SIO_invalidatePrefCache` / `_fbg_startWatchdog` / `_fbg_stopWatchdog`；`SIODoubleBox` 加 `scaled`；删除 `kSIOScaledMark`；新增 `gBlacklistItems` / `gReloadDone` / `gImplicitActionDur` / `gSIOHookSwapCount` / `gSIODyldCostMs` |
| `App/main.m` | 改动 8–9；`ReadConfig` 缓存；`WriteConfig` 增加 `dragCoeff` 参数；新增 `SIOIOQueue` / `WriteConfigOnly`；`onSave` 改异步；新增 `-coalesce:block:` |
| `tools/check_v250.py` | 新增：性能不变量核查 ×9 |
| `tools/bench_v250.py` | 新增：算法层基准 ×4 |
| `build.sh` / `.github/workflows/build.yml` | 接入上述两个脚本 |
| `PERFORMANCE.md` | 本文档 |
