// ============================================================================
//  SIOInstaller — 全项目唯一的 hook 安装编排器
// ============================================================================
//  v2.x 的安装点是「三份互相不知道对方存在的安排」：
//    · SIOriginalInit()（构造期）装了核心两族，还顺手装了约 55 个本可以延后的；
//    · SIO_installiOS16Extras() 在被调用的时机上依赖调用方，v2.5.0 才把它挪出 pre-main；
//    · 列表/按需安装又在第三个地方，且没有 gate 概念 —— 开关关了也只是「hook 里
//      判断一下就 return」，方法表照改不误。
//
//  v3.0 把这些合成**一张声明式安装表 + 一次编排**：
//    每个 hook 模块导出一个 const SIOHookEntry[]，本文件按 stage 分派。
//    「装不装」由 entry 自己声明的五个条件决定，编排器不做任何业务判断：
//      stage      —— 什么时候装（Boot / PostLaunch / OnDemand）
//      gate()     —— 业务开关（返回 NO 则**连安装动作都不发生**）
//      minOS/maxOS—— 版本窗口
//      needCaps   —— 运行时能力位（拿不到就跳过，而不是硬装后崩）
//      optional   —— 找不到原实现算不算失败（诊断用，不阻断安装）
//
//  三条启动期红线（与 SIOInternal.h 顶部一致）在这里落地：
//    · pre-main（constructor）只允许 kSIOStageBoot 条目 → 红线 #2
//    · 每个条目安装前后都判 class/method 是否真的存在 → 红线 #3（优雅降级）
//    · 安装全程 @try 包裹，单个条目异常不影响其余条目，更不影响目标 App
// ============================================================================

#import "SIOInternal.h"

#pragma mark - 各模块导出的安装表

// 每个模块一个 getter，返回静态表 + 条目数。
// 用 getter 而不是 extern 数组，是为了让「表的大小」由定义方自己算（sizeof 只在
// 定义所在的编译单元里可靠），同时避免各模块把内部 IMP 符号导出成全局。
extern const SIOHookEntry *SIOCoreAnimEntries(NSUInteger *count);
extern const SIOHookEntry *SIOUIViewAnimEntries(NSUInteger *count);
extern const SIOHookEntry *SIOViewControllerEntries(NSUInteger *count);
extern const SIOHookEntry *SIOControlsEntries(NSUInteger *count);
extern const SIOHookEntry *SIOCollectionsEntries(NSUInteger *count);
extern const SIOHookEntry *SIOScrollViewEntries(NSUInteger *count);
extern const SIOHookEntry *SIOSpringBoardEntries(NSUInteger *count);

typedef const SIOHookEntry *(*SIOEntryTableFn)(NSUInteger *count);

static const SIOEntryTableFn kSIOTableFns[] = {
    SIOCoreAnimEntries,
    SIOUIViewAnimEntries,
    SIOViewControllerEntries,
    SIOControlsEntries,
    SIOCollectionsEntries,
    SIOScrollViewEntries,
    SIOSpringBoardEntries,
};
#define kSIOTableCount (sizeof(kSIOTableFns) / sizeof(kSIOTableFns[0]))

#pragma mark - 安装记账

// 按 stage 记录「该档是否已经装过」。
// v2.x 没有这个 —— SIO_installiOS16Extras 被调用两次就会重复交换 55 次
// （虽然 SIOExchange 的 *orig 判空会兜住，但白跑一遍 55 次 objc_getClass）。
static BOOL gSIOStageDone[3] = { NO, NO, NO };
static NSUInteger gSIOEntryAttempts[3] = { 0, 0, 0 };
static NSUInteger gSIOEntrySkipped[3]  = { 0, 0, 0 };
static NSUInteger gSIOEntryFailed[3]   = { 0, 0, 0 };

// gSIOHookSwapCount 与 SIOHookSwapCount() 都定义在 SIOCore.m（唯一归属）。
// 这里是编排层，只读取计数，不重复定义 —— 否则链接期 duplicate symbol。

#pragma mark - 单条目安装

// 判定一个条目当前是否应当安装。不做任何「安装后再判断」的偷懒 ——
// 只要这里返回 NO，SIOExchange 根本不会被调用，方法表保持原样。
static BOOL SIOEntryEligible(const SIOHookEntry *e) {
    // ---- 版本窗口 ----
    if (e->minOS > 0 && gSIOMajor < e->minOS) return NO;
    if (e->maxOS > 0 && gSIOMajor > e->maxOS) return NO;

    // ---- 运行时能力位 ----
    if (e->needCaps != 0 && (gSIOCaps & e->needCaps) != e->needCaps) return NO;

    // ---- 业务开关（唯一由模块自己声明的门） ----
    if (e->gate && !e->gate()) return NO;

    return YES;
}

