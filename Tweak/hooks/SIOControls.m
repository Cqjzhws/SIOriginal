// ============================================================================
//  hooks/SIOControls — 通用控件 / 单元格 / 模糊 view / 隐式布局动画
// ============================================================================
//  这些控件动画 UIKit 不向 App 暴露 duration，只能靠事务包裹统一改。
//  它们的共同特征：**单次动画都很短、但触发极其频繁**（按钮高亮、开关滑动、
//  滑块拖动、单元格选中）。因此这一族是「包裹优化」收益最大的地方：
//    · 加速 ×1（gSIOAnimNoop）时完全不包裹 —— 42 个包裹点零开销；
//    · 内存压力告警时被 SIOWrapDuration 自动降级。
//
//  【为什么要同时 hook UIControl 基类的 setHighlighted:/setSelected:】
//  UIButton 等子类并不各自实现这两个 setter，全部继承自 UIControl。
//  这里依赖的是 Exchange 的**继承污染防护**：本类没有实现时会在本类 add 一份，
//  orig 指向父类实现 —— 绝不会改掉 UIControl 全局实现再污染所有其它 UIView。
// ============================================================================

#import "SIOInternal.h"

#pragma mark - 原 IMP 槽位

static void (*o_switch_setOn)(id, SEL, BOOL, BOOL);
static void (*o_slider_setValue)(id, SEL, float, BOOL);
static void (*o_progress_setProgress)(id, SEL, float, BOOL);
static void (*o_picker_selectRow)(id, SEL, NSInteger, NSInteger, BOOL);
static void (*o_datePicker_setDate)(id, SEL, id, BOOL);
static void (*o_segmented_setIndex)(id, SEL, NSInteger);
static void (*o_pageControl_setPage)(id, SEL, NSInteger);
static void (*o_searchBar_setShowsCancel)(id, SEL, BOOL, BOOL);
static void (*o_stepper_setValue)(id, SEL, double, BOOL);
static void (*o_effectView_setEffect)(id, SEL, id);
static void (*o_control_setHighlighted)(id, SEL, BOOL);
static void (*o_control_setSelected)(id, SEL, BOOL);
static void (*o_tvCell_setSelected)(id, SEL, BOOL, BOOL);
static void (*o_tvCell_setHighlighted)(id, SEL, BOOL, BOOL);
static void (*o_cvCell_setSelected)(id, SEL, BOOL);
static void (*o_cvCell_setHighlighted)(id, SEL, BOOL);
static void (*o_view_layoutIfNeeded)(id, SEL);

#pragma mark - 通用控件

