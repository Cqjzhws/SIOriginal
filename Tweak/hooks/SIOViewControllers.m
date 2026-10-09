// ============================================================================
//  hooks/SIOViewControllers — 导航 / 模态 / 标签 / 栏 / 页面容器 转场
// ============================================================================
//  这一族的共同形态：UIKit 不把「时长」暴露给 App，而是用内部的默认 0.35s
//  （导航/模态）或 0.25s（栏/容器），因此没有 App 传入的 duration 可以拦截。
//  唯一可控手段是把调用包进一个 **我们设定好时长的事务**里。
//
//  统一走 SIOWrapTransition()，它内部已经是：
//      CATransaction begin → setAnimationDuration(SIO_transitionBase()) → call → commit
//  v2.x 里这四个步骤在 30 多个 hook 里各写一遍，其中有两处忘了 begin/commit 配对、
//  三处忘了处理 extra 门控。v3.0 只保留一个实现。
//
//  【为什么这些必须受 Extra 门控】gExtra 是「进阶转场」开关。
//  转场是唯一可能让新页面来不及布局就被提交的那类动画，
//  属于「收益明显、偶发风险也明显」的功能，因此做成可关，默认开。
// ============================================================================

#import "SIOInternal.h"

#pragma mark - 原 IMP 槽位

static void (*o_nav_push)(id, SEL, UIViewController *, BOOL);
static void (*o_nav_pop)(id, SEL, BOOL);
static void (*o_nav_popTo)(id, SEL, UIViewController *, BOOL);
static void (*o_nav_popToRoot)(id, SEL, BOOL);
static void (*o_nav_setVCs)(id, SEL, NSArray *, BOOL);
static void (*o_nav_privDur)(id, SEL, double);
static void (*o_nav_setBarHidden)(id, SEL, BOOL, BOOL);
static void (*o_nav_setToolbarHidden)(id, SEL, BOOL, BOOL);
static void (*o_vc_present)(id, SEL, UIViewController *, BOOL, void (^)(void));
static void (*o_vc_dismiss)(id, SEL, BOOL, void (^)(void));
static void (*o_vc_transFrom)(id, SEL, UIViewController *, UIViewController *, double,
                              UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void (*o_vc_setEditing)(id, SEL, BOOL, BOOL);
static void (*o_tab_setIndex)(id, SEL, NSUInteger);
static void (*o_tab_setVC)(id, SEL, UIViewController *);
static void (*o_tabBC_setVCs)(id, SEL, NSArray *, BOOL);
static void (*o_navBar_pushItem)(id, SEL, id, BOOL);
static id   (*o_navBar_popItem)(id, SEL, BOOL);
static void (*o_navBar_setItems)(id, SEL, NSArray *, BOOL);
static void (*o_toolbar_setItems)(id, SEL, NSArray *, BOOL);
static void (*o_tabBar_setItems)(id, SEL, NSArray *, BOOL);
static void (*o_navItem_setHidesBack)(id, SEL, BOOL, BOOL);
static void (*o_navItem_setLeftBtn)(id, SEL, id, BOOL);
static void (*o_navItem_setRightBtn)(id, SEL, id, BOOL);
static void (*o_navItem_setLeftBtns)(id, SEL, NSArray *, BOOL);
static void (*o_navItem_setRightBtns)(id, SEL, NSArray *, BOOL);
static void (*o_navItem_setLargeTitle)(id, SEL, NSInteger);
static void (*o_searchCtrl_setActive)(id, SEL, BOOL, BOOL);
static void (*o_pageVC_setVCs)(id, SEL, NSArray *, UIPageViewControllerNavigationDirection, BOOL, void (^)(void));
static void (*o_pageVC_setSpine)(id, SEL, NSInteger, BOOL);
static void (*o_doc_presentPreview)(id, SEL, BOOL);
static BOOL (*o_doc_openInMenu)(id, SEL, CGRect, id, BOOL);
static BOOL (*o_doc_optionsMenu)(id, SEL, CGRect, id, BOOL);
static void (*o_popover_setContentSize)(id, SEL, CGSize, BOOL);

#pragma mark - UINavigationController

static void sio_nav_push(id self, SEL _cmd, UIViewController *vc, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_push);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_nav_push(self, _cmd, vc, anim); return; }
    SIOWrapTransition(^{ o_nav_push(self, _cmd, vc, anim); });
}
static void sio_nav_pop(id self, SEL _cmd, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_pop);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_nav_pop(self, _cmd, anim); return; }
    SIOWrapTransition(^{ o_nav_pop(self, _cmd, anim); });
}
static void sio_nav_popTo(id self, SEL _cmd, UIViewController *vc, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_popTo);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_nav_popTo(self, _cmd, vc, anim); return; }
    SIOWrapTransition(^{ o_nav_popTo(self, _cmd, vc, anim); });
}
// v2.4.0 补齐：popToRoot 此前无任何覆盖 —— 「一路退回根」是最常被吐槽慢的操作之一。
static void sio_nav_popToRoot(id self, SEL _cmd, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_popToRoot);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_nav_popToRoot(self, _cmd, anim); return; }
    SIOWrapTransition(^{ o_nav_popToRoot(self, _cmd, anim); });
}
static void sio_nav_setVCs(id self, SEL _cmd, NSArray *vcs, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_setVCs);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_nav_setVCs(self, _cmd, vcs, anim); return; }
    SIOWrapTransition(^{ o_nav_setVCs(self, _cmd, vcs, anim); });
}
// 私有 API：App 用它直接指定转场时长（比公开 API 更明确地表达了意图）。
// 存在才装（minOS 不限，拿不到就跳过）—— 它决定的是 App 自己给的值，直接缩放即可。
static void sio_nav_privDur(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_nav_privDur);
    if (SIO_blocked() || !gSIOCfg.extra) { o_nav_privDur(self, _cmd, d); return; }
    o_nav_privDur(self, _cmd, SIO_targetDurationUIKit(d));
}
static void sio_nav_setBarHidden(id self, SEL _cmd, BOOL hidden, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_setBarHidden);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_nav_setBarHidden(self, _cmd, hidden, anim); return; }
    SIOWrapTransition(^{ o_nav_setBarHidden(self, _cmd, hidden, anim); });
}
static void sio_nav_setToolbarHidden(id self, SEL _cmd, BOOL hidden, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_setToolbarHidden);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_nav_setToolbarHidden(self, _cmd, hidden, anim); return; }
    SIOWrapTransition(^{ o_nav_setToolbarHidden(self, _cmd, hidden, anim); });
}

