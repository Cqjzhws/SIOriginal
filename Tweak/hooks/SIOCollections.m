// ============================================================================
//  hooks/SIOCollections — UITableView / UICollectionView 变更族（高危，默认关）
// ============================================================================
//  全项目唯一「默认关闭」的大族（ListAccel）。原因写在 v1.8.11 的事故记录里：
//  列表的 insert/delete/reload 各自带状态机语义，把它们塞进一个被压缩的事务里，
//  轻则行数错乱、重则卡死（历史上顺丰同城骑士 App 的加载卡死就是这一类）。
//
//  因此这一族有三重保险：
//    1. 硬保护名单：SpringBoard 永不开启（开了就是黑屏/白苹果），且**不接受任何覆盖打开**；
//    2. 默认关闭：缺 key 也是关（fail-safe），用户的 App 专属覆盖也不能越过硬保护；
//    3. 按需安装：开关关闭时这 24 次方法交换**一次都不做** ——
//       v2.2.0 证明默认配置下这批交换是纯开销，全都砸在 pre-main 上。
//
//  【为什么不改写 animated 参数】文件历史上 v1.8.3/v1.8.15 两次把
//  「改写 animated: 语义」列为微信预览卡死的根因并写下禁令，
//  却在旧代码里一边写禁令一边实施。v3.0 统一：**只压事务时长，animated 原样透传**。
// ============================================================================

#import "SIOInternal.h"

#pragma mark - 原 IMP 槽位

