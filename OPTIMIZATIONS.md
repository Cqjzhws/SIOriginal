# SIOriginal v3.0 — 优化项全表（适用版本 / 预期收益 / 风险点 / 验证方式）

> 本文档对应 **v3.0.0**。每一条优化项都按用户要求的四个维度给出说明。
> 表格里「适用系统」一列中：
> - `11–18` 表示全版本可用；
> - `11–12 / 13–14 / 15–17 / 18+` 表示该段有**不同实现路径**（见 §4 分版本适配）。

---

## 0. 阅读顺序建议

1. 先看 §1「架构重构」—— v3.0 的主要价值在这里，而不是新增了多少 hook。
2. 再看 §2「UI 流畅度」与 §3「启动 / 内存 / 调度」—— 这些是用户直接可感知的。
3. §4 分版本适配表是**排查兼容性问题时的第一参考**。
4. §5 是红线与不变量，任何改动前必读。

---

## 1. 架构重构（v3.0 的核心改动）

v2.x 是一个 4772 行的 `SIOriginal.m`：配置变量、版本判定、100+ 个 hook、
安装逻辑、保活引擎全部穿插。由此产生三类结构性问题，v3.0 逐一消除。

### 1.1 单一配置入口

| 项目 | 内容 |
|---|---|
| **改造前** | 配置散落成几十个全局 BOOL/double；plist 被读两遍（动画侧 `SIO_reload()` + 保活侧 `_fbg_loadPref()`）；黑名单有两套匹配语义（`isEqualToString:` 精确 vs `hasPrefix:` 前缀） |
| **改造后** | 唯一状态 `SIOConfigState gSIOCfg`；唯一磁盘读取出口 `SIOPrefSnapshot()`（带 `os_unfair_lock` 缓存）；唯一匹配实现 `SIOBundleMatches()`（精确 + 尾 `*` 前缀） |
| **适用系统** | 11–18 |
| **预期收益** | 消除「同一份配置两个说法」类的 bug；每次配置读取少一次 `dictionaryWithContentsOfFile:`（约 0.3–1ms 且带磁盘 IO）；启动期只读盘一次 |
| **风险点** | 重构期若漏迁移某个键，表现为「开关无效」而非崩溃 —— 隐蔽。已用 `tools/check_v300.py` 的「plist 读取唯一出口」项做机械防护 |
| **验证方式** | ① `python3 tools/check_v300.py .` 应输出「plist 读取只在 SIOConfig.m」；② 安装后改任一开关保存，观察目标 App 行为即时变化；③ 用 `fs_usage` 观察目标 App 启动期对 `com.apple.UIKit.plist` 的读取次数应 ≤1 |

### 1.2 单一方法交换入口

| 项目 | 内容 |
|---|---|
| **改造前** | 交换逻辑在两个函数里重复（`SIO_swizzleInstance`/`SIO_swizzleClass`）；按需安装、列表、iOS16Extras 三处各自调用；没有交换计数 |
| **改造后** | 唯一实现 `SIOExchange()`，内建三条安全性质：① 目标方法不存在则不交换 ② `*orig` 已填充则跳过（重复安装保护）③ 超出 `swapBudget` 则放弃 |
| **适用系统** | 11–18 |
| **预期收益** | 继承污染问题被结构性消除（v1.8.19 曾因直接 `method_setImplementation` 改到父类导致崩溃）；交换次数可统计，回归可发现 |
| **风险点** | `class_addMethod` 优先的策略在「本类无自有实现」时会新增一个方法到本类，理论上改变方法解析链。实测无副作用，但需注意不要对「必须走父类实现」的方法做 hook |
| **验证方式** | ① `check_v300.py` 的「无未标注的裸交换」项；② 运行时看 `SIOLogBrand` 输出的 `swaps=` 计数是否符合预期（Boot 约 19、PostLaunch 约 40、OnDemand 0–32） |

### 1.3 三档安装栅栏