#pragma mark - UIViewController（模态）

static void sio_vc_present(id self, SEL _cmd, UIViewController *vc, BOOL anim, void (^c)(void)) {
    SIO_REQUIRE_ORIG(o_vc_present);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_vc_present(self, _cmd, vc, anim, c); return; }
    SIOWrapTransition(^{ o_vc_present(self, _cmd, vc, anim, c); });
}
static void sio_vc_dismiss(id self, SEL _cmd, BOOL anim, void (^c)(void)) {
    SIO_REQUIRE_ORIG(o_vc_dismiss);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_vc_dismiss(self, _cmd, anim, c); return; }
    SIOWrapTransition(^{ o_vc_dismiss(self, _cmd, anim, c); });
}
// 容器控制器子控制器转场：这一族 UIKit **把 duration 暴露给了 App**，
// 因此直接缩放传入值即可，不需要事务包裹。
static void sio_vc_transFrom(id self, SEL _cmd, UIViewController *from, UIViewController *to,
                             double d, UIViewAnimationOptions o, void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_vc_transFrom);
    if (SIO_blocked()) { o_vc_transFrom(self, _cmd, from, to, d, o, a, c); return; }
    SIOTlsGuard g = SIO_tlsBegin(kSIOTlsTxDur);
    o_vc_transFrom(self, _cmd, from, to, SIO_targetDurationUIKit(d), o, a, c);
    SIO_tlsEnd(g);
}
// v2.4.0 补齐：UITableView/列表右上「编辑」切换。
static void sio_vc_setEditing(id self, SEL _cmd, BOOL editing, BOOL anim) {
    SIO_REQUIRE_ORIG(o_vc_setEditing);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_vc_setEditing(self, _cmd, editing, anim); return; }
    SIOWrapTransition(^{ o_vc_setEditing(self, _cmd, editing, anim); });
}

#pragma mark - UITabBarController

