// ============================================================================
//  SIOCore — TLS / 方法交换 / 交换计数（基础设施，不含任何业务逻辑）
// ============================================================================
//  v2.x 里三个 pthread_key_t 各自单独 create + 各自判空，
//  且 swizzle 的实现被 iOS16Extras / 列表 / 按需安装三处重复调用。
//  v3.0 把「怎么交换」收敛到唯一实现 SIOExchange()，好处有三：
//    · 交换计数集中统计（v2.5.0 发现 checks 只能人肉清点 swaps，易 silently 回退）
//    · 交换预算 (swapBudget) 有了唯一强制点 —— 防止某个 App 类簇爆炸
//    · 「重复安装」保护集中一处（曾导致 orig 槽存进自己的 IMP → 无限递归爆栈）
// ============================================================================

#import "SIOInternal.h"

pthread_key_t SIOTlsKeys[kSIOTlsCount];
BOOL          SIOTlsReady = NO;
int           gSIOHookSwapCount = 0;

// ---------------------------------------------------------------------------
// v2.5.0 引入 swaps= 计数后发现一件事：「启动期交换次数」这种指标必须**机器维持**，
// 人肉清点会在下一次改动时悄悄失真（v2.2.0 声称 53→26，实际还有 55 次没搬走）。
// 因此这里不是「可观测性装饰」，而是防止启动劣化回归的护栏。

BOOL SIOTlsInit(void) {
    for (NSUInteger i = 0; i < kSIOTlsCount; i++) {
        // v2.1.0 修过：pthread_key_create 的返回值此前不检查。
        // 任一失败会让后续 SIO_tlsGet 读到未定义值 —— 行为不可预测且难复现。
        if (pthread_key_create(&SIOTlsKeys[i], NULL) != 0) {
            SIOTlsReady = NO;
            return NO;
        }
    }
    SIOTlsReady = YES;
    return YES;
}

NSString *SIOBundleID(void) {
    if (!gSIOBundleID) {
        gSIOBundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    }
    return gSIOBundleID;
}

#pragma mark - 方法交换（全项目唯一实现）

// v2.x 的 SIO_swizzleInstance / SIO_swizzleClass 逻辑一致、重复两遍。
// 这里合并为一条：isMeta 决定作用在元类还是类本身。
//
// 三个必须保留的安全性质：
//  1. 目标方法不存在 ⇒ 不交换、不加计数（避免给类凭空加方法改变消息分发）
//  2. *orig 已经被填过 ⇒ 直接返回（重复安装保护，防递归爆栈）
//  3. 超出 swapBudget ⇒ 放弃（防御性：极端 App 里可能遇到类簇导致 N 次交换）
void SIOExchange(const char *clsName, SEL sel, IMP newImp, IMP *orig, BOOL isMeta) {
    if (!clsName || !sel || !newImp || !orig) return;
    if (*orig != NULL) return;                       // (2) 已安装
    if (gSIOCfg.swapBudget > 0 && gSIOHookSwapCount >= gSIOCfg.swapBudget) return;  // (3)

    Class c = objc_getClass(clsName);
    if (!c) return;
    // 必须传「类对象」而不是元类后再取一次 object_getClass：
    // v1.8.19 在这里踩过 —— class_getClassMethod(pa) 内部已经做了 object_getClass，
    // 若调用方再套一层就会去根元类里找，必然返回 NULL，导致 hook 从未安装。
    Class target = isMeta ? object_getClass((id)c) : c;
    if (!target) return;

    Method m = class_getInstanceMethod(target, sel);
    if (!m) return;                                   // (1) 不入工作流
    IMP cur = method_getImplementation(m);
    if (!cur || cur == newImp) return;

    const char *types = method_getTypeEncoding(m);
    // ---- 继承污染防护（v1.8.19 修过的致命 bug）----
    // 若本类没有自己的实现、方法来自父类，直接 method_setImplementation 会
    // 改掉**父类**的实现 ⇒ 所有子类都被动改写。
    // 例如把 setContentOffset:animated: 直接换到 UIView 上会让所有 UIView 都进
    // UIScrollView 的判断分支（uis 崩溃）。
    // 正确做法：先尝试在本类 add 一份（仅当本类没有时成功），orig 指向父类实现。
    if (class_addMethod(target, sel, newImp, types)) {
        Class sup = class_getSuperclass(target);
        Method sm = sup ? class_getInstanceMethod(sup, sel) : NULL;
        *orig = sm ? method_getImplementation(sm) : NULL;
        gSIOHookSwapCount++;
        return;
    }
    // 本类自有实现：直接替换
    *orig = cur;
    method_setImplementation(m, newImp);
    gSIOHookSwapCount++;
}

#pragma mark - 诊断

int SIOHookSwapCount(void) { return gSIOHookSwapCount; }
