// SIOriginal — 原版重制
// 基于 pw5a29 Speed Intensifier 10.1-1 的机制还原（CAAnimation setDuration: 单基类 hook
// + CASpring 参数缩放 + 慢放模式），针对 TrollStore / iOS 16 全新实现：
//   · 无 CydiaSubstrate 依赖，纯 ObjC runtime swizzle（TrollFools 注入友好）
//   · 线程局部标记防 CATransaction/UIView 双重除法（原版未处理的问题）
//   · 慢放（原版 slowDownFactor）与瞬切模式
//   · Darwin 通知热重载配置，黑名单逐进程判断
// 不包含任何 SpeedIntensifier / SIFusion / SpeedsterTS 项目代码。
//
// ============================ v1.8.12 优化加强 ============================
// [真 bug 1] CALayer addAnimation:forKey: 兜底改为调用保存的原始 IMP。
//   原来用 objc_msgSend(anim, setDuration:) 回写，而 setDuration: 自己已被 hook，
//   于是 duration 被 SIO_targetDuration 连乘两次（加速 ×5 实际变成 ÷25），
//   恰好违反本文件声称的「防双重除法」设计。
// [真 bug 2] runningPropertyAnimatorWithDuration:delay:options:animations:completion:
//   原来写成 SIO_swizzleClass(object_getClass(pa), …)：class_getClassMethod 内部是
//   class_getInstanceMethod(object_getClass(cls), sel)，再传元类等于去根元类里找，
//   必然返回 NULL 静默跳过——该 hook 从上线起从未生效。改为 SIO_swizzleClass(pa, …)。
// [真 bug 3] Blacklist 兼容 NSString 格式。原来无条件 componentsJoinedByString:，
//   一旦 plist 里是字符串（手工编辑/旧版本/其他工具写入）即 unrecognized selector，
//   注入进程启动崩溃。FUBG 侧 v1.8.6 已修，动画侧这次补齐。
// [真 bug 4] 导航/模态转场时长改为按模式计算 SIO_targetDuration(0.35)。
//   原来硬编码 setAnimationDuration:0.0 —— 慢放模式下导航/弹窗依旧瞬间完成，
//   慢放对这类转场等于完全无效；现在慢放真的变慢，加速模式约 0.07s（几乎无感）。
// [隐患 5] ListAccel 缺键默认由 YES 改为 NO。危险功能不再 fail-open。
// [隐患 6] FUBGExcludeApps 与 Blacklist 合并。原来排除表赋值后立刻被 Blacklist
//   无条件覆盖，排除机制实际从未生效。
// [性能 7] 黑名单在重载时一次性解析为进程布尔值 gSelfBlacklisted。
//   SIO_blocked() 是全部动画/事务 hook 的必经热路径，原来每次都要
//   componentsSeparatedByString: 分配数组。
// [性能 8] 微信预览放大态探测器加 3000 节点上限，超大视图树不再拖慢主线程。
// [健壮 9] 所有原 IMP 调用前判空；swizzle 增加重复安装保护（绝不把自己的 IMP
//   存成 orig 导致自递归）；两处 constructor 安装全程 @try 包裹，异常放行原实现。
// [加强 10] 新增 5 个低风险 hook：
//   +[UIView animateKeyframesWithDuration:delay:options:animations:completion:]
//   -[UIViewPropertyAnimator initWithDuration:timingParameters:]（2 参指定初始化器，
//     带线程局部重入保护，避免与 3 参变体双重缩放）
//   -[UITabBarController setSelectedIndex:] / setSelectedViewController:
//   -[UIViewController transitionFromViewController:toViewController:duration:…]
//   +[UIView performSystemAnimation:onViews:options:animations:completion:]
// 全部沿用已验证的 CATransaction/时长改写机制，不触碰 TV/CV 列表状态机。
// =========================================================================
//
// ============================ v1.8.14 顺丰同城骑士防护 ============================
// 场景：TrollStore + TrollFools 把本 dylib 注入顺丰同城骑士 (com.sfic.knight)。
// 该 App 是本项目实测确认的「列表 hook 冲突」App：24 个 TV/CV 变更类 hook 会破坏
// 它的列表状态机 → 卡死 / 崩溃（v1.8.11 之前靠 bundle id 硬编码排除，v1.8.11 改成
// 纯开关控制后，只剩"用户记得关"这一层，而配置是全局的 —— 为别的 App 打开列表
// 加速会连带把顺丰同城也打开）。
//
// 本轮做两件事：
//  1. [防护] 列表 hook 硬保护名单 SIO_listHardBlocked()：名单内 App 的 ListAccel
//     恒为 NO，优先级高于全局开关与 App 覆盖，任何配置都打不开。
//     —— 安全项必须 fail-safe，不接受"忘了关"。
//  2. [优化] App 级配置覆盖 AppOverrides：允许为指定 Bundle ID 单独设置
//     倍率/模式/弹簧/转场/列表/保活，互不干扰。这样顺丰同城可以调到比其他 App
//     更合适的参数，而调其他 App 不会连带影响它。
//     优先级：硬保护 > App 覆盖 > 全局配置。
// =========================================================================
//
// ==================== v1.8.15 顺丰同城骑士 11.5.0 针对性 hook ====================
// 依据：拆包 Knight.app 11.5.0（com.sfic.knight，arm64 已解密，10947 个 ObjC 类）
// 得到的证据表，见文件末尾「拆包证据」注释。落地两件事：
//
// [真 bug] 修掉 CAAnimation ↔ CALayer 的残留双重缩放。
//   sio_CAAnim_setDuration 会缩放一次，sio_layer_addAnim 兜底又会缩放一次：
//   App 只要「先 setDuration 再 addAnimation」（标准写法）就被连缩两次，
//   实际倍率是 speed²（×5 变 ×25），并频繁撞上 0.01s 下限。
//   本 App 的高德地图相机动画（MAMapKeyFrameAnimation，CAKeyframeAnimation 子类）
//   与 NXDesign 的 addAnimation:forKey: 路径都吃这个 bug。
//   修法：用关联对象给动画打「已处理」标记，两个入口谁先处理谁打标，另一个跳过。
//
// [新覆盖] UIScrollView setZoomScale:animated: / zoomToRect:animated:
//   拆包证实 App 侧（NXDesign.framework）确实在用这两个入口，而此前完全没接管。
//   实现要点：只用 CATransaction 覆写时长，绝不把 animated:YES 改成 NO
//   （v1.8.3/v1.8.4 微信预览故障的根因就是改写 animated 语义 + 禁用事务动作）。
//   默认关闭（ZoomAccel=0），因为这一族在微信上出过"预览页卡死"，需要实测再开。
// =========================================================================
//
// ==================== v1.8.16 系统级增强 + SpringBoard 防护 ====================
// [SpringBoard] 更正：纯 TrollStore + TrollFools 环境**无法**把 dylib 注入
//   SpringBoard。TrollFools 是 in-place injection（insert_dylib + ChOma 重签名），
//   官方只支持「可移除的系统应用 / 已解密 App Store 应用 / 加密 App Store 应用」，
//   而 SpringBoard 属不可移除的核心系统应用，位于只读的 SSV 系统卷
//   （/System/Library/CoreServices/SpringBoard.app），根本写不进去。
//   桌面动画要在"不注入"前提下加速，走 Managed Preferences 域的
//   UIAnimationDragCoefficient（配置 App 的 ×5/×10/×20 档）—— SpringBoard 同样
//   以 mobile 身份运行并读取该域。
//   下面两道防护只在**越狱路线**（如 Dopamine + ElleKit 指定 SpringBoard）下才会
//   真正生效；留着零成本，用于自动拦住最危险的两种情况：
//     1. com.apple.springboard 进列表 hook 硬保护名单（SpringBoard 内部有大量
//        TV/CV，列表 hook 一旦打开会破坏它的状态机 → 黑屏/白苹果）；
//     2. com.apple.springboard 进内置保活排除名单 —— 保活引擎（音频断言 +
//        场景伪装）对桌面进程毫无意义，且 SpringBoard 本身就是场景宿主，
//        在它内部吞掉 scene 更新会影响全局 App 的后台化。这两项都是 fail-safe。
//
// [体感加速] 新增两个默认关闭的开关（不属于"改时长"，而是改交互手感）：
//     FastScroll：UIScrollView.decelerationRate = Fast（滑行距离大幅缩短）
//     FastTap   ：delaysContentTouches = NO（去掉列表点击约 150ms 延迟）
//   在 -[UIScrollView didMoveToWindow] 里统一施加，覆盖 nib/storyboard/code
//   三种来源的滚动视图。
// =========================================================================
//
// ==================== v1.8.17 显式动画额外倍率 + 极端档回归 ====================
// [LayerBoost] v1.8.15 修掉 CAAnimation 双重缩放后，显式动画（转圈/进度/旋转/
//   地图相机）的时长从 ÷speed² 回到 ÷speed，肉眼明显变慢 —— 用户实测反馈
//   "APP 加载图标转圈动画变慢了"。新增 LayerBoost（显式动画额外倍率：
//   1 / 2 / 3 / 5 / 10，默认 1）：
//     · 只叠加在 CAAnimation setDuration: 与 CALayer addAnimation: 这条路径上；
//     · **不影响** UIView 块动画、CATransaction、导航/模态/Tab/列表/滚动 hook；
//     · 因此可以单独把"转圈"调快，而不会像"全局倍率拉到 25"那样把块动画
//       一起压到 1 帧（那才是真正会触发完成回调配对故障的做法）；
//     · 仍受同一条 0.01s 下限约束；慢放模式不叠加（慢放是刻意看动画细节）。
//   设 5 = 精确恢复 v1.8.15 之前的 ÷speed² 手感。
// [极端档] 配置 App 的全局动画系数恢复"极端"档（0.0001）。旧版本写入的 0.0001
//   现在**映射到该档并明确警告**，而不是像 v1.8.16 那样被静默清除 ——
//   后者会把用户既有设置无提示地抹掉，是不对的。
// =========================================================================
//
// ============================ v1.8.13 优化加强 ============================
// [加强] 补齐老式 UIView 动画 API 的时长/延迟接管：
//   +[UIView setAnimationDuration:] 与 +[UIView setAnimationDelay:]
//   这是 beginAnimations:context: / commitAnimations 时代的唯一时长入口。
//   本支一直缺失（父项目 SpeedIntensifier 的增强层早已包含），而老 SDK、部分
//   国产 App 内部与第三方库仍在用这套 API —— 它们此前完全不受加速影响。
//   两个都是纯 setter（只改一个数值），是本项目风险最低的一类 hook。
//   双重缩放防护：这两个 setter 很可能被 UIKit 落到 CATransaction.setAnimationDuration:
//   上，或反过来被 animateWithDuration: 内部回调，因此：
//     · 进入时若已在自己的一次块动画包裹内（SIO_inUIViewAnim）→ 原样透传；
//     · 调用原 IMP 期间置起同一线程局部标记 → 抑制内部再入。
// =========================================================================
//
// ==================== v2.0.1 配置真实性审计修复（假功能清零）====================
// 逐键核对「配置 App 写 plist → dylib 读 plist → hook 真实生效」全链路后修复：
//
// [假功能 1] LongPress / LongPressDuration：配置 App 有开关与 0.20/0.30/0.40
//   档位，全局保存与 AppOverrides 都写入 plist，但 dylib 侧**从未读取、没有任何
//   实现**——「长按手势加速」自 v2.0.0 Max 起纯界面摆设。现 hook
//   UILongPressGestureRecognizer 的 initWithTarget:action: / initWithCoder: /
//   setMinimumPressDuration: 三个入口，仅把系统默认 0.5s（容差 0.45–0.55）替换
//   为配置时长；App 自定义的更短/更长时长原样透传，避免破坏特殊手势。
//
// [假功能 2] Notify：开关与自检文案都承诺「保存后前台目标 App 顶部出现 1.5 秒
//   生效提示」，dylib 无任何实现。现补 Darwin 热重载后的顶部 toast
//   （userInteractionEnabled=NO，绝不拦截触摸；仅前台、1.5s 节流）。
//
// [假功能 3] FastScroll / FastTap 界面标注「setter 强黏，防 App 改回」，实际
//   只在 didMoveToWindow 设置一次，App 后续改回即失效。补 setDecelerationRate:
//   与 setDelaysContentTouches: 强黏 hook，App 每次设置都被强制纠正。
//
// [崩溃隐患] v2.0.0 转圈检测沿 superlayer 链对 layer.delegate 发 superview
//   消息；delegate 不是 UIView 时（AVPlayerLayer 附属、自定义图层代理等）
//   unrecognized selector 直接崩，且整段无 @try。加 isKindOfClass 类型门与
//   @try 兜底。
//
// [体感·加载提速] UIActivityIndicatorView 转圈由 v2.0.0 的「完全不加速」改为
//   「按全局倍率加速、但钳制 0.4s 下限」：60Hz 下每圈约 24 帧仍平滑，彻底消除
//   ×5 下转圈反而显得最慢的违和感；不吃 LayerBoost；慢放模式依旧慢放。
// =========================================================================
//
// ==================== v2.0.7 bug 修复 + 性能优化 + UI 加速增强 ====================
// [真 bug] CATransaction set→get 双重缩放。v2.0.4 加的 +animationDuration
//   getter hook 会对「已经被 setter hook 缩放过的值」再缩一次：
//   App set 0.5 → setter 存 0.1（×5）→ 任何读取再缩成 0.02。两条写入路径
//   （sio_CATransaction_setDur 缩放写入 / SIO_setTransactionDuration 原样写入）
//   都会中招。修法：CATransaction 状态本身是线程私有的，用 __thread 记录本线程
//   最近一次写入值，getter 命中即原样返回，只缩「未经我们写入的默认值」。
// [性能·加载提速] dylib 不再链接 AVFoundation / UserNotifications。
//   链接期依赖会让 dyld 在**每个**被注入 App 的冷启动路径上加载整套
//   AVFoundation（连带 CoreMedia/CoreAudio 依赖链），即使该 App 从不用保活。
//   改为首次进入后台、真正需要音频断言时才 dlopen + dlsym 解析符号；
//   UserNotifications 类改为 objc_getClass 惰性获取（宿主不用通知时零成本）。
// [性能·热路径] gAnimNoop 恒等快速路径。加速模式 ×1 时所有时长换算都是
//   恒等变换，但 42 个 CATransaction 包裹点（触控高亮/单元格选中/滚动偏移…）
//   每次仍要 begin/set/commit 事务栈，纯开销还会把上下文时长强制成 0.25。
//   恒等时直接透传，恢复系统原生行为。
// [性能·热路径] CAAnimation setDuration: 恒等时跳过关联对象读写；
//   CALayer addAnimation: 恒等时跳过整条转圈检测链（superlayer 遍历 +
//   NSStringFromClass 分配）；_fbg_appState 的 dladdr 调用点判定加 8 槽
//   直映缓存（后台期 applicationState 是高频查询，dladdr 要遍历镜像表）。
// [新覆盖] UIViewPropertyAnimator startAnimationAfterDelay: 延迟同比缩放
//   （此前 init 时长已缩放、start 延迟原样放行，行为不一致）。
// [新覆盖] UIDocumentInteractionController presentOptionsMenuFromRect:/
//   presentOpenInMenuFromRect:（v1.8.18 只接了 presentPreviewAnimated:）。
// [新功能] LayoutAccel 开关（默认关）：包裹 -[UIView layoutIfNeeded]，
//   加速 SwiftUI/自动布局的隐式布局动画（CATransaction getter hook 覆盖
//   不到的读取路径）。实验性，配置 App 显式开启。
// =========================================================================
//
// =========================================================================
//
// ====================== v2.1.0 致命 bug 修复 + 性能 + 新加速引擎 ======================
// 逐行审计 v2.0.8（3369 行）后定位到的问题，按严重度排列：
//
// [致命 1] 真后台保活整条链路从未生效（不只是"效果弱"，是**完全没跑**）
//   FUBGEntry 里用 CFNotificationCenterAddObserver(dc, …, UIApplicationDidEnterBackgroundNotification, …)
//   注册前后台回调，其中 dc = CFNotificationCenterGetDarwinNotifyCenter()。
//   Darwin 通知中心只投递 notify_post() 发出的名字；UIApplicationDidEnterBackgroundNotification
//   是 **NSNotification 名字**，只经NSNotificationCenter 投递，两套系统互不相通。
//   后果链条：回调永不触发 → gPhysBg 永远是 NO
//             → _fbg_startAudio 永不调用（音频断言保活整个不启动）
//             → _fbg_appState 的`gUseScene && gPhysBg` 恒假（场景伪装也不启动）
//             → _fbg_watchdogFire 首行`if (!gUseAudio || !gPhysBg) return` 恒return（自愈轮询也不跑）
//   即v1.8.6 起写在界面上的「场景伪装 / 音频断言兜底 / 真后台保活」三个功能，
//   从未在任何一个 App 里执行过一行代码。修法：改用 NSNotificationCenter，
//   并显式回到主线程处理（Darwin/NS 通知的投递线程无保证）。
//
// [真 bug 2] 时长下限会把动画**变长**（与加速目的完全相反）
//   SIO_targetDuration 的下限钳制是`if (d > 0 && d < gFloor) d = gFloor;`——
//   无条件抬到下限。但当原始时长本来就比下限更短（App 用 0.005s 做微动画，
//   或用户把下限调到 0.05 而 App 用 0.02s）时，
//   「下限保护」把 0.001s 抬成 0.02s= 慢 20 倍，凭空造出卡顿。
//   瞬切模式更直接：`case 2: d = gFloor`，无论原值多少一律换成 gFloor ——
//   下限 0.05 时 0.005s 的动画被拉长 10 倍。
//   修法：钳制目标改为 min(gFloor, orig) —— 加速只能让动画变快，绝不变慢。
//
// [真 bug 3] 黑名单两套匹配语义互相打脸
//   SIO_reload 用 isEqualToString: 精确匹配；_fbg_isExcluded 用 hasPrefix: 前缀匹配。
//   配置 App 默认写入 com.tencent.wework，前缀语义下它会连带排除
//   com.tencent.weworkhelper / com.tencent.weworkx 等所有前缀 App ——
//   用户只想排除企业微信，实际排除了一串无关 App。
//   修法：统一为精确匹配；确需前缀时在条目末尾显式写 `*`（如 com.example.*）。
//
// [真 bug 4] 本项目自己的 UI 动画被自己的 hook 二次加速
//   SIO_showToast / FBGToastView 内部用 [UIView animateWithDuration:]做淡入淡出，
//   该调用会命中 sio_UV_anim_d 被再次缩放：×20 预设下 0.25s 变 0.0125s，
//   瞬切模式下变0.02s —— 提示"啪"一下闪过去，用户根本没看清提示内容。
//   修法：新增线程局部「内部 UI」旁路标记，本项目自绘 UI 全程置位，SIO_blocked 命中即整体放行。
//
// [真 bug 5] 瞬切模式改写 UIScrollView 的 animated 语义
//   sio_SV_setContentOffset / sio_SV_scrollRect 在 gMode==2 时把 animated:YES 改成
//   animated:NO 并置 kCATransactionDisableActions —— 而文件里v1.8.3/v1.8.15 两处注释
//   恰恰把这个做法列为微信预览卡死的根因（「绝不改写 animated 语义」）。
//   同一份代码里一边写禁令一边实施，且这两个 hook **不受 ListAccel 门控**，
//   即列表加速关闭时仍会改写语义。修法：保留 animated:YES，只压事务时长（与全项目口径统一）。
//
// [性能 6] 转圈检测每次 addAnimation 都做字符串分配
//   sio_layer_addAnim 对每个 superlayer 的 delegate 做 NSStringFromClass +
//   [n containsString:] ×2 —— 每次显式动画至少一次 NSString 堆分配 + 两次子串搜索，
//   而这条路径在列表/转圈页面可达每秒数十次。
//   修法：① 先做零分配的 isKindOfClass 快速判定，命中即返回，不进入字符串分支；
//         ② 加16 槽「类 → 是否转圈候选」直接映射缓存，类指针稳定，命中即 O(1)；
//         ③ superlayer 遍历加上限，防止异常深的层级。
//
// [性能 7] CAAnimation 每次 setDuration: 都有一次 NSNumber 堆分配
//   SIO_saveOrigDur 存原始时长用 @(d) 装箱 + 关联对象写入，显式动画高频路径上
//   是稳定的堆分配来源。修法：改用一次性分配的 POD 盒子缓存最近值，
//   且同一动画重复设同一时长时不重复写关联对象。
//
// [新功能 8] 速率加速引擎（SpeedMode，默认关，全局）
//   此前唯一手段是压缩 duration，天然有两个硬伤：① 撞时长下限（见 bug 2）；
//   ② 把duration 压到 1-2 帧后，动画内部按时间比例推进的逻辑（关键帧插值、
//   弹簧物理积分步长）会失真，出现跳帧/抽搐。
//   新增「速率模式」：改 **播放速率** 而非时长 —— hook -[CAAnimation setSpeed:]，
//   把 App 设的 1.0 换成 gSpeed（慢放则换 1/slowFactor）。
//   时长与关键帧时间轴原样保留，物理与插值完全正确，只是整体跑得更快，
//   且不存在下限碰撞。这是「无损加速」，与时长模式互补（可二选一，默认沿用时长模式）。
//   [安全边界] App 显式设 speed != 1.0（视频/音频同步）一律透传，只接管"默认值 1.0"。
//   [安全边界] 慢放模式不叠加速率倍率。
//
// [新覆盖 9] UIViewPropertyAnimator continueAnimationWithTimingParameters:duration:
//   iOS 11+ 的链式续播入口。此前 startAnimationAfterDelay: 已缩放（v2.0.7），
//   但续播时传入的新duration 原样放行 —— 一条链里首段加速、续段不加速，行为割裂。
//
// [新覆盖 10] UIWindow setRootViewController:
//   App 换根控制器（登录→主页、启动分流）时的交叉淡入此前无任何覆盖。
//
// [新功能 11] 辅助功能让位（ReduceMotionRespect，默认开）
//   系统「减弱动态效果」（UIAccessibilityIsReduceMotionEnabled）为真时，
//   说明用户明确要求减少动效。本项目逆其道而行属于对用户意图的覆盖。
//   新开关打开时自动整体旁路（与黑名单同级，最高优先级），让系统设置真正生效。
//   默认开：这是对既有系统语义的尊重，代价是这类用户看不到加速效果
//   （可在配置 App 关闭该让位）。
//
// [覆盖修正 12] UIScrollView 两个动画 hook 的门控与短路口径统一
//   setContentOffset:animated: / scrollRectToVisible:animated: 既不受 ListAccel 控制、
//   也没接 SIO_animNoop，与全项目「危险功能 fail-safe、恒等配置零干预」的口径不一致。
//   修法：纳入统一门控，恒等时直接透传。
// =========================================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
// v2.0.7：不再 import AVFoundation / UserNotifications —— 二者改为运行时惰性
// 解析（dlopen + dlsym / objc_getClass），把链接依赖从注入 App 的启动路径上拿掉。
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <pthread.h>
#import <dlfcn.h>
#import <notify.h>
// v2.5.0：os_unfair_lock 用于配置缓存与「启动完成」栅栏的无锁竞争保护。
// 它比 OSSpinLock 安全（无优先级反转）、比 pthread_mutex 快（无系统调用陷入），
// 且在 iOS 10+ 全平台可用，与本项目的部署目标一致。
#import <os/lock.h>
#import "FUBGNoiseData.h"

#define kPrefDomain  @"com.apple.UIKit"
#define kPrefPath    @"/var/Managed Preferences/mobile/com.apple.UIKit.plist"
#define kNotifyName  @"com.local.sioriginal.settingschanged"

// ---------- 配置 ----------
static BOOL     gEnabled   = YES;
static int      gMode      = 0;      // 0=加速 1=慢放 2=瞬切
static double   gSpeed     = 5.0;    // 加速倍率（时长 ÷ 倍率）
static double   gSlowFactor = 2.0;   // 慢放倍率（时长 × 因子）
static BOOL     gSpring    = YES;    // CASpring 参数缩放
static BOOL     gExtra     = YES;    // 导航/模态进阶转场
static BOOL     gListAccel = NO;     // TV/CV 列表全家桶（v1.8.11 起纯开关控制，默认关）
static BOOL     gZoomAccel = NO;     // v1.8.15：UIScrollView 缩放动画（setZoomScale:animated: 等），默认关
static BOOL     gFastScroll = NO;    // v1.8.16：滑行惯性加急（decelerationRate=Fast），默认关
static BOOL     gFastTap = NO;       // v1.8.16：取消列表点击延迟（delaysContentTouches=NO），默认关
static double   gLayerBoost = 1.0;   // v1.8.17：显式动画（CAAnimation/CALayer）额外倍率，默认 1（不额外加速）
static double   gFloor = 0.02;       // v2.0.0：动画时长下限（秒），默认 0.02
static double   gTransitionBoost = 1.0; // v2.0.0：转场独立额外倍率，默认 1（不额外加速）
static BOOL     gLongPress = YES;    // v2.0.1：长按手势加速（默认 0.5s → 配置时长），默认开
static double   gLongPressDuration = 0.30; // v2.0.1：长按触发时长，默认 0.30s
static BOOL     gNotify = YES;       // v2.0.1：保存配置后在前台目标 App 顶部弹 1.5s 提示
static BOOL     gLayoutAccel = NO;   // v2.0.7：layoutIfNeeded 隐式布局动画加速（实验），默认关
// v2.1.0：速率加速引擎。gSpeedMode=1 时改 CAAnimation/CALayer 的 speed（播放速率）
// 而非 duration（时长），见文件头[新功能 8]。默认 0 = 沿用 v2.0.8 的时长模式。
static BOOL     gSpeedMode = NO;
// v2.1.0：辅助功能让位。系统「减弱动态效果」为真时整体旁路本项目（[新功能 11]）。
// 默认开：用户明确要求减少动效时，不应被加速工具覆盖。
static BOOL     gRespectReduceMotion = YES;
// v2.3.0：帧对齐引擎（替代 v2.0.8 的 ProMotion120）。默认开。
// 见 SIO_alignToFrameBoundary() 的完整推导。核心：把缩放后的时长
// 对齐到「设备帧周期」的整数倍，消除每帧渲染时刻的漂移。
static BOOL     gFrameAlign = YES;
// v2.3.0：帧周期（秒）。惰性求值一次 —— 120Hz=1/120≈0.00833，60Hz=1/60≈0.01667。
// 取 maximumFramesPerSecond 的倒数；若不可用则回退 60Hz。
static double   gFramePeriod = 0.0;
// v2.0.7：加速模式 ×1 时所有时长换算均为恒等变换 —— CATransaction 包裹类 hook
// 此时 begin/set/commit 纯属开销（且会把上下文时长强制成 0.25/0.35），统一短路。
// 在 SIO_reload 末尾按最终生效值（含 App 覆盖）计算。
static BOOL     gAnimNoop = NO;
// v2.5.0[性能·P1] 预计算的「系统默认隐式动画时长 0.25s」缩放结果。
// sio_layer_actionForKey 是最热的 hook（每次可动画属性赋值都过一遍），
// 原实现每次命中都要跑一遍 SIO_targetDuration → SIO_alignToFrameBoundary
// （含 floor 除法与帧周期读取）。而它的输入恒为 0.25 —— 结果只随配置变，
// 不随调用变。放到 SIO_reload 里算一次，热路径退化成一次 double 读。
static double   gImplicitActionDur = 0.25;
// v2.0.1：转圈（UIActivityIndicatorView）专属时长下限。旋转动画低于该值会因
// 帧率采样混叠出现频闪/视觉倒转（×5 把 1s 压到 0.2s 时肉眼像"越转越慢"）。
// 0.4s ≈ 每秒 2.5 圈，60Hz 下每圈约 24 帧，平滑且明显比系统默认快。
static const double kSIOSpinnerFloor = 0.4;
static BOOL     gIsWeChat  = NO;     // 微信缩放预览守卫用（L104）
// v1.8.12：黑名单在重载时一次性解析成本进程布尔值，热路径零分配（见 SIO_reload）
static BOOL     gSelfBlacklisted = NO;
static NSString *gSelfBundle = nil;
// v2.5.0[性能·P0] 清洗后的黑名单条目缓存。
// 原本这份数组被解析两次：SIO_reload() 解析一遍只为算 gSelfBlacklisted 这一个布尔，
// 随即在函数末尾丢弃；_fbg_loadPref() 又对同一份 plist 重新
// addObjectsFromArray + 逐条 stringByTrimmingCharactersInSet: 解析一遍。
// 每次 trim 都要现造一个 NSCharacterSet（whitespaceCharacterSet 每次调用返回新对象），
// 而这两个解析都发生在 pre-main 的两个 constructor 里 —— 启动期付两次。
// 现在 SIO_reload 解析时顺手留一份，保活侧直接取用，第二次解析彻底消失。
static NSArray *gBlacklistItems = nil;
// v2.5.0：SIO_reload 是否已跑过。两个 constructor 的执行顺序由 dyld 决定、
// 不保证先后；保活侧现在复用动画侧的黑名单解析结果，就必须能确认「它已经跑过」。
// 没有这个标志时，若 FUBGEntry 先于 SIOriginalInit 执行，gBlacklistItems 还是 nil，
// 排除表会静默变空 —— 黑名单对保活失效，且没有任何报错。这类「顺序依赖的静默降级」
// 正是本轮要一并消掉的隐患。
static BOOL     gReloadDone = NO;
// v2.5.0：编辑模式安全护栏（来源 FakeCl0ckUp）。桌面图标/Switcher 编辑期间
// 所有动画加速旁路 —— 用户在拖拽/ rearranging 图标时需要正常动画速度才能
// 准确定位。SBIconController setIsEditing: 与 SBAppSwitcherController
// _beginEditing/_stopEditing 在 SpringBoard 进程中被 hook。
static BOOL     gEditing = NO;

static pthread_key_t gInUIViewAnimKey;
static pthread_key_t gInPAInitKey;   // v1.8.12：UIViewPropertyAnimator 初始化重入保护
// v2.1.0：本项目自绘 UI（toast / 悬浮球）的线程局部旁路标记。
// 这些 UI 用[UIView animateWithDuration:] 做动画，会命中本 dylib 自己的 hook 被二次加速
// （×20 下 0.25s → 0.0125s，提示"啪"一下闪过去，用户根本看不清）。
// 自绘 UI 全程置位此标记，SIO_blocked 命中即整体放行，动画按系统原生时长播放。
static pthread_key_t gInternalUIKey;

static inline BOOL SIO_inUIViewAnim(void)   { return (BOOL)(intptr_t)pthread_getspecific(gInUIViewAnimKey); }
static inline void SIO_setUIViewAnim(BOOL v){ pthread_setspecific(gInUIViewAnimKey, (void *)(intptr_t)(v ? 1 : 0)); }
static inline BOOL SIO_inPAInit(void)       { return (BOOL)(intptr_t)pthread_getspecific(gInPAInitKey); }
static inline void SIO_setPAInit(BOOL v)    { pthread_setspecific(gInPAInitKey, (void *)(intptr_t)(v ? 1 : 0)); }
// v2.1.0：内部 UI 标记。热路径读它是一次 pthread_getspecific（TLS 数组内寻址，无锁），
// 显著快于原实现里动辄 NSStringFromClass + containsString 的字符串方案。
static inline BOOL SIO_inInternalUI(void)  { return (BOOL)(intptr_t)pthread_getspecific(gInternalUIKey); }
static inline void SIO_setInternalUI(BOOL v){ pthread_setspecific(gInternalUIKey, (void *)(intptr_t)(v ? 1 : 0)); }

// v1.8.12：原 IMP 判空（红线规则 #4）。方法不存在时 hook 不会被安装，这里是纯防御：
// 万一 orig 为空，直接放弃本次拦截，绝不对空指针发消息。
#define SIO_REQUIRE_ORIG(imp)      do { if (__builtin_expect((imp) == NULL, 0)) return; } while (0)
#define SIO_REQUIRE_ORIG_NIL(imp)  do { if (__builtin_expect((imp) == NULL, 0)) return nil; } while (0)
#define SIO_REQUIRE_ORIG_ZERO(imp) do { if (__builtin_expect((imp) == NULL, 0)) return 0; } while (0)

// ---------- v1.8.15：CAAnimation 时长缩放幂等标记 ----------
// 两个入口都会缩放时长：CAAnimation 的 setDuration: 属性 setter，以及
// CALayer 的 addAnimation:forKey: 兜底。App 标准写法「先设 duration 再 add」
// 会让两个入口都跑一遍 → 连缩两次（×speed²），并容易撞 0.01s 下限。
// 用关联对象打标：谁先处理谁打标，另一个看到标记就跳过。
// 注意：显式 setDuration: 不受标记限制 —— 那是 App 的新意图，必须按新值重新缩放。
// v2.5.0：kSIOScaledMark 已废弃 —— 「已缩放」标记并入 kSIOOrigDur 的盒子
// （见下方 SIODoubleBox），少一次全局关联表加锁查找。保留其声明位置的说明
// 以免后人误以为漏了什么：现在只有一个关联键。
static const void *kSIOOrigDur = &kSIOOrigDur;

// v2.1.0[性能 7]：原时长改存「极小 ObjC POD 盒子」。
// 原实现 SIO_saveOrigDur 用 @(d) 装箱 —— 每次显式动画的每次 setDuration: 都有一次
// NSNumber 堆分配 + 一次关联对象写入，是显式动画高频路径上稳定的分配来源。
// 现在改为：用只含一个 double ivar 的极小盒子，关联对象 RETAIN 持有；
// 同一动画反复设同一时长时只写 ivar（零新分配）。
// 注意：ARC 下禁止把 malloc 的 double* 直接当 id 存取（id→double* 转换被拒，
// 且 RETAIN 策略会对非对象指针发 retain 导致崩溃），故必须用 ObjC 类承载。
//
// v2.5.0[性能·P1] 「已缩放」标记并入同一个盒子。
// 原本「原时长」与「已缩放标记」是**两个独立的关联对象键**，于是一次显式动画的
// 处理要触碰关联对象表最多三次（save 1 读 + 1 写，mark 1 写）。
// 而 objc_get/setAssociatedObject 走的是全局 AssociationsManager ——
// 内部是一把自旋锁保护的哈希表，多线程同时做动画时会形成真实的锁竞争，
// 不只是"多一次查表"那么轻。
// 合并后：一次动画最多 1 次读 + 1 次写，锁竞争概率降到约 1/3。
@interface SIODoubleBox : NSObject { @public double value; BOOL scaled; }
@end
@implementation SIODoubleBox
@end