static void sio_tab_setIndex(id self, SEL _cmd, NSUInteger idx) {
    SIO_REQUIRE_ORIG(o_tab_setIndex);
    if (SIO_blocked() || !gSIOCfg.extra) { o_tab_setIndex(self, _cmd, idx); return; }
    SIOWrapTransition(^{ o_tab_setIndex(self, _cmd, idx); });
}
static void sio_tab_setVC(id self, SEL _cmd, UIViewController *vc) {
    SIO_REQUIRE_ORIG(o_tab_setVC);
    if (SIO_blocked() || !gSIOCfg.extra) { o_tab_setVC(self, _cmd, vc); return; }
    SIOWrapTransition(^{ o_tab_setVC(self, _cmd, vc); });
}
static void sio_tabBC_setVCs(id self, SEL _cmd, NSArray *vcs, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tabBC_setVCs);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_tabBC_setVCs(self, _cmd, vcs, anim); return; }
    SIOWrapTransition(^{ o_tabBC_setVCs(self, _cmd, vcs, anim); });
}

#pragma mark - 导航栏 / 工具栏 / 标签栏

static void sio_navBar_pushItem(id self, SEL _cmd, id item, BOOL anim) {
    SIO_REQUIRE_ORIG(o_navBar_pushItem);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_navBar_pushItem(self, _cmd, item, anim); return; }
    SIOWrapTransition(^{ o_navBar_pushItem(self, _cmd, item, anim); });
}
static id sio_navBar_popItem(id self, SEL _cmd, BOOL anim) {
    SIO_REQUIRE_ORIG_NIL(o_navBar_popItem);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) return o_navBar_popItem(self, _cmd, anim);
    __block id r = nil;
    SIOWrapTransition(^{ r = o_navBar_popItem(self, _cmd, anim); });
    return r;
}
static void sio_navBar_setItems(id self, SEL _cmd, NSArray *items, BOOL anim) {
    SIO_REQUIRE_ORIG(o_navBar_setItems);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_navBar_setItems(self, _cmd, items, anim); return; }
    SIOWrapTransition(^{ o_navBar_setItems(self, _cmd, items, anim); });
}
static void sio_toolbar_setItems(id self, SEL _cmd, NSArray *items, BOOL anim) {
    SIO_REQUIRE_ORIG(o_toolbar_setItems);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_toolbar_setItems(self, _cmd, items, anim); return; }
    SIOWrapTransition(^{ o_toolbar_setItems(self, _cmd, items, anim); });
}
static void sio_tabBar_setItems(id self, SEL _cmd, NSArray *items, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tabBar_setItems);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_tabBar_setItems(self, _cmd, items, anim); return; }
    SIOWrapTransition(^{ o_tabBar_setItems(self, _cmd, items, anim); });
}

#pragma mark - UINavigationItem 按钮增删

static void sio_navItem_setHidesBack(id self, SEL _cmd, BOOL hide, BOOL anim) {
    SIO_REQUIRE_ORIG(o_navItem_setHidesBack);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_navItem_setHidesBack(self, _cmd, hide, anim); return; }
    SIOWrapTransition(^{ o_navItem_setHidesBack(self, _cmd, hide, anim); });
}
static void sio_navItem_setLeftBtn(id self, SEL _cmd, id item, BOOL anim) {
    SIO_REQUIRE_ORIG(o_navItem_setLeftBtn);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_navItem_setLeftBtn(self, _cmd, item, anim); return; }
    SIOWrapTransition(^{ o_navItem_setLeftBtn(self, _cmd, item, anim); });
}
static void sio_navItem_setRightBtn(id self, SEL _cmd, id item, BOOL anim) {
    SIO_REQUIRE_ORIG(o_navItem_setRightBtn);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_navItem_setRightBtn(self, _cmd, item, anim); return; }
    SIOWrapTransition(^{ o_navItem_setRightBtn(self, _cmd, item, anim); });
}
static void sio_navItem_setLeftBtns(id self, SEL _cmd, NSArray *items, BOOL anim) {
    SIO_REQUIRE_ORIG(o_navItem_setLeftBtns);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_navItem_setLeftBtns(self, _cmd, items, anim); return; }
    SIOWrapTransition(^{ o_navItem_setLeftBtns(self, _cmd, items, anim); });
}
static void sio_navItem_setRightBtns(id self, SEL _cmd, NSArray *items, BOOL anim) {
    SIO_REQUIRE_ORIG(o_navItem_setRightBtns);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_navItem_setRightBtns(self, _cmd, items, anim); return; }
    SIOWrapTransition(^{ o_navItem_setRightBtns(self, _cmd, items, anim); });
}
// v1.8.18 覆盖：大标题／小标题切换（iOS 11+）。minOS 由安装表限制。
static void sio_navItem_setLargeTitle(id self, SEL _cmd, NSInteger mode) {
    SIO_REQUIRE_ORIG(o_navItem_setLargeTitle);
    if (SIO_blocked() || !gSIOCfg.extra) { o_navItem_setLargeTitle(self, _cmd, mode); return; }
    SIOWrapTransition(^{ o_navItem_setLargeTitle(self, _cmd, mode); });
}