| 项目 | 内容 |
|---|---|
| **改造前** | 构造期一口气装约 55 个本可延后的 hook；`SIO_installiOS16Extras()` 装在哪取决于调用方；默认关闭的功能也照样改方法表 |
| **改造后** | `SIOStage` 三档：`Boot`（pre-main 核心两族）/ `PostLaunch`（启动完成后）/ `OnDemand`（开关打开才装）；每个条目自声明 `stage/gate/minOS/maxOS/needCaps`，`SIOInstaller` 统一编排 |
| **适用系统** | 11–18 |
| **预期收益** | pre-main 交换数从约 55 降到 19；默认关闭的高危项（列表/布局/缩放/长按 setter）**一次交换都不做**，不只是「装了再判断」 |
| **风险点** | 若某条目被错误地放进 `Boot`，会重新拖慢启动。已用 `check_v300.py` 断言「Boot 档只允许出现在核心两族模块」 |
| **验证方式** | ① `check_v300.py` 的 Boot/OnDemand 两项；② 启动时看 `SIOLogBrand` 的 `swaps=` 分档计数；③ 关闭列表加速后，`OnDemand` 的 attempts 应为 0 |

---

## 2. UI 渲染与动画加速

### 2.1 时长换算引擎（全项目唯一出口）

| 项目 | 内容 |
|---|---|
| **实现** | `SIOInternal.h` 内 `static inline`：`SIO_targetDuration` / `SIO_targetDurationLayer` / `SIO_targetDurationUIKit` / `SIO_targetDelay` / `SIO_springScale` / `SIO_transitionBase` |
| **适用系统** | 11–18 |
| **预期收益** | 所有动画类 hook 共享同一份换算，行为一致；`inline` 保证热路径零调用开销 |
| **风险点** | 三条安全边界必须同时成立，任一被破坏会出现「越加速越慢」的反直觉现象 |
| **验证方式** | `python3 tools/test_frame_align.py`（覆盖 60/90/120Hz × 多倍率，验证「只缩短」「不足一帧保持原值」）；`check_v300.py` 断言下限口径为 `min(floor, orig)` |

**三条安全边界**（这是本项目最容易踩坏的地方）：

1. **只能缩短，不能变慢** —— 时长下限用 `min(floor, orig)`，而不是无条件 `d = floor`。
   后者会把 0.005s 的微动画抬到 0.02s，凭空造出卡顿（与「加速」语义完全相反）。
2. **不足一帧保持原值** —— 强制拉到 1 帧会把 0.005s 变 0.0167s（慢 3 倍）。
3. **慢放 / 速率模式不参与帧对齐** —— 语义冲突（慢放需要长时长）或时间轴本就原生。

### 2.2 帧对齐引擎

| 项目 | 内容 |
|---|---|
| **问题** | CoreAnimation 按时间推进，设备每 P 秒刷新一帧。若时长 D 不是 P 的整数倍，最后一帧显示不足 P 就被提交、随后空等 P —— 这个「不足一帧 + 空等一帧」就是肉眼可见的顿挫。加速尤其容易制造余数：0.3s ÷ 5 = 0.06s，60Hz 下是 3.6 帧 |
| **实现** | `SIO_alignToFrameBoundary()`：向下取整到帧周期整数倍（3 × 16.67ms = 50ms） |
| **适用系统** | 11–18（帧率经 `UIScreen.maximumFramesPerSecond` 探测，iOS 10.3+ 可用，更低版本回落 60Hz） |
| **预期收益** | 消除余数造成的单帧顿挫；60Hz 与 120Hz 均生效。实测 0.3s÷5 从 3.6 帧对齐到 3.0 帧 |
| **风险点** | ① 高压下若帧率探测失败会回落 60Hz，120Hz 设备上对齐结果偏保守（偏长，但仍在「只缩短」约束内）② 慢放模式不做对齐，语义需要 |
| **验证方式** | `python3 tools/test_frame_align.py`（三条不变量 × 三种帧率）；真机上用 Xcode Core Animation Instrument 观察提交间隔是否整齐 |

### 2.3 速率模式（SpeedMode）