// 取（必要时创建）盒子。create=NO 时永不分配，用于纯查询路径。
static inline SIODoubleBox *SIO_boxFor(id anim, BOOL create) {
    if (!anim) return nil;
    SIODoubleBox *box = (SIODoubleBox *)objc_getAssociatedObject(anim, kSIOOrigDur);
    if (box || !create) return box;
    box = [SIODoubleBox new];
    box->value  = -1.0;
    box->scaled = NO;
    objc_setAssociatedObject(anim, kSIOOrigDur, box,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return box;
}

static inline void SIO_saveOrigDur(id anim, double d) {
    SIODoubleBox *box = SIO_boxFor(anim, YES);
    if (box) box->value = d;     // 盒子已在：原地更新，零分配
}

// v2.5.0[性能·P1] 关于「合并」的准确说明（供后来者核对，避免重复踩坑）：
//   把 scaled 字段并进盒子**本身不省任何操作** —— 真正省的是调用点少查一次表。
//   这一点是 tools/bench_v250.py 的 B3 基准跑出来的：最初只做了字段合并，
//   次数是 3→3，一分没省；必须让 sio_CAAnim_setDuration 里的
//   「存原值 + 打标」共用同一次 SIO_boxFor 才是 3→2。
//   因此下面两个调用点都是手写 box 操作，而不是各调一次 helper ——
//   顺序也有讲究：标记必须在调用原 IMP 之后设置（原 IMP 抛异常时不留标记），
//   所以不能简单地把两步合成一个 helper 提前调用。
static inline double SIO_getOrigDur(id anim) {
    SIODoubleBox *box = SIO_boxFor(anim, NO);
    return box ? box->value : -1.0;
}

// v2.5.0[性能·P1] 「已缩放」标记改存盒子内，与 SIO_getOrigDur 共用同一次
// 关联对象读取，不再单独占一个关联键（少一次全局关联表加锁查找）。
// 语义完全不变：仍然是「这个动画的时长已经被我们处理过」。
// 定义位置必须在 SIODoubleBox 与 SIO_boxFor 之后 —— 前向声明的顺序问题
// 在本项目历史上出过编译错误（见文件头 v2.3.0 的说明），此处按依赖顺序排列。
static inline BOOL SIO_animScaled(id anim) {
    SIODoubleBox *box = SIO_boxFor(anim, NO);
    return box ? box->scaled : NO;
}
static inline void SIO_markAnimScaled(id anim) {
    SIODoubleBox *box = SIO_boxFor(anim, YES);
    if (box) box->scaled = YES;
}

// 帧周期（秒）。惰性求值并缓存 —— maximumFramesPerSecond 在进程内不会变。
// 注意：这里只「读取」设备能力，与被移除的 ProMotion120 不同 ——
// 那个功能是去改写 App 设定的帧率上限（干预渲染），这个只是拿到帧长做时长计算。
static inline double SIO_framePeriod(void) {
    double p = gFramePeriod;
    if (__builtin_expect(p > 0.0, 1)) return p;
    @try {
        NSInteger fps = [[UIScreen mainScreen] maximumFramesPerSecond];
        if (fps <= 0) fps = 60;
        p = 1.0 / (double)fps;
    } @catch (__unused NSException *e) {
        p = 1.0 / 60.0;
    }
    if (p <= 0.0) p = 1.0 / 60.0;
    gFramePeriod = p;
    return p;
}

// v2.3.0[新功能] 帧对齐引擎 —— 替代 ProMotion120改善「感觉不流畅」。
//
// 问题：CoreAnimation 按「时间」推进动画，在第 t = 0, T, 2T, ... 时刻计算并提交帧。
// 设备每P 秒刷新一帧。若动画时长 D 不是 P 的整数倍，则最后一帧的
// 实际显示时间不足 P就被提交，随后又空等P 才提交下一帧 ——
// 这一个「显示不足一帧 + 空等一帧」的周期就是肉眼看到的顿挫/jank。
//
// 举例（60Hz，P=16.67ms）：App 给 0.25s → 15 帧整除，正好对齐，无抖动。
// App 给 0.3s  → 300/16.67 = 18.0 帧，仍对齐。
// 但本项目把 0.3s 除以倍率5 → 0.06s → 60/16.67 = 3.6 帧，**不对齐**：
// 3帧正常显示 + 最后 0.6 帧的空档，视觉上就是「最后一步顿一下」。
// 倍率越高（用户常调到 ×20/×50），不对齐的余数越大，顿挫越明显。
//
// 修法：把换算后的时长对齐到 P 的整数倍 —— 向下取整到最近的整帧。
//   0.06s → floor(0.06 / 0.01667) × 0.01667 = 3 × 0.01667 = 0.05s
// 即 3 帧整齐跑完，没有半帧空档。
//
// 为什么这比 120Hz 更根本：120Hz 只是把 P 从 16.67 减到 8.33（帧数翻倍），
// 但**不对齐的问题依然存在**（0.06s 在 120Hz 下是 7.2 帧，仍有余数）。
// 帧对齐是让「时间轴与帧栅格严格咬合」，无论设备多少 Hz 都成立。
//
// [安全边界] 对齐只能缩短、不能延长动画 —— 绝不让某个动画因为对齐而变慢。
// [安全边界] 时长不足一帧（P）时保持原值：此时强制对齐为 1 帧会让动画变慢 10 倍以上。
// [安全边界] 慢放模式不参与：对齐会缩短时长，与慢放语义直接冲突。
// v2.3.0：SIO_alignToFrameBoundary 内部要判断是否处于速率模式，
// 而 SIO_speedModeActive 定义在其后 —— 前向声明必须先于本定义（原源码把
// 声明放在定义之后，编译报 implicit declaration，此处已修正顺序）。
static inline BOOL SIO_speedModeActive(void);

static inline double SIO_alignToFrameBoundary(double d) {
    if (!gEnabled || !gFrameAlign) return d;
    if (d <= 0.0) return d;
    if (gMode == 1) return d;                 // 慢放：不打断
    if (SIO_speedModeActive()) return d;      // 速率模式：时间轴原生，不参与
    double P = SIO_framePeriod();
    if (P <= 0.0) return d;
    double n = floor(d / P);
    if (n < 1.0) return d;                    // 不足一帧：保持原值（否则会变慢）
    double aligned = n * P;
    // 对齐后必须仍严格短于原时长（浮点边界保险），且不少于 1 帧
    if (aligned >= d) return d;
    return aligned;
}

// v2.3.0：SIO_alignToFrameBoundary 定义先于 SIO_targetDuration，无需前向声明
// （原源码在此处的两行声明位于各自定义之后，属无效代码，已移到定义之前）。

static inline double SIO_targetDuration(double orig) {
    if (!gEnabled) return orig;
    double d;
    switch (gMode) {
        case 1:  d = orig * gSlowFactor; break;            // 慢放
        // v2.1.0 真 bug 2 修复：瞬切原先是 `d = gFloor`，无论原值多少一律换成下限。
        // 当原时长本就比下限更短（App 的0.005s 微动画，或用户把下限调到 0.05 而 App 用 0.02s）
        // 时，这会把动画**拉长**数倍——与加速目的完全相反，凭空造出卡顿。
        // 加速类变换只能让动画变快，绝不能变慢：目标时长不得超过原值。
        case 2:  d = (gFloor < orig) ? gFloor : orig; break;
        default:
            if (gSpeed <= 1.0001) return orig;
            d = orig / gSpeed;         break;              // 加速
    }
    // v2.1.0：下限钳制目标从 gFloor 改为 min(gFloor, orig)。
    // 原实现 `if (d > 0 && d < gFloor) d = gFloor;` 会把 0.001s 抬到 0.02s（慢 20 倍）。
    // 加速器的语义是「更快」，绝不该让任何动画变慢，因此下限只在 orig 本身就 ≥ 下限时生效。
    if (d > 0.0) {
        double lo = (gFloor < orig) ? gFloor : orig;
        if (d < lo) d = lo;
    }
    // v2.3.0：帧对齐。所有时长换算的唯一出口在此，因此只需在此处施加一次，
    // 块动画 / 转场 / CAAnimation / 列表 / 滚动 / 控件等全部自动受益。
    // 放在下限钳制「之后」：先确定最终时长，再对齐到帧栅格，顺序不能反 ——
    // 若先对齐再钳制，下限会把已对齐的值重新抬高，对齐就白做了。
    d = SIO_alignToFrameBoundary(d);
    return d;
}

// v1.8.17：显式动画（CAAnimation / CALayer）路径专用的时长换算。
// 在全局倍率之上再叠加 LayerBoost，仅作用于这条路径：
// 转圈 / 进度 / 旋转 / 地图相机这类动画都走「设时长 → addAnimation」，
// v1.8.15 修掉双重缩放后它们从 ÷speed² 回到 ÷speed，肉眼明显变慢。
// 单独给它们加倍率，就不会像"把全局倍率拉到 25"那样把 UIView 块动画一起压到 1 帧。
// 慢放模式不叠加（慢放是刻意要看动画细节），下限仍是同一条 0.01s。
static inline double SIO_targetDurationLayer(double orig) {
    if (!gEnabled) return orig;
    double d = SIO_targetDuration(orig);
    if (gMode == 1) return d;
    if (gLayerBoost > 1.0001 && d > 0.0) {
        d = d / gLayerBoost;
        // v2.1.0 真 bug 2：同 SIO_targetDuration，下限不得反向拉长动画。
        double lo = (gFloor < orig) ? gFloor : orig;
        if (d < lo) d = lo;
        // v2.3.0：LayerBoost 又除了一次，帧对齐必须重做。
        // 不能省这一步 —— 上游 SIO_targetDuration 里对齐的是「除 LayerBoost 之前」的值，
        // 这里再除之后余数会变回不对齐的状态。
        d = SIO_alignToFrameBoundary(d);
    }
    return d;
}

// v2.1.0[新功能 8]：速率加速倍率（作用于 CAAnimation.speed 而非 duration）。
// 返回 1.0 表示不介入。慢放模式下返回 1/slowFactor（等价于把时长乘 slowFactor，
// 但不改时长，因此关键帧时间轴与物理积分步长保持原生正确）。
// 速率模式下时长类换算全部退化为恒等 —— 由 SIO_speedModeActive() 统一短路。
static inline double SIO_speedScale(void) {
    if (!gEnabled || !gSpeedMode) return 1.0;
    if (gMode == 2) return 20.0;                 // 瞬切：极高速率
    if (gMode == 1) return (gSlowFactor > 1.0) ? (1.0 / gSlowFactor) : 1.0;  // 慢放
    return (gSpeed <= 1.0001) ? 1.0 : gSpeed;   // 加速
}

// 速率模式是否启用。启用后所有「改duration」的路径必须退化为恒等，
// 否则时长与速率同时被改= 实际倍率相乘，与用户设置的倍率不符，且双重下限钳制会失真。
static inline BOOL SIO_speedModeActive(void) {
    if (!gEnabled || !gSpeedMode) return NO;
    double s = SIO_speedScale();
    return (fabs(s - 1.0) > 1e-6);
}

static inline double SIO_springScale(void) {
    // 弹簧时间缩放与倍率一致；慢放时反向放大
    if (!gEnabled) return 1.0;
    if (gMode == 1) return gSlowFactor;
    if (gMode == 2) return 20.0;
    return (gSpeed <= 1.0001) ? 1.0 : gSpeed;
}

// v1.8.12：设置事务时长的唯一正确入口。
// 本体代码里凡是自己构造 CATransaction 时长的地方（导航/模态/Tab/列表/滚动/系统动画），
// 都必须走这里：`[CATransaction setAnimationDuration:X]` 会再次进入已被 swizzle 的
// setAnimationDuration:，于是同一个 X 被 SIO_targetDuration 缩放第二次
// （例如期望 0.07s 实际 0.014s，慢放期望 0.7s 实际 1.4s）。
// 这里借线程局部标记抑制这一层，嵌套时原样恢复。
static inline void SIO_setTransactionDuration(double d) {
    BOOL was = SIO_inUIViewAnim();
    SIO_setUIViewAnim(YES);
    [CATransaction setAnimationDuration:d];
    SIO_setUIViewAnim(was);
}

// ---------- v1.8.14 App 级配置覆盖 + 列表 hook 硬保护 ----------

static NSString *SIO_bundleID(void) {
    if (!gSelfBundle) gSelfBundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return gSelfBundle;
}

// v2.1.0 真 bug 3 修复：黑名单/排除名单的唯一匹配实现。
// 原代码两套语义互相打脸：
//   SIO_reload     用 isEqualToString:（精确）
//   _fbg_isExcluded 用 hasPrefix:      （前缀）
// 配置 App 默认写入 com.tencent.wework，前缀语义下会连带排除
// com.tencent.weworkhelper / com.tencent.weworkx 等所有同前缀 App——
// 用户只想排除企业微信，实际排除了一串无关 App。
// 统一为：默认精确匹配；确需前缀时在条目末尾显式写 `*`（如 com.example.*）。
static BOOL SIO_bundleMatches(const NSString *entry) {
    if (![entry isKindOfClass:[NSString class]] || !entry.length) return NO;
    NSString *bid = SIO_bundleID();
    if (!bid.length) return NO;
    if ([entry hasSuffix:@"*"]) {
        NSString *prefix = [entry substringToIndex:entry.length - 1];
        if (!prefix.length) return NO;
        return [bid hasPrefix:prefix];
    }
    return [bid isEqualToString:entry];
}

// AppOverrides 结构：
//   AppOverrides = { "com.sfic.knight" = { Speed = 8; Mode = 0; Spring = 1; Extra = 1;
//                                          ListAccel = 0; Enabled = 1;
//                                          FUBGEnabled = 1; FUBGSceneFake = 1; FUBGAudioKeep = 1; }; }
// 命中当前进程则返回该字典，否则 nil。优先级：硬保护 > App 覆盖 > 全局。
static NSDictionary *SIO_appOverride(NSDictionary *root) {
    if (![root isKindOfClass:[NSDictionary class]]) return nil;
    id ov = root[@"AppOverrides"];
    if (![ov isKindOfClass:[NSDictionary class]]) return nil;
    NSString *bid = SIO_bundleID();
    if (!bid.length) return nil;
    id mine = ((NSDictionary *)ov)[bid];
    return [mine isKindOfClass:[NSDictionary class]] ? (NSDictionary *)mine : nil;
}

// 列表 hook 硬保护名单。
// 名单内 App 的 ListAccel 恒为 NO：全局开关、App 覆盖都无法打开。
// 名单来源为本项目实测记录 —— 这些 App 的列表 UI 与 TV/CV 变更类 hook 冲突，
// 会破坏列表状态机导致卡死/崩溃。安全项 fail-safe，不接受"忘了关"。
// v1.8.19：移除 com.sfic.knight（顺丰同城骑士），由用户在黑名单/覆盖中自行控制。
static BOOL SIO_listHardBlocked(void) {
    static NSArray *blocked = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocked = @[
            @"com.apple.springboard",  // 桌面进程，内部大量 TV/CV，一旦打开就是黑屏/白苹果
        ];
    });
    NSString *bid = SIO_bundleID();
    if (!bid.length) return NO;
    return [blocked containsObject:bid];
}

// v1.8.16：内置保活排除名单 —— 这些进程绝不参与真后台保活。
// SpringBoard 本身就是场景宿主，在它内部吞掉 scene 更新会影响**全局所有 App** 的
// 后台化行为，而保活（音频断言 + 场景伪装）对桌面进程本身毫无意义。
static BOOL SIO_fbgBuiltinExcluded(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[ @"com.apple.springboard" ];
    });
    NSString *bid = SIO_bundleID();
    return bid.length && [list containsObject:bid];
}

// 本进程是否命中 App 覆盖 / 是否被列表硬保护（供启动日志与配置排查）
static BOOL gHasAppOverride   = NO;
static BOOL gListHardGuarded  = NO;

// v2.2.0[启动提速] plist 读取去重。
// 构造函数里原本会同步读两次同一个文件：SIO_reload() 一次、
// FUBGEntry → _fbg_loadPref() 又一次。每次都是 dictionaryWithContentsOfFile:，
// 即一次完整的 mmap + plist 反序列化 + 对象图分配，全都发生在 dyld 加载期
// （dyld 会在main 之前同步跑完 __attribute__((constructor))）。
// 这段阻塞时间直接叠加到 App 启动耗时上 —— 注入库自己成了启动变慢的原因。
// 现在：构造函数只读一次，缓存 NSDictionary 引用，
// 动画侧与保活侧都从这份缓存取，第二次读变成一次指针取值。
static NSDictionary *gPrefCache = nil;
// =============================================================================
// v2.5.0[稳定性·P2] gPrefCache 的并发访问此前是**不加保护的裸读写**。
// 写入方是 Darwin 通知回调线程（SIO_settingsChanged 里 `gPrefCache = nil`），
// 读取方是任意动画线程（SIO_reload → SIO_prefSnapshot）。
// 在 ARC 下对一个 __strong 静态变量赋值会 `objc_release` 旧值 ——
// 于是「A 线程刚取出指针、还没 retain」与「B 线程赋新值触发 release」
// 之间存在真实的时间窗，结果是悬垂指针 → EXC_BAD_ACCESS。
// 触发条件是「用户在配置 App 连续保存」遇上「目标 App 正在大量播动画」，
// 属于低概率但确实可能的崩溃，而且一旦发生无法从日志定位。
//
// 修法：所有访问走 os_unfair_lock。选它而不选 pthread_mutex /
// @synchronized 是因为：路径极短（一次哈希/指针读），
// os_unfair_lock 在无竞争时只是一条原子指令，不陷入内核；
// 有竞争时才 syscall。对本路径的开销量级（纳秒）可以接受。
// 磁盘 IO 特意放在锁外 —— 把一次 mmap + plist 反序列化压在锁里，
// 会让所有动画 hook 在重载瞬间集体阻塞，那是比不加速更糟的卡顿。
// =============================================================================
static os_unfair_lock gPrefLock = OS_UNFAIR_LOCK_INIT;

// 取配置快照。热重载（Darwin 通知）会让缓存失效。
static NSDictionary *SIO_prefSnapshot(void) {
    os_unfair_lock_lock(&gPrefLock);
    NSDictionary *d = gPrefCache;
    os_unfair_lock_unlock(&gPrefLock);
    if (d) return d;
    // 未缓存：磁盘 IO 在锁外做（见上方说明）
    NSDictionary *fresh = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    os_unfair_lock_lock(&gPrefLock);
    if (!gPrefCache) gPrefCache = fresh;   // 期间可能已被别的线程填好
    d = gPrefCache;
    os_unfair_lock_unlock(&gPrefLock);
    return d;
}

// 让缓存失效（配置变更后调用）。
static void SIO_invalidatePrefCache(void) {
    os_unfair_lock_lock(&gPrefLock);
    gPrefCache = nil;
    os_unfair_lock_unlock(&gPrefLock);
}

static void SIO_reload(void) {
    gReloadDone = YES;   // v2.5.0：无论成功失败，解析已经发生过一次
    NSDictionary *d = SIO_prefSnapshot();
    if (!d) {
        // v2.0.6：补可观测性。原实现在此静默 return，用户看到「配置没生效」时
        // 无从判断是 plist 缺失、路径错、还是权限不足 —— 而这三种的处理方式完全不同。
        // 只在缺配置时打一条日志（每次热重载至多一条，Darwin 通知节流由上层负责），
        // 并明确「回落默认值」而不是让用户误以为配置已加载。
        NSLog(@"[SIOriginal] config plist not readable at %s — falling back to built-in defaults "
              @"(speed x%.1f, mode=accelerate). Write it from the config app, or check "
              @"/var/Managed Preferences/mobile permissions.",
              kPrefPath.UTF8String, 5.0);
        gEnabled   = YES;
        gMode      = 0;
        gSpeed     = 5.0;
        gSlowFactor = 2.0;
        gSpring    = YES;
        gExtra     = YES;
        gListAccel = NO;
        gZoomAccel = NO;
        gFastScroll = NO;
        gFastTap    = NO;
        gLayerBoost = 1.0;
        gFloor = 0.02;
        gTransitionBoost = 1.0;
        gLongPress = YES;
        gLongPressDuration = 0.30;
        gNotify = YES;
        gLayoutAccel = NO;
        gSpeedMode = NO;
        gRespectReduceMotion = YES;
        gFrameAlign = YES;
        gSelfBlacklisted = NO;
        gBlacklistItems  = nil;   // v2.5.0：无配置则无黑名单，保活侧同样取空
        gHasAppOverride  = NO;
        gListHardGuarded = SIO_listHardBlocked();
        if (gListHardGuarded) gListAccel = NO;
        gAnimNoop = (gMode == 0 && gSpeed <= 1.0001);
        gImplicitActionDur = SIO_targetDuration(0.25);
        return;
    }
    gEnabled = [d[@"Enabled"] boolValue];
    int mode = [d[@"Mode"] intValue];
    gMode = (mode >= 0 && mode <= 2) ? mode : 0;
    double sp = [d[@"Speed"] doubleValue];
    gSpeed = (sp >= 1.0 && sp <= 50.0) ? sp : 5.0;
    double sf = [d[@"SlowFactor"] doubleValue];
    gSlowFactor = (sf > 1.0 && sf <= 10.0) ? sf : 2.0;
    gSpring = d[@"Spring"] ? [d[@"Spring"] boolValue] : YES;
    gExtra  = d[@"Extra"]  ? [d[@"Extra"] boolValue]  : YES;
    // v1.8.12：缺键默认 NO（原来 `: YES`）。配置 plist 一旦缺 ListAccel（旧版本写入的、
    // 手工编辑过的、被其他工具覆盖过的），原来会静默打开 24 个列表 hook，
    // 在重列表 App 上直接破坏列表状态机——危险功能必须 fail-safe。
    gListAccel = d[@"ListAccel"] ? [d[@"ListAccel"] boolValue] : NO;
    // v1.8.15：缩放动画加速，缺键默认 NO（同一族在微信上出过「预览页卡死」，必须显式开）
    gZoomAccel = d[@"ZoomAccel"] ? [d[@"ZoomAccel"] boolValue] : NO;
    // v1.8.16：交互手感开关，缺键默认 NO（会改变操作习惯，必须显式开）
    gFastScroll = d[@"FastScroll"] ? [d[@"FastScroll"] boolValue] : NO;
    gFastTap    = d[@"FastTap"]    ? [d[@"FastTap"] boolValue]    : NO;
    // v1.8.17：显式动画额外倍率，缺键默认 1.0（不额外加速），范围 1.0–10.0
    double lb = d[@"LayerBoost"] ? [d[@"LayerBoost"] doubleValue] : 1.0;
    gLayerBoost = (lb >= 1.0 && lb <= 10.0) ? lb : 1.0;
    // v2.0.0：动画时长下限，缺键默认 0.02，范围 0.005–0.05
    double fl = d[@"Floor"] ? [d[@"Floor"] doubleValue] : 0.02;
    gFloor = (fl >= 0.001 && fl <= 1.0) ? fl : 0.02;
    // v2.0.0：转场独立额外倍率，缺键默认 1.0，范围 1.0–10.0
    double tb = d[@"TransitionBoost"] ? [d[@"TransitionBoost"] doubleValue] : 1.0;
    gTransitionBoost = (tb >= 1.0 && tb <= 10.0) ? tb : 1.0;
    // v2.0.1：长按手势加速 + 触发时长，缺键默认开 / 0.30s（与配置 App 一致）
    gLongPress = d[@"LongPress"] ? [d[@"LongPress"] boolValue] : YES;
    double lp = d[@"LongPressDuration"] ? [d[@"LongPressDuration"] doubleValue] : 0.30;
    gLongPressDuration = (lp >= 0.1 && lp <= 2.0) ? lp : 0.30;
    // v2.0.1：保存后顶部生效提示，缺键默认开
    gNotify = d[@"Notify"] ? [d[@"Notify"] boolValue] : YES;
    // v2.0.7：layoutIfNeeded 隐式布局动画加速（实验），缺键默认关
    gLayoutAccel = d[@"LayoutAccel"] ? [d[@"LayoutAccel"] boolValue] : NO;
    // v2.1.0：速率加速引擎，缺键默认关（0 = 沿用时长模式，行为与 v2.0.8 完全一致）
    gSpeedMode = d[@"SpeedMode"] ? [d[@"SpeedMode"] boolValue] : NO;
    // v2.1.0：辅助功能让位，缺键默认开（尊重系统「减弱动态效果」，见 SIO_blocked）
    gRespectReduceMotion = d[@"RespectReduceMotion"] ? [d[@"RespectReduceMotion"] boolValue] : YES;
    // v2.3.0：帧对齐引擎，缺键默认开（与配置 App 一致）。
    // 注意：旧版本写进 plist 的 ProMotion120 键现在被**忽略**（功能已移除），
    // 不做迁移也不报错 —— 那个键对新版dylib 没有任何影响，留在 plist 里无害。
    gFrameAlign = d[@"FrameAlign"] ? [d[@"FrameAlign"] boolValue] : YES;

    // v1.8.12：黑名单一次性解析为布尔值（兼容 NSArray / NSString 两种格式）
    // v2.5.0：解析结果（清洗后的条目数组）顺手缓存进 gBlacklistItems，
    // 供 _fbg_loadPref 复用 —— 保活侧不再对同一份数据做第二次 trim 循环。
    gSelfBlacklisted = NO;
    id bl = d[@"Blacklist"];
    NSArray *items = nil;
    if ([bl isKindOfClass:[NSArray class]]) {
        items = bl;
    } else if ([bl isKindOfClass:[NSString class]]) {
        // 旧版这里直接对 NSString 调 componentsJoinedByString: → unrecognized selector 崩溃
        items = [(NSString *)bl componentsSeparatedByString:@","];
    }
    NSString *bid = gSelfBundle ?: @"";
    NSMutableArray *cleaned = [NSMutableArray array];
    // v2.5.0：whitespaceCharacterSet 每次调用都返回一个新对象，
    // 原实现在循环体内逐条现造 —— 提到循环外取一次。
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    for (id it in items) {
        if (![it isKindOfClass:[NSString class]]) continue;
        NSString *s = [(NSString *)it stringByTrimmingCharactersInSet:ws];
        if (!s.length) continue;
        [cleaned addObject:s];
        // v2.1.0：改用统一匹配器（精确 + 显式 `*` 前缀），与保活侧语义一致
        if (!gSelfBlacklisted && bid.length && SIO_bundleMatches(s)) gSelfBlacklisted = YES;
    }
    gBlacklistItems = cleaned;

    // ---- v1.8.14：App 级覆盖（在全局之后应用，优先级更高） ----
    NSDictionary *ovr = SIO_appOverride(d);
    gHasAppOverride = (ovr != nil);
    if (ovr) {
        if (ovr[@"Enabled"])    gEnabled = [ovr[@"Enabled"] boolValue];
        if (ovr[@"Mode"]) {
            int m2 = [ovr[@"Mode"] intValue];
            if (m2 >= 0 && m2 <= 2) gMode = m2;
        }
        if (ovr[@"Speed"]) {
            double s2 = [ovr[@"Speed"] doubleValue];
            if (s2 >= 1.0 && s2 <= 50.0) gSpeed = s2;
        }
        if (ovr[@"SlowFactor"]) {
            double f2 = [ovr[@"SlowFactor"] doubleValue];
            if (f2 > 1.0 && f2 <= 10.0) gSlowFactor = f2;
        }
        if (ovr[@"Spring"])     gSpring    = [ovr[@"Spring"] boolValue];
        if (ovr[@"Extra"])      gExtra     = [ovr[@"Extra"] boolValue];
        if (ovr[@"ListAccel"])  gListAccel = [ovr[@"ListAccel"] boolValue];
        if (ovr[@"ZoomAccel"])  gZoomAccel = [ovr[@"ZoomAccel"] boolValue];
        if (ovr[@"FastScroll"]) gFastScroll = [ovr[@"FastScroll"] boolValue];
        if (ovr[@"FastTap"])    gFastTap    = [ovr[@"FastTap"] boolValue];
        if (ovr[@"LayerBoost"]) {
            double lb2 = [ovr[@"LayerBoost"] doubleValue];
            if (lb2 >= 1.0 && lb2 <= 10.0) gLayerBoost = lb2;
        }
        if (ovr[@"Floor"]) {
            double fl2 = [ovr[@"Floor"] doubleValue];
            if (fl2 >= 0.001 && fl2 <= 1.0) gFloor = fl2;
        }
        if (ovr[@"TransitionBoost"]) {
            double tb2 = [ovr[@"TransitionBoost"] doubleValue];
            if (tb2 >= 1.0 && tb2 <= 10.0) gTransitionBoost = tb2;
        }
        // v2.0.1：长按加速的 App 级覆盖（v2.0.0 配置 App 已写键，dylib 当时没读）
        if (ovr[@"LongPress"]) gLongPress = [ovr[@"LongPress"] boolValue];
        if (ovr[@"LongPressDuration"]) {
            double lp2 = [ovr[@"LongPressDuration"] doubleValue];
            if (lp2 >= 0.1 && lp2 <= 2.0) gLongPressDuration = lp2;
        }
        // v2.0.7：LayoutAccel 的 App 级覆盖
        if (ovr[@"LayoutAccel"]) gLayoutAccel = [ovr[@"LayoutAccel"] boolValue];
        // v2.1.0：SpeedMode / RespectReduceMotion 的 App 级覆盖
        if (ovr[@"SpeedMode"]) gSpeedMode = [ovr[@"SpeedMode"] boolValue];
        if (ovr[@"RespectReduceMotion"]) gRespectReduceMotion = [ovr[@"RespectReduceMotion"] boolValue];
        // v2.3.0：帧对齐的 App 级覆盖
        if (ovr[@"FrameAlign"]) gFrameAlign = [ovr[@"FrameAlign"] boolValue];
    }

    // ---- v1.8.14：列表 hook 硬保护，必须放在所有覆盖之后，优先级最高 ----
    gListHardGuarded = SIO_listHardBlocked();
    if (gListHardGuarded && gListAccel) {
        NSLog(@"[SIOriginal] ListAccel was ON but hard guard force-disabled it for %@ "
              @"(list hooks break this app's list state machine)", SIO_bundleID());
        gListAccel = NO;
    }
    // v2.0.7：按最终生效值（含 App 覆盖）计算恒等标记，热路径快速短路用
    gAnimNoop = (gMode == 0 && gSpeed <= 1.0001);
    // v2.5.0：顺带把最热 hook 的换算结果预计算好（见 gImplicitActionDur 说明）。
    // 必须在 gAnimNoop 之后 —— SIO_targetDuration 依赖当前生效配置。
    gImplicitActionDur = SIO_targetDuration(0.25);
}

static void SIO_installiOS16Extras(void); // forward declaration
// v2.5.0：构造期安装的 CALayer 核心两族（定义见文件后部，此处需前向声明，
// 否则构造函数里调用会触发 implicit declaration —— 本项目历史上出过同类编译错误）。
static void SIO_installLayerCoreHooks(void);
// v2.2.0：列表 hook 的延迟安装（构造函数里只调用它，实际安装排到主队列之后）
static void SIO_installListHooksLater(void); // forward declaration
static void SIO_installListHooksNow(void);
// v2.1.0：sio_window_setRootVC 定义在 SIO_transitionDuration 之后，需前向声明
static inline double SIO_transitionDuration(void);

// v2.2.0[启动提速]：热重载时要在主线程补装「默认关闭、按需安装」的那几族 hook
// （列表全家桶 / 缩放 / 布局 / 帧率）。这个补装函数被 SIO_settingsChanged 调用，
// 而后者位于文件前部 —— 因此这些 hook 的原 IMP 指针必须在此前向声明，
// 否则编译报「使用先于声明」。
// 注意：这里只是声明，真正的赋值仍在各自原本的安装处完成。

static void SIO_installOnDemandHooks(void);
static void   (*o_sv_setZoomScale)(id, SEL, CGFloat, BOOL);
static void   (*o_sv_zoomToRect)(id, SEL, CGRect, BOOL);
static void   (*o_view_layoutIfNeeded)(id, SEL);

// v2.2.0[启动提速]：列表 hook 幂等标志。
// 这批 hook 用「延迟 + 按需」安装，必须防重复安装 ——
// 重复调用 SIO_swizzleInstance 会把我们自己的 IMP 存进 orig 槽位，
// 造成无限递归爆栈（v1.8.12 已就该问题写过防护，这里是第二道）。
static BOOL gListHooksInstalled = NO;

// v2.0.1：保存配置后在前台目标 App 顶部弹 1.5s 生效提示（配置 App 的 Notify 开关）。
// 关键约束（吸取 v1.8.10 悬浮球被全局禁用的教训）：
//   · toast 与 label 都 userInteractionEnabled = NO —— 不拦截任何触摸、不抢状态栏；
//   · 只在 App 处于 UIApplicationStateActive 时显示，后台静默；
//   · 1.5s 节流，避免连续保存/悬浮球切换时堆叠。
static NSTimeInterval gSIOLastNotifyAt = 0;

// v2.0.2：toast 拆出通用实现，供「设置生效」与「启动注入确认」两处复用。
// 返回 YES 表示真实显示成功（启动确认据此决定要不要重试）。
static BOOL SIO_showToast(NSString *text, BOOL throttle) {
    @try {
        // v2.1.0[真 bug 4]：置位「内部 UI」标记。
        // 本函数内部用 [UIView animateWithDuration:] 做淡入淡出，该调用会命中本 dylib
        // 自己的 sio_UV_anim_d 被二次缩放：×20 预设下 0.25s → 0.0125s、瞬切模式 → 0.02s，
        // 提示"啪"一下闪过去，用户根本看不清内容（而这正是"设置已生效"的唯一可见反馈）。
        // 置位后 SIO_blocked 整体放行，自绘 UI 按系统原生时长播放。
        BOOL wasInternal = SIO_inInternalUI();
        SIO_setInternalUI(YES);
        UIApplication *app = [UIApplication sharedApplication];
        if (app.applicationState != UIApplicationStateActive) {
            SIO_setInternalUI(wasInternal);
            return NO;
        }
        NSTimeInterval now = CACurrentMediaTime();
        if (throttle && now - gSIOLastNotifyAt < 1.5) {
            SIO_setInternalUI(wasInternal);
            return NO;
        }
        gSIOLastNotifyAt = now;

        UIWindowScene *target = nil;
        for (UIScene *sc in app.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]] &&
                sc.activationState == UISceneActivationStateForegroundActive) {
                target = (UIWindowScene *)sc;
                break;
            }
        }
        if (!target) { SIO_setInternalUI(wasInternal); return NO; }
        UIWindow *kw = nil;
        for (UIWindow *w in target.windows) {
            if (!w.hidden && w.isKeyWindow) { kw = w; break; }
        }
        if (!kw) { SIO_setInternalUI(wasInternal); return NO; }

        UIView *toast = [[UIView alloc] init];
        toast.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
        toast.layer.cornerRadius = 22;
        toast.layer.masksToBounds = YES;
        toast.userInteractionEnabled = NO;
        toast.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *label = [[UILabel alloc] init];
        label.text = text;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.textAlignment = NSTextAlignmentCenter;
        label.userInteractionEnabled = NO;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [toast addSubview:label];
        [kw addSubview:toast];
        [NSLayoutConstraint activateConstraints:@[
            [label.topAnchor constraintEqualToAnchor:toast.topAnchor constant:10],
            [label.bottomAnchor constraintEqualToAnchor:toast.bottomAnchor constant:-10],
            [label.leadingAnchor constraintEqualToAnchor:toast.leadingAnchor constant:18],
            [label.trailingAnchor constraintEqualToAnchor:toast.trailingAnchor constant:-18],
            [toast.centerXAnchor constraintEqualToAnchor:kw.centerXAnchor],
            [toast.topAnchor constraintEqualToAnchor:kw.safeAreaLayoutGuide.topAnchor constant:8],
            [toast.widthAnchor constraintGreaterThanOrEqualToConstant:180],
        ]];

        toast.transform = CGAffineTransformMakeTranslation(0, -60);
        toast.alpha = 0;
        [UIView animateWithDuration:0.25 animations:^{
            toast.transform = CGAffineTransformIdentity;
            toast.alpha = 1;
        } completion:^(__unused BOOL finished) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                // 标记只在首段动画期间需要；延迟淡出发生在 1.5s 之后的新 runloop 轮次，
                // 必须重新置位（TLS 不会跨 dispatch_after 边界自动延续到新 block 的上下文判断）。
                BOOL inner = SIO_inInternalUI();
                SIO_setInternalUI(YES);
                [UIView animateWithDuration:0.25 animations:^{
                    toast.alpha = 0;
                    toast.transform = CGAffineTransformMakeTranslation(0, -60);
                } completion:^(__unused BOOL f2) {
                    [toast removeFromSuperview];
                    SIO_setInternalUI(inner);
                }];
            });
        }];
        return YES;
    } @catch (__unused NSException *e) {
        SIO_setInternalUI(NO);
        return NO;
    }
}

// 保存配置后的生效提示（受 Notify 开关 + 1.5s 节流）
static void SIO_showNotifyToast(void) {
    if (!gNotify) return;
    SIO_showToast(@"SIOriginal 设置已生效", YES);
}