#pragma mark - 搜索 / 翻页 / 文档 / 气泡

static void sio_searchCtrl_setActive(id self, SEL _cmd, BOOL active, BOOL anim) {
    SIO_REQUIRE_ORIG(o_searchCtrl_setActive);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_searchCtrl_setActive(self, _cmd, active, anim); return; }
    SIOWrapTransition(^{ o_searchCtrl_setActive(self, _cmd, active, anim); });
}
static void sio_pageVC_setVCs(id self, SEL _cmd, NSArray *vcs,
                              UIPageViewControllerNavigationDirection dir, BOOL anim, void (^c)(void)) {
    SIO_REQUIRE_ORIG(o_pageVC_setVCs);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_pageVC_setVCs(self, _cmd, vcs, dir, anim, c); return; }
    SIOWrapTransition(^{ o_pageVC_setVCs(self, _cmd, vcs, dir, anim, c); });
}
static void sio_pageVC_setSpine(id self, SEL _cmd, NSInteger loc, BOOL anim) {
    SIO_REQUIRE_ORIG(o_pageVC_setSpine);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_pageVC_setSpine(self, _cmd, loc, anim); return; }
    SIOWrapTransition(^{ o_pageVC_setSpine(self, _cmd, loc, anim); });
}
static void sio_doc_presentPreview(id self, SEL _cmd, BOOL anim) {
    SIO_REQUIRE_ORIG(o_doc_presentPreview);
    if (SIO_blocked() || !anim) { o_doc_presentPreview(self, _cmd, anim); return; }
    SIOWrapTransition(^{ o_doc_presentPreview(self, _cmd, anim); });
}
static BOOL sio_doc_openInMenu(id self, SEL _cmd, CGRect r, id v, BOOL anim) {
    SIO_REQUIRE_ORIG_VAL(o_doc_openInMenu, NO);
    if (SIO_blocked() || !anim) return o_doc_openInMenu(self, _cmd, r, v, anim);
    __block BOOL ok = NO;
    SIOWrapTransition(^{ ok = o_doc_openInMenu(self, _cmd, r, v, anim); });
    return ok;
}
static BOOL sio_doc_optionsMenu(id self, SEL _cmd, CGRect r, id v, BOOL anim) {
    SIO_REQUIRE_ORIG_VAL(o_doc_optionsMenu, NO);
    if (SIO_blocked() || !anim) return o_doc_optionsMenu(self, _cmd, r, v, anim);
    __block BOOL ok = NO;
    SIOWrapTransition(^{ ok = o_doc_optionsMenu(self, _cmd, r, v, anim); });
    return ok;
}
static void sio_popover_setContentSize(id self, SEL _cmd, CGSize size, BOOL anim) {
    SIO_REQUIRE_ORIG(o_popover_setContentSize);
    if (SIO_blocked() || !gSIOCfg.extra || !anim) { o_popover_setContentSize(self, _cmd, size, anim); return; }
    SIOWrapTransition(^{ o_popover_setContentSize(self, _cmd, size, anim); });
}

#pragma mark - 安装表

