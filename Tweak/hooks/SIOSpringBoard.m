// ============================================================================
//  hooks/SIOSpringBoard — 桌面 / 多任务编辑态安全护栏
// ============================================================================
//  思路来源 FakeCl0ckUp：用户在拖拽图标 / 排列卡片时需要**正常**的动画速度
//  才能准确定位落点。此时任何加速都是在给用户添乱（图标卡半格、预判位置错）。
//
//  为什么单独一个模块：这两个类只存在于 SpringBoard 进程，
//  objc_getClass 在其他进程返回 nil ⇒ 安装器自动跳过。
//  而 SpringBoard 又是唯一必须避免列表 hook 的进程（硬保护名单），
//  逻辑上把它隔离出来便于审计。
//
//  版本适配（这是 iOS 18 改动最大的一处）：
//    · iOS 11–17：SBIconController setIsEditing: 稳定存在
//    · iOS 15+ ：SBAppSwitcherController 的 _beginEditing/_stopEditing
//    · iOS 18  ：宿主类可能改名或搬移 —— 由于全部走 objc_getClass + 选择器查询，
//                拿不到就是「护栏不生效」，后果只是少一层保护，绝不崩。
//                这正是本项目坚持运行时能力检测的最大理由。
// ============================================================================

#import "SIOInternal.h"

static void (*o_sbIcon_setIsEditing)(id, SEL, BOOL);
static void (*o_sbSwitcher_begin)(id, SEL);
static void (*o_sbSwitcher_stop)(id, SEL);

// v2.5.0 护栏本体：编辑期间 gSIOEditing=YES ⇒ SIO_blocked 整体旁路。
// 退出编辑态时必须复位 —— 否则整个桌面动画会永久失去加速（比不变还糟）。
static void sio_sbIcon_setIsEditing(id self, SEL _cmd, BOOL editing) {
    SIO_REQUIRE_ORIG(o_sbIcon_setIsEditing);
    gSIOEditing = editing;
    o_sbIcon_setIsEditing(self, _cmd, editing);
}
static void sio_sbSwitcher_begin(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_sbSwitcher_begin);
    gSIOEditing = YES;
    o_sbSwitcher_begin(self, _cmd);
}
static void sio_sbSwitcher_stop(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_sbSwitcher_stop);
    o_sbSwitcher_stop(self, _cmd);
    gSIOEditing = NO;
}

#pragma mark - 安装表

extern const SIOHookEntry *SIOSpringBoardEntries(NSUInteger *count);
static const SIOHookEntry kSIOSpringBoardEntries[] = {
    // 只在 SpringBoard 存在⇒ 其他进程 objc_getClass 返回 nil，自然跳过（零成本）
    { "SBIconController", "setIsEditing:", NO, (IMP)sio_sbIcon_setIsEditing, (IMP *)&o_sbIcon_setIsEditing, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "SBAppSwitcherController", "_beginEditing", NO, (IMP)sio_sbSwitcher_begin, (IMP *)&o_sbSwitcher_begin, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "SBAppSwitcherController", "_stopEditing",  NO, (IMP)sio_sbSwitcher_stop,  (IMP *)&o_sbSwitcher_stop,  kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
};
const SIOHookEntry *SIOSpringBoardEntries(NSUInteger *count) {
    if (count) *count = sizeof(kSIOSpringBoardEntries) / sizeof(kSIOSpringBoardEntries[0]);
    return kSIOSpringBoardEntries;
}