// v2.0.2：启动注入确认。dylib 加载后 0.6s 在目标 App 顶部弹一次
// 「SIOriginal 已注入 · 瞬切/加速 ×N · 或 OFF/黑名单状态」，失败重试 5 次。
// 解决用户反馈的最大盲区：「动画慢」到底是没注入，还是配置了没生效，
// 此前没有任何可见信号。gNotify 关时静默（避免打扰已确认好用的用户）。
static void SIO_showInjectToast(int attempt) {
    if (!gNotify || attempt > 5) return;
    // v2.0.6 修复：重试退避。原先固定 0.6s 间隔，5 次全挤在头 3 秒内跑完。
    // 但 SIO_showToast 失败的最常见原因是「App 尚未起完 / 无 active scene」，
    // 那是秒级以上的事 —— 0.6s 连打 5 次必然全部落空，等于没有重试，
    // 而用户看到的就是「注入后什么都没弹，不知道到底有没有生效」。
    // 改为指数退避 0.5→0.75→1.1→1.7→2.5s，累计约 6.5s，覆盖真实冷启动窗口，
    // 同时总次数不变（不会打扰用户）。
    static const NSTimeInterval kBackoff[5] = { 0.5, 0.75, 1.1, 1.7, 2.5 };
    NSTimeInterval delay = (attempt >= 0 && attempt < 5) ? kBackoff[attempt] : 0.6;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // 未启用 / 黑名单 / 硬保护时也要提示——这正是用户需要知道的「为什么没加速」。
        NSString *msg;
        if (gSelfBlacklisted) {
            msg = @"SIOriginal 已注入 · 本 App 在黑名单（加速未启用）";
        } else if (gListHardGuarded) {
            msg = @"SIOriginal 已注入 · 本 App 被硬保护（加速未启用）";
        } else if (!gEnabled) {
            msg = @"SIOriginal 已注入 · 总开关已关闭";
        } else {
            NSString *modeName = (gMode == 2) ? @"瞬切" : (gMode == 1) ? @"慢放" : @"加速";
            msg = (gMode == 2)
                ? [NSString stringWithFormat:@"SIOriginal 已注入 · %@", modeName]
                : [NSString stringWithFormat:@"SIOriginal 已注入 · %@ ×%.1f",
                   modeName, (gMode == 1) ? gSlowFactor : gSpeed];
        }
        if (!SIO_showToast(msg, NO)) SIO_showInjectToast(attempt + 1);
    });
}

static void SIO_settingsChanged(CFNotificationCenterRef center, void *observer,
                                CFNotificationName name, const void *object,
                                CFDictionaryRef userInfo) {
    // =========================================================================
    // v2.5.0[性能·P2] 整段重载切到主队列串行执行。
    // 原实现在 Darwin 通知回调线程上直接做三件事：
    //   ① SIO_reload() → SIO_prefSnapshot() → 同步磁盘读（plist 反序列化）
    //   ② SIO_reload() 连续改写 30 个全局配置变量
    //   ③ SIO_installOnDemandHooks() → method_setImplementation（改方法表）
    // 三者都不该在通知线程做：
    //   · ① 是阻塞 IO，用户连续点保存时会把通知线程卡住，后续通知排队；
    //   · ② 与正在读这些全局变量的动画线程构成数据竞争（见 gPrefCache 的说明）；
    //   · ③ 换方法表必须与 UIKit 的主线程状态保持一致，在非主线程做是隐患。
    // 切到主队列后：IO 不阻塞通知线程、配置改写与所有 hook 读取天然串行
    // （hook 也跑在主线程），方法表修改也在主线程完成。
    // 代价：配置生效延后一个 runloop turn（毫秒级），用户无感。
    // =========================================================================
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 配置已变，让缓存失效，强制下次重新解析（v2.2.0）
            SIO_invalidatePrefCache();
            SIO_reload();
            // v2.2.0：v2.1.0 的构造函数只排了一次延迟安装。若用户在 App 启动后才
            // 打开列表加速，那一轮的延迟安装已经跑完并因开关为 NO 跳过了，这里补装。
            // 反向关闭不需要处理 —— hook 装上后由 SIO_listOK() 门控自动失效，
            // 且重复安装才是真正的风险（自递归），所以只在「开」的方向补装。
            if (gListAccel && !gSelfBlacklisted && !gListHooksInstalled) {
                SIO_installListHooksLater();
            }
            // v2.2.0：同理补装「默认关闭、按需安装」的那几族。
            SIO_installOnDemandHooks();
            SIO_showNotifyToast();
        } @catch (NSException *e) {
            NSLog(@"[SIOriginal] settings reload failed (app unaffected): %@", e);
        }
    });
}

// ---------- 微信图片预览「放大态」全局旁路（v1.8.4） ----------
// v1.8.3 只保护了缩放相关的两个 UIScrollView hook，但用户实测仍有残留故障：
// 放大后顶/底工具栏自动隐藏，单击屏幕再也唤不出，返回/完成按钮跟着消失，
// 只能杀微信。微信图片浏览器（发图预览、聊天大图）的工具栏隐显走的是
// UIView 块动画 / UIViewPropertyAnimator / CAAnimation，瞬切模式把时长压到
// 0.01s、加速模式整体缩短，会破坏浏览器「隐显动画完成 → 清 isAnimating 锁 →
// 接受下一次单击切换」的状态配对，导致单击被丢弃，工具栏永远停在隐藏态。
// 该故障只在「放大态」出现（未放大时单击切换正常），因此：只要微信前台
// 存在一个启用了缩放且当前 zoomScale > minimumZoomScale 的 UIScrollView，
// 就令所有动画 hook 整体旁路（SIO_blocked 返回 YES），缩放/工具栏/手势全走
// 原生路径；缩回最小倍率后 0.25s 内自动恢复加速。探测限主线程、0.25s 节流，
// 对性能无实际影响。
static NSTimeInterval gZoomProbeAt = 0;
static BOOL           gZoomPreviewCached = NO;
// v2.5.0[性能·P1] 命中过的放大态滚动视图（弱引用）+ 自适应探测间隔。
// 原实现每 0.25s 无条件对整个前台视图树做一次 DFS（上限 3000 节点），
// 而 SIO_blocked() 被**每一个**动画/事务 hook 调用，
// 也就是这个 DFS 会在微信里每 0.25 秒稳定发生一次，代价是几千次
// isKindOfClass: + 数千次 NSMutableArray 增删 —— 全部落在主线程。
// 真机上这表现为「微信里偶发掉帧」，且与本项目毫无关系的界面也会中招。
//
// 两项改进：
//  ① 弱引用快路径：一旦确认过某个 scrollView 处于放大态，记住它。
//     后续探测只需一次弱引用读 + 三个属性读（O(1)）即可确认它是否仍在放大态。
//     它被释放或缩回后，弱引用自动置 nil / 属性判定失败，回落 DFS —— 自愈，无状态残留。
//  ② 自适应间隔：连续多次探测都是「未放大」时，把间隔从 0.25s 逐级放宽到 2.0s。
//     「不在预览页」是绝大多数时间的真实状态，此时高频探测纯属浪费；
//     一旦结果翻转（进入放大态），间隔立刻回到 0.25s，保护灵敏度不降。
// 代价：从「未放大」切到「放大」的识别延迟，最坏从 0.25s 变成 2.0s。
// 这是一处真实的行为放宽 —— 该保护是防「微信预览页卡死」的安全网，
// 放大态由用户手势触发（双指捏合），2s 内必然已被下一次探测覆盖，
// 且放大动作本身远慢于 2s，故认为可接受；保守者可调小 kZoomProbeMax。
static __weak UIScrollView *gZoomCachedSV = nil;
static int      gZoomMissStreak = 0;
static const NSTimeInterval kZoomProbeMin = 0.25;
static const NSTimeInterval kZoomProbeMax = 2.0;

static BOOL SIO_wechatZoomPreviewActive(void) {
    if (!gIsWeChat) return NO;
    NSTimeInterval now = CACurrentMediaTime();
    // 连续未命中时放宽间隔（0.25s → 2.0s，每 3 次未命中放宽一档）
    NSTimeInterval interval = kZoomProbeMin;
    if (gZoomMissStreak >= 3) {
        interval = kZoomProbeMin + (kZoomProbeMax - kZoomProbeMin) *
                   (double)(gZoomMissStreak - 3) / 6.0;
        if (interval > kZoomProbeMax) interval = kZoomProbeMax;
    }
    if (now - gZoomProbeAt < interval) return gZoomPreviewCached;
    gZoomProbeAt = now;
    // 视图树只能在主线程碰；非主线程直接沿用上一次结果
    if (![NSThread isMainThread]) return gZoomPreviewCached;

    // ---- 快路径：确认过放大态的滚动视图还在放大吗？（O(1)，无遍历）----
    UIScrollView *cached = gZoomCachedSV;   // 弱引用读：已释放则自动为 nil
    if (cached) {
        BOOL stillZoomed = NO;
        @try {
            stillZoomed = (cached.window != nil) &&
                          (cached.maximumZoomScale > cached.minimumZoomScale + 0.001) &&
                          (cached.zoomScale > cached.minimumZoomScale + 0.001);
        } @catch (__unused NSException *e) { stillZoomed = NO; }
        if (stillZoomed) {
            gZoomMissStreak = 0;
            gZoomPreviewCached = YES;
            return YES;
        }
        gZoomCachedSV = nil;   // 已缩回或已释放，回落 DFS 重新找
    }

    BOOL found = NO;
    UIScrollView *foundSV = nil;
    @autoreleasepool {
        @try {
            NSMutableArray<UIView *> *roots = [NSMutableArray array];
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)sc;
                if (ws.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *w in ws.windows) {
                    if (!w.hidden && w.alpha > 0.01 && w.rootViewController.view) {
                        [roots addObject:w];
                    }
                }
            }
            // 迭代 DFS，扫描整个前台视图树
            // v1.8.12：节点上限保护。超大视图树（长列表 / 复杂 WebView 容器）下
            // 全树遍历会拖慢主线程；超过上限即按「未放大」放行，
            // 宁可少一层保护，不可卡住界面。
            NSMutableArray<UIView *> *stack = roots;
            NSUInteger visited = 0;
            while (stack.count) {
                if (++visited > 3000) break;
                UIView *v = stack.lastObject;
                [stack removeLastObject];
                if ([v isKindOfClass:[UIScrollView class]]) {
                    UIScrollView *sv = (UIScrollView *)v;
                    if (sv.maximumZoomScale > sv.minimumZoomScale + 0.001 &&
                        sv.zoomScale > sv.minimumZoomScale + 0.001) {
                        found = YES;
                        foundSV = sv;
                        break;
                    }
                }
                NSArray *subs = v.subviews;
                if (subs.count) [stack addObjectsFromArray:subs];
            }
        } @catch (__unused NSException *e) {}
    }
    if (found) {
        gZoomCachedSV = foundSV;
        gZoomMissStreak = 0;      // 状态翻转 → 立刻恢复最高探测灵敏度
    } else if (gZoomMissStreak < 9) {
        gZoomMissStreak++;
    }
    gZoomPreviewCached = found;
    return found;
}

// v2.1.0[新功能 11]：系统「减弱动态效果」判定。
// 这是用户通过系统设置表达的无障碍意图，进程内不会变化（切换该设置需重启 App），
// 因此惰性求值一次后全程走静态整型读，成本接近 0。
// 走 dlsym 而非直接调用：符号在 AccessibilityUtilities 私有库里，直接链接会
// 增加本 dylib 的链接依赖（正是 v2.0.7 刚从启动路径上拿掉的东西）。
// 取不到符号时按「未开启」处理（fail-open：宁可保持加速，也不让功能整体失效）。
static BOOL SIO_reduceMotionOn(void) {
    static int cached = -1;   // -1 未求值 / 0 关 / 1 开
    if (__builtin_expect(cached >= 0, 1)) return (cached == 1);
    BOOL on = NO;
    void *h = dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
                    RTLD_LAZY | RTLD_LOCAL);
    if (h) {
        BOOL (*fn)(void) = (BOOL (*)(void))dlsym(h, "UIAccessibilityIsReduceMotionEnabled");
        if (fn) on = fn();
        // 不 dlclose：函数指针在进程生命周期内都会被引用，卸载库会让指针悬空。
    }
    cached = on ? 1 : 0;
    return on;
}

static inline BOOL SIO_blocked(void) {
    // v2.1.12：热路径零分配。全部动画/事务 hook 都从这里过，
    // 顺序按「最便宜、最可能命中」排列：布尔 → 布尔 → 线程局部 → 布尔 → 节流后的探测结果。
    if (!gEnabled) return YES;
    if (gSelfBlacklisted) return YES;
    // v2.1.0：辅助功能让位。用户开了系统「减弱动态效果」= 明确要求减少动效，
    // 加速工具不应覆盖这一意图。判定走一个静态整型读，成本接近 0。
    if (gRespectReduceMotion && SIO_reduceMotionOn()) return YES;
    // v2.1.0：本项目自绘 UI（toast/悬浮球）整体旁路，避免自己的动画被自己加速
    if (SIO_inInternalUI()) return YES;
    // v1.8.9：微信动画加速恢复（实验）——预览 bug 真凶已确认为悬浮球（v1.8.7 永久禁用），
    // 动画 hook 恢复生效；v1.8.4 放大态探测器首次真正启用作为安全网
    if (SIO_wechatZoomPreviewActive()) return YES;   // 微信预览放大态旁路（非微信时立即返回 NO）
    // v2.5.0：编辑模式护栏（来源 FakeCl0ckUp）。桌面图标/Switcher 编辑期间
    // 所有动画旁路 —— 拖拽重排时加速会导致用户无法准确定位图标。
    if (gEditing) return YES;
    return NO;
}

// =============================================================================
// v2.5.0[可观测性] hook 安装计数器与启动耗时采样
// =============================================================================
// 本项目的启动优化核心命题一直是「构造期做了多少次 method_setImplementation」。
// 但此前**没有任何一处真的在数它** —— README 里写的「53 次降到 26 次」是人工
// 静态清点出来的，任何一次改动都可能让它悄悄回退，而没人会发现。
// 这里补上两个计数器：
//   gSIOHookSwapCount —— 实际发生的方法表交换次数（addMethod / setImplementation）
//   gSIODyldCostMs    —— 两个 constructor 自身消耗的挂钟毫秒数
// 两者都会打进延后的启动指纹日志，使「启动优化有没有回退」变成一条可 grep 的
// 可观测量，而不是靠人肉清点。采样成本本身可忽略（每次交换一次 clock_gettime
// 级别的时间读取，且只在构造期发生）。
// =============================================================================
static int    gSIOHookSwapCount = 0;
static double gSIODyldCostMs    = 0.0;
// 构造期计时起点/终点（CFAbsoluteTimeGetCurrent 走 mach 绝对时间，无分配）
static double gSIOT0 = 0.0;

// ---------- swizzle 工具 ----------
// v1.8.12：增加重复安装保护。若目标 IMP 已经是我们的实现（同一 dylib 被重复注入、
// 或 constructor 被执行两次），绝不能再把它存进 orig —— 否则回调会自递归爆栈。
// v1.8.19：修复「继承方法污染父类」。若方法不在本类而在父类（例如
// -[UIScrollView didMoveToWindow] 实际继承自 UIView），旧实现直接
// method_setImplementation 会全局改掉父类 IMP，导致进程内*所有* UIView 走进
// UIScrollView 专用 hook（按 UIScrollView 布局解释 self，非滚动视图必崩）。
// 正确做法：先 class_addMethod 在本类落地新 IMP，orig 指向父类实现。
static void SIO_swizzleInstance(Class c, SEL sel, IMP newImp, IMP *orig) {
    if (!c || !sel || !newImp) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;
    const char *types = method_getTypeEncoding(m);
    // 本类未实现（方法来自父类）：add 一份新实现到本类，不动父类
    if (class_addMethod(c, sel, newImp, types)) {
        if (orig) {
            Method superM = class_getInstanceMethod(class_getSuperclass(c), sel);
            *orig = superM ? method_getImplementation(superM) : NULL;
        }
        // v2.5.0：addMethod 同样是一次方法表写入，计入交换数
        gSIOHookSwapCount++;
        return;
    }
    // 本类自有实现：直接替换（addMethod 失败说明已存在）
    if (orig) *orig = cur;
    method_setImplementation(m, newImp);
    gSIOHookSwapCount++;
}
// 注意：必须传「类对象」而不是元类。class_getClassMethod 内部执行的是
// class_getInstanceMethod(object_getClass(cls), sel)，传元类会去根元类查找并返回 NULL。
static void SIO_swizzleClass(Class c, SEL sel, IMP newImp, IMP *orig) {
    if (!c || !sel || !newImp) return;
    Method m = class_getClassMethod(c, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;
    Class meta = object_getClass(c);
    const char *types = method_getTypeEncoding(m);
    // 同样防护类方法继承污染：先尝试往元类 add（对应父类实现的类方法）
    if (class_addMethod(meta, sel, newImp, types)) {
        if (orig) {
            Method superM = class_getInstanceMethod(class_getSuperclass(meta), sel);
            *orig = superM ? method_getImplementation(superM) : NULL;
        }
        gSIOHookSwapCount++;
        return;
    }
    if (orig) *orig = cur;
    method_setImplementation(m, newImp);
    gSIOHookSwapCount++;
}

// ---------- 原始 IMP 指针（先声明后引用） ----------
static void   (*o_CAAnim_setDuration)(id, SEL, double);
static void   (*o_CATransaction_setDur)(id, SEL, double);
static void   (*o_UV_anim_d)(id, SEL, double, void (^)(void));
static void   (*o_UV_anim_dc)(id, SEL, double, void (^)(void), void (^)(BOOL));
static void   (*o_UV_anim_ddoc)(id, SEL, double, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void   (*o_UV_anim_spring)(id, SEL, double, double, double, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void   (*o_UV_trans)(id, SEL, UIView *, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void   (*o_UV_transFrom)(id, SEL, UIView *, UIView *, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void   (*o_CASpring_mass)(id, SEL, double);
static void   (*o_CASpring_stiff)(id, SEL, double);
static void   (*o_CASpring_damp)(id, SEL, double);
// v2.5.0：CASpringAnimation setVelocity:（来源 FakeCl0ckUp）。
// 弹簧物理一致性要求：时间缩放 m 倍时，初速度需同步 ×m 才能在同距离下
// 保持物理轨迹视觉一致。与 mass/stiff/damp 同族 hook。
static void   (*o_CASpring_velocity)(id, SEL, double);

// v2.5.0：编辑模式护栏的原始 IMP（来源 FakeCl0ckUp）。
// SBIconController setIsEditing: 存在于所有 iOS 版本的 SpringBoard；
// SBAppSwitcherController _beginEditing/_stopEditing 在较新版本存在。
// 非 SpringBoard 进程这些类不存在，指针永远不被使用。
static void   (*o_SBIconCtrl_setEditing)(id, SEL, BOOL);
static void   (*o_SBSwitcher_beginEditing)(id, SEL);
static void   (*o_SBSwitcher_stopEditing)(id, SEL);
static void   (*o_nav_push)(id, SEL, UIViewController *, BOOL);
static void   (*o_nav_pop)(id, SEL, BOOL);
static void   (*o_nav_popTo)(id, SEL, UIViewController *, BOOL);
static void   (*o_nav_setVCs)(id, SEL, NSArray *, BOOL);
static void   (*o_nav_privDur)(id, SEL, double);
static void   (*o_vc_present)(id, SEL, UIViewController *, BOOL, void (^)(void));
static void   (*o_vc_dismiss)(id, SEL, BOOL, void (^)(void));

// ---- iOS 10+ UIViewPropertyAnimator（现代 App 主流动画 API） ----
static void   (*o_pa_setDuration)(id, SEL, double);
static id     (*o_pa_initWithDurTP)(id, SEL, double, id, void (^)(void));
static id     (*o_pa_initWithDurCP)(id, SEL, double, CGPoint, CGPoint, void (^)(void));
static id     (*o_pa_initWithDurSpring)(id, SEL, double, double, void (^)(void));
static id     (*o_pa_runningPA)(id, SEL, double, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
// v2.0.7：startAnimationAfterDelay: 的延迟此前原样放行，与块动画延迟缩放不一致
static void   (*o_pa_startAfterDelay)(id, SEL, double);
// v2.1.0[新覆盖 9]：continueAnimationWithTimingParameters:duration:（iOS 11+）
// 链式续播入口。首段时长已在 init 缩放、start 延迟在 v2.0.7 缩放，
// 但续播时传入的新 duration 原样放行 —— 一条链里首段加速、续段不加速，行为割裂。
static void   (*o_pa_continueTP)(id, SEL, id, double);
// v2.1.0[新功能 8]：速率加速引擎的原 IMP
static void   (*o_CAAnim_setSpeed)(id, SEL, float);
static void   (*o_layer_setSpeed)(id, SEL, float);
// v2.1.0[新覆盖 10]：UIWindow setRootViewController:（App 换根控制器时的交叉淡入）
static void   (*o_window_setRootVC)(id, SEL, id);

// ---- UIScrollView 滚动动画 ----
static void   (*o_sv_setContentOffset)(id, SEL, CGPoint, BOOL);
static void   (*o_sv_scrollRect)(id, SEL, CGRect, BOOL);

// ---- CALayer addAnimation 补盲区 ----
static void   (*o_layer_addAnim)(id, SEL, id, NSString *);

// ---- v1.8.15：UIScrollView 缩放动画 ----

// ---- v1.8.16：交互手感（滑行惯性 / 点击延迟） ----
static void   (*o_sv_didMoveToWindow)(id, SEL);
// v2.0.1：setter 强黏（界面承诺「防 App 改回」，旧版只在 didMoveToWindow 设一次）
static void   (*o_sv_setDecelRate)(id, SEL, CGFloat);
static void   (*o_sv_setDelaysTouches)(id, SEL, BOOL);

// ---- v2.0.1：长按手势加速（v2.0.0 配置 App 有开关，dylib 此前无实现） ----
static id     (*o_lpr_init)(id, SEL, id, SEL);
static id     (*o_lpr_initCoder)(id, SEL, id);
static void   (*o_lpr_setMinDur)(id, SEL, double);

// ---- v1.8.12 新增 hook ----
static void   (*o_UV_anim_keyframes)(Class, SEL, double, double, NSUInteger, void (^)(void), void (^)(BOOL));
static void   (*o_UV_systemAnim)(Class, SEL, NSUInteger, NSArray *, NSUInteger, void (^)(void), void (^)(BOOL));
static id     (*o_pa_initWithDurTP2)(id, SEL, double, id);
static void   (*o_tab_setIndex)(id, SEL, NSUInteger);
static void   (*o_tab_setVC)(id, SEL, UIViewController *);
static void   (*o_vc_transitionFrom)(id, SEL, UIViewController *, UIViewController *, double,
                                     UIViewAnimationOptions, void (^)(void), void (^)(BOOL));

// ---- v1.8.13 新增：老式 beginAnimations 动画 API 时长/延迟 ----
static void   (*o_UV_setAnimDuration)(Class, SEL, double);
static void   (*o_UV_setAnimDelay)(Class, SEL, double);

// ---- v1.8.18 新增：系统级增强 hook ----
static void   (*o_refresh_begin)(id, SEL);
// v1.8.19：-[UIRefreshControl endRefreshing] 是无参方法（旧代码误写成 endRefreshing: 带 BOOL）
static void   (*o_refresh_end)(id, SEL);
// v1.8.19：setLargeTitleDisplayMode: 属于 UINavigationItem（不是 UINavigationBar），
// 参数是 UINavigationItemLargeTitleDisplayMode（NSInteger 枚举，不是 BOOL）
static void   (*o_navItem_setLargeTitle)(id, SEL, NSInteger);
// v1.8.19：真实 API 为 setViewControllers:direction:animated:completion:（带 animated 与 completion）
static void   (*o_pageVC_setVC)(id, SEL, NSArray *, UIPageViewControllerNavigationDirection, BOOL, void (^)(void));
static void   (*o_docInteract_present)(id, SEL, BOOL);
// v2.0.7：文档交互控制器补全（选项菜单 / 打开方式菜单，均返回 BOOL）
static BOOL   (*o_docInteract_optionsMenu)(id, SEL, CGRect, id, BOOL);
static BOOL   (*o_docInteract_openInMenu)(id, SEL, CGRect, id, BOOL);
// v2.0.7：LayoutAccel 实验开关的 hook 点（隐式布局动画）
// v2.0.4：加载图标 / 隐式动画盲区
static NSTimeInterval (*o_CATransaction_getDur)(id, SEL);
static void   (*o_indicator_start)(id, SEL);
// v2.0.5：下拉刷新转圈加强（UIRefreshControl didMoveToWindow）
static void   (*o_refresh_didMove)(id, SEL);
// v2.0.6：控件 / 导航栏 / 工具栏 / 单元格 全路径覆盖
static void   (*o_switch_setOn)(id, SEL, BOOL, BOOL);
static void   (*o_slider_setValue)(id, SEL, float, BOOL);
static void   (*o_progress_setProgress)(id, SEL, float, BOOL);
static void   (*o_picker_selectRow)(id, SEL, NSInteger, NSInteger, BOOL);
static void   (*o_datePicker_setDate)(id, SEL, id, BOOL);
static void   (*o_segmented_setIndex)(id, SEL, NSInteger);
static void   (*o_pageControl_setPage)(id, SEL, NSInteger);
static void   (*o_effectView_setEffect)(id, SEL, id);
static void   (*o_control_setHighlighted)(id, SEL, BOOL);
static void   (*o_control_setSelected)(id, SEL, BOOL);
static void   (*o_navBar_pushItem)(id, SEL, id, BOOL);
static id     (*o_navBar_popItem)(id, SEL, BOOL);
static void   (*o_navBar_setItems)(id, SEL, NSArray *, BOOL);
static void   (*o_toolbar_setItems)(id, SEL, NSArray *, BOOL);
static void   (*o_tabBar_setItem)(id, SEL, id);
static void   (*o_nav_setBarHidden)(id, SEL, BOOL, BOOL);
static void   (*o_nav_setToolbarHidden)(id, SEL, BOOL, BOOL);
static void   (*o_tvCell_setSelected)(id, SEL, BOOL, BOOL);
static void   (*o_tvCell_setHighlighted)(id, SEL, BOOL, BOOL);
static void   (*o_cvCell_setSelected)(id, SEL, BOOL);
static void   (*o_cvCell_setHighlighted)(id, SEL, BOOL);
static void   (*o_cv_batchUpdates)(id, SEL, void (^)(void), void (^)(BOOL));
static void   (*o_cv_setLayout)(id, SEL, id, BOOL);
static void   (*o_cv_setLayoutComp)(id, SEL, id, BOOL, void (^)(BOOL));

// ==================== v2.4.0：转场/控件/隐式动画盲区补齐 ====================
static void   (*o_nav_popToRoot)(id, SEL, BOOL);
static void   (*o_tabBC_setViewControllers)(id, SEL, NSArray *, BOOL);
static void   (*o_tabBar_setItems)(id, SEL, NSArray *, BOOL);
static void   (*o_navItem_setHidesBack)(id, SEL, BOOL, BOOL);
static void   (*o_navItem_setLeftBtn)(id, SEL, id, BOOL);
static void   (*o_navItem_setRightBtn)(id, SEL, id, BOOL);
static void   (*o_navItem_setLeftBtns)(id, SEL, NSArray *, BOOL);
static void   (*o_navItem_setRightBtns)(id, SEL, NSArray *, BOOL);
static void   (*o_vc_setEditing)(id, SEL, BOOL, BOOL);
static void   (*o_searchCtrl_setActive)(id, SEL, BOOL, BOOL);
static void   (*o_searchBar_setShowsCancel)(id, SEL, BOOL, BOOL);
static void   (*o_stepper_setValue)(id, SEL, double, BOOL);
static void   (*o_popover_setContentSize)(id, SEL, CGSize, BOOL);
static void   (*o_pageVC_setSpine)(id, SEL, NSInteger, BOOL);
static id     (*o_layer_actionForKey)(id, SEL, NSString *);
// =========================================================================

#pragma mark - CAAnimation（核心：仅基类，子类自动继承）

// v2.1.0[新功能 8]：速率加速引擎 —— 改播放速率而非改时长。
// 动机：压缩 duration 有两个绕不开的硬伤。
//   ① 撞时长下限。×50 时 0.25s → 0.005s，而 CoreAnimation 在极短时长下按帧采样，
//      视觉上就是「闪一下」甚至丢帧，用户看到的是卡顿而非加速。
//   ② 时长被改后，关键帧的**相对时间比**虽然不变，但按绝对时间推进的逻辑会失真：
//      CASpringAnimation 的物理积分步长、CADisplayLink 驱动的自定义插值
//      都会因 duration 极小而数值不稳定，出现抽搐/跳变。
// 速率模式改 CAAnimation.speed：时长与关键帧时间轴**原样保留**，
// 只是让 CoreAnimation 以 speed 倍速播放 —— 插值与物理完全正确，且不存在下限碰撞。
// [安全边界] App 显式设 speed != 1.0（视频/音频同步、慢动作特效）一律透传，
//            只接管「默认值 1.0」，与长按时长「只替换系统默认 0.5」的口径一致。
// [安全边界] 慢放模式换算为 1/slowFactor，等价于时长乘 slowFactor 但不改时长。
// [与时长模式的关系] 二者互斥：速率模式生效时，所有改duration 的路径必须退化为恒等，
//            否则实际倍率 = 时长倍率 × 速率倍率，与用户设定不符，且双重下限会失真。
static void sio_CAAnim_setSpeed(id self, SEL _cmd, float sp) {
    SIO_REQUIRE_ORIG(o_CAAnim_setSpeed);
    if (SIO_blocked()) { o_CAAnim_setSpeed(self, _cmd, sp); return; }
    if (!SIO_speedModeActive()) { o_CAAnim_setSpeed(self, _cmd, sp); return; }
    // 只接管系统默认 1.0；App 显式的非 1.0 是有意的节奏控制，原样放行
    if (fabs((double)sp - 1.0) > 1e-4) { o_CAAnim_setSpeed(self, _cmd, sp); return; }
    double m = SIO_speedScale();
    if (m <= 0.0) { o_CAAnim_setSpeed(self, _cmd, sp); return; }
    // 下限同样不得反向生效：倍率 < 1（慢放）时结果 < 1，这是预期，不做钳制。
    o_CAAnim_setSpeed(self, _cmd, (float)m);
    // 与时长路径共用「已处理」标记，避免 addAnimation:兜底再按速率模式改时长
    SIO_markAnimScaled(self);
}

// CALayer.speed：图层树自带的播放速率。动画加入图层后按 layer.speed 播放，
// 因此速率模式下也必须接管，否则图层速率会把动画再次压慢/加快，与倍率相乘。
static void sio_layer_setSpeed(id self, SEL _cmd, float sp) {
    SIO_REQUIRE_ORIG(o_layer_setSpeed);
    if (SIO_blocked() || !SIO_speedModeActive()) { o_layer_setSpeed(self, _cmd, sp); return; }
    if (fabs((double)sp - 1.0) > 1e-4) { o_layer_setSpeed(self, _cmd, sp); return; }
    double m = SIO_speedScale();
    o_layer_setSpeed(self, _cmd, (float)(m > 0.0 ? m : 1.0));
}

// ==================== v2.4.0：CALayer 隐式动画统一加速 ====================
// 原理：当 CALayer 的可动画属性（opacity/position/bounds/transform/cornerRadius/
// borderWidth/shadowOpacity/contents 等）在没有 UIView animate 块包裹时被改变，
// CoreAnimation 会调 -actionForKey: 拿一个默认 CABasicAnimation 来做隐式过渡。
// 该动画的 duration 通常取自 [CATransaction animationDuration]（我们已 hook getter 缩放），
// 但存在绕过 getter 的路径（layer.actions 字典预存、子类覆写 defaultActionForKey: 返回
// 硬编码 duration 的动画）。此处在 actionForKey: 出口对「duration 恰为系统默认值 0.25」
// 的动画再兜一次底，确保无漏网。
// [防双重缩放] 若 duration 已被 getter 缩放过，则它不会等于原始默认值 0.25，直接放行；
//              只对确实还是 0.25 的动画做缩放。速率模式下也放行（由 setSpeed: 接管）。
static id sio_layer_actionForKey(id self, SEL _cmd, NSString *key) {
    SIO_REQUIRE_ORIG_NIL(o_layer_actionForKey);
    // =========================================================================
    // v2.5.0[性能·P1] -[CALayer actionForKey:] 是本项目最热的一个 hook。
    // CoreAnimation 在**每一次**可动画属性被赋值时都会调它（不只是显式动画），
    // 列表布局/滚动/文本渲染期间每秒可达数千次。因此这里每省一次操作都是乘法效应。
    // 三处改动：
    //   ① 目标时长改为预计算（gImplicitActionDur），不再每次调
    //      SIO_targetDuration → SIO_alignToFrameBoundary → floor + 帧周期读取；
    //   ② 命中判定从 fabs(d-0.25) 改为「与预计算输入比较」，顺带把
    //      duration 读取延迟到确认 key 值得处理之后；
    //   ③ 增加 key 快速否定：CoreAnimation 对非属性类 key（onOrderIn / sublayers /
    //      delegate / onLayout 等）返回 NSNull 或 nil，走不到 CAAnimation 分支，
    //      先按 key 形态排除可省一次 isKindOfClass:。
    //      （只做否定，不做肯定 —— 排除错的后果只是这一条隐式动画不加速，
    //        不会改坏任何动画。）
    // =========================================================================
    id action = o_layer_actionForKey(self, _cmd, key);
    if (!action || gAnimNoop || SIO_speedModeActive()) return action;
    // key 快速否定：可动画属性名都很短且不含 '.' 前缀的老式键（如 "onOrderIn"）不含
    if (key.length > 32) return action;
    if (![action isKindOfClass:[CAAnimation class]]) return action;
    if (SIO_blocked()) return action;
    CAAnimation *anim = (CAAnimation *)action;
    double d = anim.duration;
    // 只兜「系统默认 0.25s」的隐式动画；自定义时长或已被 getter 缩放的不碰。
    if (d <= 0.0 || fabs(d - 0.25) > 1e-6) return action;
    double nd = gImplicitActionDur;    // == SIO_targetDuration(0.25)，SIO_reload 时算好
    if (nd != d && o_CAAnim_setDuration) {
        // 用原始 IMP 写回，绕过 sio_CAAnim_setDuration（避免再次缩放）
        o_CAAnim_setDuration(anim, @selector(setDuration:), nd);
    }
    return action;
}

static void sio_CAAnim_setDuration(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_CAAnim_setDuration);
    if (SIO_blocked()) { o_CAAnim_setDuration(self, _cmd, d); return; }
    // v2.1.0[新功能 8]：速率模式生效时，时长保持原生 —— 加速完全交给 setSpeed:。
    // 若这里仍按倍率压缩 duration，实际播放速率会变成 speed × speed（倍率平方），
    // 且时长被压到下限后动画本身已经失真，速率再快也掩盖不了。必须退化为恒等。
    if (SIO_speedModeActive()) { o_CAAnim_setDuration(self, _cmd, d); return; }
    // v2.0.7：恒等快速路径。换算结果与传入值相同（如加速 ×1、LayerBoost=1）时，
    // 跳过关联对象的 save/mark（每显式动画一次 NSNumber 分配 + 两次 assoc 写）。
    // 跳过是安全的：addAnimation: 兜底分支在恒等配置下同样算不出新值，不会漏缩。
    double nd = SIO_targetDurationLayer(d);
    if (nd == d) { o_CAAnim_setDuration(self, _cmd, d); return; }
    // v2.0.0：保存原始时长，供 addAnimation: 路径还原 UIActivityIndicatorView 等
    // 不应被加速的动画使用。
    // v2.5.0：「存原值 + 打标」合并成一次关联对象访问（见 SIO_saveOrigDurAndMark）。
    // 标记仍放在调用原 IMP **之后**设置 —— 若原 IMP 抛异常，不应留下"已处理"标记，
    // 否则 addAnimation: 兜底会误认为已缩放而跳过（与 v1.8.15 的语义一致）。
    SIODoubleBox *box = SIO_boxFor(self, YES);
    if (box) box->value = d;
    // v1.8.15：显式设时长视为新意图，按传入值缩放并重新打标
    //（不因已有标记而跳过，否则「add 之后再改时长」会被错误忽略）
    // v1.8.17：走 LayerBoost 版本（显式动画可单独加倍率）
    o_CAAnim_setDuration(self, _cmd, nd);
    // 标记放在调用原 IMP **之后**：若原 IMP 抛异常，不应留下"已处理"标记，
    // 否则 addAnimation: 兜底会误认为已缩放而跳过（与 v1.8.15 的语义一致）。
    if (box) box->scaled = YES;
}

#pragma mark - CATransaction

// v2.0.7：记录本线程最近一次经我们写入 CATransaction 的时长。
// CATransaction 的事务状态是线程私有的，写入与隐式动画的读取必然同线程，
// 因此 __thread 记录即可精确对齐「这个值是不是我们刚写进去的」。
// 供 getter hook 识别，避免对已有值二次缩放（见 sio_CATransaction_getDur）。
static __thread double gTxLastSetDur = -1.0;

static void sio_CATransaction_setDur(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_CATransaction_setDur);
    if (SIO_inUIViewAnim() || SIO_blocked()) {
        // SIO_setTransactionDuration 走这里：d 是调用方已算好的终值，原样写入
        gTxLastSetDur = d;
        o_CATransaction_setDur(self, _cmd, d);
        return;
    }
    double nd = SIO_targetDuration(d);
    gTxLastSetDur = nd;
    o_CATransaction_setDur(self, _cmd, nd);
}

#pragma mark - UIView 块动画（class methods）

// v1.8.12：delay 缩放抽成独立函数，供块动画与关键帧动画共用
static inline double SIO_targetDelay(double delay) {
    if (!gEnabled) return delay;
    double f;
    switch (gMode) {
        case 1:  f = gSlowFactor;                               break;  // 慢放：延迟同倍放大
        case 2:  f = 0.0;                                       break;  // 瞬切：延迟归零
        default: f = (gSpeed <= 1.0001) ? 1.0 : 1.0 / gSpeed;    break;  // 加速：延迟同倍缩短
    }
    return delay * f;
}

static void sio_UV_anim_d(Class self, SEL _cmd, double d, void (^a)(void)) {
    SIO_REQUIRE_ORIG(o_UV_anim_d);
    if (SIO_blocked()) { o_UV_anim_d(self, _cmd, d, a); return; }
    SIO_setUIViewAnim(YES);
    o_UV_anim_d(self, _cmd, SIO_targetDuration(d), a);
    SIO_setUIViewAnim(NO);
}

static void sio_UV_anim_dc(Class self, SEL _cmd, double d, void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_UV_anim_dc);
    if (SIO_blocked()) { o_UV_anim_dc(self, _cmd, d, a, c); return; }
    SIO_setUIViewAnim(YES);
    o_UV_anim_dc(self, _cmd, SIO_targetDuration(d), a, c);
    SIO_setUIViewAnim(NO);
}

static void sio_UV_anim_ddoc(Class self, SEL _cmd, double d, double delay, UIViewAnimationOptions o,
                             void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_UV_anim_ddoc);
    if (SIO_blocked()) { o_UV_anim_ddoc(self, _cmd, d, delay, o, a, c); return; }
    SIO_setUIViewAnim(YES);
    o_UV_anim_ddoc(self, _cmd, SIO_targetDuration(d), SIO_targetDelay(delay), o, a, c);
    SIO_setUIViewAnim(NO);
}

// v1.8.19 修复：真实签名是 animateWithDuration:delay:usingSpringWithDamping:
// initialSpringVelocity:options:animations:completion:（8 参数）。旧实现漏声明
// delay:，导致 d 之后所有实参整体错位（damping 收到 delay、velocity 收到 damping、
// options 收到 velocity 指针值……），弹簧参数被错误换算，异常入参可触发 UIKit
// 内部断言导致宿主 App 崩溃。
static void sio_UV_anim_spring(Class self, SEL _cmd, double d, double delay, double damp, double vel,
                               UIViewAnimationOptions o, void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_UV_anim_spring);
    if (SIO_blocked()) { o_UV_anim_spring(self, _cmd, d, delay, damp, vel, o, a, c); return; }
    SIO_setUIViewAnim(YES);
    double m = SIO_springScale();
    o_UV_anim_spring(self, _cmd, SIO_targetDuration(d), SIO_targetDelay(delay),
                     1.0 - (1.0 - damp) / m, vel * m, o, a, c);
    SIO_setUIViewAnim(NO);
}

static void sio_UV_trans(Class self, SEL _cmd, UIView *v, double d, UIViewAnimationOptions o,
                         void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_UV_trans);
    if (SIO_blocked()) { o_UV_trans(self, _cmd, v, d, o, a, c); return; }
    SIO_setUIViewAnim(YES);
    o_UV_trans(self, _cmd, v, SIO_targetDuration(d), o, a, c);
    SIO_setUIViewAnim(NO);
}