// UITableView
static void (*o_tv_selectRow)(id, SEL, NSIndexPath *, BOOL, UITableViewScrollPosition);
static void (*o_tv_deselectRow)(id, SEL, NSIndexPath *, BOOL);
static void (*o_tv_scrollToRow)(id, SEL, NSIndexPath *, UITableViewScrollPosition, BOOL);
static void (*o_tv_scrollNearest)(id, SEL, UITableViewScrollPosition, BOOL);
static void (*o_tv_reloadData)(id, SEL);
static void (*o_tv_reloadRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void (*o_tv_reloadSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void (*o_tv_insertRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void (*o_tv_deleteRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void (*o_tv_moveRow)(id, SEL, NSIndexPath *, NSIndexPath *);
static void (*o_tv_insertSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void (*o_tv_deleteSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void (*o_tv_moveSection)(id, SEL, NSUInteger, NSUInteger);
static void (*o_tv_setEditing)(id, SEL, BOOL, BOOL);
static void (*o_tv_batchUpdates)(id, SEL, void (^)(void), void (^)(BOOL));
// UICollectionView
static void (*o_cv_reloadData)(id, SEL);
static void (*o_cv_reloadItems)(id, SEL, NSArray *);
static void (*o_cv_reloadSections)(id, SEL, NSArray *);
static void (*o_cv_insertItems)(id, SEL, NSArray *);
static void (*o_cv_deleteItems)(id, SEL, NSArray *);
static void (*o_cv_moveItem)(id, SEL, NSIndexPath *, NSIndexPath *);
static void (*o_cv_scrollToItem)(id, SEL, NSIndexPath *, UICollectionViewScrollPosition, BOOL);
static void (*o_cv_selectItem)(id, SEL, NSIndexPath *, BOOL, UICollectionViewScrollPosition);
static void (*o_cv_deselectItem)(id, SEL, NSIndexPath *, BOOL);
static void (*o_cv_batchUpdates)(id, SEL, void (^)(void), void (^)(BOOL));
static void (*o_cv_setLayout)(id, SEL, id, BOOL);
static void (*o_cv_setLayoutComp)(id, SEL, id, BOOL, void (^)(BOOL));

#pragma mark - UITableView

static void sio_tv_selectRow(id self, SEL _cmd, NSIndexPath *ip, BOOL anim, UITableViewScrollPosition pos) {
    SIO_REQUIRE_ORIG(o_tv_selectRow);
    if (!SIO_listOK()) { o_tv_selectRow(self, _cmd, ip, anim, pos); return; }
    SIOWrapDefault(^{ o_tv_selectRow(self, _cmd, ip, anim, pos); });
}
static void sio_tv_deselectRow(id self, SEL _cmd, NSIndexPath *ip, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tv_deselectRow);
    if (!SIO_listOK()) { o_tv_deselectRow(self, _cmd, ip, anim); return; }
    SIOWrapDefault(^{ o_tv_deselectRow(self, _cmd, ip, anim); });
}
static void sio_tv_scrollToRow(id self, SEL _cmd, NSIndexPath *ip, UITableViewScrollPosition pos, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tv_scrollToRow);
    if (!SIO_listOK()) { o_tv_scrollToRow(self, _cmd, ip, pos, anim); return; }
    SIOWrapDefault(^{ o_tv_scrollToRow(self, _cmd, ip, pos, anim); });
}
static void sio_tv_scrollNearest(id self, SEL _cmd, UITableViewScrollPosition pos, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tv_scrollNearest);
    if (!SIO_listOK()) { o_tv_scrollNearest(self, _cmd, pos, anim); return; }
    SIOWrapDefault(^{ o_tv_scrollNearest(self, _cmd, pos, anim); });
}
static void sio_tv_reloadData(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_tv_reloadData);
    if (!SIO_listOK()) { o_tv_reloadData(self, _cmd); return; }
    SIOWrapDefault(^{ o_tv_reloadData(self, _cmd); });
}
static void sio_tv_reloadRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_reloadRows);
    if (!SIO_listOK()) { o_tv_reloadRows(self, _cmd, ips, a); return; }
    SIOWrapDefault(^{ o_tv_reloadRows(self, _cmd, ips, a); });
}
static void sio_tv_reloadSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_reloadSections);
    if (!SIO_listOK()) { o_tv_reloadSections(self, _cmd, sec, a); return; }
    SIOWrapDefault(^{ o_tv_reloadSections(self, _cmd, sec, a); });
}
static void sio_tv_insertRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_insertRows);
    if (!SIO_listOK()) { o_tv_insertRows(self, _cmd, ips, a); return; }
    SIOWrapDefault(^{ o_tv_insertRows(self, _cmd, ips, a); });
}
static void sio_tv_deleteRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_deleteRows);
    if (!SIO_listOK()) { o_tv_deleteRows(self, _cmd, ips, a); return; }
    SIOWrapDefault(^{ o_tv_deleteRows(self, _cmd, ips, a); });
}
static void sio_tv_moveRow(id self, SEL _cmd, NSIndexPath *from, NSIndexPath *to) {
    SIO_REQUIRE_ORIG(o_tv_moveRow);
    if (!SIO_listOK()) { o_tv_moveRow(self, _cmd, from, to); return; }
    SIOWrapDefault(^{ o_tv_moveRow(self, _cmd, from, to); });
}
static void sio_tv_insertSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_insertSections);
    if (!SIO_listOK()) { o_tv_insertSections(self, _cmd, sec, a); return; }
    SIOWrapDefault(^{ o_tv_insertSections(self, _cmd, sec, a); });
}
static void sio_tv_deleteSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_deleteSections);
    if (!SIO_listOK()) { o_tv_deleteSections(self, _cmd, sec, a); return; }
    SIOWrapDefault(^{ o_tv_deleteSections(self, _cmd, sec, a); });
}
static void sio_tv_moveSection(id self, SEL _cmd, NSUInteger from, NSUInteger to) {
    SIO_REQUIRE_ORIG(o_tv_moveSection);
    if (!SIO_listOK()) { o_tv_moveSection(self, _cmd, from, to); return; }
    SIOWrapDefault(^{ o_tv_moveSection(self, _cmd, from, to); });
}
static void sio_tv_setEditing(id self, SEL _cmd, BOOL editing, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tv_setEditing);
    if (!SIO_listOK()) { o_tv_setEditing(self, _cmd, editing, anim); return; }
    SIOWrapDefault(^{ o_tv_setEditing(self, _cmd, editing, anim); });
}
static void sio_tv_batchUpdates(id self, SEL _cmd, void (^u)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_tv_batchUpdates);
    if (!SIO_listOK()) { o_tv_batchUpdates(self, _cmd, u, c); return; }
    SIOWrapDefault(^{ o_tv_batchUpdates(self, _cmd, u, c); });
}

#pragma mark - UICollectionView