// 安装一个条目。返回值表示「是否发生了代价为零的失败」（缺类/缺方法）。
static BOOL SIOInstallOne(const SIOHookEntry *e) {
    if (!e->className || !e->selectorName || !e->newImp || !e->origSlot) return NO;

    // 重复安装保护的第二道（第一道在 SIOExchange 的 *orig 判空）。
    // 放在这里是因为这一步比 objc_getClass 更便宜。
    if (*e->origSlot != NULL) return YES;

    Class cls = objc_getClass(e->className);
    if (!cls) {
        // 类不存在 = 该版本/该进程没有这个 API。optional 条目这是正常情况；
        // 非 optional 的也只记录不报错 —— 绝不因为「一个 hook 没装上」就中断安装。
        return NO;
    }

    // 方法名在表中存为 C 字符串（编译期常量），这里转成 SEL。
    SEL sel = sel_registerName(e->selectorName);

    // 方法是否真的存在？不存在就跳过。
    // 这一条是 v2.x 用 %hook 时由 Theos 保证的（方法不存在则编译期失败），
    // 改成纯 runtime 之后必须自己查 —— 否则 SIOExchange 会走
    // class_addMethod 给类**凭空添加**一个方法（比如把 setVelocity: 加到
    // 不支持该方法的旧系统上），改变消息分发行为，属于红线 #3 的违反。
    Method m = e->isClassMethod ? class_getClassMethod(cls, sel)
                                : class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    @try {
        SIOExchange(e->className, sel, e->newImp, e->origSlot, e->isClassMethod);
    } @catch (__unused NSException *ex) {
        return NO;
    }
    return YES;
}

#pragma mark - 按档安装

void SIOInstallStage(SIOStage stage) {
    if (stage > kSIOStageOnDemand) return;
    if (gSIOStageDone[stage]) return;      // 幂等：同一档只跑一次
    gSIOStageDone[stage] = YES;

    for (NSUInteger t = 0; t < kSIOTableCount; t++) {
        NSUInteger n = 0;
        const SIOHookEntry *table = kSIOTableFns[t](&n);
        if (!table) continue;

        for (NSUInteger i = 0; i < n; i++) {
            const SIOHookEntry *e = &table[i];
            if (e->stage != stage) continue;
            gSIOEntryAttempts[stage]++;
            if (!SIOEntryEligible(e)) { gSIOEntrySkipped[stage]++; continue; }
            if (!SIOInstallOne(e)) {
                gSIOEntryFailed[stage]++;
                // optional 条目缺失是预期内的（例如 iOS 18 改了私有类名），
                // 非 optional 的仅记录 —— 统一走「缺了就少一层优化」的策略。
            }
        }
    }
}

// 全量安装（三档一起）。仅用于诊断场景；正常启动路径由 SIOInstall 分档调度。
void SIOInstall(void) {
    SIOInstallStage(kSIOStageBoot);
    SIOInstallStage(kSIOStagePostLaunch);
    SIOInstallStage(kSIOStageOnDemand);
}

#pragma mark - 启动指纹（延后输出）