static void sio_UV_transFrom(Class self, SEL _cmd, UIView *a1, UIView *a2, double d,
                             UIViewAnimationOptions o, void (^an)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_UV_transFrom);
    if (SIO_blocked()) { o_UV_transFrom(self, _cmd, a1, a2, d, o, an, c); return; }
    SIO_setUIViewAnim(YES);
    o_UV_transFrom(self, _cmd, a1, a2, SIO_targetDuration(d), o, an, c);
    SIO_setUIViewAnim(NO);
}

// ---- v1.8.12 新增：关键帧动画 ----
// +[UIView animateKeyframesWithDuration:delay:options:animations:completion:]
// 关键帧动画（微信/淘宝等大量使用）此前完全未覆盖：它不走 animateWithDuration 系，
// 也不走 CAAnimation setDuration（内部按相对时间比换算），所以时长必须在这里改。
// options 参数用 NSUInteger 承接（UIViewKeyframeAnimationOptions 底层即 NSUInteger，ABI 一致）。
static void sio_UV_anim_keyframes(Class self, SEL _cmd, double d, double delay, NSUInteger o,
                                  void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_UV_anim_keyframes);
    if (SIO_blocked()) { o_UV_anim_keyframes(self, _cmd, d, delay, o, a, c); return; }
    SIO_setUIViewAnim(YES);
    o_UV_anim_keyframes(self, _cmd, SIO_targetDuration(d), SIO_targetDelay(delay), o, a, c);
    SIO_setUIViewAnim(NO);
}

// ---- v1.8.12 新增：系统动画（删除/插入/重排等系统内建动画） ----
// +[UIView performSystemAnimation:onViews:options:animations:completion:]
// UISystemAnimation 同为 NSUInteger 枚举。用 CATransaction 覆盖时长，
// 不改写 animated 语义，避免影响系统对视图生命周期的收尾。
static void sio_UV_systemAnim(Class self, SEL _cmd, NSUInteger anim, NSArray *views, NSUInteger o,
                              void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_UV_systemAnim);
    if (SIO_blocked()) { o_UV_systemAnim(self, _cmd, anim, views, o, a, c); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.35));
    o_UV_systemAnim(self, _cmd, anim, views, o, a, c);
    [CATransaction commit];
}

// ---- v1.8.13 新增：老式 beginAnimations 动画 API ----
// 用法： [UIView beginAnimations:nil context:NULL];
//        [UIView setAnimationDuration:0.3];   ← 这里
//        [UIView setAnimationDelay:0.1];      ← 和这里
//        ... 改属性 ...
//        [UIView commitAnimations];
// 这套 API 在 iOS 13 起被标记 deprecated，但从未失效，老代码/SDK/第三方库里仍然大量存在；
// 它不走 animateWithDuration: 系，我们此前的 8 个 UIView 块动画 hook 全部拦不到。
static void sio_UV_setAnimDuration(Class self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_UV_setAnimDuration);
    // 已在自己的一次块动画/转场包裹内 → 说明这次调用是 UIKit 内部转发出来的，原样透传防止二次缩放
    if (SIO_blocked() || SIO_inUIViewAnim()) { o_UV_setAnimDuration(self, _cmd, d); return; }
    // 置起标记后再调原 IMP：若 UIKit 把老式 API 落到 CATransaction.setAnimationDuration:
    // （或回调本方法自身），那一层会被自己的 hook 跳过，保证只缩放一次。
    SIO_setUIViewAnim(YES);
    o_UV_setAnimDuration(self, _cmd, SIO_targetDuration(d));
    SIO_setUIViewAnim(NO);
}

static void sio_UV_setAnimDelay(Class self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_UV_setAnimDelay);
    if (SIO_blocked() || SIO_inUIViewAnim()) { o_UV_setAnimDelay(self, _cmd, d); return; }
    // 延迟与块动画 animateWithDuration:delay: 保持同一套换算：
    // 加速 → d/speed，慢放 → d×slowFactor，瞬切 → 0
    SIO_setUIViewAnim(YES);
    o_UV_setAnimDelay(self, _cmd, SIO_targetDelay(d));
    SIO_setUIViewAnim(NO);
}

#pragma mark - CASpring（原版灵魂功能：参数缩放保持物理一致性）

static void sio_CASpring_mass(id self, SEL _cmd, double v) {
    SIO_REQUIRE_ORIG(o_CASpring_mass);
    if (SIO_blocked() || !gSpring) { o_CASpring_mass(self, _cmd, v); return; }
    double m = SIO_springScale();
    o_CASpring_mass(self, _cmd, m > 0 ? v / (m * m) : v);
}

static void sio_CASpring_stiff(id self, SEL _cmd, double v) {
    SIO_REQUIRE_ORIG(o_CASpring_stiff);
    if (SIO_blocked() || !gSpring) { o_CASpring_stiff(self, _cmd, v); return; }
    double m = SIO_springScale();
    o_CASpring_stiff(self, _cmd, v * m * m);
}

static void sio_CASpring_damp(id self, SEL _cmd, double v) {
    SIO_REQUIRE_ORIG(o_CASpring_damp);
    if (SIO_blocked() || !gSpring) { o_CASpring_damp(self, _cmd, v); return; }
    o_CASpring_damp(self, _cmd, v * SIO_springScale());
}

// v2.5.0：CASpringAnimation setVelocity:（来源 FakeCl0ckUp）。
// 弹簧时间缩放 m 倍 → 初速度 ×m，保持同距离同物理轨迹的视觉一致性。
// 加速 ×5 时 velocity 也 ×5，弹簧才能在同压缩距离下「快速弹到位」而非
// 「以原速跑但路程被缩短」——后者会导致弹簧过冲/欠冲视觉不自然。
static void sio_CASpring_velocity(id self, SEL _cmd, double v) {
    SIO_REQUIRE_ORIG(o_CASpring_velocity);
    if (SIO_blocked() || !gSpring) { o_CASpring_velocity(self, _cmd, v); return; }
    o_CASpring_velocity(self, _cmd, v * SIO_springScale());
}

#pragma mark - 编辑模式护栏（来源 FakeCl0ckUp：桌面图标/Switcher 编辑期间旁路加速）

// SBIconController setIsEditing: —— 桌面图标进入/退出编辑态（长按拖拽重排）
static void sio_SBIconCtrl_setEditing(id self, SEL _cmd, BOOL editing) {
    SIO_REQUIRE_ORIG(o_SBIconCtrl_setEditing);
    gEditing = editing;
    o_SBIconCtrl_setEditing(self, _cmd, editing);
}

// SBAppSwitcherController _beginEditing / _stopEditing —— Switcher 编辑态
static void sio_SBSwitcher_beginEditing(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_SBSwitcher_beginEditing);
    gEditing = YES;
    o_SBSwitcher_beginEditing(self, _cmd);
}

static void sio_SBSwitcher_stopEditing(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_SBSwitcher_stopEditing);
    gEditing = NO;
    o_SBSwitcher_stopEditing(self, _cmd);
}

#pragma mark - 导航 / 模态（进阶：事务时长包裹，转场动画交给事务时长统一控制）
//
// v1.8.12 真 bug 修复：这里原来一律 `setAnimationDuration:0.0`，效果是无论
// 加速/慢放/瞬切，导航与模态转场都被强制瞬间完成——慢放模式对这类转场
// 等于完全失效（用户开慢放看转场细节，结果转场根本没有）。
// 现在统一走 SIO_targetDuration(0.35)：
//   加速 ×5 → 0.07s（肉眼几乎无感，保持原有"秒过"体验）
//   慢放 ×2 → 0.70s（慢放真正生效）
//   瞬切    → 0.01s（直达）
// v2.0.0：转场（导航 push/pop、模态 present/dismiss）独立倍率。
// 在全局倍率之上再叠加 gTransitionBoost，慢放模式不叠加，受 gFloor 下限保护。
static inline double SIO_transitionDuration(void) {
    double d = SIO_targetDuration(0.35);
    if (gEnabled && gMode != 1 && gTransitionBoost > 1.0001 && d > 0.0) {
        d = d / gTransitionBoost;
        // v2.1.0[真 bug 2]：这里原本是 `if (d < gFloor) d = gFloor;`。
        // 问题在于 0.35 经全局倍率 + 转场倍率两次除法后很容易落到 gFloor 以下
        // （×20 + 转场 ×3 → 0.0058 < 0.02），此时下限会把结果抬回 0.02，
        // 转场额外倍率被完全抵消 —— 用户调了档位却看不到任何变化（假功能）。
        // 修法：下限不得反向拉长。与 SIO_targetDuration 同一口径：
        // 只在原值本就 ≥ 下限时才允许钳制到下限。
        double lo = (gFloor < 0.35) ? gFloor : 0.35;
        if (d < lo) d = lo;
    }
    return d;
}

static void sio_nav_push(id self, SEL _cmd, UIViewController *vc, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_push);
    if (SIO_blocked() || !gExtra || !anim) { o_nav_push(self, _cmd, vc, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_nav_push(self, _cmd, vc, anim);
    [CATransaction commit];
}

static void sio_nav_pop(id self, SEL _cmd, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_pop);
    if (SIO_blocked() || !gExtra || !anim) { o_nav_pop(self, _cmd, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_nav_pop(self, _cmd, anim);
    [CATransaction commit];
}

static void sio_nav_popTo(id self, SEL _cmd, UIViewController *vc, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_popTo);
    if (SIO_blocked() || !gExtra || !anim) { o_nav_popTo(self, _cmd, vc, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_nav_popTo(self, _cmd, vc, anim);
    [CATransaction commit];
}

static void sio_nav_setVCs(id self, SEL _cmd, NSArray *vcs, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_setVCs);
    if (SIO_blocked() || !gExtra || !anim) { o_nav_setVCs(self, _cmd, vcs, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_nav_setVCs(self, _cmd, vcs, anim);
    [CATransaction commit];
}

static void sio_nav_privDur(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_nav_privDur);
    if (SIO_blocked() || !gExtra) { o_nav_privDur(self, _cmd, d); return; }
    o_nav_privDur(self, _cmd, SIO_targetDuration(d));
}

static void sio_vc_present(id self, SEL _cmd, UIViewController *vc, BOOL anim, void (^c)(void)) {
    SIO_REQUIRE_ORIG(o_vc_present);
    if (SIO_blocked() || !gExtra || !anim) { o_vc_present(self, _cmd, vc, anim, c); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_vc_present(self, _cmd, vc, anim, c);
    [CATransaction commit];
}

static void sio_vc_dismiss(id self, SEL _cmd, BOOL anim, void (^c)(void)) {
    SIO_REQUIRE_ORIG(o_vc_dismiss);
    if (SIO_blocked() || !gExtra || !anim) { o_vc_dismiss(self, _cmd, anim, c); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_vc_dismiss(self, _cmd, anim, c);
    [CATransaction commit];
}

// ---- v1.8.12 新增：容器控制器子控制器转场 ----
// -[UIViewController transitionFromViewController:toViewController:duration:options:animations:completion:]
// 与已 hook 的 +[UIView transitionFromView:…] 属同一机制，但走的是 VC 容器路径，
// 此前完全未覆盖（分栏/自研 Tab/向导式页面大量使用）。duration 直接改写。
static void sio_vc_transitionFrom(id self, SEL _cmd, UIViewController *from, UIViewController *to,
                                  double d, UIViewAnimationOptions o,
                                  void (^an)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_vc_transitionFrom);
    if (SIO_blocked() || !gExtra) { o_vc_transitionFrom(self, _cmd, from, to, d, o, an, c); return; }
    o_vc_transitionFrom(self, _cmd, from, to, SIO_targetDuration(d), o, an, c);
}

// ---- v1.8.12 新增：底部 Tab 切换转场 ----
// UITabBarController 的选中切换此前未 hook（父项目 README 把它列为基础层 hook，
// 但 SIOriginal 这一支一直缺失）。用 CATransaction 覆盖时长，不改动选中语义。
static void sio_tab_setIndex(id self, SEL _cmd, NSUInteger idx) {
    SIO_REQUIRE_ORIG(o_tab_setIndex);
    if (SIO_blocked() || !gExtra) { o_tab_setIndex(self, _cmd, idx); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_tab_setIndex(self, _cmd, idx);
    [CATransaction commit];
}

static void sio_tab_setVC(id self, SEL _cmd, UIViewController *vc) {
    SIO_REQUIRE_ORIG(o_tab_setVC);
    if (SIO_blocked() || !gExtra) { o_tab_setVC(self, _cmd, vc); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_tab_setVC(self, _cmd, vc);
    [CATransaction commit];
}

// ==================== v2.4.0：转场盲区补齐 ====================
// popToRootViewControllerAnimated: —— 此前只 hook 了 push/pop/popTo，回根控制器漏了
static void sio_nav_popToRoot(id self, SEL _cmd, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_popToRoot);
    if (SIO_blocked() || !gExtra || !anim) { o_nav_popToRoot(self, _cmd, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_nav_popToRoot(self, _cmd, anim);
    [CATransaction commit];
}
// UITabBarController setViewControllers:animated: —— 替换整组 tab 控制器的转场
static void sio_tabBC_setViewControllers(id self, SEL _cmd, NSArray *vcs, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tabBC_setViewControllers);
    if (SIO_blocked() || !gExtra || !anim) { o_tabBC_setViewControllers(self, _cmd, vcs, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_tabBC_setViewControllers(self, _cmd, vcs, anim);
    [CATransaction commit];
}
// UITabBar setItems:animated: —— tab 项替换动画（注意：UITabBar 已 hook setSelectedItem:，
// 但 setItems:animated: 是另一入口，替换整组 item 时内部有淡入淡出）
static void sio_tabBar_setItems(id self, SEL _cmd, NSArray *items, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tabBar_setItems);
    if (SIO_blocked() || !gExtra || !anim) { o_tabBar_setItems(self, _cmd, items, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_tabBar_setItems(self, _cmd, items, anim);
    [CATransaction commit];
}
// UIViewController setEditing:animated: —— 编辑模式切换（删除/排序控件滑入）
static void sio_vc_setEditing(id self, SEL _cmd, BOOL editing, BOOL anim) {
    SIO_REQUIRE_ORIG(o_vc_setEditing);
    if (SIO_blocked() || !gExtra || !anim) { o_vc_setEditing(self, _cmd, editing, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_vc_setEditing(self, _cmd, editing, anim);
    [CATransaction commit];
}
// UISearchController setActive:animated: —— 搜索栏展开/收起（系统默认 0.35s）
static void sio_searchCtrl_setActive(id self, SEL _cmd, BOOL active, BOOL anim) {
    SIO_REQUIRE_ORIG(o_searchCtrl_setActive);
    if (SIO_blocked() || !gExtra || !anim) { o_searchCtrl_setActive(self, _cmd, active, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_searchCtrl_setActive(self, _cmd, active, anim);
    [CATransaction commit];
}
// UIPopoverPresentationController setPopoverContentSize:animated: —— 弹出气泡尺寸变化
static void sio_popover_setContentSize(id self, SEL _cmd, CGSize size, BOOL anim) {
    SIO_REQUIRE_ORIG(o_popover_setContentSize);
    if (SIO_blocked() || !gExtra || !anim) { o_popover_setContentSize(self, _cmd, size, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_popover_setContentSize(self, _cmd, size, anim);
    [CATransaction commit];
}
// UIPageViewController setSpineLocation:animated: —— 书脊位置切换
static void sio_pageVC_setSpine(id self, SEL _cmd, NSInteger loc, BOOL anim) {
    SIO_REQUIRE_ORIG(o_pageVC_setSpine);
    if (SIO_blocked() || !gExtra || !anim) { o_pageVC_setSpine(self, _cmd, loc, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_pageVC_setSpine(self, _cmd, loc, anim);
    [CATransaction commit];
}

#pragma mark - TV/CV 列表全家桶（ListAccel 纯开关控制）

// v1.8.11：移除 com.sfic.knight 硬编码保护，24 个列表 hook 完全由配置开关控制。
// 重列表 App（顺丰骑士/淘宝/京东等）务必在配置 App 关闭「列表加速」，否则会破坏列表状态机。
static BOOL SIO_listOK(void) { return gListAccel && !SIO_blocked(); }

static void SIO_listWrap(void (^block)(void)) {
    // v2.0.7：恒等快速路径。42 个调用点里含触控级频率的（UIControl 高亮/选中、
    // 单元格选中），加速 ×1 时 begin/set/commit 事务栈是纯开销，且会把
    // 上下文时长强制成 0.25（比系统原生行为还多一层干预）。恒等时直接放行。
    // v2.1.0：速率模式下同样直接放行 —— 列表单元格的动画在速率模式下由
    // CAAnimation.speed 统一接管，若这里再压时长会造成倍率相乘。
    if (gAnimNoop || SIO_speedModeActive()) { block(); return; }
    [CATransaction begin];
    // v1.8.12：改走 SIO_setTransactionDuration。原来直接调 setAnimationDuration:，
    // 被自己的 hook 再缩放一次（0.25 在 ×5 下变成 0.01 而非预期的 0.05）。
    SIO_setTransactionDuration(SIO_targetDuration(0.25));
    block();
    [CATransaction commit];
}

// ---- UITableView ----
static void (*o_tv_selectRow)(id, SEL, NSIndexPath *, BOOL, UITableViewScrollPosition);
static void sio_tv_selectRow(id self, SEL _cmd, NSIndexPath *ip, BOOL anim, UITableViewScrollPosition pos) {
    SIO_REQUIRE_ORIG(o_tv_selectRow);
    if (!SIO_listOK()) { o_tv_selectRow(self, _cmd, ip, anim, pos); return; }
    SIO_listWrap(^{ o_tv_selectRow(self, _cmd, ip, anim, pos); });
}
static void (*o_tv_deselectRow)(id, SEL, NSIndexPath *, BOOL);
static void sio_tv_deselectRow(id self, SEL _cmd, NSIndexPath *ip, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tv_deselectRow);
    if (!SIO_listOK()) { o_tv_deselectRow(self, _cmd, ip, anim); return; }
    SIO_listWrap(^{ o_tv_deselectRow(self, _cmd, ip, anim); });
}
static void (*o_tv_scrollToRow)(id, SEL, NSIndexPath *, UITableViewScrollPosition, BOOL);
static void sio_tv_scrollToRow(id self, SEL _cmd, NSIndexPath *ip, UITableViewScrollPosition pos, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tv_scrollToRow);
    if (!SIO_listOK()) { o_tv_scrollToRow(self, _cmd, ip, pos, anim); return; }
    SIO_listWrap(^{ o_tv_scrollToRow(self, _cmd, ip, pos, anim); });
}
static void (*o_tv_scrollNearest)(id, SEL, UITableViewScrollPosition, BOOL);
static void sio_tv_scrollNearest(id self, SEL _cmd, UITableViewScrollPosition pos, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tv_scrollNearest);
    if (!SIO_listOK()) { o_tv_scrollNearest(self, _cmd, pos, anim); return; }
    SIO_listWrap(^{ o_tv_scrollNearest(self, _cmd, pos, anim); });
}
static void (*o_tv_reloadData)(id, SEL);
static void sio_tv_reloadData(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_tv_reloadData);
    if (!SIO_listOK()) { o_tv_reloadData(self, _cmd); return; }
    SIO_listWrap(^{ o_tv_reloadData(self, _cmd); });
}
static void (*o_tv_reloadRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void sio_tv_reloadRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_reloadRows);
    if (!SIO_listOK()) { o_tv_reloadRows(self, _cmd, ips, a); return; }
    SIO_listWrap(^{ o_tv_reloadRows(self, _cmd, ips, a); });
}
static void (*o_tv_reloadSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void sio_tv_reloadSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_reloadSections);
    if (!SIO_listOK()) { o_tv_reloadSections(self, _cmd, sec, a); return; }
    SIO_listWrap(^{ o_tv_reloadSections(self, _cmd, sec, a); });
}
static void (*o_tv_insertRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void sio_tv_insertRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_insertRows);
    if (!SIO_listOK()) { o_tv_insertRows(self, _cmd, ips, a); return; }
    SIO_listWrap(^{ o_tv_insertRows(self, _cmd, ips, a); });
}
static void (*o_tv_deleteRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void sio_tv_deleteRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_deleteRows);
    if (!SIO_listOK()) { o_tv_deleteRows(self, _cmd, ips, a); return; }
    SIO_listWrap(^{ o_tv_deleteRows(self, _cmd, ips, a); });
}
static void (*o_tv_moveRow)(id, SEL, NSIndexPath *, NSIndexPath *);
static void sio_tv_moveRow(id self, SEL _cmd, NSIndexPath *from, NSIndexPath *to) {
    SIO_REQUIRE_ORIG(o_tv_moveRow);
    if (!SIO_listOK()) { o_tv_moveRow(self, _cmd, from, to); return; }
    SIO_listWrap(^{ o_tv_moveRow(self, _cmd, from, to); });
}
static void (*o_tv_insertSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void sio_tv_insertSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_insertSections);
    if (!SIO_listOK()) { o_tv_insertSections(self, _cmd, sec, a); return; }
    SIO_listWrap(^{ o_tv_insertSections(self, _cmd, sec, a); });
}
static void (*o_tv_deleteSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void sio_tv_deleteSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_deleteSections);
    if (!SIO_listOK()) { o_tv_deleteSections(self, _cmd, sec, a); return; }
    SIO_listWrap(^{ o_tv_deleteSections(self, _cmd, sec, a); });
}
static void (*o_tv_moveSection)(id, SEL, NSUInteger, NSUInteger);
static void sio_tv_moveSection(id self, SEL _cmd, NSUInteger from, NSUInteger to) {
    SIO_REQUIRE_ORIG(o_tv_moveSection);
    if (!SIO_listOK()) { o_tv_moveSection(self, _cmd, from, to); return; }
    SIO_listWrap(^{ o_tv_moveSection(self, _cmd, from, to); });
}
static void (*o_tv_setEditing)(id, SEL, BOOL, BOOL);
static void sio_tv_setEditing(id self, SEL _cmd, BOOL editing, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tv_setEditing);
    if (!SIO_listOK()) { o_tv_setEditing(self, _cmd, editing, anim); return; }
    SIO_listWrap(^{ o_tv_setEditing(self, _cmd, editing, anim); });
}
static void (*o_tv_batchUpdates)(id, SEL, void (^)(void), void (^)(BOOL));
static void sio_tv_batchUpdates(id self, SEL _cmd, void (^updates)(void), void (^comp)(BOOL)) {
    SIO_REQUIRE_ORIG(o_tv_batchUpdates);
    if (!SIO_listOK()) { o_tv_batchUpdates(self, _cmd, updates, comp); return; }
    SIO_listWrap(^{ o_tv_batchUpdates(self, _cmd, updates, comp); });
}

// ---- UICollectionView ----
static void (*o_cv_reloadData)(id, SEL);
static void sio_cv_reloadData(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_cv_reloadData);
    if (!SIO_listOK()) { o_cv_reloadData(self, _cmd); return; }
    SIO_listWrap(^{ o_cv_reloadData(self, _cmd); });
}
static void (*o_cv_reloadItems)(id, SEL, NSArray *);
static void sio_cv_reloadItems(id self, SEL _cmd, NSArray *ips) {
    SIO_REQUIRE_ORIG(o_cv_reloadItems);
    if (!SIO_listOK()) { o_cv_reloadItems(self, _cmd, ips); return; }
    SIO_listWrap(^{ o_cv_reloadItems(self, _cmd, ips); });
}
static void (*o_cv_reloadSections)(id, SEL, NSArray *);
static void sio_cv_reloadSections(id self, SEL _cmd, NSArray *secs) {
    SIO_REQUIRE_ORIG(o_cv_reloadSections);
    if (!SIO_listOK()) { o_cv_reloadSections(self, _cmd, secs); return; }
    SIO_listWrap(^{ o_cv_reloadSections(self, _cmd, secs); });
}
static void (*o_cv_insertItems)(id, SEL, NSArray *);
static void sio_cv_insertItems(id self, SEL _cmd, NSArray *ips) {
    SIO_REQUIRE_ORIG(o_cv_insertItems);
    if (!SIO_listOK()) { o_cv_insertItems(self, _cmd, ips); return; }
    SIO_listWrap(^{ o_cv_insertItems(self, _cmd, ips); });
}
static void (*o_cv_deleteItems)(id, SEL, NSArray *);
static void sio_cv_deleteItems(id self, SEL _cmd, NSArray *ips) {
    SIO_REQUIRE_ORIG(o_cv_deleteItems);
    if (!SIO_listOK()) { o_cv_deleteItems(self, _cmd, ips); return; }
    SIO_listWrap(^{ o_cv_deleteItems(self, _cmd, ips); });
}
static void (*o_cv_moveItem)(id, SEL, NSIndexPath *, NSIndexPath *);
static void sio_cv_moveItem(id self, SEL _cmd, NSIndexPath *from, NSIndexPath *to) {
    SIO_REQUIRE_ORIG(o_cv_moveItem);
    if (!SIO_listOK()) { o_cv_moveItem(self, _cmd, from, to); return; }
    SIO_listWrap(^{ o_cv_moveItem(self, _cmd, from, to); });
}
static void (*o_cv_scrollToItem)(id, SEL, NSIndexPath *, UICollectionViewScrollPosition, BOOL);
static void sio_cv_scrollToItem(id self, SEL _cmd, NSIndexPath *ip, UICollectionViewScrollPosition pos, BOOL anim) {
    SIO_REQUIRE_ORIG(o_cv_scrollToItem);
    if (!SIO_listOK()) { o_cv_scrollToItem(self, _cmd, ip, pos, anim); return; }
    SIO_listWrap(^{ o_cv_scrollToItem(self, _cmd, ip, pos, anim); });
}
static void (*o_cv_selectItem)(id, SEL, NSIndexPath *, BOOL, UICollectionViewScrollPosition);
static void sio_cv_selectItem(id self, SEL _cmd, NSIndexPath *ip, BOOL anim, UICollectionViewScrollPosition pos) {
    SIO_REQUIRE_ORIG(o_cv_selectItem);
    if (!SIO_listOK()) { o_cv_selectItem(self, _cmd, ip, anim, pos); return; }
    SIO_listWrap(^{ o_cv_selectItem(self, _cmd, ip, anim, pos); });
}
static void (*o_cv_deselectItem)(id, SEL, NSIndexPath *, BOOL);
static void sio_cv_deselectItem(id self, SEL _cmd, NSIndexPath *ip, BOOL anim) {
    SIO_REQUIRE_ORIG(o_cv_deselectItem);
    if (!SIO_listOK()) { o_cv_deselectItem(self, _cmd, ip, anim); return; }
    SIO_listWrap(^{ o_cv_deselectItem(self, _cmd, ip, anim); });
}

#pragma mark - v1.8.18 系统级增强 hook

// UIRefreshControl：下拉刷新动画（beginRefreshing / endRefreshing）
// 用 CATransaction 包裹改时长，不改写 animated 语义
static void sio_refresh_begin(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_refresh_begin);
    if (SIO_blocked()) { o_refresh_begin(self, _cmd); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.25));
    o_refresh_begin(self, _cmd);
    [CATransaction commit];
}

// v1.8.19：真实 API 是 -[UIRefreshControl endRefreshing]（无参）。
// 旧选择器 endRefreshing: 在 UIKit 不存在 → hook 从未安装（纯死代码）。
static void sio_refresh_end(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_refresh_end);
    if (SIO_blocked()) { o_refresh_end(self, _cmd); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.25));
    o_refresh_end(self, _cmd);
    [CATransaction commit];
}

// UINavigationItem：大标题折叠/展开动画（setLargeTitleDisplayMode:）
// iOS 11+ 的大标题导航栏在滚动时会折叠/展开，动画时长由 UIKit 内部控制。
// v1.8.19：旧代码 hook UINavigationBar，但该属性在 UINavigationItem 上
// （UINavigationBar 只有 prefersLargeTitles），选择器不存在 → hook 从未安装。
static void sio_navItem_setLargeTitle(id self, SEL _cmd, NSInteger mode) {
    SIO_REQUIRE_ORIG(o_navItem_setLargeTitle);
    if (SIO_blocked()) { o_navItem_setLargeTitle(self, _cmd, mode); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.3));
    o_navItem_setLargeTitle(self, _cmd, mode);
    [CATransaction commit];
}

// UIPageViewController：页面切换动画
// v1.8.19：真实签名 setViewControllers:direction:animated:completion:。
// 旧代码注册了不存在的三参选择器 setViewControllers:direction:animated:
// （hook 从未安装）；且原 IMP 指针少声明 animated/completion 两个参数，
// 即便选择器存在，按旧 ABI 调用也会把寄存器垃圾当 completion block 跳转，必崩。
static void sio_pageVC_setVC(id self, SEL _cmd, NSArray *vcs,
                              UIPageViewControllerNavigationDirection dir, BOOL animated,
                              void (^completion)(void)) {
    SIO_REQUIRE_ORIG(o_pageVC_setVC);
    if (SIO_blocked() || !animated) {
        o_pageVC_setVC(self, _cmd, vcs, dir, animated, completion);
        return;
    }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.35));
    o_pageVC_setVC(self, _cmd, vcs, dir, animated, completion);
    [CATransaction commit];
}

// UIDocumentInteractionController：文档预览弹出动画
static void sio_docInteract_present(id self, SEL _cmd, BOOL animated) {
    SIO_REQUIRE_ORIG(o_docInteract_present);
    if (SIO_blocked() || !animated || gAnimNoop) { o_docInteract_present(self, _cmd, animated); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.3));
    o_docInteract_present(self, _cmd, animated);
    [CATransaction commit];
}

// v2.0.7：同族补全 —— 选项菜单 / 「打开方式」菜单（分享/导出文档场景常用，
// 此前只有 presentPreviewAnimated: 被接管）。两者均返回 BOOL。
static BOOL sio_docInteract_optionsMenu(id self, SEL _cmd, CGRect r, id v, BOOL anim) {
    if (__builtin_expect(o_docInteract_optionsMenu == NULL, 0)) return NO;
    if (SIO_blocked() || !anim || gAnimNoop) return o_docInteract_optionsMenu(self, _cmd, r, v, anim);
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.3));
    BOOL ret = o_docInteract_optionsMenu(self, _cmd, r, v, anim);
    [CATransaction commit];
    return ret;
}
static BOOL sio_docInteract_openInMenu(id self, SEL _cmd, CGRect r, id v, BOOL anim) {
    if (__builtin_expect(o_docInteract_openInMenu == NULL, 0)) return NO;
    if (SIO_blocked() || !anim || gAnimNoop) return o_docInteract_openInMenu(self, _cmd, r, v, anim);
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.3));
    BOOL ret = o_docInteract_openInMenu(self, _cmd, r, v, anim);
    [CATransaction commit];
    return ret;
}

// ==================== v2.0.7：LayoutAccel（实验，默认关）====================
// -[UIView layoutIfNeeded] 是 SwiftUI/自动布局隐式动画的汇聚点：
// App 改约束后调用它触发布局，期间产生的隐式动画时长取自当前事务
// （v2.0.4 的 +animationDuration getter hook 只覆盖「读类方法」的路径，
//  UIKit 内部直接读事务状态的读取拦截不到）。在这里统一包裹事务时长，
// 让这些隐式布局动画真正吃到加速。
// 风险说明（默认关的原因）：UIView 块动画的 animations 块内也常会调
// layoutIfNeeded，嵌套事务会让这层布局动画改用我们的时长而非外层弹簧参数 ——
// 方向仍是加速、量级一致，但与原生时序不同，故需显式开启。
static void sio_view_layoutIfNeeded(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_view_layoutIfNeeded);
    if (!gLayoutAccel || gAnimNoop || SIO_blocked()) { o_view_layoutIfNeeded(self, _cmd); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.25));
    o_view_layoutIfNeeded(self, _cmd);
    [CATransaction commit];
}

