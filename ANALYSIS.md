# SIOriginal v2.0.6 二进制审计报告

审计对象：`SIOriginal.dylib`（498,064 字节）、`SIOriginal.ipa`（109,532 字节）
审计方式：Mach-O 逐字节结构解析 + 源码静态核查（无编译环境，故未做符号级反汇编）

---

## 一、dylib 文件布局

v2.0.6 发布的 dylib 是标准的双架构 FAT 二进制，**两个 slice 均有效**：

```
偏移        大小         内容
0x00000     48 B         FAT 头（8B 头 + 2 × 20B fat_arch 条目）
0x00030     16,336 B     零填充（对齐到 2^14）
0x04000     238,016 B    slice A — arm64
0x3DFC0     7,744 B      零填充（slice B 对齐到 2^14 所需）
0x40000     235,920 B    slice B — arm64e，含 __auth_stubs / __auth_got
0x79990     —            文件结束（262,144 + 235,920 = 498,064，精确到字节）
```

正确的 FAT 架构表（大端）：

```
[0] cputype=0x0100000C (arm64)  subtype=0x0        offset=16,384  size=238,016  align=2^14
[1] cputype=0x0100000C (arm64e) subtype=0x80000002 offset=262,144 size=235,920  align=2^14
```

两个 slice 各含 **139 个 `_sio_*` 符号**，功能完全相同（日志文案逐字一致），
差别仅在 slice B 多了 arm64e 指针认证段。`arm64` 与 `arm64e` 在 139 个功能符号上
**逐一对应，无一方独有**。

### 更正：本节此前「FAT 第 2 条目畸形」的结论是错的

本报告旧版本声称第 2 条目「声明 x86_64、offset=235,920 指向 ASCII 字符串
`ppOverride`、是畸形条目」，并据此推断「文件尾部 243,664 字节（48.9%）冗余」。
**两条都是审计脚本 v1 的解析 bug 造成的误报，产物本身完全健康**：

1. Apple 标准 `struct fat_arch` 就是 **20 字节、无 reserved**（reserved 只存在于
   `fat_arch_64` 的 32 字节条目）。审计脚本 v1 误按 24 字节步长解析，
   第 2 条目整体错位 4 字节：arm64e 的 cpusubtype `0x80000002` 被读成 cputype
   （于是错标为 x86_64）、size `235,920` 被读成 offset。
2. 偏移 235,920 落在 slice A（16,384..254,400）内部的 `__objc_methname`
   字符串区 —— 所以"指向 ASCII 文本"是错位解析的必然结果，而非条目损坏。
3. 「尾部 243,664 字节冗余」同样是误算：把第 2 条目的 size 误读为 14 后，
   覆盖区间在 254,400 处中断，498,064 − 254,400 = 243,664 被错算成"冗余"。
   实际两个条目 size 之和 + 头部与对齐空隙 = 文件全长，精确吻合，无冗余。

字节级验证：262,144 + 235,920 = 498,064 = 文件总长，且偏移 262,144 处是合法的
小端 Mach-O 64 头（cputype/subtype 与 FAT 表声明一致）。
`tools/audit_dylib.py` 已修正解析，并配 `tools/test_audit_dylib.py` 回归测试。

### 空隙说明

slice A 与 slice B 之间的 7,744 字节零填充是 2^14（16KB）段对齐的必然结果
（slice A 结束于 254,400，下一个 16KB 边界为 262,144）。现代 iOS arm64 二进制
普遍使用 16KB 页对齐，属正常现象，不建议为了省这 ~8KB 改用更小对齐。

---

## 二、IPA 结构

```
Payload/SIOriginal.app/
├── SIOriginal                    373,920 B   主程序
├── Info.plist                     1,633 B
├── _CodeSignature/CodeResources    2,874 B
├── AppIcon.png / Icon-60@2x / Icon-60@3x / Icon-76@2x / Icon-83.5@2x
```