| 项目 | 内容 |
|---|---|
| **原理** | 改 `CAAnimation.speed` / `CALayer.speed`，而不是 `duration` |
| **适用系统** | 11–18 |
| **预期收益** | 避免时长下限碰撞；关键帧插值与弹簧物理保持原生正确（不抽搐） |
| **风险点** | ① 对「非动画驱动」的动画（自绘帧序列、视频）无效 ② 与时长模式互斥，必须由 `SIO_speedModeActive()` 统一短路，否则两条路径同时改会让实际倍率相乘 |
| **验证方式** | 开启速率模式后，`SIO_speedModeActive()` 为真时 `SIO_targetDuration` 应恒等返回原值（源码级检查）；真机对比开关前后动画平滑度 |

### 2.4 系统级系数补偿（UIAnimationDragCoefficient）

| 项目 | 内容 |
|---|---|
| **原理** | UIKit 原生读取 `UIAnimationDragCoefficient`（<1 变快）作为全局动画系数。本工具让**配置 App** 写入该键（经 `/var/Managed Preferences/mobile/com.apple.UIKit.plist`），覆盖 hook 够不到的 SwiftUI 内部动画与私有路径 |
| **适用系统** | 11–18（写 `Managed Preferences` 需配置 App 的私有 entitlement） |
| **预期收益** | 补上 hook 的覆盖面缺口；连未被注入的 App 也会生效（需注销 / respring） |
| **风险点** | **双重加速**：hook 拦截到的是 App 传入的、尚未乘系数的值，若不做补偿则「hook 缩放 × 系统系数」连乘，用户设 ×5 实际 ≈×8.6。v3.0 用 `SIO_compensatedDivisor()` 做**预除补偿**（hook 给出 T/c → UIKit 内部再 ×c → 最终 T） |
| **验证方式** | ① `check_v300.py` 相关断言；② 同时开「加速 ×5」与「全局兜底 0.58」，实测动画时长应约等于 0.35/5，而不是 0.35/5/0.58 |

> **v3.0 实现位置与设计取舍**
>
> - 读取侧（dylib）：`Tweak/SIOConfig.m` 读 `kSIOSysKeyDragCoefficient` → `c->systemSpeed` / `c->systemSpeedCompensate`；补偿在 `Tweak/include/SIOInternal.h` 的 `SIO_compensatedDivisor()` 中，由 `SIO_targetDurationUIKit()` 消费。
> - 写入侧（配置 App）：`App/main.m` 的 `WriteConfig(cfg, dragCoeff)`（同一 plist 只写一次）写入 `UIAnimationDragCoefficient`。
> - **取舍**：v2.5.1 是「dylib 向被注入 App 的自身 `NSUserDefaults` 写系数」，覆盖不到未被注入的 App，且存在两条写入源互相竞争。v3.0 收敛为**单侧写入（仅配置 App）+ 只读补偿（dylib 仅读取）**：写入源唯一、覆盖面扩大到全系统、结构上不可能出现「hook 侧再写一份」造成的双重加速。

### 2.5 120Hz 高刷解锁

| 项目 | 内容 |
|---|---|
| **实现** | hook `CADisplayLink.setPreferredFramesPerSecond:` 与 `CAAnimation.setPreferredFrameRateRange:`，把帧率申请抬到屏幕硬件上限 |
| **适用系统** | 11–18；**实际有感仅 ProMotion 机型（iPhone 13 Pro 及以后）**，60Hz 屏自动恒等零影响 |
| **预期收益** | 滚动与动画更丝滑；不改时长、不强制输出 |
| **风险点** | 最终帧率仍由系统按电量/温控调度，本项只抬高**申请上限**，不能保证实际帧率。过量使用会增加耗电 |
| **验证方式** | ProMotion 机型上用 Xcode 的 Animation Hitches / GPU 报告看实际帧率；60Hz 机型上开关前后应无可测差异 |