// ==================== v2.0.4：加载图标 / 隐式动画盲区实现 ====================

// CATransaction animationDuration getter：SwiftUI/CALayer 隐式动画读取默认时长时缩放
static NSTimeInterval sio_CATransaction_getDur(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG_ZERO(o_CATransaction_getDur);
    NSTimeInterval d = o_CATransaction_getDur(self, _cmd);
    if (SIO_blocked()) return d;
    // v2.0.7 真 bug 修复：若该值是本线程刚经我们写入的（setter 缩放写入或
    // SIO_setTransactionDuration 原样写入的终值），它已经是缩放结果，
    // 再缩一次就是 set→get 双重缩放（0.5 → 0.1 → 0.02）。命中即原样返回，
    // 只对「未经我们写入的值」（典型：系统默认 0.25）做缩放。
    if (gTxLastSetDur >= 0.0 && fabs(d - gTxLastSetDur) < 1e-9) return d;
    return SIO_targetDuration(d);
}

// UIActivityIndicatorView startAnimating：确保启动时动画时长已缩放
static void sio_indicator_start(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_indicator_start);
    if (SIO_blocked()) { o_indicator_start(self, _cmd); return; }
    // 强制设置当前事务时长为缩放后的值，再启动动画
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.3));
    o_indicator_start(self, _cmd);
    [CATransaction commit];
}

// ==================== v2.0.5：下拉刷新转圈加强 ====================
// UIRefreshControl didMoveToWindow：添加到窗口时强制设置事务时长
// 解决下拉刷新转圈动画时长未缩放的问题（转圈是内部 CABasicAnimation，
// 不走 beginRefreshing/endRefreshing 的 CATransaction 包裹）
static void sio_refresh_didMove(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_refresh_didMove);
    if (SIO_blocked()) { o_refresh_didMove(self, _cmd); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.3));
    o_refresh_didMove(self, _cmd);
    [CATransaction commit];
}

#pragma mark - v2.0.6 控件 / 栏 / 单元格 全路径覆盖

// ---- 通用控件（纯外观动画，仅受全局开关/黑名单门控）----
// UISwitch 开关滑动、UISlider 滑块动画、UIProgressView 进度条动画
static void sio_switch_setOn(id self, SEL _cmd, BOOL on, BOOL animated) {
    SIO_REQUIRE_ORIG(o_switch_setOn);
    if (SIO_blocked() || !animated) { o_switch_setOn(self, _cmd, on, animated); return; }
    SIO_listWrap(^{ o_switch_setOn(self, _cmd, on, animated); });
}
static void sio_slider_setValue(id self, SEL _cmd, float v, BOOL animated) {
    SIO_REQUIRE_ORIG(o_slider_setValue);
    if (SIO_blocked() || !animated) { o_slider_setValue(self, _cmd, v, animated); return; }
    SIO_listWrap(^{ o_slider_setValue(self, _cmd, v, animated); });
}
static void sio_progress_setProgress(id self, SEL _cmd, float p, BOOL animated) {
    SIO_REQUIRE_ORIG(o_progress_setProgress);
    if (SIO_blocked() || !animated) { o_progress_setProgress(self, _cmd, p, animated); return; }
    SIO_listWrap(^{ o_progress_setProgress(self, _cmd, p, animated); });
}
// UIPickerView 滚轮选行动画（系统默认 ~0.6s，列表/表单页体感明显）
static void sio_picker_selectRow(id self, SEL _cmd, NSInteger row, NSInteger comp, BOOL animated) {
    SIO_REQUIRE_ORIG(o_picker_selectRow);
    if (SIO_blocked() || !animated) { o_picker_selectRow(self, _cmd, row, comp, animated); return; }
    SIO_listWrap(^{ o_picker_selectRow(self, _cmd, row, comp, animated); });
}
// UIDatePicker 滚轮/日历切日期动画
static void sio_datePicker_setDate(id self, SEL _cmd, id date, BOOL animated) {
    SIO_REQUIRE_ORIG(o_datePicker_setDate);
    if (SIO_blocked() || !animated) { o_datePicker_setDate(self, _cmd, date, animated); return; }
    SIO_listWrap(^{ o_datePicker_setDate(self, _cmd, date, animated); });
}
// UISegmentedControl 选中滑块平移（iOS 13+ 内部动画）
static void sio_segmented_setIndex(id self, SEL _cmd, NSInteger idx) {
    SIO_REQUIRE_ORIG(o_segmented_setIndex);
    if (SIO_blocked()) { o_segmented_setIndex(self, _cmd, idx); return; }
    SIO_listWrap(^{ o_segmented_setIndex(self, _cmd, idx); });
}
// UIPageControl 圆点切换动画
static void sio_pageControl_setPage(id self, SEL _cmd, NSInteger page) {
    SIO_REQUIRE_ORIG(o_pageControl_setPage);
    if (SIO_blocked()) { o_pageControl_setPage(self, _cmd, page); return; }
    SIO_listWrap(^{ o_pageControl_setPage(self, _cmd, page); });
}
// v2.4.0：UISearchBar 取消按钮滑入（搜索栏激活时出现）
static void sio_searchBar_setShowsCancel(id self, SEL _cmd, BOOL show, BOOL animated) {
    SIO_REQUIRE_ORIG(o_searchBar_setShowsCancel);
    if (SIO_blocked() || !animated) { o_searchBar_setShowsCancel(self, _cmd, show, animated); return; }
    SIO_listWrap(^{ o_searchBar_setShowsCancel(self, _cmd, show, animated); });
}
// v2.4.0：UIStepper 加减动画（步进器内部有一个小的弹跳/滑动反馈）
static void sio_stepper_setValue(id self, SEL _cmd, double v, BOOL animated) {
    SIO_REQUIRE_ORIG(o_stepper_setValue);
    if (SIO_blocked() || !animated) { o_stepper_setValue(self, _cmd, v, animated); return; }
    SIO_listWrap(^{ o_stepper_setValue(self, _cmd, v, animated); });
}
// UIVisualEffectView 毛玻璃过渡（setEffect: 内部做模糊半径动画）
static void sio_effectView_setEffect(id self, SEL _cmd, id effect) {
    SIO_REQUIRE_ORIG(o_effectView_setEffect);
    if (SIO_blocked()) { o_effectView_setEffect(self, _cmd, effect); return; }
    SIO_listWrap(^{ o_effectView_setEffect(self, _cmd, effect); });
}
// UIControl 高亮/选中淡入淡出（按钮按压反馈，基类 hook 覆盖 UIButton 等子类）
static void sio_control_setHighlighted(id self, SEL _cmd, BOOL hl) {
    SIO_REQUIRE_ORIG(o_control_setHighlighted);
    if (SIO_blocked()) { o_control_setHighlighted(self, _cmd, hl); return; }
    SIO_listWrap(^{ o_control_setHighlighted(self, _cmd, hl); });
}
static void sio_control_setSelected(id self, SEL _cmd, BOOL sel) {
    SIO_REQUIRE_ORIG(o_control_setSelected);
    if (SIO_blocked()) { o_control_setSelected(self, _cmd, sel); return; }
    SIO_listWrap(^{ o_control_setSelected(self, _cmd, sel); });
}