| 检查项 | 结果 |
|---|---|
| 主程序架构 | FAT，2 条目（arm64 + arm64e，健康；旧报告的"畸形 x86_64 条目"同为步长误解析，offset=177,312 实为 arm64e slice 的 size 被错读为 offset） |
| 主程序 filetype | 2 = `MH_EXECUTE`，正常 |
| 最低系统 | iOS 14.0（`minos=0xe0000`），SDK 18.5（`sdk=0x120500`） |
| `embedded.mobileprovision` | **不存在** |
| `Frameworks/` 目录 | **不存在** |
| IPA 内是否含 dylib | **否** |

### 关键：IPA 与 dylib 无引用关系

主程序 23 条 load command 中**没有任何 `LC_LOAD_DYLIB` 指向 `SIOriginal.dylib`**，
二进制内也搜不到 `SIOriginal.dylib`、`DYLD_INSERT_LIBRARIES`、`dlopen` 字样。
主程序与 dylib 之间唯一的通信通道是 Darwin 通知
`com.local.sioriginal.settingschanged`。

结论：IPA 是纯配置 App（写入 `/var/Managed Preferences/mobile/com.apple.UIKit.plist`），
dylib 需由 TrollFools 注入目标 App 生效。二者是**独立交付物**，不存在
「IPA 内应打包 dylib」的关系。

### 签名

entitlements（主程序）：

```xml
<key>get-task-allow</key><true/>
<key>platform-application</key><true/>
<key>com.apple.private.security.no-sandbox</key><true/>
<key>com.apple.private.persona-mgmt</key><true/>
<key>com.apple.private.security.storage.AppDataContainers</key><true/>
```

平台应用级私有授权，配合无 mobileprovision —— TrollStore 式伪签。
注意主程序**确实带**这些私有授权，这是正确的（配置 App 需要写
`/var/Managed Preferences` 与提权重启）；`build.sh` 与 CI 均已确保
**dylib 侧不带任何 entitlement**（`ldid -S` 无参数），这一点当前实现是对的。

---

## 三、源码修复

环境限制：当前为 Windows（`win32`，Git Bash），无 Xcode / iOS SDK /
`ldid` / `codesign`，**无法编译验证**，因此以下改动均经过静态核查与逻辑推演，
但未经真机运行验证。

### 修复 1：转圈动画缺少缩放标记（真实缺陷）

`sio_layer_addAnim` 的 `isSpinner` 分支改完时长后**没有调用
`SIO_markAnimScaled`**，而通用分支的防重复缩放守卫
`![REDACTED_EMAIL](anim)` 正是依赖这个标记。

`UIActivityIndicatorView` 的 `-setAnimating:` 会把**同一个 CAAnimation 实例**
反复 `addAnimation:`。没有标记意味着该守卫对这个动画永久失效。

同时补上原始时长的取值判据：`SIO_getOrigDur` 存的是 App 上一次
`setDuration:` 传入的值，仅当它与当前 `duration` 一致时才采信，否则用当前值重算。

```objc
double cur    = ((CAAnimation *)anim).duration;
double saved  = SIO_getOrigDur(anim);
double orig   = (saved > 0.0 && fabs(saved - cur) < 1e-9) ? saved : cur;
...
SIO_markAnimScaled(anim);
```

**诚实说明**：我最初判断这里存在「逐轮累积加速」的严重 bug，并写了长注释。
随后用数值模拟逐轮推演，发现**该判断是错的**——`kSIOSpinnerFloor = 0.4` 的钳制
本已吸收全部漂移（只要 `orig/speed < 0.4`，结果恒为 0.4，与 `orig` 具体值无关；
不触发钳制时 App 每轮都重新 `setDuration:`，`saved == cur` 恒成立）。
因此已撤回那段不实注释，只保留「打标」这一项确有价值的改动。
**教训记录在案**：0.4s 钳制是个吸收器，推断 bug 前应先确认兜底逻辑是否已覆盖。

### 修复 2：注入确认提示的重试退避（体验缺陷）

`SIO_showInjectToast` 固定 0.6s 重试 5 次，全部挤在头 3 秒内。
但 `SIO_showToast` 失败的主因是「App 尚未起完 / 无 active scene」，
属秒级以上事件 —— 0.6s 连打 5 次必然全部落空，等于没有重试。

改为指数退避 `0.5 → 0.75 → 1.1 → 1.7 → 2.5` 秒，累计约 6.5s，
覆盖真实冷启动窗口，总次数不变（仍为 5 次，不增加打扰）。