// v2.5.0 的教训：一段 NSLog 曾把 UIKit / 私有框架的 dlopen 拖进 pre-main，
// 「日志本身」变成了启动劣化源。v3.0 的规则是：
//   · pre-main 最多打一行固定文案（用于确认 dylib 被加载）
//   · 完整指纹（平台/能力/交换计数/配置摘要）延后到 App 启动完成之后
void SIOLogBrand(void) {
    NSString *bid = SIOBundleID();
    NSMutableString *m = [NSMutableString stringWithFormat:
        @"[SIO] v%s loaded in %@", SIO_VER_STRING, bid.length ? bid : @"?"];
    [m appendFormat:@" | %@", SIOPlatformSummary()];
    [m appendFormat:@" | swaps=%d (boot=%u/post=%u/onDemand=%u)",
        gSIOHookSwapCount,
        (unsigned)gSIOEntryAttempts[kSIOStageBoot],
        (unsigned)gSIOEntryAttempts[kSIOStagePostLaunch],
        (unsigned)gSIOEntryAttempts[kSIOStageOnDemand]];
    [m appendFormat:@" | skip=%u/%u/%u miss=%u/%u/%u",
        (unsigned)gSIOEntrySkipped[kSIOStageBoot],
        (unsigned)gSIOEntrySkipped[kSIOStagePostLaunch],
        (unsigned)gSIOEntrySkipped[kSIOStageOnDemand],
        (unsigned)gSIOEntryFailed[kSIOStageBoot],
        (unsigned)gSIOEntryFailed[kSIOStagePostLaunch],
        (unsigned)gSIOEntryFailed[kSIOStageOnDemand]];
    if (!gSIOCfg.enabled)      [m appendString:@" | DISABLED"];
    else                       [m appendFormat:@" | mode=%d speed=%.2f", gSIOCfg.mode, gSIOCfg.speed];
    if (gSIOSelfBlacklisted)   [m appendString:@" | BLACKLISTED"];
    NSLog(@"%@", m);
}

#pragma mark - 进程入口

// ---------------------------------------------------------------------------
// pre-main 只做四件事（顺序不可调整）：
//   1. 初始化 TLS 槽位 —— 后续所有 hook 的守卫都依赖它，必须在任何 hook 前完成；
//   2. 探测平台与能力位 —— 安装表的 minOS/needCaps 判定依赖它；
//   3. 读一次配置 —— gate() 依赖它；
//   4. 装 Boot 档 —— 首屏正确性依赖的核心两族（CAAnimation / UIView 动画）。
//
// 其余一切（含保活引擎、资源看门狗、Diagnostics）都排到启动完成之后。
// 这就是红线 #2「注入库自身不得拖慢启动」的具体落实。
// ---------------------------------------------------------------------------
__attribute__((constructor))
static void SIOEntry(void) {
    @autoreleasepool {
        // 记录起点：SIOMarkBootCost() 会在启动完成时算出 dyld+构造函数总耗时，
        // 用于验证「每次改动没有让 pre-main 变慢」。
        SIOMarkBootStart();

        @try {
            // ① TLS。失败也继续 —— SIO_tlsGet 已经处理了「key 不可用」的情况，
            //    代价只是失去重入保护，而不是崩溃。
            SIOTlsInit();

            // ② 平台探测（纯内存操作，无磁盘 IO、无 UIScreen 访问）。
            SIOProbePlatform();

            // ③ 配置（一次磁盘读，进缓存；后续所有读取走缓存）。
            SIOConfigLoad();
            SIOEnginePrepare();

            // ④ 只装 Boot 档。
            SIOInstallStage(kSIOStageBoot);

            // ⑤ 注册配置热重载监听（注册本身是内存操作，不触发 IO）。
            SIOConfigRegisterObserver();

            // ⑥ 把「启动完成之后要做的事」登记好。注意这里只是排队：
            //    SIOAfterBoot 在 didFinishLaunching 或 0.35s 超时后才会执行。
            SIOAfterBoot(^{
                @autoreleasepool {
                    SIOMarkBootCost();

                    // 昂贵环境探测（stat 外部路径、access 可写性）挪到这里 ——
                    // pre-main 里每一次 stat 都算进启动耗时。
                    SIOProbeEnvironmentDeferred();

                    // PostLaunch 档：UIViewPropertyAnimator、导航/模态转场、
                    // 滚动/长按、SpringBoard 编辑护栏。
                    SIOInstallStage(kSIOStagePostLaunch);

                    // 内存护栏 + QoS 策略（只注册监听源，不做事）。
                    if (gSIOCfg.memoryGuard)     SIOSetupResourceWatchdog();
                    if (gSIOCfg.schedulingBoost) SIOApplyQoSPolicy();

                    // 保活引擎（只在自己声明要用的进程里装）。
                    SIOSetupBackground();

                    // OnDemand 档：默认关闭的高危开关。开关关闭时
                    // SIOEntryEligible 会直接跳过，一次交换都不会发生。
                    SIOInstallStage(kSIOStageOnDemand);

                    // 指纹放到最后打 —— 此时换计数、平台信息、配置都已就绪。
                    SIOLogBrand();
                }
            });
        } @catch (NSException *e) {
            // 红线 #3：注入库自己出问题，目标 App 必须完好无损。
            NSLog(@"[SIO] install failed (app unaffected): %@", e);
        }
    }
}