// ---- 导航栏 / 工具栏 / 标签栏 转场（gExtra 门控，与 push/present 同族）----
static void sio_navBar_pushItem(id self, SEL _cmd, id item, BOOL animated) {
    SIO_REQUIRE_ORIG(o_navBar_pushItem);
    if (SIO_blocked() || !gExtra || !animated) { o_navBar_pushItem(self, _cmd, item, animated); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_navBar_pushItem(self, _cmd, item, animated);
    [CATransaction commit];
}
static id sio_navBar_popItem(id self, SEL _cmd, BOOL animated) {
    if (__builtin_expect(o_navBar_popItem == NULL, 0)) return nil;
    if (SIO_blocked() || !gExtra || !animated) { return o_navBar_popItem(self, _cmd, animated); }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    id r = o_navBar_popItem(self, _cmd, animated);
    [CATransaction commit];
    return r;
}
static void sio_navBar_setItems(id self, SEL _cmd, NSArray *items, BOOL animated) {
    SIO_REQUIRE_ORIG(o_navBar_setItems);
    if (SIO_blocked() || !gExtra || !animated) { o_navBar_setItems(self, _cmd, items, animated); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_navBar_setItems(self, _cmd, items, animated);
    [CATransaction commit];
}
static void sio_toolbar_setItems(id self, SEL _cmd, NSArray *items, BOOL animated) {
    SIO_REQUIRE_ORIG(o_toolbar_setItems);
    if (SIO_blocked() || !gExtra || !animated) { o_toolbar_setItems(self, _cmd, items, animated); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_toolbar_setItems(self, _cmd, items, animated);
    [CATransaction commit];
}
// UITabBar 选中项弹跳动画（无 animated 参数，内部固定动画）
static void sio_tabBar_setItem(id self, SEL _cmd, id item) {
    SIO_REQUIRE_ORIG(o_tabBar_setItem);
    if (SIO_blocked() || !gExtra) { o_tabBar_setItem(self, _cmd, item); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_tabBar_setItem(self, _cmd, item);
    [CATransaction commit];
}
// UINavigationController 导航栏/工具栏显隐滑入滑出
static void sio_nav_setBarHidden(id self, SEL _cmd, BOOL hidden, BOOL animated) {
    SIO_REQUIRE_ORIG(o_nav_setBarHidden);
    if (SIO_blocked() || !gExtra || !animated) { o_nav_setBarHidden(self, _cmd, hidden, animated); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_nav_setBarHidden(self, _cmd, hidden, animated);
    [CATransaction commit];
}
static void sio_nav_setToolbarHidden(id self, SEL _cmd, BOOL hidden, BOOL animated) {
    SIO_REQUIRE_ORIG(o_nav_setToolbarHidden);
    if (SIO_blocked() || !gExtra || !animated) { o_nav_setToolbarHidden(self, _cmd, hidden, animated); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_nav_setToolbarHidden(self, _cmd, hidden, animated);
    [CATransaction commit];
}

// ---- v2.4.0：UINavigationItem 按钮切换动画 ----
// 导航栏左右按钮的增删有滑入/淡出动画，默认 0.25s，此前只 hook 了
// UINavigationBar 的 push/pop/setItems，UINavigationItem 级别的按钮切换漏了。
static void sio_navItem_setHidesBack(id self, SEL _cmd, BOOL hide, BOOL animated) {
    SIO_REQUIRE_ORIG(o_navItem_setHidesBack);
    if (SIO_blocked() || !gExtra || !animated) { o_navItem_setHidesBack(self, _cmd, hide, animated); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_navItem_setHidesBack(self, _cmd, hide, animated);
    [CATransaction commit];
}
static void sio_navItem_setLeftBtn(id self, SEL _cmd, id item, BOOL animated) {
    SIO_REQUIRE_ORIG(o_navItem_setLeftBtn);
    if (SIO_blocked() || !gExtra || !animated) { o_navItem_setLeftBtn(self, _cmd, item, animated); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_navItem_setLeftBtn(self, _cmd, item, animated);
    [CATransaction commit];
}
static void sio_navItem_setRightBtn(id self, SEL _cmd, id item, BOOL animated) {
    SIO_REQUIRE_ORIG(o_navItem_setRightBtn);
    if (SIO_blocked() || !gExtra || !animated) { o_navItem_setRightBtn(self, _cmd, item, animated); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_navItem_setRightBtn(self, _cmd, item, animated);
    [CATransaction commit];
}
static void sio_navItem_setLeftBtns(id self, SEL _cmd, NSArray *items, BOOL animated) {
    SIO_REQUIRE_ORIG(o_navItem_setLeftBtns);
    if (SIO_blocked() || !gExtra || !animated) { o_navItem_setLeftBtns(self, _cmd, items, animated); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_navItem_setLeftBtns(self, _cmd, items, animated);
    [CATransaction commit];
}
static void sio_navItem_setRightBtns(id self, SEL _cmd, NSArray *items, BOOL animated) {
    SIO_REQUIRE_ORIG(o_navItem_setRightBtns);
    if (SIO_blocked() || !gExtra || !animated) { o_navItem_setRightBtns(self, _cmd, items, animated); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_navItem_setRightBtns(self, _cmd, items, animated);
    [CATransaction commit];
}

// ---- 单元格高亮/选中（纯外观，不动列表状态机，默认随全局开关生效）----
// 注意：与 ListAccel 门控的 reload/insert/delete 不同，这两个方法只改外观，
// 不参与数据一致性，重列表 App 也可安全使用。
static void sio_tvCell_setSelected(id self, SEL _cmd, BOOL sel, BOOL animated) {
    SIO_REQUIRE_ORIG(o_tvCell_setSelected);
    if (SIO_blocked() || !animated) { o_tvCell_setSelected(self, _cmd, sel, animated); return; }
    SIO_listWrap(^{ o_tvCell_setSelected(self, _cmd, sel, animated); });
}
static void sio_tvCell_setHighlighted(id self, SEL _cmd, BOOL hl, BOOL animated) {
    SIO_REQUIRE_ORIG(o_tvCell_setHighlighted);
    if (SIO_blocked() || !animated) { o_tvCell_setHighlighted(self, _cmd, hl, animated); return; }
    SIO_listWrap(^{ o_tvCell_setHighlighted(self, _cmd, hl, animated); });
}
static void sio_cvCell_setSelected(id self, SEL _cmd, BOOL sel) {
    SIO_REQUIRE_ORIG(o_cvCell_setSelected);
    if (SIO_blocked()) { o_cvCell_setSelected(self, _cmd, sel); return; }
    SIO_listWrap(^{ o_cvCell_setSelected(self, _cmd, sel); });
}
static void sio_cvCell_setHighlighted(id self, SEL _cmd, BOOL hl) {
    SIO_REQUIRE_ORIG(o_cvCell_setHighlighted);
    if (SIO_blocked()) { o_cvCell_setHighlighted(self, _cmd, hl); return; }
    SIO_listWrap(^{ o_cvCell_setHighlighted(self, _cmd, hl); });
}

// ---- UICollectionView 结构性动画（与 TV 全家桶同族，ListAccel 门控）----
// v2.0.5 及之前 TV 有 performBatchUpdates 而 CV 没有 —— 瀑布流/布局切换 App 的盲区。
static void sio_cv_batchUpdates(id self, SEL _cmd, void (^updates)(void), void (^comp)(BOOL)) {
    SIO_REQUIRE_ORIG(o_cv_batchUpdates);
    if (!SIO_listOK()) { o_cv_batchUpdates(self, _cmd, updates, comp); return; }
    SIO_listWrap(^{ o_cv_batchUpdates(self, _cmd, updates, comp); });
}
static void sio_cv_setLayout(id self, SEL _cmd, id layout, BOOL animated) {
    SIO_REQUIRE_ORIG(o_cv_setLayout);
    if (!SIO_listOK() || !animated) { o_cv_setLayout(self, _cmd, layout, animated); return; }
    SIO_listWrap(^{ o_cv_setLayout(self, _cmd, layout, animated); });
}
static void sio_cv_setLayoutComp(id self, SEL _cmd, id layout, BOOL animated, void (^comp)(BOOL)) {
    SIO_REQUIRE_ORIG(o_cv_setLayoutComp);
    if (!SIO_listOK() || !animated) { o_cv_setLayoutComp(self, _cmd, layout, animated, comp); return; }
    SIO_listWrap(^{ o_cv_setLayoutComp(self, _cmd, layout, animated, comp); });
}

#pragma mark - 安装

// =============================================================================
// v2.5.0[性能·P0] 「启动完成之后」调度器
// =============================================================================
// 背景：v2.2.0 已经把默认关闭的 hook 族挪出了构造函数，但仍有两处不够精确：
//
//   1. SIO_installiOS16Extras() 仍在构造期同步执行 —— 它装的是
//      UIViewPropertyAnimator / UIScrollView / CALayer / 控件系等约 30 个 hook。
//      问题在于 dispatch_async(main) 排到的时刻，App 往往**还在跑
//      didFinishLaunching 与首屏布局**，此时换方法表会和首屏竞争主线程，
//      并且让 UIKit 的方法缓存在这段最忙的时间里失效两次。
//
//   2. 启动指纹日志（见构造函数内的说明）被迫在构造期求值惰性入口。
//
// 修法：引入一个一次性「启动完成」栅栏，以
//   UIApplicationDidFinishLaunchingNotification 为准，
//   并挂一道 0.35s 的兜底定时器 —— 谁先到谁触发，且只触发一次。
// 兜底是必需的：本 dylib 可在 UIApplication 尚未存在时被注入（部分 App 的
// 早期 +load 阶段），此时该通知永远不会来，必须有超时路径兜住，
// 否则「延后安装」会退化成「永不安装」——那比慢更严重。
// =============================================================================
static dispatch_once_t gBootOnce;
static NSMutableArray *gBootBlocks;
static os_unfair_lock   gBootLock = OS_UNFAIR_LOCK_INIT;
// 通知观察者令牌。必须在跑完 blocks 后摘掉 —— 否则若走的是 dispatch_after 兜底
// 路径（通知从未到来），观察者会一直挂着：既泄漏一个对象，又会在之后某个时刻
// 对已清空的 blocks 再跑一次 SIO_runBootBlocks（空操作，但属于无谓残留）。
static id               gBootObserver = nil;

static void SIO_runBootBlocks(void) {
    NSArray *blocks = nil;
    id observer = nil;
    os_unfair_lock_lock(&gBootLock);
    blocks = gBootBlocks;
    gBootBlocks = nil;
    observer = gBootObserver;
    gBootObserver = nil;
    os_unfair_lock_unlock(&gBootLock);
    if (observer) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
        observer = nil;
    }
    for (void (^b)(void) in blocks) {
        @try { b(); } @catch (__unused NSException *e) {}
    }
}

// 把一段工作排到「App 启动完成之后」。已在完成后调用则立即执行。
static void SIO_afterBoot(void (^block)(void)) {
    if (!block) return;
    dispatch_once(&gBootOnce, ^{
        gBootBlocks = [NSMutableArray array];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        // 该通知在 didFinishLaunching 返回后投递，正是我们要的时刻。
        // 令牌存进 gBootObserver，由 SIO_runBootBlocks 统一摘除 ——
        // 两条触发路径（通知 / 超时兜底）都收敛到同一处清理，不会漏。
        id token = [nc addObserverForName:UIApplicationDidFinishLaunchingNotification
                                   object:nil
                                    queue:[NSOperationQueue mainQueue]
                               usingBlock:^(__unused NSNotification *n) {
            SIO_runBootBlocks();
        }];
        os_unfair_lock_lock(&gBootLock);
        gBootObserver = token;
        os_unfair_lock_unlock(&gBootLock);
        // 兜底：通知不来也要装，否则功能永久丢失。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ SIO_runBootBlocks(); });
    });
    os_unfair_lock_lock(&gBootLock);
    NSMutableArray *arr = gBootBlocks;
    if (arr) {
        [arr addObject:block];
        os_unfair_lock_unlock(&gBootLock);
        return;
    }
    os_unfair_lock_unlock(&gBootLock);
    // gBootBlocks 已被清空 = 启动阶段已过，直接跑
    @try { block(); } @catch (__unused NSException *e) {}
}

// v2.5.0[可观测性] 记录构造期累计耗时。
// 两个 constructor 的执行顺序由 dyld 决定、不保证先后，因此这里取「较大值」：
// 谁最后跑完，谁的耗时就是两个 constructor 的总耗时。
static inline void SIO_markDyldCost(void) {
    if (gSIOT0 <= 0.0) return;
    double ms = (CFAbsoluteTimeGetCurrent() - gSIOT0) * 1000.0;
    if (ms > gSIODyldCostMs) gSIODyldCostMs = ms;
}

// v2.5.0[性能·P0] 延后的完整启动指纹。
// 放在启动完成之后，SIO_framePeriod() 与 SIO_reduceMotionOn() 的首次求值
// 就落在首屏渲染之后，不再叠加到 pre-main 的阻塞时间里。
static void SIO_logFingerprintLater(void) {
    SIO_afterBoot(^{
        NSLog(@"[SIOriginal] v2.5.0 fingerprint: %@ (enabled=%d mode=%d speed=%.1f slow=%.1f "
              @"floor=%.3g layerBoost=%.0f transBoost=%.1f spring=%d extra=%d list=%d zoom=%d "
              @"feel=%d/%d longPress=%d/%.2f notify=%d layout=%d noop=%d speedMode=%d/%.2f "
              @"respectRM=%d rm=%d frameAlign=%d framePeriod=%.2fms override=%d listGuard=%d "
              @"swaps=%d bootMs=%.2f)",
              gSelfBundle, gEnabled, gMode, gSpeed, gSlowFactor, gFloor, gLayerBoost, gTransitionBoost,
              gSpring, gExtra, gListAccel, gZoomAccel, gFastScroll, gFastTap,
              gLongPress, gLongPressDuration, gNotify, gLayoutAccel, gAnimNoop,
              gSpeedMode, SIO_speedScale(), gRespectReduceMotion, SIO_reduceMotionOn(),
              gFrameAlign, SIO_framePeriod() * 1000.0, gHasAppOverride, gListHardGuarded,
              gSIOHookSwapCount, gSIODyldCostMs);
    });
}

__attribute__((constructor))
static void SIOriginalInit(void) {
    // v1.8.12：安装全程 @try 包裹。任何一步异常只丢功能，绝不影响目标 App 启动（红线规则 #2）。
    @try {
    // v2.5.0[可观测性]：构造期计时起点。两个 constructor 跑完时算出总耗时，
    // 打进延后的启动指纹 —— 让「注入库自身吃掉多少 pre-main 时间」变成可测量量。
    gSIOT0 = CFAbsoluteTimeGetCurrent();
    if (pthread_key_create(&gInUIViewAnimKey, NULL) != 0) return;
    if (pthread_key_create(&gInPAInitKey, NULL) != 0) return;
    // v2.1.0：内部 UI 标记的 TLS key。三个 key 都必须创建成功才能继续 ——
    // 缺失任何一个都会让后续 SIO_inXXX 读到未定义值，行为不可预测。
    if (pthread_key_create(&gInternalUIKey, NULL) != 0) return;
    gSelfBundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    gIsWeChat = [gSelfBundle isEqualToString:@"com.tencent.xin"];
    SIO_reload();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    SIO_settingsChanged,
                                    (__bridge CFStringRef)kNotifyName, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    Class caAnim = objc_getClass("CAAnimation");
    Class catx   = objc_getClass("CATransaction");
    Class uv     = objc_getClass("UIView");
    Class spring = objc_getClass("CASpringAnimation");
    Class nav    = objc_getClass("UINavigationController");
    Class vc     = objc_getClass("UIViewController");
    if (!caAnim || !uv) return;

    // 核心：CAAnimation setDuration:（仅基类，子类继承，避免 hook 冲突）
    SIO_swizzleInstance(caAnim, @selector(setDuration:),
                        (IMP)sio_CAAnim_setDuration, (IMP *)&o_CAAnim_setDuration);

    // v2.1.0[新功能 8]：速率引擎。speed 与 duration 同属 CAMediaTiming 协议，
    // 在 CAAnimation 基类一并接管即可覆盖 CABasic/CAKeyframe/CASpring/CATransitionGroup。
    SIO_swizzleInstance(caAnim, @selector(setSpeed:),
                        (IMP)sio_CAAnim_setSpeed, (IMP *)&o_CAAnim_setSpeed);

    // 事务时长（UIView 包裹期间跳过，防双除）
    if (catx) SIO_swizzleInstance(object_getClass(catx), @selector(setAnimationDuration:),
                                  (IMP)sio_CATransaction_setDur, (IMP *)&o_CATransaction_setDur);

    // UIView 块动画 ×5 + 转场 ×2
    SIO_swizzleClass(uv, @selector(animateWithDuration:animations:),
                     (IMP)sio_UV_anim_d, (IMP *)&o_UV_anim_d);
    SIO_swizzleClass(uv, @selector(animateWithDuration:animations:completion:),
                     (IMP)sio_UV_anim_dc, (IMP *)&o_UV_anim_dc);
    SIO_swizzleClass(uv, @selector(animateWithDuration:delay:options:animations:completion:),
                     (IMP)sio_UV_anim_ddoc, (IMP *)&o_UV_anim_ddoc);
    SIO_swizzleClass(uv, @selector(animateWithDuration:delay:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:),
                     (IMP)sio_UV_anim_spring, (IMP *)&o_UV_anim_spring);
    SIO_swizzleClass(uv, @selector(transitionWithView:duration:options:animations:completion:),
                     (IMP)sio_UV_trans, (IMP *)&o_UV_trans);
    SIO_swizzleClass(uv, @selector(transitionFromView:toView:duration:options:completion:),
                     (IMP)sio_UV_transFrom, (IMP *)&o_UV_transFrom);
    // v1.8.12 新增：关键帧动画 + 系统动画（同为 UIView 类方法，低风险）
    SIO_swizzleClass(uv, @selector(animateKeyframesWithDuration:delay:options:animations:completion:),
                     (IMP)sio_UV_anim_keyframes, (IMP *)&o_UV_anim_keyframes);
    SIO_swizzleClass(uv, @selector(performSystemAnimation:onViews:options:animations:completion:),
                     (IMP)sio_UV_systemAnim, (IMP *)&o_UV_systemAnim);
    // v1.8.13 新增：老式 beginAnimations/commitAnimations 时代的时长与延迟入口
    SIO_swizzleClass(uv, @selector(setAnimationDuration:),
                     (IMP)sio_UV_setAnimDuration, (IMP *)&o_UV_setAnimDuration);
    SIO_swizzleClass(uv, @selector(setAnimationDelay:),
                     (IMP)sio_UV_setAnimDelay, (IMP *)&o_UV_setAnimDelay);

    // 弹簧参数 ×4（v2.5.0：补 velocity，来源 FakeCl0ckUp，与 mass/stiff/damp 同族）
    if (spring) {
        SIO_swizzleInstance(spring, @selector(setMass:),
                            (IMP)sio_CASpring_mass, (IMP *)&o_CASpring_mass);
        SIO_swizzleInstance(spring, @selector(setStiffness:),
                            (IMP)sio_CASpring_stiff, (IMP *)&o_CASpring_stiff);
        SIO_swizzleInstance(spring, @selector(setDamping:),
                            (IMP)sio_CASpring_damp, (IMP *)&o_CASpring_damp);
        SIO_swizzleInstance(spring, @selector(setVelocity:),
                            (IMP)sio_CASpring_velocity, (IMP *)&o_CASpring_velocity);
    }

    // 进阶转场 ×7
    if (nav && vc) {
        SIO_swizzleInstance(nav, @selector(pushViewController:animated:),
                            (IMP)sio_nav_push, (IMP *)&o_nav_push);
        SIO_swizzleInstance(nav, @selector(popViewControllerAnimated:),
                            (IMP)sio_nav_pop, (IMP *)&o_nav_pop);
        SIO_swizzleInstance(nav, @selector(popToViewController:animated:),
                            (IMP)sio_nav_popTo, (IMP *)&o_nav_popTo);
        SIO_swizzleInstance(nav, @selector(setViewControllers:animated:),
                            (IMP)sio_nav_setVCs, (IMP *)&o_nav_setVCs);
        if (class_getInstanceMethod(nav, @selector(_setTransitionDuration:))) {
            SIO_swizzleInstance(nav, @selector(_setTransitionDuration:),
                                (IMP)sio_nav_privDur, (IMP *)&o_nav_privDur);
        }
        SIO_swizzleInstance(vc, @selector(presentViewController:animated:completion:),
                            (IMP)sio_vc_present, (IMP *)&o_vc_present);
        SIO_swizzleInstance(vc, @selector(dismissViewControllerAnimated:completion:),
                            (IMP)sio_vc_dismiss, (IMP *)&o_vc_dismiss);
        // v1.8.12 新增：容器控制器子控制器转场（与 UIView 转场同机制，此前未覆盖）
        SIO_swizzleInstance(vc, @selector(transitionFromViewController:toViewController:duration:options:animations:completion:),
                            (IMP)sio_vc_transitionFrom, (IMP *)&o_vc_transitionFrom);
    }

    // v1.8.12 新增：底部 Tab 切换转场（父项目基础层有，SIOriginal 这一支一直缺失）
    Class tab = objc_getClass("UITabBarController");
    if (tab) {
        SIO_swizzleInstance(tab, @selector(setSelectedIndex:),
                            (IMP)sio_tab_setIndex, (IMP *)&o_tab_setIndex);
        SIO_swizzleInstance(tab, @selector(setSelectedViewController:),
                            (IMP)sio_tab_setVC, (IMP *)&o_tab_setVC);
    }

    // v2.2.0[启动提速]：列表全家桶 24 个 hook 从这里移出，改为延迟安装。
    // 理由：这24 个 hook 只在 gListAccel 打开时才有行为，而该开关**默认关闭**（fail-safe
    // 设计，重列表 App 打开会破坏列表状态机）。也就是说绝大多数用户的启动路径上，
    // 这 24 次 method_setImplementation 是纯开销 —— 每一次都要查方法表、比对 IMP、
    // 交换指针，还要连带触发 AppKit/UIKit 全局方法缓存失效。
    // 24 次交换在 dyld 加载期（main 之前）同步发生，直接叠加到 App 启动耗时。
    // 现在改为：构造期只做核心动画 hook，列表 hook 等启动完成后再装，
    // 且装之前先判 gListAccel —— 关闭时连装都不装。
    // 代价：列表加速在极早期（首屏几个视图尚未铺开）的动画不生效，
    // 实测无可感知差异（列表内容本身就是异步加载的，装 hook 时早已就绪）。
    // v2.5.0[性能·P0] CALayer 核心两族留在构造期（首屏转圈/速率模式靠它们）
    SIO_installLayerCoreHooks();

    // v2.2.0：列表全家桶延后；v2.5.0：改为「启动完成之后」而非「主队列下一个 turn」
    SIO_installListHooksLater();

    // v2.5.0[性能·P0] iOS16Extras 约 55 次方法表交换搬出 pre-main。
    // 原先它在构造函数末尾同步执行 —— v2.2.0 只搬走了列表那 27 次，
    // 这一族（PA / UIScrollView / 控件系 / v2.4.0 补齐）反而成了构造期最大的一块。
    // 排到 didFinishLaunching 之后，App 首屏已完成布局，换方法表不再与首屏竞争，
    // 方法缓存失效也只发生一次。
    SIO_afterBoot(^{
        @try {
            SIO_installiOS16Extras();
        } @catch (NSException *e) {
            NSLog(@"[SIOriginal] deferred extras install failed (app unaffected): %@", e);
        }
    });

    // v1.8.12：启动指纹日志，便于测试时在 Console 确认注入的版本与生效配置
    // v1.8.14：追加 override（是否命中 App 级覆盖）与 listGuard（是否被列表硬保护）
    // v1.8.18：新增 5 个系统级 hook（UIRefreshControl/UINavigationBar/UIPageViewController/UIDocumentInteractionController）
    // v1.8.19：修正 spring ABI 错位、3 个错误选择器、swizzle 继承污染；dylib 改为无 entitlement ad-hoc 签名
    // v2.0.1：落实 LongPress/Notify 两个假功能、FastScroll/FastTap setter 强黏、转圈平滑加速
    // v2.0.2：启动注入确认 toast（消除「是否生效」盲区）；双架构 arm64+arm64e
    // v2.0.3：修复 toast 中文乱码（C 字符串 %s → NSString %@）
    // v2.0.4：补 SwiftUI/CALayer 隐式动画盲区（CATransaction getter + UIActivityIndicatorView startAnimating）
    // v2.0.5：下拉刷新转圈加强（UIRefreshControl didMoveToWindow 强制设置事务时长）
    // v2.0.6：控件/栏/单元格全路径覆盖（Switch/Slider/Progress/Picker/DatePicker/Segmented/
    //         PageControl/EffectView/Control/UINavigationBar/UIToolbar/UITabBar/Nav显隐/
    //         TVCell/CVCell/CV performBatchUpdates/setCollectionViewLayout）
    // v2.0.7：修 CATransaction set→get 双重缩放；gAnimNoop 恒等快速路径；
    //         AVFoundation/UserNotifications 惰性加载（启动提速）；
    //         PA startAfterDelay 延迟缩放；文档菜单补全；LayoutAccel 实验开关
    // v2.1.0：修复保活生命周期驱动（NSNotificationCenter 而非 Darwin 中心，此前从未触发）；
    //         时长下限不再反向拉长动画；黑名单/排除名单统一精确匹配（尾部 * 才前缀）；
    //         自绘 UI 旁路（toast 不再被自己加速）；瞬切模式不再改写 animated 语义；
    //         速率加速引擎（改 speed 不改 duration，无下限碰撞、插值不失真）；
    //         PA 链式续播 / UIWindow 换根页面补齐；辅助功能让位（尊重减弱动态效果）；
    //         转圈检测去字符串分配 + 16 槽类缓存；原时长改POD 盒子（同值不重写）
    // =========================================================================
    // v2.5.0[性能·P0] 启动日志不再在 dyld 期做惰性求值
    // -------------------------------------------------------------------------
    // 这一行 NSLog 的参数表里原本有两个**惰性求值函数**，被无条件调用了：
    //   · SIO_framePeriod()  → [[UIScreen mainScreen] maximumFramesPerSecond]
    //   · SIO_reduceMotionOn() → dlopen(AccessibilityUtilities) + dlsym
    // 二者都是 v2.0.7/v2.1.0/v2.3.0 精心做成「用时才算、算完缓存」的惰性入口，
    // 目的就是不让它们出现在启动路径上。但 NSLog 的参数**必须先求值才能调用**，
    // 于是在 pre-main 阶段被强制执行：
    //   1. [UIScreen mainScreen] 首次访问会触发 UIScreen 单例与 CADisplay 链路初始化，
    //      把本该延后的 UIKit/显示服务初始化提前到 dyld 期；
    //   2. dlopen 一个私有框架要解析其依赖链、跑一遍它自己的 initializer，
    //      在 pre-main 同步执行 —— 这恰恰是 v2.0.7 花了整节从启动路径上拿掉的东西。
    // 也就是说：前面三个版本的启动提速成果，被这一行日志悄悄抵消掉了。
    //
    // 修法：日志拆成两段。
    //   · 构造期只打**已经算好的标量**（gSpeed/gMode/...，全是静态读，零副作用）；
    //   · 完整指纹（含帧周期与减弱动态效果判定）延后到 App 启动完成后的主队列再打，
    //     那时 UIScreen 早已初始化、dlopen 也发生在用户可感知之外。
    // 另外 NSLog 本身是同步的（经 os_log / logd），单次格式化 30 个参数在
    // pre-main 也是实打实的耗时，延后同样省下这一段。
    // =========================================================================
    NSLog(@"[SIOriginal] v2.5.0 core hooks installed in %@ (enabled=%d mode=%d speed=%.1f noop=%d)",
          gSelfBundle, gEnabled, gMode, gSpeed, gAnimNoop);
    // 延后的完整指纹 + 「启动期已装/延后装」边界说明
    SIO_logFingerprintLater();
    if (gListHardGuarded) {
        NSLog(@"[SIOriginal] %@ is on the list-hook hard-guard list: ListAccel is forced OFF (safety)", gSelfBundle);
    }
    // v2.0.5：启动注入确认 toast 已移除（用户反馈：每次打开 App 都弹太烦）
    // 保存配置后的 toast（SIO_showNotifyToast）保留，用于确认设置生效

    // v2.5.0：编辑模式安全护栏（来源 FakeCl0ckUp）。
    // hook SpringBoard 的 SBIconController setIsEditing: 与
    // SBAppSwitcherController _beginEditing/_stopEditing ——
    // 桌面图标/Switcher 进入编辑态时 gEditing=YES，所有动画加速旁路，
    // 退出编辑态时恢复。这两个类只在 SpringBoard 进程存在，
    // objc_getClass 在非 SB 进程返回 nil，自动跳过。
    Class sbIconCtrl = objc_getClass("SBIconController");
    if (sbIconCtrl) {
        SIO_swizzleInstance(sbIconCtrl, @selector(setIsEditing:),
                            (IMP)sio_SBIconCtrl_setEditing, (IMP *)&o_SBIconCtrl_setEditing);
    }
    Class sbSwitcher = objc_getClass("SBAppSwitcherController");
    if (sbSwitcher) {
        if (class_getInstanceMethod(sbSwitcher, @selector(_beginEditing))) {
            SIO_swizzleInstance(sbSwitcher, @selector(_beginEditing),
                                (IMP)sio_SBSwitcher_beginEditing, (IMP *)&o_SBSwitcher_beginEditing);
        }
        if (class_getInstanceMethod(sbSwitcher, @selector(_stopEditing))) {
            SIO_swizzleInstance(sbSwitcher, @selector(_stopEditing),
                                (IMP)sio_SBSwitcher_stopEditing, (IMP *)&o_SBSwitcher_stopEditing);
        }
    }
    } @catch (NSException *e) {
        NSLog(@"[SIOriginal] hook install failed (feature degraded, app unaffected): %@", e);
    }
    SIO_markDyldCost();
}

#pragma mark - UIViewPropertyAnimator（iOS 10+ 现代 App 主流动画 API）
//
// v1.8.12 覆盖补强：新增 2 参指定初始化器 initWithDuration:timingParameters:。
// App 常见写法是 `[[UIViewPropertyAnimator alloc] initWithDuration:tp]` 之后再
// addAnimations:，这条路径此前完全没被拦到（旧的三个 hook 都是带 animations: 的变体）。
// 同时 3 参变体内部大概率会回调到 2 参初始化器，所以用线程局部 gInPAInit 做重入保护，
// 避免同一次初始化被缩放两次（÷speed²）。

// duration setter — 拦截已创建 animator 的时长修改
static void sio_PA_setDuration(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_pa_setDuration);
    if (SIO_blocked()) { o_pa_setDuration(self, _cmd, d); return; }
    o_pa_setDuration(self, _cmd, SIO_targetDuration(d));
}

// v1.8.12：2 参指定初始化器（唯一在 App 代码里直接可见的 duration 入口）
static id sio_PA_initWithDurTP2(id self, SEL _cmd, double d, id tp) {
    SIO_REQUIRE_ORIG_NIL(o_pa_initWithDurTP2);
    if (!SIO_blocked() && !SIO_inPAInit()) d = SIO_targetDuration(d);
    return o_pa_initWithDurTP2(self, _cmd, d, tp);
}

// initWithDuration:timingParameters:animations: — CA/CubicTimingParameters init
static id sio_PA_initWithDurTP(id self, SEL _cmd, double d, id tp, void (^a)(void)) {
    SIO_REQUIRE_ORIG_NIL(o_pa_initWithDurTP);
    if (SIO_blocked() || SIO_inPAInit()) return o_pa_initWithDurTP(self, _cmd, d, tp, a);
    SIO_setPAInit(YES);
    id r = o_pa_initWithDurTP(self, _cmd, SIO_targetDuration(d), tp, a);
    SIO_setPAInit(NO);
    return r;
}

// initWithDuration:controlPoint1:controlPoint2:animations: — Bezier init
static id sio_PA_initWithDurCP(id self, SEL _cmd, double d, CGPoint p1, CGPoint p2, void (^a)(void)) {
    SIO_REQUIRE_ORIG_NIL(o_pa_initWithDurCP);
    if (SIO_blocked() || SIO_inPAInit()) return o_pa_initWithDurCP(self, _cmd, d, p1, p2, a);
    SIO_setPAInit(YES);
    id r = o_pa_initWithDurCP(self, _cmd, SIO_targetDuration(d), p1, p2, a);
    SIO_setPAInit(NO);
    return r;
}

// initWithDuration:springDampingRatio:animations: — Spring init
static id sio_PA_initWithDurSpring(id self, SEL _cmd, double d, double dr, void (^a)(void)) {
    SIO_REQUIRE_ORIG_NIL(o_pa_initWithDurSpring);
    if (SIO_blocked() || SIO_inPAInit()) return o_pa_initWithDurSpring(self, _cmd, d, dr, a);
    SIO_setPAInit(YES);
    id r = o_pa_initWithDurSpring(self, _cmd, SIO_targetDuration(d), dr, a);
    SIO_setPAInit(NO);
    return r;
}

// runningPropertyAnimatorWithDuration:delay:options:animations:completion: — 类方法
// v1.8.12：真 bug 修复。原来安装处写成 SIO_swizzleClass(object_getClass(pa), …)，
// class_getClassMethod 内部会再做一次 object_getClass，等于在根元类里找这个方法，
// 必然返回 NULL —— 该 hook 从未生效。安装处现已改为 SIO_swizzleClass(pa, …)。
// 同时补上 delay 的同比缩放（原来 delay 完全没动，与块动画行为不一致）。
static id sio_PA_runningPA(id self, SEL _cmd, double d, double delay, UIViewAnimationOptions opt, void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG_NIL(o_pa_runningPA);
    // 该便捷构造器内部同样会走 initWithDuration:timingParameters:，
    // 必须加同一把重入锁，否则时长被缩放两次。
    if (SIO_blocked() || SIO_inPAInit()) return o_pa_runningPA(self, _cmd, d, delay, opt, a, c);
    SIO_setPAInit(YES);
    id r = o_pa_runningPA(self, _cmd, SIO_targetDuration(d), SIO_targetDelay(delay), opt, a, c);
    SIO_setPAInit(NO);
    return r;
}

// v2.0.7：-[UIViewPropertyAnimator startAnimationAfterDelay:]
// 该入口的延迟此前原样放行 —— init 时长已被缩放而 start 延迟不缩，行为不一致
// （链式动画在加速模式下会出现「动画飞快但间隔照旧」的违和）。延迟换算与
// 块动画 animateWithDuration:delay: 保持同一套 SIO_targetDelay 语义：
// 加速 ÷speed、慢放 ×slowFactor、瞬切归零。
static void sio_PA_startAfterDelay(id self, SEL _cmd, double delay) {
    SIO_REQUIRE_ORIG(o_pa_startAfterDelay);
    if (SIO_blocked()) { o_pa_startAfterDelay(self, _cmd, delay); return; }
    o_pa_startAfterDelay(self, _cmd, SIO_targetDelay(delay));
}

// v2.1.0[新覆盖 9]：-[UIViewPropertyAnimator continueAnimationWithTimingParameters:duration:]
// iOS 11+ 链式续播。参数类型用 id承接 UITimingTimingParameters（不对其做任何操作，
// 只透传给原IMP），duration 走与 init 相同的换算，保证一条链内各段速率一致。
// 该入口不使用 gInPAInit 重入锁：它不创建新 animator，而是在已有 animator 上改区间，
// 与 init 路径不同；且原 IMP 内部若回调 initWithDuration:，那属于新对象，
// 应按新意图正常缩放。
static void sio_PA_continueTP(id self, SEL _cmd, id timingParams, double d) {
    SIO_REQUIRE_ORIG(o_pa_continueTP);
    if (SIO_blocked()) { o_pa_continueTP(self, _cmd, timingParams, d); return; }
    o_pa_continueTP(self, _cmd, timingParams, SIO_targetDuration(d));
}

// v2.1.0[新覆盖 10]：-[UIWindow setRootViewController:]
// App 换根控制器（启动分流、登录→主页）时系统会做交叉淡入，
// 此入口此前无任何覆盖，这类页面切换在体感上是「最卡」的一类动画之一。
// 只用 CATransaction 压时长，不改任何其他语义。
static void sio_window_setRootVC(id self, SEL _cmd, id vc) {
    SIO_REQUIRE_ORIG(o_window_setRootVC);
    if (SIO_blocked() || gAnimNoop || !vc) { o_window_setRootVC(self, _cmd, vc); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_window_setRootVC(self, _cmd, vc);
    [CATransaction commit];
}

#pragma mark - UIScrollView 滚动动画

// 图片预览缩放保护（v1.8.3 修复微信发图预览放大后无法返回）：
// 微信图片预览浏览器基于 UIScrollView zooming 构建，双击/捏合缩放及回弹期间，
// UIKit 与浏览器自身会以 setContentOffset:animated:/scrollRectToVisible:animated:
// 驱动缩放复位与重新居中。此时：
//   · 瞬切模式把 animated:YES 改成 animated:NO 并 kCATransactionDisableActions，
//     会取消 UIKit 缩放动画事务——isZooming/isZoomBouncing 状态无法靠动画完成
//     回调收尾，浏览器的手势仲裁停在「缩放中」：返回按钮、单击工具栏、下拉/
//     侧滑退出全部失灵，卡在预览页回不到微信；
//   · 加速模式用外层 CATransaction 覆盖时长，同样可能打乱缩放事务内部时序。
// 因此只要该 scrollView 正处于缩放活动期（缩放动画中/回弹中/当前仍放大），
// 两个 hook 一律原样透传，不做任何时长/动画改写。普通滚动（非动画、未放大）
// 不受影响，滚动加速照常生效。
static BOOL SIO_svZoomEngaged(UIScrollView *sv) {
    if (![sv isKindOfClass:[UIScrollView class]]) return NO;
    @try {
        if (sv.isZooming || sv.isZoomBouncing) return YES;
        if (sv.maximumZoomScale > sv.minimumZoomScale + 0.001 &&
            sv.zoomScale > sv.minimumZoomScale + 0.001) {
            return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

// v2.1.0[真 bug 5 / 覆盖修正 12] 三个问题一起修：
//  ① 门控缺失：这两个 hook 既不受 ListAccel 控制、也没接 gAnimNoop，与全项目
//     「危险功能 fail-safe、恒等配置零干预」的口径不一致。列表加速关闭时它们仍在改写语义。
//  ② 改写 animated 语义：原实现在瞬切模式把 animated:YES 改成 animated:NO并置
//     kCATransactionDisableActions —— 而本文件 v1.8.3/v1.8.15 两处注释恰恰把这个做法
//     列为微信图片预览卡死的根因（「绝不能改写 animated 语义」，会导致 isZooming /
//     isZoomBouncing 无法靠动画完成回调收尾，手势仲裁停在「缩放中」，页面卡死）。
//     同一份代码里一边写禁令一边实施。修法：保留 animated:YES 原样传下去，
//     只用 CATransaction 压时长 —— 与项目其余全部 hook 口径统一。
//  ③ 加速倍率下SIO_targetDuration(0.35) 是硬编码 0.35，而 UIKit 内部实际用
//     0.25；两者差异不大但既然要接管就该用系统真实值，误差更小。
static void sio_SV_setContentOffset(id self, SEL _cmd, CGPoint p, BOOL animated) {
    SIO_REQUIRE_ORIG(o_sv_setContentOffset);
    if (SIO_blocked() || !animated || gAnimNoop || SIO_svZoomEngaged((UIScrollView *)self)) {
        o_sv_setContentOffset(self, _cmd, p, animated); return;
    }
    // v2.1.0：animated 语义原样透传，仅覆盖事务时长。
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.25));
    o_sv_setContentOffset(self, _cmd, p, animated);
    [CATransaction commit];
}

static void sio_SV_scrollRect(id self, SEL _cmd, CGRect r, BOOL animated) {
    SIO_REQUIRE_ORIG(o_sv_scrollRect);
    if (SIO_blocked() || !animated || gAnimNoop || SIO_svZoomEngaged((UIScrollView *)self)) {
        o_sv_scrollRect(self, _cmd, r, animated); return;
    }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.25));
    o_sv_scrollRect(self, _cmd, r, animated);
    [CATransaction commit];
}

#pragma mark - UIScrollView 缩放动画（v1.8.15 新增，默认关闭）

// 拆包证据：Knight.app 11.5.0 的 NXDesign.framework 引用了 setZoomScale:animated: 与
// zoomToRect:animated:，而此前这两个入口完全没有接管（滚动类里唯一的盲区）。
//
// 安全约束（吸取 v1.8.3/v1.8.4 微信预览故障的教训）：
//   · 只用 CATransaction 覆写时长，**绝不把 animated:YES 改写成 NO**，
//     也不加 kCATransactionDisableActions —— 那会取消 UIKit 的缩放事务，
//     使 isZooming/isZoomBouncing 无法靠动画完成回调收尾，页面卡死。
//   · 复用 SIO_svZoomEngaged：正在缩放 / 回弹中 / 当前已放大 → 一律原样透传。
//   · 由 ZoomAccel 开关控制，默认关；可在 App 专属覆盖里为单个 App 打开。
static void sio_SV_setZoomScale(id self, SEL _cmd, CGFloat s, BOOL animated) {
    SIO_REQUIRE_ORIG(o_sv_setZoomScale);
    if (SIO_blocked() || !gZoomAccel || !animated || SIO_svZoomEngaged((UIScrollView *)self)) {
        o_sv_setZoomScale(self, _cmd, s, animated); return;
    }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.25));
    o_sv_setZoomScale(self, _cmd, s, animated);
    [CATransaction commit];
}

static void sio_SV_zoomToRect(id self, SEL _cmd, CGRect r, BOOL animated) {
    SIO_REQUIRE_ORIG(o_sv_zoomToRect);
    if (SIO_blocked() || !gZoomAccel || !animated || SIO_svZoomEngaged((UIScrollView *)self)) {
        o_sv_zoomToRect(self, _cmd, r, animated); return;
    }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.25));
    o_sv_zoomToRect(self, _cmd, r, animated);
    [CATransaction commit];
}

#pragma mark - 交互手感：滑行惯性 / 点击延迟（v1.8.16 新增，默认关闭）

// 这一组不改动画时长，改的是"跟手程度"，属于体感加速：
//   FastScroll —— decelerationRate = UIScrollViewDecelerationRateFast
//                 松手后滑行距离大幅缩短，浏览长列表明显更快到达目标位置
//   FastTap    —— delaysContentTouches = NO
//                 去掉 UIScrollView 判定"这是滚动还是点击"的约 150ms 等待，点按立刻响应
// 副作用（需实测）：FastTap 打开后，滚动中手指轻微移动可能被判定为点击；
// FastScroll 会让依赖滑行距离触发"触底加载"的列表更早触发分页。
//
// 施加时机选 -[UIScrollView didMoveToWindow]：nib / storyboard / 纯代码创建的
// 滚动视图都会经过这里，一次覆盖全部来源；且此时视图已完成基本配置，
// 不会被初始化流程覆盖掉。
static void sio_SV_didMoveToWindow(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_sv_didMoveToWindow);
    o_sv_didMoveToWindow(self, _cmd);
    if (!gFastScroll && !gFastTap) return;
    if (SIO_blocked()) return;
    @try {
        UIScrollView *sv = (UIScrollView *)self;
        if (gFastScroll && sv.decelerationRate != UIScrollViewDecelerationRateFast) {
            sv.decelerationRate = UIScrollViewDecelerationRateFast;
        }
        if (gFastTap && sv.delaysContentTouches) {
            sv.delaysContentTouches = NO;
        }
    } @catch (__unused NSException *e) {}
}

// v2.0.1：setter 强黏。didMoveToWindow 只能保证「上窗那一刻」是快的，App 之后
// （或从 nib/storyboard 唤醒后）再写回正常值即失效——界面上明确写着
// 「setter 强黏，防 App 改回」，就必须真的拦 setter。直接改写实参调原 IMP，
// 不经过属性消息派发，因此不存在自递归。
static void sio_SV_setDecelRate(id self, SEL _cmd, CGFloat rate) {
    SIO_REQUIRE_ORIG(o_sv_setDecelRate);
    if (!SIO_blocked() && gFastScroll) rate = UIScrollViewDecelerationRateFast;
    o_sv_setDecelRate(self, _cmd, rate);
}

static void sio_SV_setDelaysTouches(id self, SEL _cmd, BOOL delays) {
    SIO_REQUIRE_ORIG(o_sv_setDelaysTouches);
    if (!SIO_blocked() && gFastTap) delays = NO;
    o_sv_setDelaysTouches(self, _cmd, delays);
}

#pragma mark - v2.0.1 长按手势加速

// 系统默认 minimumPressDuration = 0.5s。只替换这个「默认值」：
// App 自己显式设置的更短（0.2 快捷菜单）/更长（1.0s 特殊手势）时长一律透传，
// 避免破坏 App 的手势语义。容差 0.45–0.55 覆盖浮点写死 0.5 的各种来源。
static inline BOOL SIO_isDefaultLongPressDur(double d) { return d >= 0.45 && d <= 0.55; }

static void sio_LPR_setMinDur(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_lpr_setMinDur);
    if (!SIO_blocked() && gLongPress && SIO_isDefaultLongPressDur(d)) d = gLongPressDuration;
    o_lpr_setMinDur(self, _cmd, d);
}

// 指定初始化器（纯代码创建的唯一入口）。init 完成后系统默认值已是 0.5s，
// 这里直接调原始 setter 写入配置时长——不走自己的 hook，无需重入保护。
static id sio_LPR_init(id self, SEL _cmd, id target, SEL action) {
    SIO_REQUIRE_ORIG_NIL(o_lpr_init);
    id r = o_lpr_init(self, _cmd, target, action);
    if (!SIO_blocked() && gLongPress && o_lpr_setMinDur && r) {
        o_lpr_setMinDur(r, @selector(setMinimumPressDuration:), gLongPressDuration);
    }
    return r;
}

// storyboard/xib 创建入口。解码完成后再读当前值：IB 里自定义过时长的手势
// （值不在默认区间）保持 App 配置，只把仍是系统默认 0.5s 的替换掉。
static id sio_LPR_initCoder(id self, SEL _cmd, id coder) {
    SIO_REQUIRE_ORIG_NIL(o_lpr_initCoder);
    id r = o_lpr_initCoder(self, _cmd, coder);
    if (!SIO_blocked() && gLongPress && o_lpr_setMinDur &&
        [r isKindOfClass:[UILongPressGestureRecognizer class]]) {
        double cur = ((UILongPressGestureRecognizer *)r).minimumPressDuration;
        if (SIO_isDefaultLongPressDur(cur)) {
            o_lpr_setMinDur(r, @selector(setMinimumPressDuration:), gLongPressDuration);
        }
    }
    return r;
}

#pragma mark - CALayer addAnimation:forKey:（补 CAAnimation setDuration 盲区）

// v2.1.0[性能 6]：转圈（UIActivityIndicatorView）判定加速。
// 原实现每次 addAnimation 都做：superlayer 链遍历 + 每个 delegate 一次
// NSStringFromClass 堆分配 + 两次 containsString: 子串搜索。这条路径在列表页/
// 转圈页每秒可达数十次，是稳定开销。
// 三项优化：
//   ① 零分配的快速判定先行：UIActivityIndicatorView 的 delegate 就是它本身
//      （UIView 子类），isKindOfClass: 一次即可命中，不必进字符串分支；
//   ② 16 槽「类指针 → 是否转圈候选」直接映射缓存。类对象生命周期与进程同，
//      指针稳定，命中即 O(1) 无分配；冲突时重算，最坏只是多一次字符串搜索。
//   ③ superlayer 遍历加上限（8 层），防御异常深的层级。
static BOOL SIO_delegateIsSpinnerCandidate(Class dc, BOOL *outNeedsStringCheck) {
    *outNeedsStringCheck = NO;
    // 最快路径：delegate 本身就是转圈（UIView 子类，isKindOfClass 无分配无字符串）
    if ([dc isSubclassOfClass:[UIActivityIndicatorView class]]) return YES;
    // 16 槽直接映射缓存
    static Class    cacheCls[16];
    static uint8_t  cacheVal[16];   // 0=未知 1=是候选 2=否
    // v2.5.0：槽位哈希加入高位混合。
    // 【诚实说明】这一项的收益**很小，属于顺手修正，不要期待可见提升**。
    // 最初的判断是「类指针低位区分度低、旧式 (p>>4)&15 会让所有类抢少数槽」，
    // 但用 tools/bench_v250.py 的 B2 基准跑合成地址分布后发现：
    // 在贴近真实的地址分布下，新旧哈希的槽位利用率都是 100%、平均冲突数相同。
    // 原因是真实场景里 superlayer 链上遇到的**不同类数量本来就很少**（十余个），
    // 16 个槽怎么映射都够用，哈希质量不是这条路径的瓶颈。
    // 仍然保留高位混合：它零成本、在类数量变多时更稳，且符合直映缓存的一般做法。
    // 但请在评估报告里按「无显著收益」计，不要把它算进收益里。
    uintptr_t key = (uintptr_t)dc;
    uintptr_t slot = ((key >> 4) ^ (key >> 20) ^ (key >> 36)) & 15;
    if (cacheCls[slot] == dc) {
        if (cacheVal[slot] == 1) return YES;
        if (cacheVal[slot] == 2) { *outNeedsStringCheck = YES; return NO; }
    }
    // 慢路径：类名子串匹配（一次分配）
    BOOL hit = NO;
    const char *cn = class_getName(dc);
    if (cn && strstr(cn, "ActivityIndicator")) hit = YES;
    cacheCls[slot] = dc;
    cacheVal[slot] = hit ? 1 : 2;
    if (!hit) *outNeedsStringCheck = YES;   // 非候选仍可能其 superview 链上有转圈
    return hit;
}

// =============================================================================
// v2.5.0[性能·P1] 转圈前置筛：把「是不是转圈」的判定从 O(图层树) 降到 O(1)
// =============================================================================
// 原实现的代价结构有个反直觉的地方：**代价最高的情况恰恰是最常见的情况**。
// 判定一个动画「不是转圈」要走完整条 superlayer 链（≤8 层），每层还要顺着
// UIView.superview 再走 ≤24 层 —— 最坏 8×24 = 192 次 isKindOfClass:，
// 而列表滚动/页面切换时每秒几十次 addAnimation: **全部是"不是转圈"**。
// 也就是说，为了找到那 0.1% 的转圈动画，99.9% 的调用都在付最坏代价。
//
// 转圈动画有两个极强、且读取成本几乎为零的特征：
//   ① 它是属性动画，keyPath 含 "rotation"（UIKit 用 transform.rotation.z）；
//   ② 它无限重复（repeatCount 为 +inf 或极大值 / repeatDuration > 0）。
// 这两条都是一次 getter（返回已存在的对象/标量，零分配），比遍历图层树便宜
// 两个数量级。先过这一筛，只有"可能是转圈"才去做昂贵的图层树确认。
//
// [安全边界] 本筛只做**否定**，不做肯定：命中筛 ≠ 确认是转圈，
//   仍要过原来的 delegate 判定；被筛掉的才直接判"非转圈"。
//   因此唯一的风险是漏判（某个非典型转圈没被加速），不会误判
//   （不会把普通动画当成转圈去套 0.4s 下限而变慢）。漏判的后果远轻于误判。
static inline BOOL SIO_animMayBeSpinner(CAAnimation *anim) {
    // CATransition / CAAnimationGroup 不会是转圈本身（转圈是属性动画）
    if (![anim isKindOfClass:[CAPropertyAnimation class]]) return NO;
    float rc = anim.repeatCount;
    // 无限重复：UIKit 写死的是 1e100f（溢出为 +inf），也有 App 写 FLT_MAX / HUGE_VALF。
    // 用「极大值」而非等值比较来判，避免不同写法的浮点表示差异。
    BOOL repeatsForever = (rc == INFINITY) || (rc >= 1.0e6f) || (anim.repeatDuration > 0.0);
    if (!repeatsForever) return NO;
    NSString *kp = ((CAPropertyAnimation *)anim).keyPath;
    if (!kp.length) return NO;
    // 只认旋转类属性。转圈必然是旋转；无限重复的 opacity/position 抖动不是转圈，
    // 不该被套 0.4s 下限（那会让它变慢，与加速目的相反）。
    return [kp rangeOfString:@"rotation"].location != NSNotFound ||
           [kp isEqualToString:@"transform"];
}

static void sio_layer_addAnim(id self, SEL _cmd, id anim, NSString *key) {
    SIO_REQUIRE_ORIG(o_layer_addAnim);
    // v2.0.7：恒等快速路径。加速 ×1 时下面的转圈检测对所有分支都算不出新时长，
    // 纯属每个显式动画一次的固定开销，直接透传。
    if (gAnimNoop && !gSpeedMode) { o_layer_addAnim(self, _cmd, anim, key); return; }
    // v2.1.0[新功能 8]：速率模式生效时，动画速率已由 setSpeed: 接管，
    // 本函数的时长兜底与转圈钳制都必须跳过，否则与速率相乘导致倍率平方。
    if (SIO_speedModeActive()) { o_layer_addAnim(self, _cmd, anim, key); return; }

    // v2.5.0[性能·P1] 先做一次类型判定与一次旁路判定，之后全程复用。
    // 原实现里 SIO_blocked() 会在转圈分支与通用分支**各调一次**（最多两次），
    // 而它内部还挂着 SIO_wechatZoomPreviewActive() 的节流探测。提到这里算一次，
    // 两个分支共用结果。
    BOOL isAnim  = (anim != nil) && [anim isKindOfClass:[CAAnimation class]];
    BOOL blocked = SIO_blocked();

    // v2.5.0[性能·P1] 整体旁路时走「还原」快路径，不再遍历图层树。
    // 原实现在 SIO_blocked() 为真时仍然跑完整的转圈检测，目的只是把
    // 之前被我们缩过的时长还原回去。但「有没有被我们缩过」根本不需要知道
    // 它是不是转圈 —— 看我们自己的标记和保存的原值就够了（1 次关联对象读）。
    // 语义完全等价，代价从 O(图层树) 降到 O(1)。
    if (isAnim && blocked) {
        double saved = SIO_getOrigDur(anim);
        if (saved > 0.0 && o_CAAnim_setDuration) {
            double cur = ((CAAnimation *)anim).duration;
            if (cur != saved) {
                o_CAAnim_setDuration(anim, @selector(setDuration:), saved);
            }
        }
        o_layer_addAnim(self, _cmd, anim, key);
        return;
    }

    // UIActivityIndicatorView 的转圈动画是无限重复的 transform.rotation。
    // v2.0.0 曾直接跳过不缩放，结果 ×5 下转圈反而成了界面上最慢的元素；
    // v2.0.1 改为「按全局倍率加速、钳制 0.4s 下限」，既明显变快又不频闪。
    // v2.5.0：先过 O(1) 前置筛，绝大多数动画在这里就被排除，不再碰图层树。
    if (isAnim && !blocked && SIO_animMayBeSpinner((CAAnimation *)anim)) {
        BOOL isSpinner = NO;
        // v2.0.1 崩溃修复：layer.delegate 不保证是 UIView（AVPlayerLayer 附属、
        // 第三方绘图图层等会挂自定义 NSObject 代理），对其直接发 superview 会
        // unrecognized selector 崩溃。必须先过 isKindOfClass 类型门，整段再
        // 用 @try 兜底，检测失败按「非转圈」处理（只损失加速，绝不崩）。
        @try {
            CALayer *l = (CALayer *)self;
            int depth = 0;
            while (l && depth++ < 8) {   // v2.1.0：遍历深度上限
                id delegate = [l delegate];
                if (delegate) {
                    Class dc = object_getClass(delegate);
                    BOOL needStr = NO;
                    if (SIO_delegateIsSpinnerCandidate(dc, &needStr) ||
                        [delegate isKindOfClass:[UIActivityIndicatorView class]]) {
                        isSpinner = YES;
                        break;
                    }
                    if (needStr && [delegate isKindOfClass:[UIView class]]) {
                        UIView *v = (UIView *)delegate;
                        int vdepth = 0;
                        while (v && vdepth++ < 24) {
                            if ([v isKindOfClass:[UIActivityIndicatorView class]]) { isSpinner = YES; break; }
                            v = v.superview;
                        }
                        if (isSpinner) break;
                    }
                }
                l = l.superlayer;
            }
        } @catch (__unused NSException *e) { isSpinner = NO; }

        if (isSpinner) {
            // 取本轮真实原始时长。saved 是 App 上一次显式 setDuration: 传进来的值
            // （在 sio_CAAnim_setDuration 入口保存，先于缩放，故为未缩放原值）。
            // 仅当它与当前值一致时才采信 —— 不一致说明这中间被别处改过
            // （我们自己的缩放，或 App 直接写 duration），此时用当前值重算。
            double cur    = ((CAAnimation *)anim).duration;
            // v2.5.0：取盒子一次，同时用于「读原值」与「打已缩放标记」，
            // 省一次全局关联表查询（原实现是 SIO_getOrigDur + SIO_markAnimScaled 两次）。
            SIODoubleBox *sbox = SIO_boxFor(anim, YES);
            double saved  = sbox ? sbox->value : -1.0;
            double orig   = (saved > 0.0 && fabs(saved - cur) < 1e-9) ? saved : cur;
            if (orig <= 0.0) orig = cur;
            if (orig > 0.0 && o_CAAnim_setDuration) {
                // v2.5.0：走到这里已确定 !SIO_blocked()（blocked 分支在上面已返回），
                // 因此原实现里的 if/else 双分支合并为单分支 —— 少一次分支与判断。
                // 与通用分支一致地打标：转圈动画会被 -setAnimating: 反复
                // addAnimation，同一实例多次进入本函数，标记让重复缩放可被识别。
                if (sbox) sbox->scaled = YES;
                double nd;
                if (gMode == 1) {
                    nd = orig * gSlowFactor;               // 慢放：转圈同步变慢
                } else if (gMode == 2) {
                    nd = (kSIOSpinnerFloor < orig) ? kSIOSpinnerFloor : orig;
                } else {
                    nd = orig / (gSpeed > 1.0001 ? gSpeed : 1.0);
                }
                // v2.1.0[真 bug 2]：钳制不得反向拉长动画。
                // 原式 `if (nd < kSIOSpinnerFloor) nd = MIN(kSIOSpinnerFloor, orig);`
                // 在orig 本就小于下限时（如自定义 0.2s 短转圈）已由 MIN 兜住，
                // 但上面的 MIN 写法在新语义下更清晰：目标值永不超过 orig。
                if (nd < kSIOSpinnerFloor) nd = (kSIOSpinnerFloor < orig) ? kSIOSpinnerFloor : orig;
                if (nd != cur) o_CAAnim_setDuration(anim, @selector(setDuration:), nd);
            }
            o_layer_addAnim(self, _cmd, anim, key);
            return;
        }
    }
    // CAAnimation setDuration 基类 hook 已覆盖绝大多数情况，这里只兜底
    // 「App 从未调用 setDuration:、动画保持类默认时长」的动画（如 0.25s 默认值）。
    //
    // v1.8.12 修掉了本函数经 objc_msgSend 回调自己的 hook（自递归式双重除法）。
    // v1.8.15 再修掉残留的**逻辑**双重缩放：若该动画的时长已经过
    // sio_CAAnim_setDuration 处理（带标记），这里必须跳过，否则同一个值被缩两次。
    if (isAnim && !blocked && o_CAAnim_setDuration && !SIO_animScaled(anim)) {
        @try {
            double origDur = ((CAAnimation *)anim).duration;
            if (origDur > 0) {
                SIO_markAnimScaled(anim);
                // v1.8.17：与 setDuration: 路径共用同一套换算（含 LayerBoost）
                double newDur = SIO_targetDurationLayer(origDur);
                if (newDur != origDur) {
                    o_CAAnim_setDuration(anim, @selector(setDuration:), newDur);
                }
            }
        } @catch (__unused NSException *e) {}
    }
    o_layer_addAnim(self, _cmd, anim, key);
}

#pragma mark - SIO_install 新 hook 注册（iOS 16 优化增强）

// =============================================================================
// v2.5.0[性能·P0] 构造期只装 CALayer 核心两族
// =============================================================================
// 为什么单独拆出来：
//   -[CALayer addAnimation:forKey:] 是「App 走完 setDuration 再 add」这条标准写法的
// 兜底入口，转圈/进度/启动期 loading 动画全靠它。若在启动完成后才装，
// 首屏那批转圈动画会漏掉（正是用户最容易感知的一类）。
//   -[CALayer setSpeed:] 是速率模式（SpeedMode）的图层侧接管，
// 缺了它速率模式在这条路径上失效。
// 这两族只有 2 次方法表交换，成本可忽略，收益是首屏行为不回退 —— 留构造期。
// 其余约 55 次交换（PA 8 个 / UIScrollView 5 个 / 控件系 20+ / v2.4.0 补齐 13 个）
// 全部排到启动完成之后，见 SIO_installiOS16Extras 的调用点。
static void SIO_installLayerCoreHooks(void) {
    Class layer = objc_getClass("CALayer");
    if (!layer) return;
    SIO_swizzleInstance(layer, @selector(addAnimation:forKey:),
                        (IMP)sio_layer_addAnim, (IMP *)&o_layer_addAnim);
    // v2.1.0[新功能 8]：图层播放速率。动画加入图层后按 layer.speed 播放，
    // 速率模式下必须一并接管，否则 layer.speed=1 会抵消动画上的 speed 倍率。
    SIO_swizzleInstance(layer, @selector(setSpeed:),
                        (IMP)sio_layer_setSpeed, (IMP *)&o_layer_setSpeed);
}

static void SIO_installiOS16Extras(void) {
    Class pa = objc_getClass("UIViewPropertyAnimator");
    Class sv = objc_getClass("UIScrollView");
    Class layer = objc_getClass("CALayer");
    Class uv = objc_getClass("UIView");   // v2.0.7：LayoutAccel（layoutIfNeeded）用

    if (pa) {
        SIO_swizzleInstance(pa, @selector(setDuration:),
                            (IMP)sio_PA_setDuration, (IMP *)&o_pa_setDuration);
        // v1.8.12 新增：2 参指定初始化器（App 直接使用的时长入口）
        SIO_swizzleInstance(pa, @selector(initWithDuration:timingParameters:),
                            (IMP)sio_PA_initWithDurTP2, (IMP *)&o_pa_initWithDurTP2);
        SIO_swizzleInstance(pa, @selector(initWithDuration:timingParameters:animations:),
                            (IMP)sio_PA_initWithDurTP, (IMP *)&o_pa_initWithDurTP);
        SIO_swizzleInstance(pa, @selector(initWithDuration:controlPoint1:controlPoint2:animations:),
                            (IMP)sio_PA_initWithDurCP, (IMP *)&o_pa_initWithDurCP);
        SIO_swizzleInstance(pa, @selector(initWithDuration:springDampingRatio:animations:),
                            (IMP)sio_PA_initWithDurSpring, (IMP *)&o_pa_initWithDurSpring);
        // v1.8.12 真 bug 修复：必须传类对象 pa，不能传 object_getClass(pa)（元类）。
        // class_getClassMethod 内部会执行 class_getInstanceMethod(object_getClass(cls), sel)，
        // 传元类等于去根元类查找，必然 NULL —— 原来这一行是静默失效的死代码。
        SIO_swizzleClass(pa, @selector(runningPropertyAnimatorWithDuration:delay:options:animations:completion:),
                         (IMP)sio_PA_runningPA, (IMP *)&o_pa_runningPA);
        // v2.0.7：startAnimationAfterDelay: 延迟同比缩放（与 init 时长缩放配套）
        SIO_swizzleInstance(pa, @selector(startAnimationAfterDelay:),
                            (IMP)sio_PA_startAfterDelay, (IMP *)&o_pa_startAfterDelay);
        // v2.1.0[新覆盖 9]：链式续播。iOS 11+ 才有，选择器不存在时静默跳过。
        SIO_swizzleInstance(pa, @selector(continueAnimationWithTimingParameters:duration:),
                            (IMP)sio_PA_continueTP, (IMP *)&o_pa_continueTP);
    }

    if (sv) {
        SIO_swizzleInstance(sv, @selector(setContentOffset:animated:),
                            (IMP)sio_SV_setContentOffset, (IMP *)&o_sv_setContentOffset);
        SIO_swizzleInstance(sv, @selector(scrollRectToVisible:animated:),
                            (IMP)sio_SV_scrollRect, (IMP *)&o_sv_scrollRect);
        // v1.8.15 新增：缩放动画（默认关闭，ZoomAccel 控制）
        // v2.2.0[启动提速]：这两个 hook 只在 ZoomAccel 打开时才有行为，而该开关
        // 默认关闭（该族在微信上出过「预览页卡死」，需显式开启）。
        // 既然默认不生效，就不占启动期的方法表交换 —— 只在开关打开时安装，
        // 热重载时由 SIO_settingsChanged 补装。
        if (gZoomAccel) {
            SIO_swizzleInstance(sv, @selector(setZoomScale:animated:),
                                (IMP)sio_SV_setZoomScale, (IMP *)&o_sv_setZoomScale);
            SIO_swizzleInstance(sv, @selector(zoomToRect:animated:),
                                (IMP)sio_SV_zoomToRect, (IMP *)&o_sv_zoomToRect);
        }
        // v1.8.16 新增：交互手感（滑行惯性 / 点击延迟），FastScroll / FastTap 控制
        SIO_swizzleInstance(sv, @selector(didMoveToWindow),
                            (IMP)sio_SV_didMoveToWindow, (IMP *)&o_sv_didMoveToWindow);
        // v2.0.1：setter 强黏（App 任何时候写回都会被拦回）
        SIO_swizzleInstance(sv, @selector(setDecelerationRate:),
                            (IMP)sio_SV_setDecelRate, (IMP *)&o_sv_setDecelRate);
        SIO_swizzleInstance(sv, @selector(setDelaysContentTouches:),
                            (IMP)sio_SV_setDelaysTouches, (IMP *)&o_sv_setDelaysTouches);
    }

    // v2.0.1：长按手势加速（v2.0.0 只有配置界面、dylib 无实现）。
    // initWithTarget:action: 继承自 UIGestureRecognizer，SIO_swizzleInstance
    // 会在本类落地新 IMP、orig 指向父类实现，不污染父类（v1.8.19 防护规则）。
    Class lpr = objc_getClass("UILongPressGestureRecognizer");
    if (lpr) {
        SIO_swizzleInstance(lpr, @selector(initWithTarget:action:),
                            (IMP)sio_LPR_init, (IMP *)&o_lpr_init);
        SIO_swizzleInstance(lpr, @selector(initWithCoder:),
                            (IMP)sio_LPR_initCoder, (IMP *)&o_lpr_initCoder);
        SIO_swizzleInstance(lpr, @selector(setMinimumPressDuration:),
                            (IMP)sio_LPR_setMinDur, (IMP *)&o_lpr_setMinDur);
    }

    // v2.5.0[性能·P0] CALayer 两族已迁到构造期安装（见 SIO_installLayerCoreHooks），
    // 此处不再重复安装 —— 延迟安装族里只保留非关键入口。
    // v2.1.0[新覆盖 10]：UIWindow setRootViewController:（换根页面的交叉淡入）
    Class windowCls = objc_getClass("UIWindow");
    if (windowCls && class_getInstanceMethod(windowCls, @selector(setRootViewController:))) {
        SIO_swizzleInstance(windowCls, @selector(setRootViewController:),
                            (IMP)sio_window_setRootVC, (IMP *)&o_window_setRootVC);
    }

    // v1.8.18：系统级增强 hook（v1.8.19 修正选择器与 ABI）
    Class refresh = objc_getClass("UIRefreshControl");
    if (refresh) {
        SIO_swizzleInstance(refresh, @selector(beginRefreshing),
                            (IMP)sio_refresh_begin, (IMP *)&o_refresh_begin);
        SIO_swizzleInstance(refresh, @selector(endRefreshing),
                            (IMP)sio_refresh_end, (IMP *)&o_refresh_end);
        // v2.0.5：下拉刷新转圈加强（添加到窗口时强制设置事务时长）
        SIO_swizzleInstance(refresh, @selector(didMoveToWindow),
                            (IMP)sio_refresh_didMove, (IMP *)&o_refresh_didMove);
    }

    // setLargeTitleDisplayMode: 是 UINavigationItem（iOS 11+）的属性，不在 UINavigationBar 上
    Class navItem = objc_getClass("UINavigationItem");
    if (navItem && class_getInstanceMethod(navItem, @selector(setLargeTitleDisplayMode:))) {
        SIO_swizzleInstance(navItem, @selector(setLargeTitleDisplayMode:),
                            (IMP)sio_navItem_setLargeTitle, (IMP *)&o_navItem_setLargeTitle);
    }

    Class pageVC = objc_getClass("UIPageViewController");
    if (pageVC) {
        SIO_swizzleInstance(pageVC, @selector(setViewControllers:direction:animated:completion:),
                            (IMP)sio_pageVC_setVC, (IMP *)&o_pageVC_setVC);
    }

    Class docInteract = objc_getClass("UIDocumentInteractionController");
    if (docInteract && class_getInstanceMethod(docInteract, @selector(presentPreviewAnimated:))) {
        SIO_swizzleInstance(docInteract, @selector(presentPreviewAnimated:),
                            (IMP)sio_docInteract_present, (IMP *)&o_docInteract_present);
        // v2.0.7：选项菜单 / 打开方式菜单（选择器存在性由 swizzle 内部静默跳过保证）
        SIO_swizzleInstance(docInteract, @selector(presentOptionsMenuFromRect:inView:animated:),
                            (IMP)sio_docInteract_optionsMenu, (IMP *)&o_docInteract_optionsMenu);
        SIO_swizzleInstance(docInteract, @selector(presentOpenInMenuFromRect:inView:animated:),
                            (IMP)sio_docInteract_openInMenu, (IMP *)&o_docInteract_openInMenu);
    }

// v2.0.7：LayoutAccel（实验，默认关）—— UIView layoutIfNeeded 在 UIView 本类
    // 自有实现，swizzle 只换本类 IMP，全部子类继承，覆盖 nib/代码/SwiftUI 宿主视图。
    // v2.2.0[启动提速]：LayoutAccel 默认关闭（实验性，嵌套事务会改写布局动画时序，
    // 必须用户显式开启）。-layoutIfNeeded 是 UIView 的**热点方法**，
    // 任何一次布局都会调到 —— 常态下替换它只增加一次间接调用，收益为零、代价非零。
    // 因此改为仅在开关打开时安装。
    if (gLayoutAccel && uv && class_getInstanceMethod(uv, @selector(layoutIfNeeded))) {
        SIO_swizzleInstance(uv, @selector(layoutIfNeeded),
                            (IMP)sio_view_layoutIfNeeded, (IMP *)&o_view_layoutIfNeeded);
    }


    // ==================== v2.0.4：加载图标 / SwiftUI / 隐式动画盲区 ====================
    // 问题：瞬切模式下微信/系统 App 的加载图标（转圈）仍然慢。
    // 根因：这些动画走 SwiftUI 或 CALayer 隐式动画路径，不经过我们已 hook 的显式 API。
    //
    // [盲区 1] CATransaction 默认动画时长：CALayer 属性改变（如 transform.rotation.z）
    // 时如果没有显式动画，系统会创建默认 CABasicAnimation，时长由 CATransaction
    // 的 animationDuration 决定。虽然已 hook setAnimationDuration:，但 getter
    // 也需要 hook——否则 SwiftUI/系统内部读取默认时长时会拿到未缩放的原值。
    Class catx_cls = objc_getClass("CATransaction");
    if (catx_cls && class_getClassMethod(catx_cls, @selector(animationDuration))) {
        SIO_swizzleClass(catx_cls, @selector(animationDuration),
                         (IMP)sio_CATransaction_getDur, (IMP *)&o_CATransaction_getDur);
    }
    // [盲区 2] UIActivityIndicatorView startAnimating：v2.0.1 只处理了动画时长，
    // 但 startAnimating 会重置动画，确保启动时也应用缩放。
    Class indicator = objc_getClass("UIActivityIndicatorView");
    if (indicator) {
        SIO_swizzleInstance(indicator, @selector(startAnimating),
                            (IMP)sio_indicator_start, (IMP *)&o_indicator_start);
    }
    // [盲区 3] SwiftUI 动画桥接：SwiftUI 的 Animation 是 struct，不能直接 hook。
    // 但 SwiftUI 最终会通过 UIView/CALayer 的隐式动画执行，上面的 CATransaction
    // getter hook 会覆盖这条路径。
    // =========================================================================

    // ==================== v2.0.6：控件 / 栏 / 单元格 全路径覆盖 ====================
    // 门控规则与本体一致：通用控件与单元格仅受全局开关+黑名单；导航/工具/标签栏
    // 受 gExtra；CV 结构性动画（batchUpdates/setLayout）受 ListAccel。
    // SIO_swizzleInstance 在方法不存在时静默跳过，此处无需逐一判 selector。
    Class uiswitch = objc_getClass("UISwitch");
    if (uiswitch) SIO_swizzleInstance(uiswitch, @selector(setOn:animated:),
                                      (IMP)sio_switch_setOn, (IMP *)&o_switch_setOn);
    Class uislider = objc_getClass("UISlider");
    if (uislider) SIO_swizzleInstance(uislider, @selector(setValue:animated:),
                                      (IMP)sio_slider_setValue, (IMP *)&o_slider_setValue);
    Class uiprogress = objc_getClass("UIProgressView");
    if (uiprogress) SIO_swizzleInstance(uiprogress, @selector(setProgress:animated:),
                                        (IMP)sio_progress_setProgress, (IMP *)&o_progress_setProgress);
    Class uipicker = objc_getClass("UIPickerView");
    if (uipicker) SIO_swizzleInstance(uipicker, @selector(selectRow:inComponent:animated:),
                                      (IMP)sio_picker_selectRow, (IMP *)&o_picker_selectRow);
    Class uidatepicker = objc_getClass("UIDatePicker");
    if (uidatepicker) SIO_swizzleInstance(uidatepicker, @selector(setDate:animated:),
                                          (IMP)sio_datePicker_setDate, (IMP *)&o_datePicker_setDate);
    Class uisegmented = objc_getClass("UISegmentedControl");
    if (uisegmented) SIO_swizzleInstance(uisegmented, @selector(setSelectedSegmentIndex:),
                                         (IMP)sio_segmented_setIndex, (IMP *)&o_segmented_setIndex);
    Class uipagecontrol = objc_getClass("UIPageControl");
    if (uipagecontrol) SIO_swizzleInstance(uipagecontrol, @selector(setCurrentPage:),
                                           (IMP)sio_pageControl_setPage, (IMP *)&o_pageControl_setPage);
    Class uieffect = objc_getClass("UIVisualEffectView");
    if (uieffect) SIO_swizzleInstance(uieffect, @selector(setEffect:),
                                      (IMP)sio_effectView_setEffect, (IMP *)&o_effectView_setEffect);
    Class uicontrol = objc_getClass("UIControl");
    if (uicontrol) {
        SIO_swizzleInstance(uicontrol, @selector(setHighlighted:),
                            (IMP)sio_control_setHighlighted, (IMP *)&o_control_setHighlighted);
        SIO_swizzleInstance(uicontrol, @selector(setSelected:),
                            (IMP)sio_control_setSelected, (IMP *)&o_control_setSelected);
    }

    Class navbar = objc_getClass("UINavigationBar");
    if (navbar) {
        SIO_swizzleInstance(navbar, @selector(pushNavigationItem:animated:),
                            (IMP)sio_navBar_pushItem, (IMP *)&o_navBar_pushItem);
        SIO_swizzleInstance(navbar, @selector(popNavigationItemAnimated:),
                            (IMP)sio_navBar_popItem, (IMP *)&o_navBar_popItem);
        SIO_swizzleInstance(navbar, @selector(setItems:animated:),
                            (IMP)sio_navBar_setItems, (IMP *)&o_navBar_setItems);
    }
    Class toolbar = objc_getClass("UIToolbar");
    if (toolbar) SIO_swizzleInstance(toolbar, @selector(setItems:animated:),
                                     (IMP)sio_toolbar_setItems, (IMP *)&o_toolbar_setItems);
    Class tabbar = objc_getClass("UITabBar");
    if (tabbar) SIO_swizzleInstance(tabbar, @selector(setSelectedItem:),
                                    (IMP)sio_tabBar_setItem, (IMP *)&o_tabBar_setItem);
    Class nav2 = objc_getClass("UINavigationController");
    if (nav2) {
        SIO_swizzleInstance(nav2, @selector(setNavigationBarHidden:animated:),
                            (IMP)sio_nav_setBarHidden, (IMP *)&o_nav_setBarHidden);
        SIO_swizzleInstance(nav2, @selector(setToolbarHidden:animated:),
                            (IMP)sio_nav_setToolbarHidden, (IMP *)&o_nav_setToolbarHidden);
    }

    Class tvcell = objc_getClass("UITableViewCell");
    if (tvcell) {
        SIO_swizzleInstance(tvcell, @selector(setSelected:animated:),
                            (IMP)sio_tvCell_setSelected, (IMP *)&o_tvCell_setSelected);
        SIO_swizzleInstance(tvcell, @selector(setHighlighted:animated:),
                            (IMP)sio_tvCell_setHighlighted, (IMP *)&o_tvCell_setHighlighted);
    }
    Class cvcell = objc_getClass("UICollectionViewCell");
    if (cvcell) {
        SIO_swizzleInstance(cvcell, @selector(setSelected:),
                            (IMP)sio_cvCell_setSelected, (IMP *)&o_cvCell_setSelected);
        SIO_swizzleInstance(cvcell, @selector(setHighlighted:),
                            (IMP)sio_cvCell_setHighlighted, (IMP *)&o_cvCell_setHighlighted);
    }
    Class cv2 = objc_getClass("UICollectionView");
    if (cv2) {
        // v2.2.0[启动提速 + 门控一致性]：
        // 这三个 CV 入口全部受 SIO_listOK() 门控（即只在 gListAccel 打开时才有行为），
        // 但原先在这里**无条件安装** —— 与构造函数里被搬走的 24 个 TV/CV hook 是同一族，
        // 却一个延迟一个同步，口径不一致；而且默认配置（ListAccel=NO）下它们同样是
        // 纯粹的启动开销。现在统一交给 SIO_installListHooksNow 按需安装。
        // 注意 performBatchUpdates: 只在 SIO_installListHooksNow 里装一次，
        // 此处不再重复（否则会二次交换，把自己的 IMP 存成 orig 导致自递归）。
    }
    // =========================================================================

    // ==================== v2.4.0：转场/控件/隐式动画盲区补齐 ====================
    // 导航回根、Tab 控制器替换、TabBar 项替换、VC 编辑模式、搜索栏激活、
    // 弹出气泡尺寸、PageVC 书脊 —— 全部走 CATransaction 时长包裹（gExtra 门控）
    Class nav3 = objc_getClass("UINavigationController");
    if (nav3) SIO_swizzleInstance(nav3, @selector(popToRootViewControllerAnimated:),
                                  (IMP)sio_nav_popToRoot, (IMP *)&o_nav_popToRoot);
    Class tabBC = objc_getClass("UITabBarController");
    if (tabBC) SIO_swizzleInstance(tabBC, @selector(setViewControllers:animated:),
                                   (IMP)sio_tabBC_setViewControllers, (IMP *)&o_tabBC_setViewControllers);
    Class tabBar2 = objc_getClass("UITabBar");
    if (tabBar2) SIO_swizzleInstance(tabBar2, @selector(setItems:animated:),
                                     (IMP)sio_tabBar_setItems, (IMP *)&o_tabBar_setItems);
    Class vc2 = objc_getClass("UIViewController");
    if (vc2) SIO_swizzleInstance(vc2, @selector(setEditing:animated:),
                                 (IMP)sio_vc_setEditing, (IMP *)&o_vc_setEditing);
    Class searchCtrl = objc_getClass("UISearchController");
    if (searchCtrl) SIO_swizzleInstance(searchCtrl, @selector(setActive:animated:),
                                        (IMP)sio_searchCtrl_setActive, (IMP *)&o_searchCtrl_setActive);
    Class popover = objc_getClass("UIPopoverPresentationController");
    if (popover) SIO_swizzleInstance(popover, @selector(setPopoverContentSize:animated:),
                                     (IMP)sio_popover_setContentSize, (IMP *)&o_popover_setContentSize);
    Class pageVC2 = objc_getClass("UIPageViewController");
    if (pageVC2) SIO_swizzleInstance(pageVC2, @selector(setSpineLocation:animated:),
                                     (IMP)sio_pageVC_setSpine, (IMP *)&o_pageVC_setSpine);

    // UINavigationItem 按钮切换（5 个入口，gExtra 门控）
    Class navItem2 = objc_getClass("UINavigationItem");
    if (navItem2) {
        SIO_swizzleInstance(navItem2, @selector(setHidesBackButton:animated:),
                            (IMP)sio_navItem_setHidesBack, (IMP *)&o_navItem_setHidesBack);
        SIO_swizzleInstance(navItem2, @selector(setLeftBarButtonItem:animated:),
                            (IMP)sio_navItem_setLeftBtn, (IMP *)&o_navItem_setLeftBtn);
        SIO_swizzleInstance(navItem2, @selector(setRightBarButtonItem:animated:),
                            (IMP)sio_navItem_setRightBtn, (IMP *)&o_navItem_setRightBtn);
        SIO_swizzleInstance(navItem2, @selector(setLeftBarButtonItems:animated:),
                            (IMP)sio_navItem_setLeftBtns, (IMP *)&o_navItem_setLeftBtns);
        SIO_swizzleInstance(navItem2, @selector(setRightBarButtonItems:animated:),
                            (IMP)sio_navItem_setRightBtns, (IMP *)&o_navItem_setRightBtns);
    }

    // 控件类：UISearchBar 取消按钮、UIStepper 加减（SIO_listWrap，仅全局开关门控）
    Class searchBar = objc_getClass("UISearchBar");
    if (searchBar) SIO_swizzleInstance(searchBar, @selector(setShowsCancelButton:animated:),
                                       (IMP)sio_searchBar_setShowsCancel, (IMP *)&o_searchBar_setShowsCancel);
    Class stepper = objc_getClass("UIStepper");
    if (stepper) SIO_swizzleInstance(stepper, @selector(setValue:animated:),
                                     (IMP)sio_stepper_setValue, (IMP *)&o_stepper_setValue);

    // CALayer actionForKey: —— 隐式动画统一兜底（与 CATransaction getter 互补，不双重缩放）
    if (layer) SIO_swizzleInstance(layer, @selector(actionForKey:),
                                   (IMP)sio_layer_actionForKey, (IMP *)&o_layer_actionForKey);
    // =========================================================================
}

#pragma mark - FUBackground v2.0.0 Max 整合（真后台保活）

static NSString *const kFBGLocalOff = @"fubg_local_off";

// ---- 全局状态 ----
static BOOL    gFUBGEnabled    = YES;
static BOOL    gSceneFake  = YES;
static BOOL    gAudioKeep  = YES;
static BOOL    gShowBall   = YES;
static NSArray *gExclude   = nil;
static BOOL    gLocalOff   = NO;

static BOOL    gActive    = NO;   // 本 App 最终是否参与保活（总开关∧名单∧本地开关）
static BOOL    gUseScene  = NO;   // 本 App 是否启用场景伪装
static BOOL    gUseAudio  = NO;   // 本 App 是否启用音频断言
static BOOL    gPhysBg    = NO;   // 物理上是否处于后台（由真实生命周期通知维护）
static BOOL    gHasAudioMode = NO;

// ---- v2.0.7：AVFoundation 惰性加载（启动提速）----
// 此前 dylib 链接期依赖 AVFoundation —— dyld 会在**每个**被注入 App 的冷启动
// 路径上加载整套框架（连带 CoreMedia/CoreAudio 一串依赖），即使该 App 从不
// 进后台保活。改为首次真正需要音频断言时才 dlopen，类与字符串常量全部
// 运行时解析；用到的枚举值是 iOS 6/10 起冻结的 ABI 常量，直接内联：
//   AVAudioSessionCategoryOptionMixWithOthers               = 1
//   AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation = 1
//   AVAudioSessionInterruptionTypeEnded                     = 0
//   AVAudioSessionInterruptionOptionShouldResume            = 1
@protocol SIOAVPlayer <NSObject>
- (instancetype)initWithData:(NSData *)data error:(NSError **)outError;
- (BOOL)prepareToPlay;
- (BOOL)play;
- (void)pause;
- (BOOL)isPlaying;
- (void)setNumberOfLoops:(NSInteger)n;
- (void)setVolume:(float)v;
@end

@protocol SIOAVSession <NSObject>
- (BOOL)setCategory:(NSString *)category withOptions:(NSUInteger)options error:(NSError **)outError;
- (BOOL)setActive:(BOOL)active error:(NSError **)outError;
- (BOOL)setActive:(BOOL)active withOptions:(NSUInteger)options error:(NSError **)outError;
@end

static id<SIOAVPlayer> gPlayer = nil;
static UIBackgroundTaskIdentifier gTask = 0;   // 0 = 无桥接任务（UIBackgroundTaskInvalid 非文件级编译期常量）
static NSTimer *gWatchdog = nil;

#pragma mark - 配置

static BOOL _fbg_isExcluded(void) {
    // v1.8.16：内置排除（SpringBoard 等）优先级最高，配置无法打开
    if (SIO_fbgBuiltinExcluded()) return YES;
    // v2.1.0 真 bug 3：改用统一匹配器。原实现用 hasPrefix:，
    // 配置 App 默认写入的 com.tencent.wework 会连带排除 com.tencent.weworkhelper 等
    // 所有同前缀 App —— 用户只想排除企业微信，实际排除了一串无关 App。
    for (NSString *b in gExclude) {
        if (SIO_bundleMatches(b)) return YES;
    }
    return NO;
}

static void _fbg_recalc(void) {
    gActive   = gFUBGEnabled && !gLocalOff && !_fbg_isExcluded();
    gUseScene = gActive && gSceneFake;
    gUseAudio = gActive && gAudioKeep;
}

static void _fbg_loadPref(void) {
    @try {
        // v2.5.0[顺序兜底]：本函数复用动画侧 SIO_reload() 的黑名单解析结果，
        // 但两个 constructor 的先后由 dyld 决定。若保活侧先跑，
        // gBlacklistItems 还是 nil —— 排除表会静默变空（黑名单对保活失效）。
        // 这里补一次：没跑过就自己跑一遍（SIO_reload 幂等，plist 走缓存不会重复读盘）。
        if (!gReloadDone) SIO_reload();
        // v2.2.0[启动提速]：复用构造函数已读好的缓存，不再第二次解析同一文件。
        NSDictionary *d = SIO_prefSnapshot();
        if (d) {
            if (d[@"FUBGEnabled"])      gFUBGEnabled   = [d[@"FUBGEnabled"] boolValue];
            if (d[@"FUBGSceneFake"])    gSceneFake = [d[@"FUBGSceneFake"] boolValue];
            if (d[@"FUBGAudioKeep"])    gAudioKeep = [d[@"FUBGAudioKeep"] boolValue];
            if (d[@"FUBGFloatingBall"]) gShowBall  = [d[@"FUBGFloatingBall"] boolValue];
            // v1.8.12 隐患修复：FUBGExcludeApps 与 Blacklist 取并集。
            // 原实现先赋 FUBGExcludeApps、紧接着被 Blacklist 无条件覆盖——只要配置里
            // 存在 Blacklist（配置 App 默认就会写入 com.tencent.wework），排除表永久失效。
            //
            // v2.5.0[性能·P0] 黑名单部分直接复用 SIO_reload 已经清洗好的
            // gBlacklistItems —— 那段 trim + NSCharacterSet 循环不再跑第二遍。
            // 仍需清洗的只剩 FUBGExcludeApps 这一路（它只在这里被读）。
            NSMutableArray *clean = [NSMutableArray array];
            id exRaw = d[@"FUBGExcludeApps"];
            NSArray *rawEx = [exRaw isKindOfClass:[NSArray class]] ? exRaw : nil;
            if (rawEx.count) {
                NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
                for (id it in rawEx) {
                    if (![it isKindOfClass:[NSString class]]) continue;
                    NSString *s = [(NSString *)it stringByTrimmingCharactersInSet:ws];
                    if (s.length) [clean addObject:s];
                }
            }
            // 复用 SIOriginal 黑名单（v1.8.6：兼容字符串格式，原来只认 NSArray 导致黑名单对 FUBG 永远无效）
            if (gBlacklistItems.count) [clean addObjectsFromArray:gBlacklistItems];
            gExclude = clean;
            // v1.8.14：保活相关的 App 级覆盖（与动画侧共用同一份 AppOverrides）
            NSDictionary *ovr = SIO_appOverride(d);
            if (ovr) {
                if (ovr[@"FUBGEnabled"])   gFUBGEnabled = [ovr[@"FUBGEnabled"] boolValue];
                if (ovr[@"FUBGSceneFake"]) gSceneFake   = [ovr[@"FUBGSceneFake"] boolValue];
                if (ovr[@"FUBGAudioKeep"]) gAudioKeep   = [ovr[@"FUBGAudioKeep"] boolValue];
            }
        }
    } @catch (__unused NSException *e) {}
    if (!gExclude) gExclude = @[];
    gLocalOff = NO;

    NSArray *modes = [[NSBundle mainBundle] infoDictionary][@"UIBackgroundModes"];
    gHasAudioMode = [modes isKindOfClass:[NSArray class]] && [modes containsObject:@"audio"];

    _fbg_recalc();
}

#pragma mark - 引擎一：场景伪装
// 移植/修改自 ImmortalizerJailed main.m（GPLv3, Serge Alagon），致谢 @khanhduytran0

static void (*gOrigSceneUpdate)(id, SEL, id, id, id, id);

// 由后台化 diff 的描述特征判断这是否是一条"让 App 退到后台"的场景更新
static BOOL _fbg_isBackgroundingDiff(NSString *desc) {
    if (!desc) return NO;
    // =========================================================================
    // v2.5.0[性能·P1] [arg2 description] 本身才是这里最大的开销，
    // 而它是在**调用方**无条件生成的 —— 场景更新期间每次都产出一段
    // 可能长达数 KB 的描述字符串，随后做 7 次全串 containsString: 扫描。
    // 本函数无法省掉上游的 description，但可以把下游扫描从「7 次独立全串扫描」
    // 降到「1 次定位 + 局部比较」：
    //   · 4 条 foreground 判据都以 "foreground = " 开头 —— 先做一次
    //     rangeOfString 定位，再只比较紧随其后的几个字符；
    //   · 3 条快照判据 + 1 条 FBSceneSnapshotAction 仍走 containsString，
    //     但排在后面，绝大多数前台更新在第一段就返回 NO。
    // 效果：常见（非后台化）场景更新从 7 次 O(n) 降到 1 次 O(n)。
    // 语义严格不变 —— 匹配的是同一批子串。
    // =========================================================================
    NSRange fg = [desc rangeOfString:@"foreground = "];
    if (fg.location != NSNotFound) {
        NSUInteger start = fg.location + fg.length;
        NSUInteger len = desc.length;
        if (start < len) {
            // 逐一比较 4 种写法：NotSet / No / BSSettingFlagNo / NO
            if ([desc compare:@"NotSet" options:0
                        range:NSMakeRange(start, MIN(6, len - start))] == NSOrderedSame) return YES;
            if ([desc compare:@"No" options:0
                        range:NSMakeRange(start, MIN(2, len - start))] == NSOrderedSame) return YES;
            if ([desc compare:@"BSSettingFlagNo" options:0
                        range:NSMakeRange(start, MIN(15, len - start))] == NSOrderedSame) return YES;
            if ([desc compare:@"NO" options:0
                        range:NSMakeRange(start, MIN(2, len - start))] == NSOrderedSame) return YES;
        }
    }
    // 后台切换器快照相关更新同样吞掉，避免快照暴露/状态推进
    if ([desc containsString:@"hostContextIdentifierForSnapshotting = 0"] ||
        [desc containsString:@"scenePresenterRenderIdentifierForSnapshotting = 0"] ||
        [desc containsString:@"targetOfEventDeferringEnvironments = (empty)"] ||
        [desc containsString:@"FBSceneSnapshotAction:"]) {
        return YES;
    }
    return NO;
}

static void _fbg_sceneUpdate(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    if (!gOrigSceneUpdate) return;
    if (gUseScene) {
        @try {
            if (_fbg_isBackgroundingDiff([arg2 description])) {
                NSLog(@"[FUBG] swallowed backgrounding scene diff");
                return;
            }
        } @catch (__unused NSException *e) {}
    }
    gOrigSceneUpdate(self, _cmd, arg1, arg2, arg3, arg4);
}

// ---- applicationState 伪装 ----
static UIApplicationState (*gOrigAppState)(id, SEL);

static UIApplicationState _fbg_appState(id self, SEL _cmd) {
    if (gUseScene && gPhysBg) {
        // 推送/通知框架需要真实答案：前台态时它们不会建立后台接收通道
        void *ret = __builtin_extract_return_addr(__builtin_return_address(0));
        // v2.0.7：dladdr 需遍历已加载镜像表，而后台期 applicationState 是高频
        // 查询（音频会话 / 定时器 / 推送框架轮询）。调用点地址是稳定的，
        // 用 8 槽直映缓存记住「该调用点是否来自推送/通知框架」；
        // 多线程并发写同一槽最坏只是重算一次，结果幂等，无需加锁。
        static void *cacheAddr[8] = {0};
        static BOOL  cacheIsPush[8] = {0};
        // v2.5.0[性能·P1] 一个实质改动 + 一个次要改动：
        // ① 【实质】去掉 NSString 分配：原实现把镜像路径转成 NSString 再做两次
        //    containsString:（一次堆分配 + 两次 O(n) 扫描）。
        //    dli_fname 本来就是 C 字符串，直接用 strstr 判定，零分配。
        //    这是本处唯一确定有收益的改动 —— 后台期 applicationState 是高频查询，
        //    每次省一次 malloc + 一次 free。
        // ② 【次要】槽位哈希加入高位混合（(p>>4)&7 → 高位异或混合）。
        //    与 SIO_delegateIsSpinnerCandidate 里的同项改动一样，
        //    经 bench_v250.py 的 B2 基准验证：**在真实量级的调用点数下无显著差异**。
        //    保留仅为稳健，不计入收益。
        uintptr_t ka = (uintptr_t)ret;
        uintptr_t slot = ((ka >> 4) ^ (ka >> 20) ^ (ka >> 36)) & 7;
        BOOL isPush;
        if (__builtin_expect(cacheAddr[slot] == ret, 1)) {
            isPush = cacheIsPush[slot];
        } else {
            isPush = NO;
            Dl_info info;
            if (dladdr(ret, &info) && info.dli_fname) {
                if (strstr(info.dli_fname, "UserNotifications") ||
                    strstr(info.dli_fname, "PushKit")) {
                    isPush = YES;
                }
            }
            cacheAddr[slot] = ret;
            cacheIsPush[slot] = isPush;
        }
        if (isPush) return UIApplicationStateBackground;
        return UIApplicationStateActive;
    }
    return gOrigAppState ? gOrigAppState(self, _cmd) : UIApplicationStateActive;
}

// ---- 通知横幅伪装 ----
// v2.0.7：UserNotifications 改为惰性解析（objc_getClass），类型一律用 id。
// 展示选项常量为 iOS 10 起冻结的 ABI 值：Badge=1 Sound=2 Alert=4 Banner=16(iOS14+)。
// 部署目标 iOS 14+，直接用 Banner；| Sound | Badge = 16|2|1 = 19。
#define SIO_UN_PRESENT_BANNER_SOUND_BADGE ((NSUInteger)19)

static void (*gOrigWillPresent)(id, SEL, id, id, void (^)(NSUInteger));

static void _fbg_willPresent(id self, SEL _cmd, id center,
                             id note,
                             void (^handler)(NSUInteger)) {
    if (gUseScene && gPhysBg) {
        handler(SIO_UN_PRESENT_BANNER_SOUND_BADGE);
    } else if (gOrigWillPresent) {
        gOrigWillPresent(self, _cmd, center, note, handler);
    }
}

static void (*gOrigUNSetDelegate)(id, SEL, id);

static void _fbg_unSetDelegate(id self, SEL _cmd, id delegate) {
    if (gOrigUNSetDelegate) gOrigUNSetDelegate(self, _cmd, delegate);
    if (delegate) {
        Class dc = [delegate class];
        SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        Method m = class_getInstanceMethod(dc, sel);
        if (m) {
            IMP cur = method_getImplementation(m);
            if (cur != (IMP)_fbg_willPresent) {
                gOrigWillPresent = (void *)cur;
                method_setImplementation(m, (IMP)_fbg_willPresent);
            }
        }
    }
}

static void _fbg_installSceneHooks(void) {
    Class wsClass = objc_getClass("FBSWorkspaceScenesClient");
    Method sceneM = wsClass ? class_getInstanceMethod(
        wsClass, @selector(sceneID:updateWithSettingsDiff:transitionContext:completion:)) : NULL;
    if (sceneM) {
        gOrigSceneUpdate = (void (*)(id, SEL, id, id, id, id))method_getImplementation(sceneM);
        method_setImplementation(sceneM, (IMP)_fbg_sceneUpdate);
        NSLog(@"[FUBG] scene hook installed");
    } else {
        NSLog(@"[FUBG] FBSWorkspaceScenesClient method not found, scene engine disabled");
    }

    Method stateM = class_getInstanceMethod([UIApplication class], @selector(applicationState));
    if (stateM) {
        gOrigAppState = (UIApplicationState (*)(id, SEL))method_getImplementation(stateM);
        method_setImplementation(stateM, (IMP)_fbg_appState);
    }

    // v2.0.7：objc_getClass 惰性获取 —— 宿主 App 不用通知框架时该类不存在，
    // 横幅伪装本就无事可做，直接跳过（同时不再把框架拖进启动路径）。
    Class unClass = objc_getClass("UNUserNotificationCenter");
    if (unClass) {
        Method delM = class_getInstanceMethod(unClass, @selector(setDelegate:));
        if (delM) {
            gOrigUNSetDelegate = (void (*)(id, SEL, id))method_getImplementation(delM);
            method_setImplementation(delM, (IMP)_fbg_unSetDelegate);
        }
    }
}

#pragma mark - 引擎二：音频断言

// v2.0.7：惰性解析 AVFoundation。首次进入后台真正需要音频断言时才 dlopen，
// 成功同时注册打断/路由变更两个通知（字符串常量此前不存在，不能提前注册 ——
// 用 nil 名注册会订阅到全部通知）。宿主 App 自己已链接 AVFoundation 时
// dlopen 只是引用计数 +1，零额外加载。
static Class gAVPlayerCls  = Nil;
static Class gAVSessionCls = Nil;
static NSString *gAVCatPlayback  = nil;
static NSString *gAVNoteInt      = nil;
static NSString *gAVNoteRoute    = nil;
static NSString *gAVKeyIntType   = nil;
static NSString *gAVKeyIntOption = nil;

static void _fbg_onInterruption(NSNotification *note); // 前向声明（惰性注册用）

static BOOL _fbg_avEnsure(void) {
    if (gAVSessionCls && gAVPlayerCls) return YES;
    static dispatch_once_t once;
    __block BOOL ok = NO;
    dispatch_once(&once, ^{
        @try {
            void *h = dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation",
                             RTLD_LAZY | RTLD_LOCAL);
            if (!h) { NSLog(@"[FUBG] dlopen AVFoundation failed: %s", dlerror()); return; }
            Class p = objc_getClass("AVAudioPlayer");
            Class s = objc_getClass("AVAudioSession");
            // 字符串常量从框架句柄解析（RTLD_LOCAL 下不能依赖 RTLD_DEFAULT 全局域）
            // ARC 要求指向 ObjC 对象的指针显式声明所有权，故加 __strong
            NSString *__strong *cat = (NSString *__strong *)dlsym(h, "AVAudioSessionCategoryPlayback");
            NSString *__strong *ni  = (NSString *__strong *)dlsym(h, "AVAudioSessionInterruptionNotification");
            NSString *__strong *nr  = (NSString *__strong *)dlsym(h, "AVAudioSessionRouteChangeNotification");
            NSString *__strong *kt  = (NSString *__strong *)dlsym(h, "AVAudioSessionInterruptionTypeKey");
            NSString *__strong *ko  = (NSString *__strong *)dlsym(h, "AVAudioSessionInterruptionOptionKey");
            if (!p || !s || !cat || !*cat || !ni || !*ni || !nr || !*nr ||
                !kt || !*kt || !ko || !*ko) {
                NSLog(@"[FUBG] AVFoundation symbols incomplete, audio engine disabled");
                return;
            }
            gAVPlayerCls = p; gAVSessionCls = s;
            gAVCatPlayback = *cat; gAVNoteInt = *ni; gAVNoteRoute = *nr;
            gAVKeyIntType = *kt; gAVKeyIntOption = *ko;
            // 打断/路由变更通知此时才注册（此前常量不存在）
            [[NSNotificationCenter defaultCenter] addObserverForName:gAVNoteInt
                object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n){ _fbg_onInterruption(n); }];
            [[NSNotificationCenter defaultCenter] addObserverForName:gAVNoteRoute
                object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *n){
                    if (gUseAudio && gPhysBg) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            if (gPlayer && ![gPlayer isPlaying]) [gPlayer play];
                        });
                    }
                }];
            ok = YES;
            NSLog(@"[FUBG] AVFoundation lazily loaded (audio engine ready)");
        } @catch (__unused NSException *e) {}
    });
    return ok;
}

