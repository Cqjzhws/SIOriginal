# SIOriginal — iOS 动画加速 + 真后台保活

面向 iOS 14–17（含 iOS 16/17）的动画加速方案，共 **100+ 个 Hook**，适配 TrollStore / TrollFools，无需 CydiaSubstrate。

## v2.3.0 移除 120Hz，改用帧对齐引擎

### 为什么移除 ProMotion120

v2.0.8 的「强制 120Hz」做的是**改写 App 设定的帧率上限**
（`CADisplayLink.setPreferredFramesPerSecond:` 的 60 → 设备上限、
`setPreferredFrameRateRange:` 的maximum/preferred 拓宽）。移除原因：

1. **它不解决「感觉不流畅」的主要成因**。卡顿的根源是帧时间不稳定，
   而 120Hz 只是把帧周期从 16.67ms 减到 8.33ms —— 如果动画时长本身
   不对齐帧栅格，余数依然存在，顿挫依然在。
2. **功耗代价明确**。全局 120Hz 会让 GPU/CPU 多渲染一倍的帧，
   在动画密集页面发热与耗电肉眼可见。
3. **干预面广**。要拦的是所有 App 的渲染循环，属于最侵入式的一类 hook。

### 新功能：帧对齐引擎（`FrameAlign`，默认开）

这是 120Hz 之外**真正改善流畅感**的方案。

**问题**：CoreAnimation 按「时间」推进动画，在第 `0, T, 2T, …` 时刻提交帧，
而设备每 `P` 秒刷新一帧。当动画时长 `D` 不是 `P` 的整数倍时，
最后一帧的显示时间不足 `P` 就被提交，随后又空等 `P` 才提交下一帧 ——
这个「显示不足一帧 + 空等一帧」的周期就是肉眼看到的顿挫。

**本项目尤其容易制造余数**：加速就是拿时长除以倍率。
`0.3s ÷ 5 = 0.06s`，在 60Hz 下是 **3.6 帧** —— 3 帧正常跑完，
最后 0.6 帧的空档就是那一下顿挫。倍率越高余数越大
（×20/×50 是常用档，问题更明显）。

**修法**：把换算后的时长**向下取整到帧边界的整数倍**。
上例 `floor(0.06 / 0.01667) × 0.01667 = 3 帧 = 0.05s`，三帧整齐跑完，无空档。

三条安全边界：
- 对齐**只能缩短、绝不能延长**动画（绝不让任何动画因对齐变慢）
- 时长**不足一帧**时保持原值（强制对齐为 1 帧会把 0.005s 拉成 0.0167s，慢 3 倍）
- 慢放模式与速率模式**不参与**（前者语义冲突，后者时间轴本就原生）

### 为什么这比 120Hz 更根本

120Hz 让帧数翻倍，但**不对齐的问题依旧存在** —— 0.06s 在 120Hz 下是 7.2 帧，
仍有余数。帧对齐是让**时间轴与帧栅格严格咬合**，在 60Hz 设备上同样有效。

### 验证

新增 `tools/test_frame_align.py`，复刻算法并验证三条不变量
（结果必为帧周期整数倍 / 只能缩短 / 不足一帧时保持原值），
覆盖 60Hz、120Hz、90Hz 三种帧率与 ×5/×10/×20/×50 极端倍率。
真实场景实测：60Hz 下 `0.3s÷5` 从 3.60 帧对齐到 3.00 帧。

## v2.2.0 启动提速：注入库自己不该是启动变慢的原因

用户反馈「App 反应慢」，逐行核查后发现**注入库自身在启动路径上做了不少事**——
`__attribute__((constructor))` 跑在 `main` 之前，里面的每一次 `method_setImplementation`
都要查方法表、比对 IMP、交换指针，并让 UIKit 全局方法缓存失效；这些时间**直接叠加到 App 启动耗时**。