static void sio_cv_reloadData(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_cv_reloadData);
    if (!SIO_listOK()) { o_cv_reloadData(self, _cmd); return; }
    SIOWrapDefault(^{ o_cv_reloadData(self, _cmd); });
}
static void sio_cv_reloadItems(id self, SEL _cmd, NSArray *ips) {
    SIO_REQUIRE_ORIG(o_cv_reloadItems);
    if (!SIO_listOK()) { o_cv_reloadItems(self, _cmd, ips); return; }
    SIOWrapDefault(^{ o_cv_reloadItems(self, _cmd, ips); });
}
static void sio_cv_reloadSections(id self, SEL _cmd, NSArray *secs) {
    SIO_REQUIRE_ORIG(o_cv_reloadSections);
    if (!SIO_listOK()) { o_cv_reloadSections(self, _cmd, secs); return; }
    SIOWrapDefault(^{ o_cv_reloadSections(self, _cmd, secs); });
}
static void sio_cv_insertItems(id self, SEL _cmd, NSArray *ips) {
    SIO_REQUIRE_ORIG(o_cv_insertItems);
    if (!SIO_listOK()) { o_cv_insertItems(self, _cmd, ips); return; }
    SIOWrapDefault(^{ o_cv_insertItems(self, _cmd, ips); });
}
static void sio_cv_deleteItems(id self, SEL _cmd, NSArray *ips) {
    SIO_REQUIRE_ORIG(o_cv_deleteItems);
    if (!SIO_listOK()) { o_cv_deleteItems(self, _cmd, ips); return; }
    SIOWrapDefault(^{ o_cv_deleteItems(self, _cmd, ips); });
}
static void sio_cv_moveItem(id self, SEL _cmd, NSIndexPath *from, NSIndexPath *to) {
    SIO_REQUIRE_ORIG(o_cv_moveItem);
    if (!SIO_listOK()) { o_cv_moveItem(self, _cmd, from, to); return; }
    SIOWrapDefault(^{ o_cv_moveItem(self, _cmd, from, to); });
}
static void sio_cv_scrollToItem(id self, SEL _cmd, NSIndexPath *ip, UICollectionViewScrollPosition pos, BOOL anim) {
    SIO_REQUIRE_ORIG(o_cv_scrollToItem);
    if (!SIO_listOK()) { o_cv_scrollToItem(self, _cmd, ip, pos, anim); return; }
    SIOWrapDefault(^{ o_cv_scrollToItem(self, _cmd, ip, pos, anim); });
}
static void sio_cv_selectItem(id self, SEL _cmd, NSIndexPath *ip, BOOL anim, UICollectionViewScrollPosition pos) {
    SIO_REQUIRE_ORIG(o_cv_selectItem);
    if (!SIO_listOK()) { o_cv_selectItem(self, _cmd, ip, anim, pos); return; }
    SIOWrapDefault(^{ o_cv_selectItem(self, _cmd, ip, anim, pos); });
}
static void sio_cv_deselectItem(id self, SEL _cmd, NSIndexPath *ip, BOOL anim) {
    SIO_REQUIRE_ORIG(o_cv_deselectItem);
    if (!SIO_listOK()) { o_cv_deselectItem(self, _cmd, ip, anim); return; }
    SIOWrapDefault(^{ o_cv_deselectItem(self, _cmd, ip, anim); });
}
static void sio_cv_batchUpdates(id self, SEL _cmd, void (^u)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_cv_batchUpdates);
    if (!SIO_listOK()) { o_cv_batchUpdates(self, _cmd, u, c); return; }
    SIOWrapDefault(^{ o_cv_batchUpdates(self, _cmd, u, c); });
}
static void sio_cv_setLayout(id self, SEL _cmd, id layout, BOOL anim) {
    SIO_REQUIRE_ORIG(o_cv_setLayout);
    if (!SIO_listOK() || !anim) { o_cv_setLayout(self, _cmd, layout, anim); return; }
    SIOWrapDefault(^{ o_cv_setLayout(self, _cmd, layout, anim); });
}
static void sio_cv_setLayoutComp(id self, SEL _cmd, id layout, BOOL anim, void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_cv_setLayoutComp);
    if (!SIO_listOK() || !anim) { o_cv_setLayoutComp(self, _cmd, layout, anim, c); return; }
    SIOWrapDefault(^{ o_cv_setLayoutComp(self, _cmd, layout, anim, c); });
}

#pragma mark - 安装表