### 修复 3：配置缺失的可观测性

`SIO_reload` 在 plist 不可读时静默 `return` 并回落默认值。用户看到
「配置没生效」时无从判断是 plist 缺失、路径错、还是权限不足 ——
而这三者处理方式完全不同。补一条日志说明回落到了默认值及原因。

### 未改动但加了防呆注释

`App/main.m` 的 `WriteConfig` 中 `if (cfg[k])` 曾被我误判为 bug
（以为 `if (id)` 会按 NSNumber 的**值**判真假，导致 `@NO` 写不进 plist）。
**这是错的**：Objective-C 裸 `id` 条件只判**指针非空**，而 `@NO` 是
tagged pointer（arm64 上为 `0x4`，非 nil），因此 `@NO` 能正确写入。
已在源码加注释固化此认知，防止后人误改成值判断而引入真实 bug。

---

## 四、新增工具

### `tools/static_check.py`

编译前的静态核查，覆盖项目历史上反复出现的三类错误：

- 括号 / 花括号配平（先剥离注释与字符串字面量，避免误计）
- 原 IMP 判空：识别宏判空、`__builtin_expect`、短路条件内判空、
  显式布尔判空四种写法（初版只认宏，产生 4 处误报，已修正）
- hook 符号配对：声明了 `o_xxx` 却从未被赋值

当前结果：**通过**（SIOriginal.m 3033 行、main.m 1410 行均无异常）。

### `tools/audit_dylib.py`

Mach-O 结构审计，逐条目校验 FAT 架构表。已接入 `build.sh` 与
`.github/workflows/build.yml`，畸形架构条目会直接让构建失败。

修正步长解析后，对 v2.0.6 产物运行的结果（健康）：

```
[0] arm64      offset=16,384  size=238,016  align=2^14
[1] arm64e     offset=262,144 size=235,920  align=2^14
✓ 结构健康：所有 FAT 条目均指向合法 Mach-O，段覆盖自洽。
```

配套 `tools/test_audit_dylib.py`：用 struct 手工构造 3 个合法样本（双架构 FAT、
单架构瘦 Mach-O、MH_EXECUTE）与多个畸形样本（offset 越界、size 越界、
magic 损坏、条目指向 ASCII 区等），断言退出码与关键输出，防止解析器自身回归。

---

## 五、后续建议

**加载提速**

~~旧版本节基于"49% 尾部冗余"的误算给出瘦身建议，已随第一节更正作废。~~
真实的提速杠杆在 v2.0.7 已落地两条、剩余一条可选：

1. ✅ 已做（v2.0.7）：dylib 不再链接 AVFoundation / UserNotifications ——
   链接期依赖会被 dyld 拖进每个注入 App 的冷启动路径；改为运行时惰性解析后，
   不用保活的 App 启动路径上完全不再加载这两个框架。
2. ✅ 已做（v2.0.7）：热路径恒等快速路径（gAnimNoop），加速 ×1 时全部
   CATransaction 包裹点零包裹开销。
3. 可选（需用户决策）：arm64e 单架构产物可把体积从 ~486KB 降到 ~236KB，
   代价是放弃 A11 及更早设备（arm64）。A12+ 已占绝对主流，但属兼容性取舍，
   不默认改。

**功能增强的合理方向**

**功能增强的合理方向**

代码注释里已列出两条线索，值得优先跟进：

- `_gIsWeChat` 特判只覆盖 `com.tencent.xin`，而同类预览放大态问题
  在其他 App（小红书、淘宝图片预览等）同样存在 —— 可考虑改为
  「通用放大态探测 + 按 bundle id 灰名单」
- 注释 [7] 明确列出了**无法用改时长加速**的引擎（SVGA / Lottie /
  RN Reanimated / Ugen），这些是当前能力边界。若要覆盖需换机制
  （CADisplayLink 层介入），属独立课题

---

## 六、v2.0.7 变更（源码级，待 GitHub Actions 构建验证）