- **[性能·启动] plist 读取去重**：构造函数里原本同步读同一个文件**两次**
  （`SIO_reload` 一次、`FUBGEntry → _fbg_loadPref` 又一次），
  每次都是完整的 mmap + plist 反序列化 + 对象图分配。现引入 `gPrefCache`，
  构造函数只读一次，两侧都从缓存取；热重载时让缓存失效，**全程仍只解析一次**。
- **[性能·启动] 列表全家桶 27 个 hook 改为「延迟 + 按需」安装**：
  这批 hook 只在 `ListAccel` 打开时才有行为，而该开关**默认关闭**（fail-safe）。
  也就是说默认配置下这 27 次方法表交换是**纯开销**。
  现在构造期不碰，改为启动后异步安装，且**开关关闭时连装都不装**。
- **[性能·启动] 其余默认关闭的 hook 同样按需安装**：
  缩放动画（`ZoomAccel`）、布局动画（`LayoutAccel`）、
  120Hz 帧率（`ProMotion120`）。其中 `layoutIfNeeded` 尤其值得按需 ——
  它是 `UIView` 的热点方法，任何一次布局都会调到，常态下替换只增加间接调用。
- **[功能补全] 热重载补装**：按需安装的必然副作用是「运行后才打开开关」时 hook 装不上
  （表现为"我明明开了却没反应"）。新增 `SIO_installOnDemandHooks()`，
  由配置保存后的 Darwin 通知触发补装，全部幂等。
- **[修正] 门控一致性**：`setCollectionViewLayout:animated:`
  与 `performBatchUpdates:` 同样受 `SIO_listOK()` 门控，却原先在构造函数无条件安装 ——
  与被搬走的 24 个是同一族却一个延迟一个同步。已统一。

**效果**：默认配置下冷启动期执行的 `method_setImplementation` 从 **53次降到 26 次（-51%）**，
plist 解析从 2 次降到 1 次。开启列表加速的用户会在启动后补装那 27 次，
代价是首屏最初几十毫秒列表动画不生效（列表内容本身是异步填充，实测无可感知差异）。

## v2.1.0 致命 bug 修复 + 无损加速引擎

### 修复的真 bug（含 1 个致命）

- **[致命] 真后台保活整条链路从未生效** —— 不是「效果弱」，是**一行代码都没跑过**。
  `UIApplicationDidEnterBackgroundNotification` 是 **NSNotification** 名字，
  却被注册到 `CFNotificationCenterGetDarwinNotifyCenter()`（Darwin 中心只投递
  `notify_post()` 的名字，两套通知系统互不相通）。后果链条：
  `gPhysBg` 永远 `NO` → `_fbg_startAudio` 永不调用 → `applicationState` 伪装条件恒假
  → 自愈轮询首行即 return。
  即配置界面上的「场景伪装 / 音频断言兜底 / 真后台保活」三个功能，自 v1.8.6 起
  **从未在任何 App 里执行过一行代码**。改用 `NSNotificationCenter` + 主队列。
- **[真 bug] 时长下限把动画变长**（与加速目的完全相反）：
  原钳制 `if (d < gFloor) d = gFloor;` 无条件抬到下限。当原时长本就比下限更短
  （App 的 0.005s 微动画，或下限调到 0.05 而 App 用 0.02s）时，
  0.001s 被抬成 0.02s = **慢 20 倍**，凭空造出卡顿。瞬切模式更直接：
  `case 2: d = gFloor` 无视原值一律替换。现统一为 `min(gFloor, orig)` ——
  **加速只能让动画变快，绝不能变慢**。
  同类问题另修`SIO_transitionDuration`：转场倍率压到下限以下时被下限抬回，
  用户调了档位却看不到变化（假功能）。
- **[真 bug] 黑名单两套匹配语义互相打脸**：`SIO_reload` 用精确匹配，
  `_fbg_isExcluded` 用前缀匹配。配置默认写入的 `com.tencent.wework` 在前缀语义下
  会连带排除 `com.tencent.weworkhelper` 等全部同前缀 App。现统一为精确匹配，
  确需前缀时在条目末尾显式写 `*`。