// 列表族全部是 kSIOStageOnDemand：ListAccel 关闭时**一次交换都不做**。
// 安装器会在 stage=OnDemand 且 SIO_listOK() 为真时才执行 ——
// 也就是说「装不装」与「跑不跑」由同一个门控决定，不会出现「装了但永远不生效」。
extern const SIOHookEntry *SIOCollectionsEntries(NSUInteger *count);
static const SIOHookEntry kSIOCollectionsEntries[] = {
    { "UITableView", "selectRowAtIndexPath:animated:scrollPosition:", NO, (IMP)sio_tv_selectRow, (IMP *)&o_tv_selectRow, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UITableView", "deselectRowAtIndexPath:animated:", NO, (IMP)sio_tv_deselectRow, (IMP *)&o_tv_deselectRow, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UITableView", "scrollToRowAtIndexPath:atScrollPosition:animated:", NO, (IMP)sio_tv_scrollToRow, (IMP *)&o_tv_scrollToRow, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UITableView", "scrollToNearestSelectedRowAtScrollPosition:animated:", NO, (IMP)sio_tv_scrollNearest, (IMP *)&o_tv_scrollNearest, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UITableView", "reloadData", NO, (IMP)sio_tv_reloadData, (IMP *)&o_tv_reloadData, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UITableView", "reloadRowsAtIndexPaths:withRowAnimation:", NO, (IMP)sio_tv_reloadRows, (IMP *)&o_tv_reloadRows, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UITableView", "reloadSections:withRowAnimation:", NO, (IMP)sio_tv_reloadSections, (IMP *)&o_tv_reloadSections, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UITableView", "insertRowsAtIndexPaths:withRowAnimation:", NO, (IMP)sio_tv_insertRows, (IMP *)&o_tv_insertRows, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UITableView", "deleteRowsAtIndexPaths:withRowAnimation:", NO, (IMP)sio_tv_deleteRows, (IMP *)&o_tv_deleteRows, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UITableView", "moveRowAtIndexPath:toIndexPath:", NO, (IMP)sio_tv_moveRow, (IMP *)&o_tv_moveRow, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UITableView", "insertSections:withRowAnimation:", NO, (IMP)sio_tv_insertSections, (IMP *)&o_tv_insertSections, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UITableView", "deleteSections:withRowAnimation:", NO, (IMP)sio_tv_deleteSections, (IMP *)&o_tv_deleteSections, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UITableView", "moveSection:toSection:", NO, (IMP)sio_tv_moveSection, (IMP *)&o_tv_moveSection, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UITableView", "setEditing:animated:", NO, (IMP)sio_tv_setEditing, (IMP *)&o_tv_setEditing, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UITableView", "performBatchUpdates:completion:", NO, (IMP)sio_tv_batchUpdates, (IMP *)&o_tv_batchUpdates, kSIOStageOnDemand, NULL, 11, 0, 0, NO },
    { "UICollectionView", "reloadData", NO, (IMP)sio_cv_reloadData, (IMP *)&o_cv_reloadData, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UICollectionView", "reloadItemsAtIndexPaths:", NO, (IMP)sio_cv_reloadItems, (IMP *)&o_cv_reloadItems, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UICollectionView", "reloadSections:", NO, (IMP)sio_cv_reloadSections, (IMP *)&o_cv_reloadSections, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UICollectionView", "insertItemsAtIndexPaths:", NO, (IMP)sio_cv_insertItems, (IMP *)&o_cv_insertItems, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UICollectionView", "deleteItemsAtIndexPaths:", NO, (IMP)sio_cv_deleteItems, (IMP *)&o_cv_deleteItems, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UICollectionView", "moveItemAtIndexPath:toIndexPath:", NO, (IMP)sio_cv_moveItem, (IMP *)&o_cv_moveItem, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UICollectionView", "scrollToItemAtIndexPath:atScrollPosition:animated:", NO, (IMP)sio_cv_scrollToItem, (IMP *)&o_cv_scrollToItem, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UICollectionView", "selectItemAtIndexPath:animated:scrollPosition:", NO, (IMP)sio_cv_selectItem, (IMP *)&o_cv_selectItem, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UICollectionView", "deselectItemAtIndexPath:animated:", NO, (IMP)sio_cv_deselectItem, (IMP *)&o_cv_deselectItem, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UICollectionView", "performBatchUpdates:completion:", NO, (IMP)sio_cv_batchUpdates, (IMP *)&o_cv_batchUpdates, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UICollectionView", "setCollectionViewLayout:animated:", NO, (IMP)sio_cv_setLayout, (IMP *)&o_cv_setLayout, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
    { "UICollectionView", "setCollectionViewLayout:animated:completion:", NO, (IMP)sio_cv_setLayoutComp, (IMP *)&o_cv_setLayoutComp, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
};
const SIOHookEntry *SIOCollectionsEntries(NSUInteger *count) {
    if (count) *count = sizeof(kSIOCollectionsEntries) / sizeof(kSIOCollectionsEntries[0]);
    return kSIOCollectionsEntries;
}