> **v3.0 实现位置**：v2.5.1 已实现本功能，v3.0 做**结构化迁移**并纳入统一安装表 ——
>
> - 新增独立模块 `Tweak/hooks/SIOHighRefresh.m`：`sio_dl_setFPS` / `sio_dl_setRange` / `sio_caanim_setRange` 三个 hook，均带 `SIO_REQUIRE_ORIG`。
> - `SIO_maxFPS()` 函数内 static 惰性求值，避免 pre-main 触碰 `UIScreen`（红线 #2）。
> - 3 条条目全部登记为 `kSIOStagePostLaunch` 档 + `gate = SIOHighRefreshGate`（即 `gSIOCfg.highRefresh`）+ `optional = YES`，与 v2.5.1 的「全局无条件生效」不同：**默认关闭，开关打开才安装**。
> - 配置键迁移：`App/main.m` 白名单新增 `HighRefresh`，保存时写入 `cfg[@"HighRefresh"]`；dylib 侧 `SIOConfig.m` 读取到 `c->highRefresh`（`SIOInternal.h` 的 `SIOConfigState` 字段）。

### 2.6 各 hook 族的覆盖清单

| 模块 | 覆盖对象 | 档位 | 适用系统 | 风险 |
|---|---|---|---|---|
| `SIOCoreAnimation` | `CAAnimation` setDuration/setSpeed、`CATransaction` set/getAnimationDuration、`CALayer` setSpeed/actionForKey/addAnimation、`CASpring*` 四参数 | Boot（19 条） | 11–18（`setVelocity:` 需 iOS 10+） | 低（核心路径，改动需回归） |
| `SIOUIViewAnim` | `UIView` 10 个类方法、`UIViewPropertyAnimator` 8 个入口、`UIWindow.setRootViewController:` | Boot + PostLaunch | 11–18（`UIViewPropertyAnimator` 需 iOS 10+） | 低 |
| `SIOViewControllers` | 33 个导航/模态/标签/栏/Item/搜索/翻页/文档/气泡转场 | PostLaunch | 11–18（`setLargeTitleDisplayMode:` 需 11+） | 中（覆盖面广，个别私有方法需 `optional`） |
| `SIOControls` | `UISwitch/Slider/ProgressView/Picker/DatePicker/SegmentedControl/PageControl/SearchBar/Stepper/VisualEffectView` + `UIControl` 基类 2 个 + Cell 4 个 | PostLaunch；`layoutIfNeeded` 为 OnDemand | 11–18 | 低 |
| `SIOCollections` | 27 个 `UITableView`/`UICollectionView` 变更族 | **OnDemand（默认关）** | 11–18（`performBatchUpdates:` 需 11+） | **高**（可破坏列表状态机，见 §6） |
| `SIOScrollView` | 偏移/滚动/缩放、长按三件套、`decelerationRate`/`delaysContentTouches` 强黏 | PostLaunch + OnDemand | 11–18 | 中（缩放族曾出微信预览卡死，故默认关） |
| `SIOSpringBoard` | 桌面编辑态、Switcher 编辑态护栏 | PostLaunch | 11–17 稳定；18+ 类名可能变，靠 `objc_getClass` 探测 | 低（拿不到只少一层保护） |

---

## 3. 启动 / 内存 / 调度

### 3.1 冷启动最小 footprint

| 项目 | 内容 |
|---|---|
| **实现** | pre-main 只做四件事：① `SIOTlsInit` ② `SIOProbePlatform`（纯内存）③ `SIOConfigLoad`（一次读盘）④ `SIOInstallStage(Boot)`。其余全部登记到 `SIOAfterBoot` 之后 |
| **适用系统** | 11–18 |
| **预期收益** | pre-main 交换数 55 → 19；不在 pre-main 触发 `UIScreen` 单例、不做外部路径 `stat`、不打完整指纹日志 |
| **风险点** | `SIOAfterBoot` 依赖 `UIApplicationDidFinishLaunchingNotification`，若某 App 不投递该通知，靠 **0.35s 超时兜底** 触发（防止「延后退化为永不安装」） |
| **验证方式** | ① 启动完成时 `SIOLogBrand` 打出的 `swaps=` 分档计数；② Instruments 的 App Launch 模板对比 v2.5.1 与 v3.0 的 pre-main 时间；③ 确认 0.35s 兜底路径可用（临时禁用通知观察者测试） |