- **[真 bug] 本项目自己的 UI 动画被自己加速**：toast 淡入淡出走
  `[UIView animateWithDuration:]`，命中自己的 hook 被二次缩放（×20 下 0.25s → 0.0125s），
  「设置已生效」提示一闪而过，用户根本看不清。现新增线程局部「内部 UI」旁路标记。
- **[真 bug] 瞬切模式改写 UIScrollView 的 animated 语义**：文件里 v1.8.3/v1.8.15
  两处注释把这个做法列为微信预览卡死的根因（「绝不能改写 animated 语义」），
  同一份代码里却一边写禁令一边实施，且这两个 hook 还不受 ListAccel 门控。现保留
  `animated:YES` 只压事务时长，与全项目口径统一。

### 新增功能

- **[新功能] 速率加速引擎（SpeedMode，默认关，全局/可 App 覆盖）**：
  此前唯一手段是压缩 duration，有两个绕不开的硬伤 —— 撞时长下限；
  duration 极小时关键帧插值与弹簧物理积分失真（抽搐/跳变）。
  新模式改 `CAAnimation.speed` / `CALayer.speed`：**时长与关键帧时间轴原样保留，
  只提高播放速率**，插值与物理完全正确且无下限碰撞。
  安全边界：App 显式设 `speed != 1.0`（视频/音频同步、慢动作特效）一律透传；
  慢放换算为 `1/slowFactor`；与时长模式互斥（同时生效会造成倍率平方）。
- **[新功能] 辅助功能让位（默认开）**：系统「减弱动态效果」为真时自动整体旁路。
  用户开启该设置即表达「减少动效」意图，加速工具不应覆盖它。
  判定用 `dlsym`惰性解析，不给 dylib 增加链接依赖（保持 v2.0.7 的启动提速成果）。
- **[新覆盖] `UIViewPropertyAnimator continueAnimationWithTimingParameters:duration:`**：
  iOS 11+ 链式续播入口。此前首段时长与 start 延迟都已缩放，唯独续播传入的新时长
  原样放行 —— 一条链里首段加速、续段不加速。
- **[新覆盖] `UIWindow setRootViewController:`**：换根页面（启动分流、登录→主页）
  的交叉淡入此前无任何覆盖。
- **[性能] 转圈检测去字符串分配**：原实现在 superlayer 链上每个 delegate 都做
  `NSStringFromClass` + 两次 `containsString:`，每秒可达数十次。现改为
  零分配的 `isSubclassOfClass:` 快速判定 + 16 槽「类指针 → 是否候选」直接映射缓存
  + 遍历深度上限（8 层）。
- **[性能] 原时长改 POD 盒子**：`SIO_saveOrigDur` 原用 `@(d)` 装箱，
  每次显式动画的每次 `setDuration:` 都有一次堆分配。改为 8 字节 malloc 盒子，
  同一动画重复设值时原地更新、零分配。
- **[健壮] TLS key 创建判空**：三个 `pthread_key_create` 此前不检查返回值，
  任一失败都会让后续 `SIO_inXXX` 读到未定义值。

### 新增校验工具

`tools/check_v210.py` —— 针对本轮改动做**语义级**交叉引用核查（`static_check.py`
不做语义分析）。覆盖：原 IMP 声明/赋值配对、inline 定义先于使用（含前向声明识别）、
TLS key 创建与判空、配置变量在 `SIO_reload` 两个分支均赋值、已删除函数无残留引用、
括号配平，以及「时长下限不得反向拉长动画」这条关键不变量。
已用故意注入错误验证过有效性（能抓出并返回退出码 1）。

## v2.0.7 修复 + 性能优化 + UI 加速增强