extern const SIOHookEntry *SIOViewControllerEntries(NSUInteger *count);
static const SIOHookEntry kSIOViewControllerEntries[] = {
    { "UINavigationController", "pushViewController:animated:", NO, (IMP)sio_nav_push, (IMP *)&o_nav_push, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationController", "popViewControllerAnimated:", NO, (IMP)sio_nav_pop, (IMP *)&o_nav_pop, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationController", "popToViewController:animated:", NO, (IMP)sio_nav_popTo, (IMP *)&o_nav_popTo, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationController", "popToRootViewControllerAnimated:", NO, (IMP)sio_nav_popToRoot, (IMP *)&o_nav_popToRoot, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationController", "setViewControllers:animated:", NO, (IMP)sio_nav_setVCs, (IMP *)&o_nav_setVCs, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationController", "_setTransitionDuration:", NO, (IMP)sio_nav_privDur, (IMP *)&o_nav_privDur, kSIOStagePostLaunch, NULL, 0, 0, 0, YES },
    { "UINavigationController", "setNavigationBarHidden:animated:", NO, (IMP)sio_nav_setBarHidden, (IMP *)&o_nav_setBarHidden, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationController", "setToolbarHidden:animated:", NO, (IMP)sio_nav_setToolbarHidden, (IMP *)&o_nav_setToolbarHidden, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIViewController", "presentViewController:animated:completion:", NO, (IMP)sio_vc_present, (IMP *)&o_vc_present, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIViewController", "dismissViewControllerAnimated:completion:", NO, (IMP)sio_vc_dismiss, (IMP *)&o_vc_dismiss, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIViewController", "transitionFromViewController:toViewController:duration:options:animations:completion:", NO, (IMP)sio_vc_transFrom, (IMP *)&o_vc_transFrom, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIViewController", "setEditing:animated:", NO, (IMP)sio_vc_setEditing, (IMP *)&o_vc_setEditing, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UITabBarController", "setSelectedIndex:", NO, (IMP)sio_tab_setIndex, (IMP *)&o_tab_setIndex, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UITabBarController", "setSelectedViewController:", NO, (IMP)sio_tab_setVC, (IMP *)&o_tab_setVC, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UITabBarController", "setViewControllers:animated:", NO, (IMP)sio_tabBC_setVCs, (IMP *)&o_tabBC_setVCs, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationBar", "pushNavigationItem:animated:", NO, (IMP)sio_navBar_pushItem, (IMP *)&o_navBar_pushItem, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationBar", "popNavigationItemAnimated:", NO, (IMP)sio_navBar_popItem, (IMP *)&o_navBar_popItem, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationBar", "setItems:animated:", NO, (IMP)sio_navBar_setItems, (IMP *)&o_navBar_setItems, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIToolbar", "setItems:animated:", NO, (IMP)sio_toolbar_setItems, (IMP *)&o_toolbar_setItems, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UITabBar", "setItems:animated:", NO, (IMP)sio_tabBar_setItems, (IMP *)&o_tabBar_setItems, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationItem", "setHidesBackButton:animated:", NO, (IMP)sio_navItem_setHidesBack, (IMP *)&o_navItem_setHidesBack, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationItem", "setLeftBarButtonItem:animated:", NO, (IMP)sio_navItem_setLeftBtn, (IMP *)&o_navItem_setLeftBtn, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationItem", "setRightBarButtonItem:animated:", NO, (IMP)sio_navItem_setRightBtn, (IMP *)&o_navItem_setRightBtn, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationItem", "setLeftBarButtonItems:animated:", NO, (IMP)sio_navItem_setLeftBtns, (IMP *)&o_navItem_setLeftBtns, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationItem", "setRightBarButtonItems:animated:", NO, (IMP)sio_navItem_setRightBtns, (IMP *)&o_navItem_setRightBtns, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UINavigationItem", "setLargeTitleDisplayMode:", NO, (IMP)sio_navItem_setLargeTitle, (IMP *)&o_navItem_setLargeTitle, kSIOStagePostLaunch, NULL, 11, 0, 0, NO },
    { "UISearchController", "setActive:animated:", NO, (IMP)sio_searchCtrl_setActive, (IMP *)&o_searchCtrl_setActive, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIPageViewController", "setViewControllers:direction:animated:completion:", NO, (IMP)sio_pageVC_setVCs, (IMP *)&o_pageVC_setVCs, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIPageViewController", "setSpineLocation:animated:", NO, (IMP)sio_pageVC_setSpine, (IMP *)&o_pageVC_setSpine, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIDocumentInteractionController", "presentPreviewAnimated:", NO, (IMP)sio_doc_presentPreview, (IMP *)&o_doc_presentPreview, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIDocumentInteractionController", "presentOpenInMenuFromRect:inView:animated:", NO, (IMP)sio_doc_openInMenu, (IMP *)&o_doc_openInMenu, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIDocumentInteractionController", "presentOptionsMenuFromRect:inView:animated:", NO, (IMP)sio_doc_optionsMenu, (IMP *)&o_doc_optionsMenu, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIPopoverController", "setPopoverContentSize:animated:", NO, (IMP)sio_popover_setContentSize, (IMP *)&o_popover_setContentSize, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
};
const SIOHookEntry *SIOViewControllerEntries(NSUInteger *count) {
    if (count) *count = sizeof(kSIOViewControllerEntries) / sizeof(kSIOViewControllerEntries[0]);
    return kSIOViewControllerEntries;
}