- **真 bug 修复**：CATransaction set→get 双重缩放。v2.0.4 的
  `+animationDuration` getter hook 对已被 setter 缩放（或经
  `SIO_setTransactionDuration` 原样写入）的值再缩一次。修：`__thread`
  记录本线程最近写入值 `gTxLastSetDur`，getter 命中即原样返回。
- **启动提速**：dylib 解除对 AVFoundation / UserNotifications 的链接依赖，
  音频引擎首次启用时才 `dlopen` + `dlsym`（`SIOAVPlayer`/`SIOAVSession`
  协议提供编译期签名，枚举值用冻结 ABI 常量内联）；UN 类 `objc_getClass`
  惰性获取。CI `otool -L` 断言防回退。
- **热路径**：`gAnimNoop`（加速 ×1 恒等）短路 42 个 CATransaction 包裹点、
  UIScrollView 滚动 hook、`addAnimation:` 转圈检测链；`setDuration:` 恒等时
  免关联对象读写；`_fbg_appState` 的 dladdr 判定加 8 槽直映缓存。
- **新覆盖**：`startAnimationAfterDelay:` 延迟缩放；
  UIDocumentInteractionController 选项/打开方式菜单。
- **新功能**：LayoutAccel 开关（默认关）—— `-[UIView layoutIfNeeded]` 包裹，
  加速 SwiftUI/自动布局隐式动画；配置 App 全局开关 + App 专属覆盖均已落地。

## 八、v2.1.0 变更：致命 bug 修复 + 无损加速引擎

### 8.1 逐行审计发现的问题

对 v2.0.8（3369 行）做逐行审计，定位到 12 处问题，其中 1 处为致命。

| # | 级别 | 问题 | 影响 |
|---|------|------|------|
| 1 | **致命** | `UIApplicationDidEnterBackgroundNotification` 被注册到 **Darwin** 通知中心 | NSNotification 名字只经 `NSNotificationCenter` 投递，两套系统互不相通 → `gPhysBg` 恒 `NO` → 音频断言保活/场景伪装/自愈轮询**三个功能全部从未执行** |
| 2 | 真 bug | 时长下限无条件抬升（`if (d<gFloor) d=gFloor` 与 `case 2: d=gFloor`） | 比下限更短的动画被**拉长**（0.005s → 0.02s，慢 4 倍），凭空造出卡顿 |
| 3 | 真 bug | 黑名单两套匹配语义（精确 vs 前缀） | `com.tencent.wework` 前缀语义下连带排除一批无关 App |
| 4 | 真 bug | 自绘 toast 走 `[UIView animateWithDuration:]` 命中自己的 hook | 「设置已生效」提示被二次加速，×20 下 0.0125s，一闪而过 |
| 5 | 真 bug | 瞬切模式改写 `UIScrollView` 的 `animated:` 语义 | 违反本文件 v1.8.3/v1.8.15 自己写下的禁令；且该hook 不受 ListAccel 门控 |
| 6 | 性能 | 转圈检测每次 `addAnimation` 做 `NSStringFromClass` + 2× `containsString:` | 稳定堆分配，每秒数十次 |
| 7 | 性能 | `SIO_saveOrigDur` 用 `@(d)` 装箱 | 显式动画热路径的稳定堆分配 |
| 8 | 健壮 | 3 个 `pthread_key_create` 不检查返回值 | 任一失败则 `SIO_inXXX` 读到未定义值 |
| 9 | 假功能 | `SIO_transitionDuration` 里转场倍率压到下限以下时被下限抬回 | 用户调档位看不到变化 |
| 10 | 覆盖 | `continueAnimationWithTimingParameters:duration:` 未接管 | 链式动画首段加速、续段不加速 |
| 11 | 覆盖 | `UIWindow setRootViewController:` 未接管 | 换根页面的交叉淡入无加速 |
| 12 | 语义 | 无障碍意图被覆盖 | 用户开「减弱动态效果」= 明确要求少动效，本项目逆行 |

### 8.2 新增能力

- **速率加速引擎**（`SpeedMode`，默认关）：改 `CAAnimation.speed` / `CALayer.speed`
  而非 duration。相比压时长有两个结构性优势 ——
  ① 不存在下限碰撞；② 时长与关键帧时间轴原样保留，
  弹簧物理积分步长与关键帧插值不失真，不会抽搐/跳变。
  安全边界：App 显式设 `speed != 1.0`（视频/音频同步）一律透传，只接管默认值 1.0；
  与时长模式**互斥**（同时生效会得到倍率平方，且双重下限钳制失真）。