static void sio_switch_setOn(id self, SEL _cmd, BOOL on, BOOL animated) {
    SIO_REQUIRE_ORIG(o_switch_setOn);
    if (SIO_blocked() || !animated) { o_switch_setOn(self, _cmd, on, animated); return; }
    SIOWrapDefault(^{ o_switch_setOn(self, _cmd, on, animated); });
}
static void sio_slider_setValue(id self, SEL _cmd, float v, BOOL animated) {
    SIO_REQUIRE_ORIG(o_slider_setValue);
    if (SIO_blocked() || !animated) { o_slider_setValue(self, _cmd, v, animated); return; }
    SIOWrapDefault(^{ o_slider_setValue(self, _cmd, v, animated); });
}
static void sio_progress_setProgress(id self, SEL _cmd, float p, BOOL animated) {
    SIO_REQUIRE_ORIG(o_progress_setProgress);
    if (SIO_blocked() || !animated) { o_progress_setProgress(self, _cmd, p, animated); return; }
    SIOWrapDefault(^{ o_progress_setProgress(self, _cmd, p, animated); });
}
// UIPickerView 滚轮选行：系统默认约 0.6s，在表单页体感极其明显。
static void sio_picker_selectRow(id self, SEL _cmd, NSInteger row, NSInteger comp, BOOL animated) {
    SIO_REQUIRE_ORIG(o_picker_selectRow);
    if (SIO_blocked() || !animated) { o_picker_selectRow(self, _cmd, row, comp, animated); return; }
    SIOWrapDefault(^{ o_picker_selectRow(self, _cmd, row, comp, animated); });
}
static void sio_datePicker_setDate(id self, SEL _cmd, id date, BOOL animated) {
    SIO_REQUIRE_ORIG(o_datePicker_setDate);
    if (SIO_blocked() || !animated) { o_datePicker_setDate(self, _cmd, date, animated); return; }
    SIOWrapDefault(^{ o_datePicker_setDate(self, _cmd, date, animated); });
}
static void sio_segmented_setIndex(id self, SEL _cmd, NSInteger idx) {
    SIO_REQUIRE_ORIG(o_segmented_setIndex);
    if (SIO_blocked()) { o_segmented_setIndex(self, _cmd, idx); return; }
    SIOWrapDefault(^{ o_segmented_setIndex(self, _cmd, idx); });
}
static void sio_pageControl_setPage(id self, SEL _cmd, NSInteger page) {
    SIO_REQUIRE_ORIG(o_pageControl_setPage);
    if (SIO_blocked()) { o_pageControl_setPage(self, _cmd, page); return; }
    SIOWrapDefault(^{ o_pageControl_setPage(self, _cmd, page); });
}
static void sio_searchBar_setShowsCancel(id self, SEL _cmd, BOOL show, BOOL animated) {
    SIO_REQUIRE_ORIG(o_searchBar_setShowsCancel);
    if (SIO_blocked() || !animated) { o_searchBar_setShowsCancel(self, _cmd, show, animated); return; }
    SIOWrapDefault(^{ o_searchBar_setShowsCancel(self, _cmd, show, animated); });
}
static void sio_stepper_setValue(id self, SEL _cmd, double v, BOOL animated) {
    SIO_REQUIRE_ORIG(o_stepper_setValue);
    if (SIO_blocked() || !animated) { o_stepper_setValue(self, _cmd, v, animated); return; }
    SIOWrapDefault(^{ o_stepper_setValue(self, _cmd, v, animated); });
}
// UIVisualEffectView 毛玻璃过渡：setEffect: 内部做模糊半径动画，iOS 15+ 尤为明显。
static void sio_effectView_setEffect(id self, SEL _cmd, id effect) {
    SIO_REQUIRE_ORIG(o_effectView_setEffect);
    if (SIO_blocked()) { o_effectView_setEffect(self, _cmd, effect); return; }
    SIOWrapDefault(^{ o_effectView_setEffect(self, _cmd, effect); });
}

#pragma mark - 按压反馈（UIControl 基类）

static void sio_control_setHighlighted(id self, SEL _cmd, BOOL hl) {
    SIO_REQUIRE_ORIG(o_control_setHighlighted);
    if (SIO_blocked()) { o_control_setHighlighted(self, _cmd, hl); return; }
    SIOWrapDefault(^{ o_control_setHighlighted(self, _cmd, hl); });
}
static void sio_control_setSelected(id self, SEL _cmd, BOOL sel) {
    SIO_REQUIRE_ORIG(o_control_setSelected);
    if (SIO_blocked()) { o_control_setSelected(self, _cmd, sel); return; }
    SIOWrapDefault(^{ o_control_setSelected(self, _cmd, sel); });
}

#pragma mark - 单元格选中 / 高亮

static void sio_tvCell_setSelected(id self, SEL _cmd, BOOL sel, BOOL animated) {
    SIO_REQUIRE_ORIG(o_tvCell_setSelected);
    if (SIO_blocked() || !animated) { o_tvCell_setSelected(self, _cmd, sel, animated); return; }
    SIOWrapDefault(^{ o_tvCell_setSelected(self, _cmd, sel, animated); });
}
static void sio_tvCell_setHighlighted(id self, SEL _cmd, BOOL hl, BOOL animated) {
    SIO_REQUIRE_ORIG(o_tvCell_setHighlighted);
    if (SIO_blocked() || !animated) { o_tvCell_setHighlighted(self, _cmd, hl, animated); return; }
    SIOWrapDefault(^{ o_tvCell_setHighlighted(self, _cmd, hl, animated); });
}
static void sio_cvCell_setSelected(id self, SEL _cmd, BOOL sel) {
    SIO_REQUIRE_ORIG(o_cvCell_setSelected);
    if (SIO_blocked()) { o_cvCell_setSelected(self, _cmd, sel); return; }
    SIOWrapDefault(^{ o_cvCell_setSelected(self, _cmd, sel); });
}
static void sio_cvCell_setHighlighted(id self, SEL _cmd, BOOL hl) {
    SIO_REQUIRE_ORIG(o_cvCell_setHighlighted);
    if (SIO_blocked()) { o_cvCell_setHighlighted(self, _cmd, hl); return; }
    SIOWrapDefault(^{ o_cvCell_setHighlighted(self, _cmd, hl); });
}