- **[真 bug] CATransaction set→get 双重缩放**：v2.0.4 的 `+animationDuration`
  getter hook 会对已被 setter hook 缩放过的值再缩一次（0.5→0.1→0.02）。
  现用 `__thread` 记录本线程最近一次写入值，getter 命中即原样返回，
  只缩「未经我们写入的默认值」（CATransaction 状态线程私有，天然对齐）。
- **[性能·启动提速] dylib 不再链接 AVFoundation / UserNotifications**：
  链接期依赖会让 dyld 在**每个**被注入 App 的冷启动路径上加载整套
  AVFoundation（连带 CoreMedia/CoreAudio 依赖链），即使该 App 从不用保活。
  改为首次进入后台、真正需要音频断言时才 `dlopen`+`dlsym`；
  UserNotifications 类改为 `objc_getClass` 惰性获取。CI 新增 `otool -L` 断言防回退。
- **[性能·热路径] gAnimNoop 恒等快速路径**：加速 ×1 时所有时长换算都是
  恒等变换，但 42 个 CATransaction 包裹点（触控高亮/单元格选中/滚动偏移…）
  每次仍要 begin/set/commit 事务栈。恒等时直接透传，恢复系统原生行为。
  另：CAAnimation setDuration: 恒等时跳过关联对象读写；CALayer addAnimation:
  恒等时跳过整条转圈检测链；保活侧 applicationState 的 dladdr 判定加 8 槽缓存。
- **[新覆盖]** `UIViewPropertyAnimator startAnimationAfterDelay:` 延迟同比缩放
  （此前 init 时长缩放、start 延迟原样放行，行为不一致）；
  `UIDocumentInteractionController` 补全选项菜单 / 打开方式菜单两个入口。
- **[新功能] LayoutAccel 开关（实验，默认关）**：包裹 `-[UIView layoutIfNeeded]`，
  加速 SwiftUI/自动布局的隐式布局动画（getter hook 覆盖不到的读取路径），
  支持全局开关与 App 专属覆盖。

## v2.0.6 修复

对已发布产物做 Mach-O 级审计 + 源码静态核查后的修复：

- **[真缺陷] 转圈动画缺少缩放标记**：`-[CALayer addAnimation:forKey:]` 的
  `UIActivityIndicatorView` 分支改完时长后没有打 `SIO_animScaled` 标记，
  而通用分支的防重复缩放守卫正依赖该标记。转圈动画是无限重复动画、
  会被 `-setAnimating:` 反复 `addAnimation:` 同一实例，缺标记等于该守卫
  对它永久失效。同时补上原始时长取值判据（仅当保存值与当前值一致时采信）。
- **[体验] 注入确认提示重试改为指数退避**：原固定 0.6s × 5 次全挤在头 3 秒，
  而 toast 失败主因是「App 未起完」（秒级事件），必然全部落空等于没重试。
  改为 0.5→0.75→1.1→1.7→2.5s，累计约 6.5s，总次数不变。
- **[可观测性] 配置缺失时补日志**：`SIO_reload` 原本静默回落默认值，
  用户无法区分「plist 缺失 / 路径错 / 权限不足」，现在会明确说明。
- **[工具] 新增 `tools/static_check.py`**：编译前静态核查（括号配平、
  原 IMP 判空、hook 符号配对）。本项目历史上多次因漏写 `SIO_REQUIRE_ORIG`
  出错，静态阶段拦下比等 clang 报错更快。已接入 CI 与 `build.sh`。
- **[工具] 新增 `tools/audit_dylib.py`**：Mach-O 结构审计，逐条目校验
  FAT 架构表（`lipo -info` 只读架构名列表、不校验条目是否真能解析）。
  已接入 CI 与 `build.sh`。