- **辅助功能让位**（默认开）：`dlsym` 惰性解析
  `UIAccessibilityIsReduceMotionEnabled`，不增加链接依赖。
- **PA 链式续播 / UIWindow 换根页面** 补齐。

### 8.3 校验工具

新增 `tools/check_v210.py`，做 `static_check.py` 不覆盖的**语义级**核查：
原IMP 声明/赋值配对、inline 定义先于使用（含前向声明识别）、
TLS key 创建与判空、配置变量在 `SIO_reload` 两个分支均赋值、
已删除函数无残留引用、括号配平，以及「下限不得反向拉长动画」这条关键不变量。
已通过故意注入错误验证有效性。

*本报告基于静态分析生成，未经编译或真机验证。v2.1.0 全部变更建议在
macOS（GitHub Actions）构建后于真机确认；其中问题 1（保活链路）修复后
需重点验证后台保活是否真正启动。*


## 九、v2.3.0 变更：移除 120Hz，新增帧对齐引擎

### 9.1 移除 ProMotion120

**该功能的实际作用**是改写 App 设定的帧率上限
（`CADisplayLink.setPreferredFramesPerSecond:` 的 60 → 设备上限、
`setPreferredFrameRateRange:` 的 maximum/preferred 拓宽）。

**移除理由**：
1. 不解决「感觉不流畅」的主要成因 —— 卡顿根源是帧时间不稳定，
   而 120Hz 只是把帧周期从 16.67ms 减到 8.33ms；时长不对齐帧栅格时余数依然存在。
2. 功耗代价明确 —— 全局 120Hz 让 GPU/CPU 多渲染一倍帧数。
3. 干预面广 —— 拦的是所有App 的渲染循环，属最侵入式 hook。

**清理完整性**：删除 `gPM120` 开关、`SIO_pmMaxFPS`/`SIO_pmTarget`、
`sio_DL_setFPS`/`sio_DL_setRange`、`o_dl_*` 原 IMP、`SIOFrameRateRange` 类型、
两处安装点（常规 + 按需补装）、配置 App 的 UI/默认值/写入白名单/保存逻辑，
以及 README/ANALYSIS/control 中的相关描述。已用grep 验证无残留。

### 9.2 新增帧对齐引擎（`FrameAlign`，默认开）

**问题机理**：CoreAnimation 按时间在 `0, T, 2T, …` 提交帧，设备每 `P` 秒刷新一帧。
时长 `D` 不是 `P` 整数倍时，最后一帧显示不足 `P` 即被提交，
随后空等 `P` 才提交下一帧 —— 这一个「不足一帧 + 空等一帧」的周期即视觉顿挫。

**本项目为何尤其容易制造余数**：加速即时长除以倍率。
`0.3s ÷ 5 = 0.06s`在 60Hz 下是 3.6 帧，倍率越高余数越大（×20/×50 为常用档）。

**修法**：换算后向下取整到帧边界整数倍。`floor(0.06/0.01667)×0.01667 = 0.05s`。

**三条不变量**（由 `tools/test_frame_align.py` 机器验证）：
1. 结果必为帧周期的整数倍
2. 只能缩短、绝不能延长
3. 时长不足一帧时保持原值（否则 0.005s → 0.0167s，慢 3 倍）

**施加位置**：在 `SIO_targetDuration` 末尾（下限钳制**之后**）。
顺序不可颠倒 —— 若先对齐再钳制，下限会把已对齐的值重新抬高，对齐白做。
`SIO_targetDurationLayer` 因额外除了一次 LayerBoost，必须**重做**对齐。

**为什么优于 120Hz**：120Hz 让帧数翻倍但不对齐问题依旧（0.06s 在 120Hz 下是 7.2 帧）。
帧对齐让时间轴与帧栅格严格咬合，在 60Hz 设备上同样有效。

*本报告基于静态分析生成，未经编译或真机验证。*