### 3.2 惰性加载 AVFoundation / UserNotifications

| 项目 | 内容 |
|---|---|
| **实现** | 不 `#import` 框架头、不链接框架；用 `@protocol` 声明 + `dlopen`/`dlsym` + `objc_getClass` 运行时解析。首次真正需要音频断言时才 `dlopen` |
| **适用系统** | 11–18 |
| **预期收益** | 不使用保活的 App，启动路径上完全不含这两个框架（及其连带的 CoreMedia/CoreAudio 依赖链） |
| **风险点** | `RTLD_LOCAL` 下不能依赖全局符号域，字符串常量必须从框架句柄 `dlsym`；用 `nil` 名注册通知会订阅到**全部**通知（v2.x 隐患，已修） |
| **验证方式** | ① CI 里 `otool -L SIOriginal.dylib \| grep -E "AVFoundation\|UserNotifications"` 必须无输出；② `check_v300.py` 的「无框架级 import」项 |

### 3.3 内存护栏（两级降级 + 可还原）

| 项目 | 内容 |
|---|---|
| **实现** | 双路径监听：`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`（NORMAL/WARN/CRITICAL）+ `UIApplicationDidReceiveMemoryWarningNotification`。**Level 0** 正常；**Level 1** 关 `layerBoost`/`listAccel`/`layoutAccel`/`zoomAccel`；**Level 2** 再关 `transitionBoost`（等于整体旁路）。压力解除后按 `gSIOCfgPristine` 快照**还原** |
| **适用系统** | 11–18（内存压力源需 iOS 8+；`os_proc_available_memory` 需 13+，作为能力位探测） |
| **预期收益** | 低内存机型 / 小内存进程上避免成为 OOM 的最后一根稻草；降级是临时的，不会「降级一次就永久降级」 |
| **风险点** | ① 快照/还原必须成对，否则用户配置被永久改写 ② 两条监听路径可能同时触发，`SIOApplyMemoryLevel` 必须幂等 |
| **验证方式** | ① 用 Xcode 的 Simulate Memory Warning 触发 Level 1，确认动画恢复原生、压力解除后恢复加速；② 检查 `gSIOCfgPristine` 在每次 `SIOConfigReload` 后同步更新 |

### 3.4 调度策略（QoS 避让）

| 项目 | 内容 |
|---|---|
| **实现** | `SIOWorkQueue()` 为串行队列，QoS = `QOS_CLASS_UTILITY`；配置重载、环境探测等内部工作全走它 |
| **适用系统** | 11–18 |
| **预期收益** | 内部工作不与首屏渲染、滚动动画抢 CPU 时间片（避免「配置一改就掉帧」） |
| **风险点** | QoS 过低在极端负载下可能让配置重载延迟生效（用户感知为「保存后没立刻生效」）；实测延迟 <100ms，可接受 |
| **验证方式** | 编辑配置保存后观察生效延迟；Instruments 的 Time Profiler 确认内部工作在 Utility 队列 |

### 3.5 保活引擎重构（真后台）