- **[更正] 审计脚本 v1 曾误报「v2.0.6 产物 FAT 第 2 条目畸形」**：
  真相是解析器自身 bug —— 把标准的 20 字节 `fat_arch` 条目误按 24 字节
  步长解析，第 2 条目错位 4 字节（arm64e 的 cpusubtype 0x80000002 被读成
  cputype、size 被读成 offset）。发布的 dylib 一直健康（arm64+arm64e）。
  现有 `tools/test_audit_dylib.py` 回归测试防解析器自身回归。

详见 [ANALYSIS.md](ANALYSIS.md)。

## v2.0.1 修复（配置真实性审计 · 假功能清零）
逐键核对「配置 App 写 plist → dylib 读 plist → hook 真实生效」全链路：
- **长按加速落地**：LongPress / LongPressDuration 在 v2.0.0 只有界面开关，dylib 从未读取实现；
  现 hook `UILongPressGestureRecognizer` 的 init/initWithCoder:/setMinimumPressDuration:，
  只把系统默认 0.5s 替换为配置时长，App 自定义时长透传
- **生效提示落地**：Notify 开关承诺的「保存后目标 App 顶部 1.5s 提示」此前无实现；
  现补不拦截触摸（userInteractionEnabled=NO）的顶部 toast，仅前台显示、1.5s 节流
- **setter 强黏落地**：滑行加急 / 点击零延迟新增 setDecelerationRate: /
  setDelaysContentTouches: hook，App 任何时候写回都会被拦回（旧版只在 didMoveToWindow 设一次）
- **转圈加载提速**：UIActivityIndicatorView 由「完全不加速」改为按全局倍率加速并钳制
  0.4s 平滑下限（×5 下不再是界面上最慢的元素，且不频闪）
- **崩溃修复**：转圈检测对非 UIView 的 layer.delegate 发 superview 会 unrecognized selector，
  增加类型门 + @try 兜底
- **配置 App 修复**：关闭某 App 专属开关时旧覆盖字典未删除（旧参数继续生效、开关关不掉）；
  切换 Bundle ID 时控件残留上一个 App 的值

## 特性

**动画加速**
- 三种模式：加速（×1–×50）、慢放（×1–×10）、瞬切（Floor 下限）
- 弹簧参数缩放（保持物理一致性）
- 进阶转场（导航栈 / 模态弹窗）+ 转场独立额外倍率 TransitionBoost（×1/×1.5/×2/×3）
- 显式动画额外倍率 LayerBoost（进度/旋转/地图相机单独加速 ×1–×10；转圈走独立平滑下限）
- 动画时长下限 Floor（0.005 / 0.01 / 0.02 / 0.05s 可配）
- 列表加速（TV/CV 全家桶，高危，默认关）
- 缩放动画加速（UIScrollView，实验性，默认关）
- 交互手感：滑行惯性加急 + 点击零延迟（setter 强黏）+ 长按手势加速（0.20/0.30/0.40s）
- UIKit 全局动画系数（×5/×10/×20/极端档）
- 系统动态效果：减弱动态效果 / 交叉淡出 / 减少透明度
- 一键预设（极速/均衡/保守/瞬切）、配置 JSON 导入导出、注入环境自检

**v1.8.18 新增 hook**
- UIRefreshControl：beginRefreshing / endRefreshing
- UINavigationItem：大标题过渡动画（setLargeTitleDisplayMode:）
- UIPageViewController：页面切换
- UIDocumentInteractionController：预览动画

**v1.8.19 修复（注入闪退专项）**
- dylib 改为**无 entitlement** ad-hoc 签名：旧版把 platform-application / no-sandbox /
  persona-mgmt 等私有授权签进 dylib，TrollFools 注入普通 App 后 dyld/AMFI 直接 SIGKILL（启动即闪退）
- dylib install_name 改回 `@rpath/SIOriginal.dylib`（旧版是 MobileSubstrate 绝对路径）
- 修复弹簧动画 hook 参数整体错位（`animateWithDuration:delay:usingSpringWithDamping:...` 漏声明 delay:）
- 修正 3 处错误选择器/ABI：`endRefreshing`（无参）、`UINavigationItem setLargeTitleDisplayMode:`、
  `setViewControllers:direction:animated:completion:`