#pragma mark - LayoutAccel（实验，默认关）

// v2.0.7 引入：包裹 layoutIfNeeded 以加速 SwiftUI / 自动布局的**隐式**布局动画。
// 为什么默认关：layoutIfNeeded 是 UIView 的超级热点方法，任何一次布局都会经过，
// 常态下替换只增加一层间接调用；而且把布局强制包进事务会改变某些 App 的布局时序
// （出现过约束尚未更新就提交的情况）。默认关闭是谨慎起见，实测确有需求再开。
static void sio_view_layoutIfNeeded(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_view_layoutIfNeeded);
    if (!gSIOCfg.layoutAccel || SIO_blocked()) { o_view_layoutIfNeeded(self, _cmd); return; }
    SIOWrapDefault(^{ o_view_layoutIfNeeded(self, _cmd); });
}

#pragma mark - 安装表

extern const SIOHookEntry *SIOControlsEntries(NSUInteger *count);
static const SIOHookEntry kSIOControlsEntries[] = {
    { "UISwitch", "setOn:animated:", NO, (IMP)sio_switch_setOn, (IMP *)&o_switch_setOn, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UISlider", "setValue:animated:", NO, (IMP)sio_slider_setValue, (IMP *)&o_slider_setValue, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIProgressView", "setProgress:animated:", NO, (IMP)sio_progress_setProgress, (IMP *)&o_progress_setProgress, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIPickerView", "selectRow:inComponent:animated:", NO, (IMP)sio_picker_selectRow, (IMP *)&o_picker_selectRow, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIDatePicker", "setDate:animated:", NO, (IMP)sio_datePicker_setDate, (IMP *)&o_datePicker_setDate, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UISegmentedControl", "setSelectedSegmentIndex:", NO, (IMP)sio_segmented_setIndex, (IMP *)&o_segmented_setIndex, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIPageControl", "setCurrentPage:", NO, (IMP)sio_pageControl_setPage, (IMP *)&o_pageControl_setPage, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UISearchBar", "setShowsCancelButton:animated:", NO, (IMP)sio_searchBar_setShowsCancel, (IMP *)&o_searchBar_setShowsCancel, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIStepper", "setValue:", NO, (IMP)sio_stepper_setValue, (IMP *)&o_stepper_setValue, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIVisualEffectView", "setEffect:", NO, (IMP)sio_effectView_setEffect, (IMP *)&o_effectView_setEffect, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIControl", "setHighlighted:", NO, (IMP)sio_control_setHighlighted, (IMP *)&o_control_setHighlighted, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UIControl", "setSelected:", NO, (IMP)sio_control_setSelected, (IMP *)&o_control_setSelected, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UITableViewCell", "setSelected:animated:", NO, (IMP)sio_tvCell_setSelected, (IMP *)&o_tvCell_setSelected, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UITableViewCell", "setHighlighted:animated:", NO, (IMP)sio_tvCell_setHighlighted, (IMP *)&o_tvCell_setHighlighted, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UICollectionViewCell", "setSelected:", NO, (IMP)sio_cvCell_setSelected, (IMP *)&o_cvCell_setSelected, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    { "UICollectionViewCell", "setHighlighted:", NO, (IMP)sio_cvCell_setHighlighted, (IMP *)&o_cvCell_setHighlighted, kSIOStagePostLaunch, NULL, 0, 0, 0, NO },
    // LayoutAccel：**按需**安装 —— 默认关闭时一次方法交换都不做（v2.2.0 的核心收益）
    { "UIView", "layoutIfNeeded", NO, (IMP)sio_view_layoutIfNeeded, (IMP *)&o_view_layoutIfNeeded, kSIOStageOnDemand, NULL, 0, 0, 0, NO },
};
const SIOHookEntry *SIOControlsEntries(NSUInteger *count) {
    if (count) *count = sizeof(kSIOControlsEntries) / sizeof(kSIOControlsEntries[0]);
    return kSIOControlsEntries;
}