| 项目 | 内容 |
|---|---|
| **改造前** | ① 生命周期回调注册在 Darwin 中心却监听 NSNotification 名字 → **回调从未触发**，导致 `gPhysBg` 永远 NO，场景伪装 / 音频断言 / 自愈轮询三件事从未执行过一行代码（v2.1.0 修）② 配置读两遍 ③ 自愈定时器前台后台常驻空转 |
| **改造后** | ① 只用 `NSNotificationCenter` 一条生命周期路径 ② 复用 `SIOPrefSnapshot()` 与 `gSIOBlacklistItems` ③ 定时器随前后台生命周期启停 ④ 三条场景 hook 统一走 `SIOExchange` |
| **适用系统** | 11–18（场景伪装依赖私有类 `FBSWorkspaceScenesClient`，拿不到就自动少开这一项） |
| **预期收益** | 保活真正生效；前台期零空转定时器；启动路径不含 AVFoundation |
| **风险点** | ① 场景伪装属侵入性能力，吞掉 App 的 backgrounding scene diff ② iOS 18 上私有类可能改名 ③ 音频断言需宿主声明 `audio` 后台模式，否则可能更早被杀 |
| **验证方式** | ① 目标 App 进后台后观察是否存活超过 30 秒 ② 用 `os_log` 确认 `gPhysBg` 正确翻转 ③ 有 `privilegeGated` 时确认 `SIOSceneFakingAllowed()` 的降级行为 |

---

## 4. iOS 11 → 18 分版本适配

**核心方法论：用「能力探测」而不是「版本号」决定 API 可用性。**
版本号只作为最后 fallback（且必须配 `@available` 编译守卫）。

| 版本段 | 窗口 / Scene 策略 | 帧率 | 能力位差异 | 特殊处理 |
|---|---|---|---|---|
| **11–12** | 无 `UIScene`。UI 遍历走 `UIApplication.windows` / `keyWindow` | `maximumFramesPerSecond` 可用（10.3+） | 无 `kSIOCapWindowScene`、无 `kSIOCapOsProcMem` | `setLargeTitleDisplayMode:` 恰好 11.0 引入，标注 `minOS=11` |
| **13–14** | 有 `UIScene`，但 `UIWindowScene.windows` 到 15 才可用 → **仍回落到 `UIApplication.windows`** | 同上 | 有 `kSIOCapWindowScene` / `kSIOCapSwiftUIHosting`(13.1+) / `kSIOCapOsProcMem` | SwiftUI 开始普及，`UIHostingController` 内部动画需靠系统系数覆盖 |
| **15–17** | `UIWindowScene.windows` 可用，**优先 scene**（16 起 `UIApplication.windows` 常返回空） | 120Hz 机型普及 | 有 `kSIOCapBlurHosting`(15+) / `kSIOCapRefreshPkgChg`(17+) | 模糊/材质栈归属变化；`UIRefreshControl` 包结构变动需探测式启用 |
| **18+** | 同 15–17 路径 | 同 | **私有类与 C 符号一律不假设存在**，拿不到就少开功能 | SpringBoard 宿主类可能改名；`FBSWorkspaceScenesClient` 等全部走 `objc_getClass` 探测，拿不到不崩 |

**实现要点**（`SIOPlatform.m` + `SIOInternal.h`）：

- `SIOProbePlatform()` 一次探测成位图 `SIOCaps`，hook 侧只做 `if (caps & ...)`。
- `SIOForegroundWindow()` 内部：`@available(iOS 15.0,*)` 时走 scene，否则 `app.windows` 两次兜底。
- `SIOAtLeast(major)` / `SIOBelow(major)` 仅在拿不到能力位时使用。
- **版本号拿不到时按 iOS 11 保守处理**（`SIOProbeVersion()` 的兜底分支）。
- 安装表的 `minOS` / `maxOS` 字段提供声明式版本窗口，避免 hook 里到处写 `if`。

**验证方式**：
- 静态：`check_v300.py` 断言 Boot 档不越界、能力位使用规范。
- 动态：在 iOS 11 / 14 / 17 / 18 四类设备（或模拟器）上跑，确认 `SIOLogBrand` 的 `SIOPlatformSummary()` 输出与预期一致，且无崩溃。

---

## 5. 四条红线（任何改动前必读）