static id<SIOAVSession> _fbg_session(void) {
    // +sharedInstance 是类方法，经 objc_msgSend 显式签名调用（无参、返回 id），
    // 不依赖编译器对「id<协议> 上调类方法」的可见性推断。
    return ((id<SIOAVSession> (*)(Class, SEL))objc_msgSend)(gAVSessionCls,
                                                            @selector(sharedInstance));
}

static BOOL _fbg_activateSession(void) {
    if (!_fbg_avEnsure()) return NO;
    NSError *e = nil;
    id<SIOAVSession> s = _fbg_session();
    if (![s setCategory:gAVCatPlayback withOptions:1 /* MixWithOthers */ error:&e] || e) {
        NSLog(@"[FUBG] setCategory failed: %@", e); return NO;
    }
    e = nil;
    if (![s setActive:YES error:&e] || e) {
        NSLog(@"[FUBG] setActive failed: %@", e); return NO;
    }
    return YES;
}

static void _fbg_buildAndPlay(void) {
    @try {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:kFBGNoiseB64
                                                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
        id<SIOAVPlayer> p = [[gAVPlayerCls alloc] initWithData:data error:nil];
        if (!p) return;
        [p setNumberOfLoops:-1];
        [p setVolume:0.0f];
        [p prepareToPlay];
        [p play];
        gPlayer = p;
    } @catch (__unused NSException *e) {}
}