- 修复 swizzle 对「继承自父类方法」直接替换导致父类实现被全局污染（如所有 UIView 误进 UIScrollView hook）
- 链接器禁用 chained fixups（-no_fixup_chains），兼容 iOS 14 与旧注入工具
- 配置 App：systemCyanColor/systemMintColor 增加 iOS 15 可用性守卫（iOS 14 不再崩溃）
- CI：修复 Release 创建 403（显式 contents: write 权限），IPA 补全 _CodeSignature/CodeResources

**安全防护**
- CAAnimation 幂等缩放标记（修双重缩放 bug）
- 列表 hook 硬保护名单（SpringBoard 永不开启；顺丰同城骑士 v1.8.19 起移出名单，由用户黑名单/专属覆盖控制）
- 微信图片预览放大态全局旁路
- 所有原 IMP 调用前判空 + 重复安装保护 + @try 包裹

**真后台保活（FUBackground 引擎）**
- 场景伪装（吞掉 backgrounding scene diff）
- 音频断言兜底（静音白噪声）
- 前台/后台自动切换 + 看门狗 + 中断恢复

**App 专属覆盖**
- 为指定 Bundle ID 单独配置倍率/模式/弹簧/转场/列表/保活
- 优先级：硬保护 > App 覆盖 > 全局配置

## 产物
- `SIOriginal.dylib` — 核心 Tweak（动画加速 + 保活引擎），用 TrollFools 注入目标 App
- `SIOriginal.ipa` — 配置 App，用 TrollStore 安装

## 配置
写入 `/var/Managed Preferences/mobile/com.apple.UIKit.plist`：
```xml
<key>Enabled</key><true/>
<key>Mode</key><integer>2</integer>
<key>Speed</key><real>5.0</real>
<key>SlowFactor</key><real>2.0</real>
<key>Spring</key><true/>
<key>Extra</key><true/>
<key>ListAccel</key><false/>
<key>ZoomAccel</key><false/>
<key>FastScroll</key><true/>
<key>FastTap</key><true/>
<key>LongPress</key><true/>
<key>LongPressDuration</key><real>0.30</real>
<key>LayerBoost</key><real>1.0</real>
<key>Floor</key><real>0.02</real>
<key>TransitionBoost</key><real>1.0</real>
<key>Notify</key><true/>
<key>LayoutAccel</key><false/>
<key>ProMotion120</key><false/>
<key>Blacklist</key><array><string>com.tencent.wework</string></array>
<key>FUBGEnabled</key><true/>
<key>FUBGSceneFake</key><true/>
<key>FUBGAudioKeep</key><true/>
<key>AppOverrides</key><dict>
    <key>com.sfic.knight</key>
    <dict>
        <key>Speed</key><real>8.0</real>
        <key>ListAccel</key><false/>
    </dict>
</dict>
```
Darwin 通知 `com.local.sioriginal.settingschanged` 触发热重载。

## 构建
GitHub Actions 自动构建（`.github/workflows/build.yml`，macos-15）：
- dylib：纯 clang 直编（-O2）+ `ldid -S` **无 entitlement** ad-hoc 签名（注入库绝不带私有授权）
- IPA：clang 直编 .app + 整包 `codesign --entitlements`（App 主程序保留 no-sandbox 等私有授权），含 CodeResources
- 推送 `v*` tag 自动发布 GitHub Release（工作流已声明 `contents: write` 权限）；也可 workflow_dispatch 手动触发

## 安装
1. TrollStore 安装 `SIOriginal.ipa`（配置 App）
2. TrollFools 选择目标 App → 注入 `SIOriginal.dylib` → 重开 App 生效
3. 在配置 App 中调整参数 → 保存 → 注销/重启