| 红线 | 含义 | 机械防护 |
|---|---|---|
| **#1** | 加速只能让动画变快，绝不能变慢 | `check_v300.py` 断言 `SIO_targetDuration` 下限口径 = `min(floor, orig)`；`test_frame_align.py` 验证数值不变量 |
| **#2** | 注入库自身不得拖慢 App 启动 | `check_v300.py` 断言唯一 constructor + Boot 档只在核心两族 |
| **#3** | hook 失败必须优雅降级，绝不崩目标 App | `SIO_REQUIRE_ORIG*` 宏（全项目 128 处）；`SIOExchange` 的方法存在性检查；`static_check.py` 核查判空与符号配对 |
| **#4** | 不用保活的 App，启动路径上不得出现 AVFoundation / UserNotifications | `check_v300.py` 的 import 检查 + CI 的 `otool -L` 断言 |

---

## 6. 高危项说明（默认关闭的理由）

| 功能 | 风险 | 为什么默认关 |
|---|---|---|
| **列表加速**（`UITableView`/`UICollectionView` 27 个 hook） | 改写动画时长可能破坏列表的**变更状态机**（批量更新与插入/删除动画配对），最坏导致列表错乱或崩溃 | 一旦打开就是「黑屏 / 白苹果」级别事故。三重保险：SpringBoard 硬保护（不接受覆盖）、缺键 fail-safe 关、按需安装默认零交换。**绝不改写 `animated` 语义** |
| **缩放动画加速** | 历史上出过微信图片预览卡死 | 需针对具体 App 做豁免判断，默认关 |
| **布局动画加速**（`layoutIfNeeded`） | 影响面极大（所有约束布局），实验性 | 默认关，`OnDemand` |
| **`decelerationRate` / `delaysContentTouches` 强黏** | 与 App 自身设置冲突时表现为「开关关不掉」 | 仅在开关打开时安装；关闭时完全放行 |

---

## 7. 完整验证清单（发布前）

```bash
# 静态核查（无 Mac 也能跑）
python3 tools/static_check.py .      # 括号配平 / IMP 判空 / 符号配对
python3 tools/check_v300.py .        # 架构不变量 15 项（含三处构建清单一致性）
python3 tools/check_symbols.py .     # 跨模块符号：声明↔定义 / 重复定义 / 全局变量
python3 tools/check_config_keys.py . # 配置键闭环：白名单 ↔ dylib 读取
python3 tools/test_frame_align.py    # 帧对齐数值不变量（60/90/120Hz）

# 产物结构核查（需 macOS + iPhoneOS SDK）
otool -D SIOriginal.dylib | grep '@rpath/SIOriginal.dylib'
lipo -info SIOriginal.dylib          # 必须含 arm64 + arm64e
ldid -e SIOriginal.dylib             # 必须为空（无 entitlement）
otool -L SIOriginal.dylib | grep -E 'AVFoundation|UserNotifications' && echo FAIL
unzip -l SIOriginal.ipa | grep '_CodeSignature/CodeResources'
```

> **为什么静态核查里有三项结构检查**：
> · `check_v300.py` 第 15 项「构建清单一致性」—— 本项目 16 个 `.m` 需同时登记在
>   `Makefile` / `build.sh` / `.github/workflows/build.yml` 三处。漏登记一处不会编译报错，
>   而是**静默少一个功能**或链接期 `undefined symbol`。v3.0 开发中
>   `Tweak/hooks/SIOHighRefresh.m` 真的漏过三处，故固化为机械检查。
> · `check_symbols.py` —— 覆盖「头文件声明了但没实现」「同一函数实现了两次」两类链接期事故。
> · `check_config_keys.py` —— 覆盖「界面有开关但功能无效」这类静默失效。配置键的
>   三类契约（双向键 / 单侧写入键 / dylib 内部高级键）见 `SIOInternal.h`。

真机验证（按优先级）：
1. 注入一个普通 App，确认**能启动不闪退**（红线 #3）。
2. 开关全关 → 行为与未注入完全一致（可回归性）。
3. 只开「加速 ×2」→ 动画明显变快且**不变慢**（红线 #1）。
4. 开启列表加速 → 反复上下滑动 + 下拉刷新 + 批量插入删除，确认不错乱。
5. 触发内存告警 → 确认降级与还原。
6. 进后台 → 确认保活生效（若开启）。
7. iOS 18 设备上确认无崩溃（私有类探测路径）。