static void _fbg_startAudio(void) {
    if (!gUseAudio) return;
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (gTask == 0) {
            gTask = [app beginBackgroundTaskWithName:@"fubg-bridge" expirationHandler:^{
                NSLog(@"[FUBG] bridge task expired");
                if (gTask != 0) { [app endBackgroundTask:gTask]; gTask = 0; }
            }];
        }
        if (_fbg_activateSession() && (!gPlayer || ![gPlayer isPlaying])) {
            if (gPlayer) { [gPlayer play]; }
            else { _fbg_buildAndPlay(); }
        }
        NSLog(@"[FUBG] audio keep-alive started (audioMode=%d)", gHasAudioMode);
    } @catch (__unused NSException *e) {}
}

static void _fbg_stopAudio(BOOL releaseSession) {
    @try {
        if ([gPlayer isPlaying]) [gPlayer pause];
        // 经验（Immortalizer 作者）：mix 模式下保持 session 激活、不主动 setActive:NO，
        // 可避免与目标 App 自身音频会话打架造成的卡顿；仅彻底关闭时通知他人恢复。
        if (releaseSession && gAVSessionCls) {
            [_fbg_session() setActive:NO withOptions:1 /* NotifyOthersOnDeactivation */ error:nil];
        }
        UIApplication *app = [UIApplication sharedApplication];
        if (gTask != 0) { [app endBackgroundTask:gTask]; gTask = 0; }
    } @catch (__unused NSException *e) {}
}

// ---- v2.5.0[性能·P2] watchdog 随前后台生命周期启停 ----
// 只在「真的进了后台 + 真的用音频断言」时存在。定时器重复启停是幂等的
// （invalidate 后重建），且 NSTimer 强持有 target block，invalidate 后即释放，
// 不存在泄漏；重复调用 start 也只会先停旧的再建新的。
static void _fbg_stopWatchdog(void) {
    if (gWatchdog) {
        [gWatchdog invalidate];
        gWatchdog = nil;
    }
}

static void _fbg_watchdogFire(NSTimer *t);  // 前向声明：下方 timer block 先于定义引用

static void _fbg_startWatchdog(void) {
    if (!gUseAudio) return;          // 不用音频断言 → 定时器永远无事可做
    if (gWatchdog) return;           // 已在跑
    gWatchdog = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES
                                                  block:^(NSTimer *t){ _fbg_watchdogFire(t); }];
    // CommonModes：滚动/拖拽时 runloop 处于 tracking mode，
    // 不加这一行定时器会在滑动期间停摆（原实现有，保留）。
    [[NSRunLoop mainRunLoop] addTimer:gWatchdog forMode:NSRunLoopCommonModes];
}

// 自愈轮询：仅在停摆时重建，兼顾可靠与耗电
static void _fbg_watchdogFire(__unused NSTimer *t) {
    if (!gUseAudio || !gPhysBg) return;
    @try {
        if (!gPlayer || ![gPlayer isPlaying]) {
            NSLog(@"[FUBG] watchdog: player stopped, rebuilding");
            _fbg_activateSession();
            if (gPlayer) { [gPlayer play]; }
            else { _fbg_buildAndPlay(); }
        }
    } @catch (__unused NSException *e) {}
}

static void _fbg_onInterruption(NSNotification *note) {
    if (!gUseAudio || !gAVKeyIntType) return;
    NSNumber *type = note.userInfo[gAVKeyIntType];
    if (type.unsignedIntegerValue != 0 /* AVAudioSessionInterruptionTypeEnded */) return;
    NSNumber *opt = note.userInfo[gAVKeyIntOption];
    if (opt.unsignedIntegerValue & 1 /* AVAudioSessionInterruptionOptionShouldResume */) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gUseAudio && gPhysBg) {
                _fbg_activateSession();
                if (gPlayer) { [gPlayer play]; } else { _fbg_buildAndPlay(); }
            }
        });
    }
}

#pragma mark - 悬浮球

@interface FBGToastView : UIView
+ (void)showIn:(UIView *)container title:(NSString *)title subtitle:(NSString *)subtitle
      iconName:(NSString *)iconName;
@end

@implementation FBGToastView
+ (void)showIn:(UIView *)container title:(NSString *)title subtitle:(NSString *)subtitle
      iconName:(NSString *)iconName {
    FBGToastView *blur = [[self alloc] initWithFrame:CGRectMake(0, -90, container.bounds.size.width, 80)];
    blur.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    blur.layer.cornerRadius = 18;
    blur.layer.masksToBounds = YES;

    UIImageView *iv = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:iconName]];
    iv.tintColor = [UIColor whiteColor];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *t = [[UILabel alloc] init];
    t.text = title;
    t.textColor = [UIColor whiteColor];
    t.font = [UIFont boldSystemFontOfSize:15];
    UILabel *s = [[UILabel alloc] init];
    s.text = subtitle;
    s.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    s.font = [UIFont systemFontOfSize:12];
    UIStackView *txt = [[UIStackView alloc] initWithArrangedSubviews:@[t, s]];
    txt.axis = UILayoutConstraintAxisVertical;
    txt.spacing = 2;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[iv, txt]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [blur addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [iv.widthAnchor constraintEqualToConstant:28], [iv.heightAnchor constraintEqualToConstant:28],
        [row.leadingAnchor constraintEqualToAnchor:blur.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:blur.trailingAnchor constant:-16],
        [row.centerYAnchor constraintEqualToAnchor:blur.centerYAnchor],
    ]];
    [container addSubview:blur];

    [UIView animateWithDuration:0.3 animations:^{
        blur.transform = CGAffineTransformMakeTranslation(0, 110);
    } completion:^(__unused BOOL f) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                blur.alpha = 0;
                blur.transform = CGAffineTransformMakeTranslation(0, 40);
            } completion:^(__unused BOOL f2) { [blur removeFromSuperview]; }];
        });
    }];
}
@end

@interface FBGFloatingWindow : UIWindow
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, strong) UIView *handle;
@property (nonatomic, assign) BOOL docked;
@property (nonatomic, strong) NSTimer *dockTimer;
+ (instancetype)shared;
- (void)attachWhenSceneReady;
- (void)refreshState;
@end

@implementation FBGFloatingWindow

+ (instancetype)shared {
    static FBGFloatingWindow *one;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ one = [[self alloc] initWithFrame:UIScreen.mainScreen.bounds]; });
    return one;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor clearColor];
        self.rootViewController = [UIViewController new];
        self.rootViewController.view.backgroundColor = [UIColor clearColor];

        _ball = [UIButton buttonWithType:UIButtonTypeCustom];
        _ball.frame = CGRectMake(self.bounds.size.width - 70, 220, 52, 52);
        _ball.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
        _ball.layer.cornerRadius = 26;
        _ball.layer.masksToBounds = YES;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(onPan:)];
        [_ball addGestureRecognizer:pan];
        [_ball addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
        [self.rootViewController.view addSubview:_ball];
        [self snap];

        _handle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 46)];
        _handle.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.7];
        _handle.layer.cornerRadius = 6;
        _handle.hidden = YES; _handle.alpha = 0;
        UIPanGestureRecognizer *hpan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(onHandlePan:)];
        UITapGestureRecognizer *htap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(undock)];
        [_handle addGestureRecognizer:hpan];
        [_handle addGestureRecognizer:htap];
        [self.rootViewController.view addSubview:_handle];

        [self refreshState];
    }
    return self;
}

- (void)makeKeyWindow {
    [super makeKeyWindow];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *kw = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive &&
                [sc isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w.isKeyWindow) { kw = w; break; }
                }
            }
        }
        if (kw && kw != weakSelf) [kw makeKeyWindow];
    });
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!_ball.hidden) {
        CGPoint p = [self convertPoint:point toView:_ball];
        if ([_ball pointInside:p withEvent:event]) return [super hitTest:point withEvent:event];
    }
    if (!_handle.hidden) {
        CGPoint p = [self convertPoint:point toView:_handle];
        if ([_handle pointInside:p withEvent:event]) return [super hitTest:point withEvent:event];
    }
    return nil;
}

- (void)attachWhenSceneReady {
    __block int tries = 0;
    __weak typeof(self) weakSelf = self;
    __block void (^attempt)(void);
    attempt = ^{
        typeof(self) me = weakSelf;
        if (!me) { attempt = nil; return; }
        UIWindowScene *target = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) { target = (UIWindowScene *)sc; break; }
        }
        if (target) {
            me.windowScene = target;
            me.hidden = NO;
            [me makeKeyAndVisible];
            [me startDockClock];
            [me refreshState];
            attempt = nil;
        } else if (++tries < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), attempt);
        } else {
            attempt = nil;
        }
    };
    dispatch_async(dispatch_get_main_queue(), attempt);
}

- (void)refreshState {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.hidden = !gShowBall;
        if (!gShowBall) return;
        BOOL on = !gLocalOff && gFUBGEnabled;
        UIImage *icon = [UIImage systemImageNamed: on ? @"hourglass" : @"powersleep"];
        [self.ball setImage:icon forState:UIControlStateNormal];
        self.ball.tintColor = on ? [UIColor systemBlueColor] : [UIColor systemRedColor];
    });
}

- (void)snap {
    CGFloat w = self.bounds.size.width;
    CGPoint c = _ball.center;
    c.x = c.x < w / 2 ? 26 : w - 26;
    c.y = MAX(26, MIN(self.bounds.size.height - 26, c.y));
    [UIView animateWithDuration:0.25 animations:^{ _ball.center = c; }];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    [self resetDockClock];
    CGPoint tr = [g translationInView:self];
    g.view.center = CGPointMake(g.view.center.x + tr.x, g.view.center.y + tr.y);
    [g setTranslation:CGPointZero inView:self];
    if (g.state == UIGestureRecognizerStateEnded) { [self snap]; [self startDockClock]; }
}

- (void)onHandlePan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) { [self undock]; return; }
    CGPoint tr = [g translationInView:self];
    _ball.center = CGPointMake(_ball.center.x + tr.x, _ball.center.y + tr.y);
    [g setTranslation:CGPointZero inView:self];
    if (g.state == UIGestureRecognizerStateEnded) { [self snap]; [self startDockClock]; }
}

- (void)startDockClock {
    [_dockTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _dockTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:NO block:^(__unused NSTimer *t) {
        [weakSelf dock];
    }];
}
- (void)resetDockClock {
    if (_docked) return;
    [_dockTimer invalidate];
    [self startDockClock];
}

- (void)dock {
    if (_docked) return;
    _docked = YES;
    BOOL left = _ball.center.x < self.bounds.size.width / 2;
    _handle.frame = CGRectMake(left ? 0 : self.bounds.size.width - 14,
                               _ball.frame.origin.y + 3, 14, 46);
    [UIView animateWithDuration:0.25 animations:^{
        _ball.alpha = 0;
        _ball.transform = CGAffineTransformMakeScale(0.5, 0.5);
    } completion:^(__unused BOOL f) {
        _ball.hidden = YES;
        _handle.hidden = NO;
        [UIView animateWithDuration:0.2 animations:^{ _handle.alpha = 1; }];
    }];
}

- (void)undock {
    if (!_docked) return;
    _docked = NO;
    _ball.hidden = NO;
    BOOL left = _handle.frame.origin.x < self.bounds.size.width / 2;
    _ball.center = CGPointMake(left ? 26 + 7 : self.bounds.size.width - 26 - 7, _handle.center.y);
    [UIView animateWithDuration:0.25 animations:^{
        _handle.alpha = 0;
        _ball.alpha = 1;
        _ball.transform = CGAffineTransformIdentity;
    } completion:^(__unused BOOL f) {
        _handle.hidden = YES;
        [self startDockClock];
    }];
}

- (void)onTap {
    [self resetDockClock];
    BOOL newOff = !gLocalOff;
    [[NSUserDefaults standardUserDefaults] setBool:newOff forKey:kFBGLocalOff];
    gLocalOff = newOff;
    _fbg_recalc();
    notify_post([kNotifyName UTF8String]);

    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [fb impactOccurred];

    [self refreshState];
    [UIView animateWithDuration:0.1 animations:^{
        _ball.transform = CGAffineTransformMakeScale(1.2, 1.2);
    } completion:^(__unused BOOL f) {
        [UIView animateWithDuration:0.1 animations:^{
            _ball.transform = CGAffineTransformIdentity;
        }];
    }];

    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"] ?: @"App";
    [FBGToastView showIn:self.rootViewController.view
                   title:appName
                subtitle:(newOff ? @"真后台 已暂停（本 App）" : @"真后台 已开启")
                iconName:(newOff ? @"powersleep" : @"hourglass")];

    if (newOff && gPhysBg) _fbg_stopAudio(YES);
}

@end

#pragma mark - 生命周期 / Darwin

// v2.1.0[致命 1] 修复后，_fbg_onEnterBackground / _fbg_onEnterForeground 两个
// Darwin 回调函数已无调用方—— 生命周期改由上面的 NSNotificationCenter block 处理。
// 原实现存在两个独立问题：
//   ① 注册在 Darwin 中心却监听 NSNotification 名字，回调永不触发；
//   ② 即使能触发，Darwin 回调运行在注册时的线程（构造函数线程，非主线程），
//      而它们要动 UIApplication / AVAudioSession —— UIKit 主线程约束下属于违规调用。
// 保留死代码会误导后续维护者以为这条链路是活的，故明确移除。

static void _fbg_onPrefReload(CFNotificationCenterRef c, void *o, CFStringRef n,
                              const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    // v2.2.0[启动提速]：配置已变，让缓存失效。
    // 同一个 Darwin 名字同时驱动两个回调（SIO_settingsChanged 与本函数），
    // 两者都会清缓存——这是幂等的：谁先清都一样，下一个读缓存的人负责重新解析，
    // 全程仍只解析一次，不存在「两次都 miss 导致重复 IO」的情况。
    gPrefCache = nil;
    _fbg_loadPref();
    NSLog(@"[FUBG] prefs reloaded: active=%d scene=%d audio=%d ball=%d override=%d",
          gActive, gUseScene, gUseAudio, gShowBall, gHasAppOverride);
    // v1.8.10：悬浮球全局禁用，无需刷新
    if (!gUseAudio && gPhysBg) _fbg_stopAudio(NO);
    if (gUseAudio && gPhysBg && (!gPlayer || ![gPlayer isPlaying])) _fbg_startAudio();
}

#pragma mark - 入口

__attribute__((constructor))
static void FUBGEntry(void) {
    @autoreleasepool {
    // v1.8.12：与动画侧同样全程 @try 包裹，保活引擎装不上也不能拖垮目标 App。
    @try {
        // v1.8.10：全 App 通用保活（场景伪装+音频断言），悬浮球全局禁用。
        // 悬浮球是常驻全屏透明 UIWindow（alert+1 层级），会拦截触摸/抢占状态栏。
        // 场景伪装/音频断言只在后台活跃，不影响前台 UI。
        _fbg_loadPref();

        // hook 一次性安装，内部按全局开关决定行为
        // v2.5.0：与动画侧共用同一个「启动完成之后」栅栏，避免又一次
        // 在 didFinishLaunching 期间抢主线程去做 method_setImplementation。
        SIO_afterBoot(^{
            @try { _fbg_installSceneHooks(); } @catch (__unused NSException *e) {}
        });

        // v2.1.0[致命 1] 真 bug 修复：前后台生命周期回调此前注册在 **Darwin** 通知中心，
        //   但 UIApplicationDidEnterBackgroundNotification 是 **NSNotification** 名字，
        //   只经NSNotificationCenter 投递，Darwin 中心只投递 notify_post() 的名字 ——
        //   两套系统互不相通，回调从未被触发过。后果链条：
        //     gPhysBg 永远 NO → _fbg_startAudio 永不调用（音频断言保活整个不启动）
        //     → _fbg_appState 的 `gUseScene && gPhysBg` 恒假（场景伪装也不启动）
        //     → _fbg_watchdogFire 首行 `if (!gUseAudio || !gPhysBg) return` 恒 return（自愈轮询也不跑）
        //   即「场景伪装 / 音频断言兜底 / 真后台保活」三个功能从未执行过一行代码。
        //   修法：改用 NSNotificationCenter，并显式切回主线程（通知投递线程无保证，
        //   而这些处理要动UIApplication / AVAudioSession）。
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *__unused n) {
            // 已在主队列，此处直接处理
            gPhysBg = YES;
            _fbg_startAudio();
            // v2.5.0：只有此刻 watchdog 才可能做有用功 —— 进后台才起定时器
            _fbg_startWatchdog();
        }];
        [nc addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *__unused n) {
            gPhysBg = NO;
            // v2.5.0：回前台立刻停掉定时器 —— 前台期间它 100% 是空转
            _fbg_stopWatchdog();
            // 回前台只暂停播放、保留会话（mix 模式下不与 App 音频冲突）
            if ([gPlayer isPlaying]) [gPlayer pause];
            if (gTask != 0) {
                [[UIApplication sharedApplication] endBackgroundTask:gTask];
                gTask = 0;
            }
        }];

        // 设置热重载：Darwin 名字是本项目自己的 notify_post，确实走Darwin 中心，注册正确。
        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, NULL, _fbg_onPrefReload,
            (__bridge CFStringRef)kNotifyName, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // v2.0.7：音频会话打断/路由变更通知不再在此注册 —— AVFoundation 改为惰性
        // 加载后，通知名字符串常量此刻尚不存在（用 nil 名注册会订阅全部通知），
        // 统一移到 _fbg_avEnsure() 内、框架真正加载成功时注册。

        // v1.8.10：悬浮球全局禁用（常驻透明 UIWindow 会拦截触摸/抢占状态栏）
        // v2.5.0[性能·P2] watchdog 不再常驻。
        // 原实现在构造期就起了一个 1.5s 的重复定时器并挂到 CommonModes，
        // 此后**无论前台后台都一直跑**。而 _fbg_watchdogFire 首行就是
        // `if (!gUseAudio || !gPhysBg) return;` —— 也就是说前台期间
        // 每 1.5 秒一次定时器唤醒 + 一次方法调用 + 一次条件判断，
        // 100% 是无用功：它阻止不了任何事，只消耗唤醒次数与电量。
        // 改为随前后台生命周期启停（见 _fbg_startWatchdog / _fbg_stopWatchdog）：
        // 只在真正进后台、且确实用音频断言时才存在。
        // 行为完全等价 —— 因为定时器唯一能做事的条件就是 gPhysBg == YES。
        // =========================================================================

        NSLog(@"[FUBG] v2.5.0 (SIOriginal) loaded in %@: active=%d scene=%d audio=%d ball=%d audioMode=%d%@",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
              gActive, gUseScene, gUseAudio, gShowBall, gHasAudioMode,
              (gHasAudioMode || gUseScene) ? @"" : @" (WARNING: no audio mode & no scene engine)");
    } @catch (NSException *e) {
        NSLog(@"[FUBG] keep-alive install failed (app unaffected): %@", e);
    }
    SIO_markDyldCost();
    }
}



// ============================================================================
// 拆包证据（v1.8.15，Knight.app 11.5.0 / com.sfic.knight / arm64 已解密）
// ----------------------------------------------------------------------------
// 来源：IPA 内 Payload/Knight.app/Knight（180MB，cryptid=0），
//       解析 Mach-O 的 __TEXT,__objc_classname / __objc_methname 得到
//       10,947 个 ObjC 类名、148,813 个方法名、114,402 条 C 字符串。
//
// [1] UI 技术栈：原生 UIKit + 大量 .nib（数百个 *AlertView/*Cell/*View nib），
//     非 Flutter；RN 只占少量模块（hermes.framework + RNInnerBundleResource.plist）。
//     → 现有 UIView / CAAnimation / CATransaction 系 hook 在本 App 上确实生效。
//
// [2] App 在用、且我们已覆盖的动画入口（__objc_methname 命中）：
//     beginAnimations:context: / commitAnimations / setAnimationDuration: /
//     setAnimationDelay:（老式 API —— v1.8.13 才补上，对本品是净增覆盖）
//     animateKeyframesWithDuration:delay:options:animations:completion:（v1.8.12 补）
//     transitionFromViewController:toViewController:duration:options:animations:completion:（v1.8.12 补）
//     animateWithDuration: 全系 / transitionWithView:duration: /
//     setDuration: / addAnimation:forKey: / setMass: / setStiffness: / setDamping:
//     setContentOffset:animated: / scrollRectToVisible:animated: / setSelectedIndex:
//     presentViewController:animated:completion: / dismissViewControllerAnimated:completion:
//
// [3] App 在用、v1.8.15 才覆盖：setZoomScale:animated:、zoomToRect:animated:
//     （由 NXDesign.framework 引用）
//
// [4] App 未使用 → 我们这些 hook 在本品上是惰性的（无害，不必再投入）：
//     UIViewPropertyAnimator 的 addAnimations: / startAnimationAfterDelay: /
//     runningPropertyAnimatorWithDuration:、setCollectionViewLayout:animated:、
//     performSystemAnimation:onViews:、transitionFromView:toView:、
//     setCamera:animated:
//
// [5] 地图：高德 AMap 静态链入（MAMapView / MAMapKeyFrameAnimation /
//     MAAnnotationMoveAnimation / MAAnimatedAnnotation），
//     相机动画属性类型为 CAKeyframeAnimation（如 _mapCenterAnimation /
//     _cameraDegreeAnimation / _zoomAnimation）。
//     → 地图相机动画走 CAKeyframeAnimation，本文件的 CAAnimation setDuration: hook 已覆盖，
//       无需再为 MAMapView 单独加 hook；而 [1] 的双重缩放 bug 修正对它是直接收益。
//
// [6] App 自研 UI 体系（动画由内部 UIView/CAAnimation 驱动，同样已被覆盖）：
//     NAAlertController / NAAlertView / NA_PresentAnimation / NA_DimissAnimation（弹窗转场）
//     NXDesign.framework：SFSlideOverController / slideOverViewController:type:animated:、
//     nx_pushViewController:animated: / safe_pushViewController:animated:、
//     navigationController:animationControllerForOperation:...（自定义导航转场）
//     SFToast / SFMToastView / SFAnimatedImageView
//
// [7] 无法用「改时长」加速的动画引擎（做了也没用，不要承诺）：
//     SVGA（SVGAPlayer / SVGAVideoEntity，CADisplayLink 自驱）、
//     Ugen 动态 UI 引擎（UgenAnimation* 自有渲染循环）、
//     CSJRWLottie*（穿山甲广告 SDK 自带 Lottie）、RN Reanimated。
//
// [8] 风险提示：二进制含越狱/注入检测语料
//     （cydia ×15 / substrate ×17 / jailbreak ×6 / frida ×2 / inject ×18 / debugger ×3），
//     且 App 内嵌 CydiaSubstrate.framework。本 dylib 不新增任何 hook 安装时序，
//     仅按 bundle id 读配置；若设备上出现启动即崩，优先怀疑这一层，用黑名单整体停用排查。
// ============================================================================
// ===============================================================================
// v2.2.0[启动提速] 列表全家桶的延迟安装
// ===============================================================================
// 从构造函数里搬出来的 24 个 UITableView / UICollectionView hook。
//
// 为什么延迟：
//   这批 hook 只在 gListAccel == YES 时才有实际行为，而该开关默认关闭
//   （fail-safe：重列表 App 打开会破坏列表状态机，见 SIO_listHardBlocked）。
//   也就是说默认配置下，这 24 次 method_setImplementation 是纯粹的启动开销 ——
//   每一次都要查方法表、比对 IMP、交换指针，并触发 UIKit 全局方法缓存失效。
//   放在构造函数（dyld 加载期，main 之前同步执行）里等于让注入库自己拖慢启动。
//
// 为什么「按需安装」而不是「无条件延迟安装」：
//   装 hook 本身有成本（见上）。若用户没开列表加速，装了也是白装。
//   因此这里先判开关，关则完全不碰方法表 —— 连 24 次遍历都省掉。
//
// 代价与取舍：
//   列表加速在「启动最初的几十毫秒」内不生效。实测无可感知差异，因为
//   列表内容本身是异步加载/分页填充的，等 hook 装好时首批内容往往还没铺进屏幕。
//   反之，若放在构造函数里，24 次交换的代价是**每次启动都要付**。
static void SIO_installListHooksNow(void) {
    Class tv = objc_getClass("UITableView");
    Class cv = objc_getClass("UICollectionView");
    if (tv) {
        SIO_swizzleInstance(tv, @selector(selectRowAtIndexPath:animated:scrollPosition:),
                            (IMP)sio_tv_selectRow, (IMP *)&o_tv_selectRow);
        SIO_swizzleInstance(tv, @selector(deselectRowAtIndexPath:animated:),
                            (IMP)sio_tv_deselectRow, (IMP *)&o_tv_deselectRow);
        SIO_swizzleInstance(tv, @selector(scrollToRowAtIndexPath:atScrollPosition:animated:),
                            (IMP)sio_tv_scrollToRow, (IMP *)&o_tv_scrollToRow);
        SIO_swizzleInstance(tv, @selector(scrollToNearestSelectedRowAtScrollPosition:animated:),
                            (IMP)sio_tv_scrollNearest, (IMP *)&o_tv_scrollNearest);
        SIO_swizzleInstance(tv, @selector(reloadData),
                            (IMP)sio_tv_reloadData, (IMP *)&o_tv_reloadData);
        SIO_swizzleInstance(tv, @selector(reloadRowsAtIndexPaths:withRowAnimation:),
                            (IMP)sio_tv_reloadRows, (IMP *)&o_tv_reloadRows);
        SIO_swizzleInstance(tv, @selector(reloadSections:withRowAnimation:),
                            (IMP)sio_tv_reloadSections, (IMP *)&o_tv_reloadSections);
        SIO_swizzleInstance(tv, @selector(insertRowsAtIndexPaths:withRowAnimation:),
                            (IMP)sio_tv_insertRows, (IMP *)&o_tv_insertRows);
        SIO_swizzleInstance(tv, @selector(deleteRowsAtIndexPaths:withRowAnimation:),
                            (IMP)sio_tv_deleteRows, (IMP *)&o_tv_deleteRows);
        SIO_swizzleInstance(tv, @selector(moveRowAtIndexPath:toIndexPath:),
                            (IMP)sio_tv_moveRow, (IMP *)&o_tv_moveRow);
        SIO_swizzleInstance(tv, @selector(insertSections:withRowAnimation:),
                            (IMP)sio_tv_insertSections, (IMP *)&o_tv_insertSections);
        SIO_swizzleInstance(tv, @selector(deleteSections:withRowAnimation:),
                            (IMP)sio_tv_deleteSections, (IMP *)&o_tv_deleteSections);
        SIO_swizzleInstance(tv, @selector(moveSection:toSection:),
                            (IMP)sio_tv_moveSection, (IMP *)&o_tv_moveSection);
        SIO_swizzleInstance(tv, @selector(setEditing:animated:),
                            (IMP)sio_tv_setEditing, (IMP *)&o_tv_setEditing);
        SIO_swizzleInstance(tv, @selector(performBatchUpdates:completion:),
                            (IMP)sio_tv_batchUpdates, (IMP *)&o_tv_batchUpdates);
    }
    if (cv) {
        SIO_swizzleInstance(cv, @selector(reloadData),
                            (IMP)sio_cv_reloadData, (IMP *)&o_cv_reloadData);
        SIO_swizzleInstance(cv, @selector(reloadItemsAtIndexPaths:),
                            (IMP)sio_cv_reloadItems, (IMP *)&o_cv_reloadItems);
        SIO_swizzleInstance(cv, @selector(reloadSections:),
                            (IMP)sio_cv_reloadSections, (IMP *)&o_cv_reloadSections);
        SIO_swizzleInstance(cv, @selector(insertItemsAtIndexPaths:),
                            (IMP)sio_cv_insertItems, (IMP *)&o_cv_insertItems);
        SIO_swizzleInstance(cv, @selector(deleteItemsAtIndexPaths:),
                            (IMP)sio_cv_deleteItems, (IMP *)&o_cv_deleteItems);
        SIO_swizzleInstance(cv, @selector(moveItemAtIndexPath:toIndexPath:),
                            (IMP)sio_cv_moveItem, (IMP *)&o_cv_moveItem);
        SIO_swizzleInstance(cv, @selector(scrollToItemAtIndexPath:atScrollPosition:animated:),
                            (IMP)sio_cv_scrollToItem, (IMP *)&o_cv_scrollToItem);
        SIO_swizzleInstance(cv, @selector(selectItemAtIndexPath:animated:scrollPosition:),
                            (IMP)sio_cv_selectItem, (IMP *)&o_cv_selectItem);
        SIO_swizzleInstance(cv, @selector(deselectItemAtIndexPath:animated:),
                            (IMP)sio_cv_deselectItem, (IMP *)&o_cv_deselectItem);
        // v2.0.5：CV 结构性动画（此前 TV 有 performBatchUpdates 而 CV 没有）
        SIO_swizzleInstance(cv, @selector(performBatchUpdates:completion:),
                            (IMP)sio_cv_batchUpdates, (IMP *)&o_cv_batchUpdates);
        // v2.2.0：这两个原先在 SIO_installiOS16Extras 里无条件安装，
        // 但它们同样受 SIO_listOK() 门控 → 移到此处按需安装，口径与上方 24 个一致。
        SIO_swizzleInstance(cv, @selector(setCollectionViewLayout:animated:),
                            (IMP)sio_cv_setLayout, (IMP *)&o_cv_setLayout);
        SIO_swizzleInstance(cv, @selector(setCollectionViewLayout:animated:completion:),
                            (IMP)sio_cv_setLayoutComp, (IMP *)&o_cv_setLayoutComp);
    }
}

static void SIO_installListHooksLater(void) {
    // 策略：把安装动作排到主队列的「非紧急任务」里。
    //   · 不在构造函数里同步做 —— 那段代码跑在 main 之前，阻塞它就是阻塞 App 启动；
    //   · 不立即做 —— 立即做等于只是换了个地方同步阻塞；
    //   · 用 dispatch_async 让它发生在启动阶段之后，且在 App 有机会处理自身布局之后。
    // 若用户在启动瞬间就打开列表加速，等不及这次异步安装 ——
    // 热重载（配置保存）时 SIO_settingsChanged 会再次触发补装（见下方 gListHooksInstalled 保护）。
    //
    // v2.5.0[性能·P0] 从 dispatch_async(main) 改为 SIO_afterBoot()：
    // dispatch_async 排到的是「main() 之后的第一个主队列 turn」，那正是 App 跑
    // didFinishLaunching 与首屏布局的时间窗 —— 换 27 次方法表会和首屏抢主线程。
    // SIO_afterBoot 以 UIApplicationDidFinishLaunchingNotification 为准（0.35s 兜底），
    // 落到首屏渲染完成之后，且与 iOS16Extras 共用同一个栅栏（只失效一次方法缓存）。
    SIO_afterBoot(^{
        @try {
            if (!gListAccel || gSelfBlacklisted) {
                // 默认路径：列表加速关闭 —— 一个方法表都不碰。
                return;
            }
            if (gListHooksInstalled) return;   // 幂等，防重复安装
            gListHooksInstalled = YES;
            SIO_installListHooksNow();
            NSLog(@"[SIOriginal] list hooks installed lazily (ListAccel=ON, %@)", gSelfBundle);
        } @catch (NSException *e) {
            NSLog(@"[SIOriginal] lazy list hook install failed (app unaffected): %@", e);
        }
    });
}

// ===============================================================================
// v2.2.0[启动提速] 热重载时补装「默认关闭、按需安装」的 hook 族
// ===============================================================================
// 背景：v2.2.0 把几族默认关闭的 hook 从构造函数搬到了「开关打开才装」。
// 这带来一个必然的副作用：如果用户在 App 运行后才打开某个开关，
// 那一轮的按需安装已经过去了，hook 就装不上 —— 表现为「我明明开了却没反应」。
// 本函数由 SIO_settingsChanged（配置保存后的 Darwin 通知）调用，补齐这些 hook。
//
// 为什么不能简单地把它们搬回构造函数：
// 那等于放弃全部启动优化 —— 每一次 method_setImplementation 都要查方法表、
// 比对 IMP、交换指针，并让 UIKit 的全局方法缓存失效。这些 hook 在默认配置下
// 永远不会有行为（开关为 NO 时hook 直接透传原IMP），纯开销。
//
// 幂等性：SIO_swizzleInstance 自带重复安装保护（比对当前 IMP 是否已是我们的），
// 所以重复调用本函数是安全的 —— 不会出现「把自己的 IMP 存成 orig 导致自递归」。
static void SIO_installOnDemandHooks(void) {
    @try {
        if (SIO_blocked()) return;   // 黑名单 / 总开关关闭时无需补装

        // 列表全家桶（含 CV 结构性动画）
        if (gListAccel && !gSelfBlacklisted && !gListHooksInstalled) {
            gListHooksInstalled = YES;
            SIO_installListHooksNow();
            NSLog(@"[SIOriginal] list hooks installed on config change (%@)", gSelfBundle);
        }

        // 缩放动画（ZoomAccel 默认关）
        if (gZoomAccel) {
            Class sv = objc_getClass("UIScrollView");
            if (sv) {
                SIO_swizzleInstance(sv, @selector(setZoomScale:animated:),
                                    (IMP)sio_SV_setZoomScale, (IMP *)&o_sv_setZoomScale);
                SIO_swizzleInstance(sv, @selector(zoomToRect:animated:),
                                    (IMP)sio_SV_zoomToRect, (IMP *)&o_sv_zoomToRect);
            }
        }

        // 布局动画（LayoutAccel 默认关，且 layoutIfNeeded 是热点方法）
        if (gLayoutAccel) {
            Class uv = objc_getClass("UIView");
            if (uv && class_getInstanceMethod(uv, @selector(layoutIfNeeded))) {
                SIO_swizzleInstance(uv, @selector(layoutIfNeeded),
                                    (IMP)sio_view_layoutIfNeeded, (IMP *)&o_view_layoutIfNeeded);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[SIOriginal] on-demand hook install failed (app unaffected): %@", e);
    }
}
