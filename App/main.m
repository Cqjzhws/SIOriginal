// SIOriginal — 配置 App（TrollStore 安装）
// v2.0.2：双架构 arm64+arm64e；启动注入确认 toast
// v2.0.1：修复专属开关关闭后旧覆盖仍生效、切换 Bundle 控件残留；版本同步
// v2.0.0 Max：底部 Tab 栏 UI（引擎/手感/系统/高级），新增 Floor / TransitionBoost / LongPress
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <signal.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>

#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif
extern char **environ;
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);

#ifndef RB_AUTOBOOT
#define RB_AUTOBOOT 0
#endif
extern int reboot(int);

static NSString * const PrefPath  = @"/var/Managed Preferences/mobile/com.apple.UIKit.plist";
static NSString * const NotifyKey = @"com.local.sioriginal.settingschanged";

static UIColor *SIOCyanColor(void) {
    if (@available(iOS 15.0, *)) return [UIColor systemCyanColor];
    return [UIColor colorWithRed:0.0 green:0.75 blue:0.83 alpha:1.0];
}
static UIColor *SIOMintColor(void) {
    if (@available(iOS 15.0, *)) return [UIColor systemMintColor];
    return [UIColor colorWithRed:0.0 green:0.72 blue:0.65 alpha:1.0];
}

static NSArray *HardGuardBundles(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ a = @[ @"com.apple.springboard" ]; });
    return a;
}

static void SpawnRoot(NSString *path, NSArray *args) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    pid_t pid;
    char *argv[args.count + 2];
    argv[0] = (char *)path.fileSystemRepresentation;
    for (NSUInteger i = 0; i < args.count; i++)
        argv[i + 1] = (char *)[args[i] UTF8String];
    argv[args.count + 1] = NULL;
    int rc = posix_spawn(&pid, path.fileSystemRepresentation, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (rc == 0 && pid > 0) {
        int status;
        waitpid(pid, &status, 0);
    }
}

static void SpawnRootNowait(NSString *path, NSArray *args) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    pid_t pid = -1;
    char *argv[args.count + 2];
    argv[0] = (char *)path.fileSystemRepresentation;
    for (NSUInteger i = 0; i < args.count; i++)
        argv[i + 1] = (char *)[args[i] UTF8String];
    argv[args.count + 1] = NULL;
    posix_spawn(&pid, path.fileSystemRepresentation, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
}

static NSString *SIOReboot(void) {
    pid_t pid;
    NSString *selfPath = [[NSBundle mainBundle] executablePath];
    if (selfPath.length) {
        posix_spawnattr_t attr0;
        posix_spawnattr_init(&attr0);
        posix_spawnattr_set_persona_np(&attr0, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        posix_spawnattr_set_persona_uid_np(&attr0, 0);
        posix_spawnattr_set_persona_gid_np(&attr0, 0);
        char *a0[] = { (char *)[selfPath UTF8String], "--sio-reboot-helper", NULL };
        int s0 = posix_spawn(&pid, [selfPath UTF8String], NULL, &attr0, a0, environ);
        posix_spawnattr_destroy(&attr0);
        if (s0 == 0) return @"root 助手 reboot()";
    }
    const char *paths[] = { "/usr/sbin/reboot", "/sbin/reboot" };
    for (int i = 0; i < 2; i++) {
        posix_spawnattr_t a;
        posix_spawnattr_init(&a);
        posix_spawnattr_set_persona_np(&a, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        posix_spawnattr_set_persona_uid_np(&a, 0);
        posix_spawnattr_set_persona_gid_np(&a, 0);
        char *av[] = { (char *)paths[i], NULL };
        int s = posix_spawn(&pid, paths[i], NULL, &a, av, environ);
        posix_spawnattr_destroy(&a);
        if (s == 0) return [NSString stringWithFormat:@"%s", paths[i]];
    }
    const char *kills[][3] = { {"/usr/bin/killall","-9","launchd"},
                               {"/usr/bin/killall","-9","backboardd"} };
    for (int i = 0; i < 2; i++) {
        posix_spawnattr_t a;
        posix_spawnattr_init(&a);
        posix_spawnattr_set_persona_np(&a, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        posix_spawnattr_set_persona_uid_np(&a, 0);
        posix_spawnattr_set_persona_gid_np(&a, 0);
        char *av[] = { (char *)kills[i][0], (char *)kills[i][1], (char *)kills[i][2], NULL };
        int s = posix_spawn(&pid, kills[i][0], NULL, &a, av, environ);
        posix_spawnattr_destroy(&a);
        if (s == 0) return [NSString stringWithFormat:@"%s %s", kills[i][1], kills[i][2]];
    }
    return @"全部失败";
}

static void Respring(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) == 0) {
        len += 16 * sizeof(struct kinfo_proc);
        struct kinfo_proc *list = malloc(len);
        if (list && sysctl(mib, 4, list, &len, NULL, 0) == 0) {
            int n = (int)(len / sizeof(struct kinfo_proc));
            for (int i = 0; i < n; i++)
                if (strncmp(list[i].kp_proc.p_comm, "SpringBoard", sizeof(list[i].kp_proc.p_comm)) == 0)
                    kill(list[i].kp_proc.p_pid, SIGKILL);
        }
        free(list);
    }
    SpawnRoot(@"/usr/bin/killall", @[@"-9", @"SpringBoard"]);
}

static NSMutableDictionary *ReadConfig(void) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:PrefPath] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    if (!d[@"Enabled"])          d[@"Enabled"]          = @YES;
    if (!d[@"Mode"])             d[@"Mode"]             = @0;
    if (!d[@"Speed"])            d[@"Speed"]            = @5.0;
    if (!d[@"SlowFactor"])       d[@"SlowFactor"]       = @2.0;
    if (!d[@"Spring"])           d[@"Spring"]           = @YES;
    if (!d[@"Extra"])            d[@"Extra"]            = @YES;
    if (!d[@"ListAccel"])        d[@"ListAccel"]        = @NO;
    if (!d[@"ZoomAccel"])        d[@"ZoomAccel"]        = @NO;
    if (!d[@"FastScroll"])       d[@"FastScroll"]       = @YES;
    if (!d[@"FastTap"])          d[@"FastTap"]          = @YES;
    if (!d[@"LongPress"])        d[@"LongPress"]        = @YES;
    if (!d[@"LongPressDuration"])d[@"LongPressDuration"]= @0.30;
    if (!d[@"Floor"])            d[@"Floor"]            = @0.02;
    if (!d[@"LayerBoost"])       d[@"LayerBoost"]       = @1.0;
    if (!d[@"TransitionBoost"])  d[@"TransitionBoost"]  = @1.0;
    if (!d[@"Notify"])           d[@"Notify"]           = @YES;
    if (!d[@"LayoutAccel"])      d[@"LayoutAccel"]      = @NO;
    if (!d[@"Blacklist"])        d[@"Blacklist"]        = @[ @"com.tencent.wework" ];
    if (!d[@"FUBGEnabled"])      d[@"FUBGEnabled"]      = @YES;
    if (!d[@"FUBGSceneFake"])    d[@"FUBGSceneFake"]    = @YES;
    if (!d[@"FUBGAudioKeep"])    d[@"FUBGAudioKeep"]    = @YES;
    if (!d[@"FUBGFloatingBall"]) d[@"FUBGFloatingBall"] = @NO;
    if (!d[@"AppOverrides"])     d[@"AppOverrides"]     = @{};
    return d;
}

static BOOL WriteConfig(NSMutableDictionary *cfg) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    NSMutableDictionary *merged = [[NSDictionary dictionaryWithContentsOfFile:PrefPath] mutableCopy];
    if (!merged) merged = [NSMutableDictionary dictionary];
    NSArray *sioKeys = @[ @"Enabled", @"Mode", @"Speed", @"SlowFactor",
                          @"Spring", @"Extra", @"ListAccel", @"Blacklist", @"ZoomAccel",
                          @"FastScroll", @"FastTap", @"LongPress", @"LongPressDuration",
                          @"Floor", @"LayerBoost", @"TransitionBoost", @"Notify",
                          @"LayoutAccel",
                          @"FUBGEnabled", @"FUBGSceneFake", @"FUBGAudioKeep",
                          @"FUBGFloatingBall", @"FUBGExcludeApps", @"AppOverrides" ];
    for (NSString *k in sioKeys) {
        // 注：这里用 `if (cfg[k])` 判断的是**指针非空**（Objective-C 裸 id 条件
        // 语义），不是 NSNumber 的值真伪。@NO / @0 都是 tagged pointer（非 nil），
        // 因此「关掉开关」能正确写入 @NO，不会被跳过。切勿改成 [cfg[k] boolValue]
        // 之类的值判断，否则 @NO 会被当缺失而保留旧值。
        if (cfg[k]) merged[k] = cfg[k];
    }
    BOOL ok = [merged writeToFile:PrefPath atomically:YES];
    if (ok) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)NotifyKey, NULL, NULL, YES);
    }
    return ok;
}

static NSString *ModeText(int m) {
    return m == 1 ? @"慢放" : (m == 2 ? @"瞬切" : @"加速");
}

static NSString * const AxPath = @"/var/mobile/Library/Preferences/com.apple.Accessibility.plist";
static BOOL ReadAx(NSString *key) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:AxPath];
    return d[key] ? [d[key] boolValue] : NO;
}
static void WriteAx(NSString *key, BOOL val) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:AxPath] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    d[key] = @(val);
    [d writeToFile:AxPath atomically:YES];
}

static NSString * const UIKitPath = @"/var/Managed Preferences/mobile/com.apple.UIKit.plist";

static double ReadUIKitDrag(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:UIKitPath];
    NSNumber *v = d[@"UIAnimationDragCoefficient"];
    return v ? v.doubleValue : 0.0;
}
static void WriteUIKitDrag(double coeff) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:UIKitPath] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    if (coeff > 0.0) {
        d[@"UIAnimationDragCoefficient"] = @(coeff);
    } else {
        [d removeObjectForKey:@"UIAnimationDragCoefficient"];
    }
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    [d writeToFile:UIKitPath atomically:YES];
}

static double DragCoeffForIndex(int i) {
    switch (i) {
        case 1:  return 0.2;
        case 2:  return 0.1;
        case 3:  return 0.05;
        case 4:  return 0.0001;
        default: return 0.0;
    }
}
static int DragIndexForCoeff(double c) {
    if (c > 0.04 && c < 0.06)  return 3;
    if (c > 0.08 && c < 0.12)  return 2;
    if (c > 0.15 && c < 0.25)  return 1;
    if (c > 0.0 && c < 0.04)   return 4;
    return 0;
}
static int DragMultiplierForCoeff(double c) {
    if (c > 0.04 && c < 0.06)  return 20;
    if (c > 0.08 && c < 0.12)  return 10;
    if (c > 0.15 && c < 0.25)  return 5;
    return 0;
}

static double LayerBoostForIndex(int i) {
    switch (i) {
        case 1:  return 2.0;
        case 2:  return 3.0;
        case 3:  return 5.0;
        case 4:  return 10.0;
        default: return 1.0;
    }
}
static int LayerIndexForBoost(double b) {
    if (b > 1.5 && b < 2.5)  return 1;
    if (b > 2.5 && b < 4.0)  return 2;
    if (b > 4.0 && b < 7.0)  return 3;
    if (b >= 7.0)            return 4;
    return 0;
}

static double FloorForIndex(int i) {
    switch (i) {
        case 0:  return 0.005;
        case 1:  return 0.01;
        case 2:  return 0.02;
        case 3:  return 0.05;
        default: return 0.02;
    }
}
static int FloorIndexForValue(double v) {
    if (v < 0.0075) return 0;
    if (v < 0.015)  return 1;
    if (v < 0.035)  return 2;
    return 3;
}

static double TransitionBoostForIndex(int i) {
    switch (i) {
        case 1:  return 1.5;
        case 2:  return 2.0;
        case 3:  return 3.0;
        default: return 1.0;
    }
}
static int TransitionBoostIndexForValue(double v) {
    if (v > 1.2 && v < 1.8)  return 1;
    if (v > 1.8 && v < 2.5)  return 2;
    if (v >= 2.5)            return 3;
    return 0;
}

static double LongPressDurationForIndex(int i) {
    switch (i) {
        case 0:  return 0.20;
        case 1:  return 0.30;
        case 2:  return 0.40;
        default: return 0.30;
    }
}
static int LongPressDurationIndexForValue(double v) {
    if (v < 0.25) return 0;
    if (v < 0.35) return 1;
    return 2;
}

#pragma mark - 现代化卡片容器

@interface SIOCardView : UIView
@property (nonatomic, strong) UIStackView *stack;
@end

@implementation SIOCardView
- (instancetype)init {
    if (self = [super init]) {
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        self.layer.cornerRadius = 12;
        self.layer.masksToBounds = YES;
        _stack = [[UIStackView alloc] init];
        _stack.axis = UILayoutConstraintAxisVertical;
        _stack.spacing = 0;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_stack];
        [NSLayoutConstraint activateConstraints:@[
            [_stack.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];
    }
    return self;
}
- (void)addRow:(UIView *)row isLast:(BOOL)isLast {
    if (self.stack.arrangedSubviews.count > 0) {
        UIView *sep = [[UIView alloc] init];
        sep.backgroundColor = [UIColor separatorColor];
        sep.translatesAutoresizingMaskIntoConstraints = NO;
        [self.stack addArrangedSubview:sep];
        [sep.heightAnchor constraintEqualToConstant:0.5].active = YES;
        [sep.leadingAnchor constraintEqualToAnchor:self.stack.leadingAnchor constant:16].active = YES;
    }
    [self.stack addArrangedSubview:row];
}
@end

#pragma mark - 设置行视图

@interface SIOSettingRow : UIView
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *control;
@end

@implementation SIOSettingRow
- (instancetype)initWithTitle:(NSString *)title icon:(NSString *)iconName iconColor:(UIColor *)color control:(UIView *)ctrl {
    if (self = [super init]) {
        self.backgroundColor = [UIColor clearColor];
        _iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:iconName]];
        _iconView.tintColor = color;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:16];
        _titleLabel.textColor = [UIColor labelColor];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        UIView *content = [[UIView alloc] init];
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_iconView];
        [content addSubview:_titleLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_iconView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
            [_iconView.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:28],
            [_iconView.heightAnchor constraintEqualToConstant:28],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
            [content.heightAnchor constraintEqualToConstant:50],
        ]];
        UIStackView *h = [[UIStackView alloc] initWithArrangedSubviews:@[content, ctrl ?: [UIView new]]];
        h.axis = UILayoutConstraintAxisHorizontal;
        h.alignment = UIStackViewAlignmentCenter;
        h.spacing = 12;
        h.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:h];
        [NSLayoutConstraint activateConstraints:@[
            [h.topAnchor constraintEqualToAnchor:self.topAnchor],
            [h.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [h.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [h.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];
        _control = ctrl;
    }
    return self;
}
@end

#pragma mark - Section Header

@interface SIOSectionHeader : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation SIOSectionHeader
- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    if (self = [super init]) {
        self.backgroundColor = [UIColor clearColor];
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:13];
        _titleLabel.textColor = [UIColor secondaryLabelColor];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_titleLabel];
        if (subtitle) {
            UILabel *sub = [[UILabel alloc] init];
            sub.text = subtitle;
            sub.font = [UIFont systemFontOfSize:12];
            sub.textColor = [UIColor tertiaryLabelColor];
            sub.numberOfLines = 0;
            sub.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:sub];
            [NSLayoutConstraint activateConstraints:@[
                [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
                [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
                [sub.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
                [sub.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
                [sub.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
                [sub.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
            ]];
        } else {
            [NSLayoutConstraint activateConstraints:@[
                [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
                [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
                [_titleLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
            ]];
        }
    }
    return self;
}
@end

#pragma mark - 主视图控制器

typedef NS_ENUM(NSInteger, SIOTabType) {
    SIOTabEngine = 0,
    SIOTabFeel,
    SIOTabSystem,
    SIOTabAdvanced,
};

@interface SIOVC : UIViewController
- (instancetype)initWithTab:(SIOTabType)tab;
@end

@interface SIOVC () {
    SIOTabType _tab;
    // 引擎
    UISwitch *_swEnabled;
    UISegmentedControl *_segMode;
    UISlider *_slider, *_sliderSlow;
    UILabel *_sliderLabel, *_sliderSlowLabel;
    UISegmentedControl *_segFloor, *_segLayer, *_segTrans;
    UILabel *_floorHint, *_layerHint, *_transHint;
    // 手感
    UISwitch *_swFastScroll, *_swFastTap, *_swLongPress, *_swZoom, *_swList, *_swNotify, *_swLayout;
    UISegmentedControl *_segLongPress;
    UITextView *_blacklist;
    // 系统
    UISwitch *_swFUBG, *_swFUBGScene, *_swFUBGAudio, *_swFUBGBall;
    UISwitch *_swRM, *_swCF, *_swRT;
    UISegmentedControl *_segDrag;
    UILabel *_dragHint;
    // 高级 - App覆盖
    UITextField *_ovBundle;
    UISwitch *_ovOn, *_ovSpring, *_ovExtra, *_ovList, *_ovZoom, *_ovFastScroll, *_ovFastTap, *_ovLongPress, *_ovLayout;
    UISegmentedControl *_ovLayer, *_ovMode, *_ovFloor, *_ovTrans, *_ovLongPressDur;
    UISlider *_ovSpeed;
    UILabel *_ovSpeedLabel, *_ovGuard;
    // 高级 - 自检
    UILabel *_selfCheck;
}
@end

@implementation SIOVC

- (instancetype)initWithTab:(SIOTabType)tab {
    if (self = [super init]) { _tab = tab; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    UIStackView *mainStack = [[UIStackView alloc] init];
    mainStack.axis = UILayoutConstraintAxisVertical;
    mainStack.spacing = 20;
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:mainStack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [mainStack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [mainStack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [mainStack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:16],
        [mainStack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-16],
        [mainStack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    NSMutableDictionary *cfg = ReadConfig();

    switch (_tab) {
        case SIOTabEngine:   [self buildEngine:cfg stack:mainStack]; break;
        case SIOTabFeel:     [self buildFeel:cfg stack:mainStack]; break;
        case SIOTabSystem:   [self buildSystem:cfg stack:mainStack]; break;
        case SIOTabAdvanced: [self buildAdvanced:cfg stack:mainStack]; break;
    }
}

- (UILabel *)label:(NSString *)t size:(CGFloat)s dim:(BOOL)dim {
    UILabel *l = [[UILabel alloc] init];
    l.text = t;
    l.font = [UIFont systemFontOfSize:s];
    l.textColor = dim ? [UIColor secondaryLabelColor] : [UIColor labelColor];
    l.numberOfLines = 0;
    return l;
}

- (UIView *)hintRow:(UILabel *)label {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:row.topAnchor constant:8],
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-8],
    ]];
    return row;
}

#pragma mark - 引擎 Tab

- (void)buildEngine:(NSDictionary *)cfg stack:(UIStackView *)stack {
    self.title = @"引擎";
    double speed = [cfg[@"Speed"] doubleValue];
    double slowFactor = [cfg[@"SlowFactor"] doubleValue];

    // Hero 卡片
    UIView *hero = [[UIView alloc] init];
    hero.translatesAutoresizingMaskIntoConstraints = NO;
    hero.layer.cornerRadius = 16;
    hero.layer.masksToBounds = YES;
    hero.backgroundColor = [UIColor colorWithRed:0.08 green:0.28 blue:0.20 alpha:1.0];
    [hero.heightAnchor constraintEqualToConstant:90].active = YES;

    UILabel *heroTitle = [[UILabel alloc] init];
    heroTitle.text = @"隔壁老王·王灿专用";
    heroTitle.font = [UIFont boldSystemFontOfSize:22];
    heroTitle.textColor = [UIColor whiteColor];
    heroTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [hero addSubview:heroTitle];

    UILabel *heroSub = [[UILabel alloc] init];
    heroSub.text = @"SIOriginal v2.0.7 Max · 动画加速超强版";
    heroSub.font = [UIFont systemFontOfSize:12];
    heroSub.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    heroSub.translatesAutoresizingMaskIntoConstraints = NO;
    [hero addSubview:heroSub];

    [NSLayoutConstraint activateConstraints:@[
        [heroTitle.topAnchor constraintEqualToAnchor:hero.topAnchor constant:18],
        [heroTitle.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:18],
        [heroSub.topAnchor constraintEqualToAnchor:heroTitle.bottomAnchor constant:4],
        [heroSub.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:18],
    ]];
    [stack addArrangedSubview:hero];

    // 一键预设
    UILabel *presetLabel = [self label:@"一键预设（点击立即套用并保存）" size:13 dim:YES];
    [stack addArrangedSubview:presetLabel];

    UIStackView *presetRow = [[UIStackView alloc] init];
    presetRow.axis = UILayoutConstraintAxisHorizontal;
    presetRow.spacing = 10;
    presetRow.distribution = UIStackViewDistributionFillEqually;
    NSArray *presets = @[
        @{ @"title": @"极速", @"icon": @"bolt.fill",   @"color": [UIColor systemGreenColor] },
        @{ @"title": @"均衡", @"icon": @"scalemass",   @"color": [UIColor systemBlueColor] },
        @{ @"title": @"保守", @"icon": @"shield.fill",  @"color": [UIColor systemOrangeColor] },
        @{ @"title": @"瞬切", @"icon": @"bolt.horizontal", @"color": [UIColor systemYellowColor] },
    ];
    for (int i = 0; i < 4; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:presets[i][@"title"] forState:UIControlStateNormal];
        [b setImage:[UIImage systemImageNamed:presets[i][@"icon"]] forState:UIControlStateNormal];
        b.tintColor = [UIColor whiteColor];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.backgroundColor = presets[i][@"color"];
        b.layer.cornerRadius = 12;
        b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        b.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 0);
        b.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 6);
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [b.heightAnchor constraintEqualToConstant:40].active = YES;
        b.tag = i;
        [b addTarget:self action:@selector(presetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [presetRow addArrangedSubview:b];
    }
    [stack addArrangedSubview:presetRow];

    // 基础设置卡片
    SIOCardView *c1 = [[SIOCardView alloc] init];
    _swEnabled = [[UISwitch alloc] init];
    _swEnabled.on = [cfg[@"Enabled"] boolValue];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"启用动画引擎" icon:@"bolt.fill" iconColor:[UIColor systemGreenColor] control:_swEnabled] isLast:NO];

    _segMode = [[UISegmentedControl alloc] initWithItems:@[ @"加速", @"慢放", @"瞬切" ]];
    _segMode.selectedSegmentIndex = [cfg[@"Mode"] intValue];
    [_segMode addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"模式" icon:@"gearshape.fill" iconColor:[UIColor systemBlueColor] control:_segMode] isLast:NO];

    _sliderLabel = [self label:[NSString stringWithFormat:@"×%.1f", speed] size:15 dim:YES];
    _slider = [[UISlider alloc] init];
    _slider.minimumValue = 1.0; _slider.maximumValue = 50.0;
    _slider.value = speed;
    [_slider addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
    [_slider.widthAnchor constraintEqualToConstant:140].active = YES;
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"加速倍率" icon:@"speedometer" iconColor:[UIColor systemGreenColor] control:_slider] isLast:NO];

    _sliderSlowLabel = [self label:[NSString stringWithFormat:@"×%.1f", slowFactor] size:15 dim:YES];
    _sliderSlow = [[UISlider alloc] init];
    _sliderSlow.minimumValue = 1.0; _sliderSlow.maximumValue = 10.0;
    _sliderSlow.value = slowFactor;
    [_sliderSlow addTarget:self action:@selector(slowSliderChanged) forControlEvents:UIControlEventValueChanged];
    [_sliderSlow.widthAnchor constraintEqualToConstant:140].active = YES;
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"慢放倍率" icon:@"tortoise.fill" iconColor:[UIColor systemOrangeColor] control:_sliderSlow] isLast:YES];
    [stack addArrangedSubview:c1];

    // 动画时长下限
    [stack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"动画时长下限" subtitle:nil]];
    SIOCardView *c2 = [[SIOCardView alloc] init];
    _segFloor = [[UISegmentedControl alloc] initWithItems:@[ @"0.005", @"0.01", @"0.02", @"0.05" ]];
    _segFloor.selectedSegmentIndex = FloorIndexForValue([cfg[@"Floor"] doubleValue]);
    [_segFloor addTarget:self action:@selector(floorChanged) forControlEvents:UIControlEventValueChanged];
    [c2 addRow:[[SIOSettingRow alloc] initWithTitle:@"时长下限（秒）" icon:@"timer" iconColor:[UIColor systemOrangeColor] control:_segFloor] isLast:NO];
    _floorHint = [self label:@"" size:12 dim:YES];
    _floorHint.numberOfLines = 0;
    [c2 addRow:[self hintRow:_floorHint] isLast:YES];
    [stack addArrangedSubview:c2];
    [self updateFloorHint];

    // 显式动画额外倍率
    [stack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"显式动画额外倍率" subtitle:nil]];
    SIOCardView *c3 = [[SIOCardView alloc] init];
    _segLayer = [[UISegmentedControl alloc] initWithItems:@[ @"×1", @"×2", @"×3", @"×5", @"×10" ]];
    _segLayer.selectedSegmentIndex = LayerIndexForBoost([cfg[@"LayerBoost"] doubleValue]);
    [_segLayer addTarget:self action:@selector(layerChanged) forControlEvents:UIControlEventValueChanged];
    [c3 addRow:[[SIOSettingRow alloc] initWithTitle:@"显式倍率" icon:@"layers.fill" iconColor:SIOCyanColor() control:_segLayer] isLast:NO];
    _layerHint = [self label:@"" size:12 dim:YES];
    _layerHint.numberOfLines = 0;
    [c3 addRow:[self hintRow:_layerHint] isLast:YES];
    [stack addArrangedSubview:c3];
    [self updateLayerHint];

    // 转场独立额外倍率
    [stack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"转场独立额外倍率" subtitle:nil]];
    SIOCardView *c4 = [[SIOCardView alloc] init];
    _segTrans = [[UISegmentedControl alloc] initWithItems:@[ @"×1", @"×1.5", @"×2", @"×3" ]];
    _segTrans.selectedSegmentIndex = TransitionBoostIndexForValue([cfg[@"TransitionBoost"] doubleValue]);
    [_segTrans addTarget:self action:@selector(transChanged) forControlEvents:UIControlEventValueChanged];
    [c4 addRow:[[SIOSettingRow alloc] initWithTitle:@"转场倍率" icon:@"rectangle.on.rectangle" iconColor:[UIColor systemIndigoColor] control:_segTrans] isLast:NO];
    _transHint = [self label:@"" size:12 dim:YES];
    _transHint.numberOfLines = 0;
    [c4 addRow:[self hintRow:_transHint] isLast:YES];
    [stack addArrangedSubview:c4];
    [self updateTransHint];

    [self modeChanged];
}

- (void)presetTapped:(UIButton *)sender {
    int idx = (int)sender.tag;
    switch (idx) {
        case 0: // 极速
            _segMode.selectedSegmentIndex = 0;
            _slider.value = 50.0;
            _segFloor.selectedSegmentIndex = 0;
            _segLayer.selectedSegmentIndex = 4;
            _segTrans.selectedSegmentIndex = 3;
            break;
        case 1: // 均衡
            _segMode.selectedSegmentIndex = 0;
            _slider.value = 5.0;
            _segFloor.selectedSegmentIndex = 2;
            _segLayer.selectedSegmentIndex = 1;
            _segTrans.selectedSegmentIndex = 1;
            break;
        case 2: // 保守
            _segMode.selectedSegmentIndex = 0;
            _slider.value = 2.0;
            _segFloor.selectedSegmentIndex = 3;
            _segLayer.selectedSegmentIndex = 0;
            _segTrans.selectedSegmentIndex = 0;
            break;
        case 3: // 瞬切
            _segMode.selectedSegmentIndex = 2;
            _segFloor.selectedSegmentIndex = 1;
            _segLayer.selectedSegmentIndex = 0;
            _segTrans.selectedSegmentIndex = 0;
            break;
    }
    [self modeChanged];
    [self sliderChanged];
    [self updateFloorHint];
    [self updateLayerHint];
    [self updateTransHint];
    [self onSave];
}

#pragma mark - 手感 Tab

- (void)buildFeel:(NSDictionary *)cfg stack:(UIStackView *)stack {
    self.title = @"手感·列表";

    // 交互跟手
    [stack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"交互跟手" subtitle:nil]];
    SIOCardView *c1 = [[SIOCardView alloc] init];
    _swFastScroll = [[UISwitch alloc] init];
    _swFastScroll.on = [cfg[@"FastScroll"] boolValue];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"滑行惯性加急（setter 强黏，防 App 改回）" icon:@"hand.swipe.left.fill" iconColor:[UIColor systemOrangeColor] control:_swFastScroll] isLast:NO];
    _swFastTap = [[UISwitch alloc] init];
    _swFastTap.on = [cfg[@"FastTap"] boolValue];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"点击零延迟（delaysContentTouches 强黏）" icon:@"hand.tap.fill" iconColor:[UIColor systemPinkColor] control:_swFastTap] isLast:NO];
    _swLongPress = [[UISwitch alloc] init];
    _swLongPress.on = [cfg[@"LongPress"] boolValue];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"长按手势加速（系统默认 0.5s 下压）" icon:@"hand.point.up.left.fill" iconColor:[UIColor systemTealColor] control:_swLongPress] isLast:NO];
    _segLongPress = [[UISegmentedControl alloc] initWithItems:@[ @"0.20s", @"0.30s", @"0.40s" ]];
    _segLongPress.selectedSegmentIndex = LongPressDurationIndexForValue([cfg[@"LongPressDuration"] doubleValue]);
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"长按触发时长" icon:@"timer" iconColor:[UIColor systemTealColor] control:_segLongPress] isLast:NO];
    _swNotify = [[UISwitch alloc] init];
    _swNotify.on = [cfg[@"Notify"] boolValue];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"保存后在目标 App 顶部弹生效提示" icon:@"bell.fill" iconColor:[UIColor systemRedColor] control:_swNotify] isLast:YES];
    [stack addArrangedSubview:c1];

    // 滚动 / 缩放
    [stack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"滚动 / 缩放" subtitle:nil]];
    SIOCardView *c2 = [[SIOCardView alloc] init];
    _swZoom = [[UISwitch alloc] init];
    _swZoom.on = [cfg[@"ZoomAccel"] boolValue];
    [c2 addRow:[[SIOSettingRow alloc] initWithTitle:@"缩放动画加速（实验，图片预览异常就关）" icon:@"magnifyingglass" iconColor:[UIColor systemTealColor] control:_swZoom] isLast:NO];
    _swLayout = [[UISwitch alloc] init];
    _swLayout.on = [cfg[@"LayoutAccel"] boolValue];
    [c2 addRow:[[SIOSettingRow alloc] initWithTitle:@"布局动画加速（实验，SwiftUI/约束布局）" icon:@"squareshape.split.3x3" iconColor:[UIColor systemIndigoColor] control:_swLayout] isLast:YES];
    [stack addArrangedSubview:c2];

    // 高危项
    [stack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"高危项" subtitle:nil]];
    SIOCardView *c3 = [[SIOCardView alloc] init];
    _swList = [[UISwitch alloc] init];
    _swList.on = [cfg[@"ListAccel"] boolValue];
    _swList.onTintColor = [UIColor systemRedColor];
    [c3 addRow:[[SIOSettingRow alloc] initWithTitle:@"列表加速 TV/CV" icon:@"list.bullet" iconColor:[UIColor systemRedColor] control:_swList] isLast:NO];
    UILabel *listWarn = [self label:@"⚠️ 硬保护名单：桌面进程 com.apple.springboard — 列表加速恒为关闭，任何配置都打不开（SpringBoard 打开会黑屏/白苹果）。淘宝/京东等重列表 App 也建议保持关闭。" size:12 dim:YES];
    listWarn.textColor = [UIColor systemOrangeColor];
    [c3 addRow:[self hintRow:listWarn] isLast:YES];
    [stack addArrangedSubview:c3];

    // 黑名单
    [stack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"黑名单（每行一个 Bundle ID，命中则完全不加速）" subtitle:nil]];
    SIOCardView *c4 = [[SIOCardView alloc] init];
    _blacklist = [[UITextView alloc] init];
    _blacklist.translatesAutoresizingMaskIntoConstraints = NO;
    _blacklist.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _blacklist.layer.borderColor = [UIColor separatorColor].CGColor;
    _blacklist.layer.borderWidth = 0.5;
    _blacklist.layer.cornerRadius = 8;
    _blacklist.text = [cfg[@"Blacklist"] componentsJoinedByString:@"\n"];
    [_blacklist.heightAnchor constraintEqualToConstant:100].active = YES;
    UIView *blRow = [[UIView alloc] init];
    blRow.translatesAutoresizingMaskIntoConstraints = NO;
    [blRow addSubview:_blacklist];
    [NSLayoutConstraint activateConstraints:@[
        [_blacklist.topAnchor constraintEqualToAnchor:blRow.topAnchor constant:12],
        [_blacklist.leadingAnchor constraintEqualToAnchor:blRow.leadingAnchor constant:16],
        [_blacklist.trailingAnchor constraintEqualToAnchor:blRow.trailingAnchor constant:-16],
        [_blacklist.bottomAnchor constraintEqualToAnchor:blRow.bottomAnchor constant:-12],
    ]];
    [c4 addRow:blRow isLast:YES];
    [stack addArrangedSubview:c4];
}

#pragma mark - 系统 Tab

- (void)buildSystem:(NSDictionary *)cfg stack:(UIStackView *)stack {
    self.title = @"保活·系统";

    // 真后台保活
    [stack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"真后台保活（FUBackground v2.0）" subtitle:nil]];
    SIOCardView *c1 = [[SIOCardView alloc] init];
    _swFUBG = [[UISwitch alloc] init];
    _swFUBG.on = [cfg[@"FUBGEnabled"] boolValue];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"启用真后台保活" icon:@"battery.100.bolt" iconColor:[UIColor systemGreenColor] control:_swFUBG] isLast:NO];
    _swFUBGScene = [[UISwitch alloc] init];
    _swFUBGScene.on = [cfg[@"FUBGSceneFake"] boolValue];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"场景伪装引擎（推荐）" icon:@"theatermasks.fill" iconColor:[UIColor systemIndigoColor] control:_swFUBGScene] isLast:NO];
    _swFUBGAudio = [[UISwitch alloc] init];
    _swFUBGAudio.on = [cfg[@"FUBGAudioKeep"] boolValue];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"音频断言兜底（静音白噪）" icon:@"speaker.wave.2.fill" iconColor:[UIColor systemOrangeColor] control:_swFUBGAudio] isLast:NO];
    _swFUBGBall = [[UISwitch alloc] init];
    _swFUBGBall.on = [cfg[@"FUBGFloatingBall"] boolValue];
    _swFUBGBall.enabled = NO;
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"悬浮球（已全局禁用）" icon:@"circle.fill" iconColor:[UIColor systemGrayColor] control:_swFUBGBall] isLast:YES];
    [stack addArrangedSubview:c1];

    // 系统动态效果
    [stack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"系统动态效果（写入辅助功能，需注销生效）" subtitle:nil]];
    SIOCardView *c2 = [[SIOCardView alloc] init];
    _swRM = [[UISwitch alloc] init];
    _swRM.on = ReadAx(@"ReduceMotionEnabled");
    [c2 addRow:[[SIOSettingRow alloc] initWithTitle:@"减弱动态效果（系统级）" icon:@"tortoise.fill" iconColor:[UIColor systemGrayColor] control:_swRM] isLast:NO];
    _swCF = [[UISwitch alloc] init];
    _swCF.on = ReadAx(@"PreferCrossFadeTransitions");
    [c2 addRow:[[SIOSettingRow alloc] initWithTitle:@"首选交叉淡出过渡" icon:@"arrow.triangle.2.circlepath" iconColor:[UIColor systemGrayColor] control:_swCF] isLast:NO];
    _swRT = [[UISwitch alloc] init];
    _swRT.on = ReadAx(@"ReduceTransparencyEnabled");
    [c2 addRow:[[SIOSettingRow alloc] initWithTitle:@"减少透明度（关毛玻璃，降 GPU 负载）" icon:@"circle.lefthalf.filled" iconColor:[UIColor systemGrayColor] control:_swRT] isLast:YES];
    [stack addArrangedSubview:c2];

    // UIKit 全局动画系数
    [stack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"UIKit 全局动画系数（需注销/重启目标 App）" subtitle:nil]];
    SIOCardView *c3 = [[SIOCardView alloc] init];
    _segDrag = [[UISegmentedControl alloc] initWithItems:@[ @"关闭", @"×5", @"×10", @"×20", @"极端" ]];
    _segDrag.selectedSegmentIndex = DragIndexForCoeff(ReadUIKitDrag());
    [_segDrag addTarget:self action:@selector(dragChanged) forControlEvents:UIControlEventValueChanged];
    [c3 addRow:[[SIOSettingRow alloc] initWithTitle:@"全局系数" icon:@"slider.horizontal.3" iconColor:SIOMintColor() control:_segDrag] isLast:NO];
    _dragHint = [self label:@"" size:12 dim:YES];
    _dragHint.numberOfLines = 0;
    [c3 addRow:[self hintRow:_dragHint] isLast:YES];
    [stack addArrangedSubview:c3];
    [self updateDragHint];
}

#pragma mark - 高级 Tab

- (void)buildAdvanced:(NSDictionary *)cfg stack:(UIStackView *)stack {
    self.title = @"高级";
    NSDictionary *ovAllCfg = [cfg[@"AppOverrides"] isKindOfClass:[NSDictionary class]]
                             ? cfg[@"AppOverrides"] : @{};
    NSString *ovFirst = ovAllCfg[@"com.sfic.knight"] ? @"com.sfic.knight"
                      : ([ovAllCfg.allKeys sortedArrayUsingSelector:@selector(compare:)].firstObject
                         ?: @"com.sfic.knight");

    // App 专属覆盖
    [stack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"App 专属覆盖（只影响该 Bundle ID）" subtitle:nil]];
    SIOCardView *c1 = [[SIOCardView alloc] init];

    _ovBundle = [[UITextField alloc] init];
    _ovBundle.translatesAutoresizingMaskIntoConstraints = NO;
    _ovBundle.text = ovFirst;
    _ovBundle.placeholder = @"com.sfic.knight";
    _ovBundle.borderStyle = UITextBorderStyleRoundedRect;
    _ovBundle.font = [UIFont systemFontOfSize:14];
    _ovBundle.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _ovBundle.autocorrectionType = UITextAutocorrectionTypeNo;
    _ovBundle.spellCheckingType = UITextSpellCheckingTypeNo;
    _ovBundle.keyboardType = UIKeyboardTypeURL;
    _ovBundle.clearButtonMode = UITextFieldViewModeWhileEditing;
    _ovBundle.returnKeyType = UIReturnKeyDone;
    [_ovBundle addTarget:self action:@selector(ovBundleChanged) forControlEvents:UIControlEventEditingDidEnd | UIControlEventEditingDidEndOnExit];
    [_ovBundle.heightAnchor constraintEqualToConstant:36].active = YES;
    UIView *bundleRow = [[UIView alloc] init];
    bundleRow.translatesAutoresizingMaskIntoConstraints = NO;
    [bundleRow addSubview:_ovBundle];
    [NSLayoutConstraint activateConstraints:@[
        [_ovBundle.topAnchor constraintEqualToAnchor:bundleRow.topAnchor constant:12],
        [_ovBundle.leadingAnchor constraintEqualToAnchor:bundleRow.leadingAnchor constant:16],
        [_ovBundle.trailingAnchor constraintEqualToAnchor:bundleRow.trailingAnchor constant:-16],
        [_ovBundle.bottomAnchor constraintEqualToAnchor:bundleRow.bottomAnchor constant:-12],
    ]];
    [c1 addRow:bundleRow isLast:NO];

    _ovOn = [[UISwitch alloc] init];
    [_ovOn addTarget:self action:@selector(ovToggled) forControlEvents:UIControlEventValueChanged];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"为该 App 启用专属配置" icon:@"toggleswitch.fill" iconColor:[UIColor systemBlueColor] control:_ovOn] isLast:NO];

    _ovSpeedLabel = [self label:@"×5.0" size:15 dim:YES];
    _ovSpeed = [[UISlider alloc] init];
    _ovSpeed.minimumValue = 1.0; _ovSpeed.maximumValue = 50.0;
    _ovSpeed.value = 5.0;
    [_ovSpeed addTarget:self action:@selector(ovSliderChanged) forControlEvents:UIControlEventValueChanged];
    [_ovSpeed.widthAnchor constraintEqualToConstant:140].active = YES;
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"专属倍率" icon:@"speedometer" iconColor:[UIColor systemGreenColor] control:_ovSpeed] isLast:NO];

    _ovMode = [[UISegmentedControl alloc] initWithItems:@[ @"加速", @"慢放", @"瞬切" ]];
    [_ovMode addTarget:self action:@selector(ovModeChanged) forControlEvents:UIControlEventValueChanged];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"专属模式" icon:@"gearshape.fill" iconColor:[UIColor systemBlueColor] control:_ovMode] isLast:NO];

    _ovLayer = [[UISegmentedControl alloc] initWithItems:@[ @"×1", @"×2", @"×3", @"×5", @"×10" ]];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"显式动画额外倍率" icon:@"layers.fill" iconColor:SIOCyanColor() control:_ovLayer] isLast:NO];

    _ovFloor = [[UISegmentedControl alloc] initWithItems:@[ @"0.005", @"0.01", @"0.02", @"0.05" ]];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"时长下限" icon:@"timer" iconColor:[UIColor systemOrangeColor] control:_ovFloor] isLast:NO];

    _ovTrans = [[UISegmentedControl alloc] initWithItems:@[ @"×1", @"×1.5", @"×2", @"×3" ]];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"转场额外倍率" icon:@"rectangle.on.rectangle" iconColor:[UIColor systemIndigoColor] control:_ovTrans] isLast:NO];

    _ovSpring = [[UISwitch alloc] init]; _ovSpring.on = YES;
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"弹簧参数缩放" icon:@"circle.hexagongrid.fill" iconColor:[UIColor systemPurpleColor] control:_ovSpring] isLast:NO];
    _ovExtra = [[UISwitch alloc] init]; _ovExtra.on = YES;
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"进阶转场" icon:@"rectangle.on.rectangle" iconColor:[UIColor systemIndigoColor] control:_ovExtra] isLast:NO];
    _ovList = [[UISwitch alloc] init]; _ovList.on = NO; _ovList.onTintColor = [UIColor systemRedColor];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"列表加速（高危）" icon:@"list.bullet" iconColor:[UIColor systemRedColor] control:_ovList] isLast:NO];
    _ovZoom = [[UISwitch alloc] init]; _ovZoom.on = NO;
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"缩放动画加速" icon:@"magnifyingglass" iconColor:[UIColor systemTealColor] control:_ovZoom] isLast:NO];
    _ovLayout = [[UISwitch alloc] init]; _ovLayout.on = NO;
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"布局动画加速（实验）" icon:@"squareshape.split.3x3" iconColor:[UIColor systemIndigoColor] control:_ovLayout] isLast:NO];
    _ovFastScroll = [[UISwitch alloc] init]; _ovFastScroll.on = NO;
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"滑行惯性加急" icon:@"hand.swipe.left.fill" iconColor:[UIColor systemOrangeColor] control:_ovFastScroll] isLast:NO];
    _ovFastTap = [[UISwitch alloc] init]; _ovFastTap.on = NO;
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"点击零延迟" icon:@"hand.tap.fill" iconColor:[UIColor systemPinkColor] control:_ovFastTap] isLast:NO];
    _ovLongPress = [[UISwitch alloc] init]; _ovLongPress.on = NO;
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"长按手势加速" icon:@"hand.point.up.left.fill" iconColor:[UIColor systemTealColor] control:_ovLongPress] isLast:NO];

    _ovLongPressDur = [[UISegmentedControl alloc] initWithItems:@[ @"0.20s", @"0.30s", @"0.40s" ]];
    [c1 addRow:[[SIOSettingRow alloc] initWithTitle:@"专属长按时长" icon:@"timer" iconColor:[UIColor systemTealColor] control:_ovLongPressDur] isLast:NO];

    _ovGuard = [self label:@"" size:12 dim:YES];
    _ovGuard.textColor = [UIColor systemRedColor];
    _ovGuard.numberOfLines = 0;
    [c1 addRow:[self hintRow:_ovGuard] isLast:YES];
    [stack addArrangedSubview:c1];

    // 配置导入/导出
    [stack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"配置导入/导出（JSON，经剪贴板）" subtitle:nil]];
    UIStackView *ioRow = [[UIStackView alloc] init];
    ioRow.axis = UILayoutConstraintAxisHorizontal;
    ioRow.spacing = 12;
    ioRow.distribution = UIStackViewDistributionFillEqually;
    UIButton *exportBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [exportBtn setTitle:@"导出配置到剪贴板" forState:UIControlStateNormal];
    exportBtn.backgroundColor = [UIColor systemBlueColor];
    [exportBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    exportBtn.layer.cornerRadius = 12;
    exportBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [exportBtn.heightAnchor constraintEqualToConstant:44].active = YES;
    [exportBtn addTarget:self action:@selector(onExport) forControlEvents:UIControlEventTouchUpInside];
    UIButton *importBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [importBtn setTitle:@"从剪贴板导入并保存" forState:UIControlStateNormal];
    importBtn.backgroundColor = SIOMintColor();
    [importBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    importBtn.layer.cornerRadius = 12;
    importBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [importBtn.heightAnchor constraintEqualToConstant:44].active = YES;
    [importBtn addTarget:self action:@selector(onImport) forControlEvents:UIControlEventTouchUpInside];
    [ioRow addArrangedSubview:exportBtn];
    [ioRow addArrangedSubview:importBtn];
    [stack addArrangedSubview:ioRow];

    // 注入/环境自检
    [stack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"注入/环境自检" subtitle:nil]];
    UIButton *recheck = [UIButton buttonWithType:UIButtonTypeSystem];
    [recheck setTitle:@"🔍 重新检测" forState:UIControlStateNormal];
    recheck.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    recheck.backgroundColor = [UIColor systemBlueColor];
    [recheck setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    recheck.layer.cornerRadius = 14;
    recheck.layer.borderWidth = 1;
    recheck.layer.borderColor = [UIColor systemBlueColor].CGColor;
    recheck.translatesAutoresizingMaskIntoConstraints = NO;
    [recheck addTarget:self action:@selector(onSelfCheck) forControlEvents:UIControlEventTouchUpInside];
    [recheck.heightAnchor constraintEqualToConstant:50].active = YES;
    [stack addArrangedSubview:recheck];
    SIOCardView *c2 = [[SIOCardView alloc] init];
    _selfCheck = [self label:@"" size:12 dim:YES];
    _selfCheck.numberOfLines = 0;
    [c2 addRow:[self hintRow:_selfCheck] isLast:YES];
    [stack addArrangedSubview:c2];
    [self onSelfCheck];

    // 电源操作
    [stack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"电源操作（会先自动保存）" subtitle:nil]];
    UIButton *rs = [UIButton buttonWithType:UIButtonTypeSystem];
    [rs setTitle:@"🔄 注销 SpringBoard" forState:UIControlStateNormal];
    rs.backgroundColor = [UIColor systemBlueColor];
    [rs setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    rs.layer.cornerRadius = 14;
    rs.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [rs.heightAnchor constraintEqualToConstant:50].active = YES;
    [rs addTarget:self action:@selector(onRespring) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:rs];

    UIButton *rb = [UIButton buttonWithType:UIButtonTypeSystem];
    [rb setTitle:@"⚠️ 硬重启设备" forState:UIControlStateNormal];
    rb.backgroundColor = [UIColor systemRedColor];
    [rb setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    rb.layer.cornerRadius = 14;
    rb.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [rb.heightAnchor constraintEqualToConstant:50].active = YES;
    [rb addTarget:self action:@selector(onReboot) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:rb];

    [self ovBundleChanged];
    [self ovToggled];
    [self ovModeChanged];
}

#pragma mark - 引擎 handlers

- (void)modeChanged {
    int m = (int)_segMode.selectedSegmentIndex;
    _slider.hidden = (m != 0);
    _sliderLabel.hidden = (m != 0);
    _sliderSlow.hidden = (m != 1);
    _sliderSlowLabel.hidden = (m != 1);
}

- (void)sliderChanged {
    _sliderLabel.text = [NSString stringWithFormat:@"×%.1f", _slider.value];
}

- (void)slowSliderChanged {
    _sliderSlowLabel.text = [NSString stringWithFormat:@"×%.1f", _sliderSlow.value];
}

- (void)floorChanged { [self updateFloorHint]; }
- (void)updateFloorHint {
    double v = FloorForIndex((int)_segFloor.selectedSegmentIndex);
    _floorHint.text = [NSString stringWithFormat:@"所有动画的时长下限：%.3gs。追求极致选 0.005s（风险自担）；遇到卡顿/回调异常请调回 0.01s 或更高。瞬切模式也使用该下限。", v];
}

- (void)layerChanged { [self updateLayerHint]; }
- (void)updateLayerHint {
    int idx = (int)_segLayer.selectedSegmentIndex;
    if (idx == 0) {
        _layerHint.text = @"×1：不额外加速，显式动画按全局倍率缩放";
    } else {
        _layerHint.text = [NSString stringWithFormat:@"转圆/进度/旋转/地图相机等显式动画在全局倍率上再 ×%g。不影响 UIView 块动画与转场；慢放不叠加；受下限保护。", LayerBoostForIndex(idx)];
    }
}

- (void)transChanged { [self updateTransHint]; }
- (void)updateTransHint {
    int idx = (int)_segTrans.selectedSegmentIndex;
    if (idx == 0) {
        _transHint.text = @"×1 = 不额外加速。push/pop/模态弹窗按全局倍率缩放。";
    } else {
        _transHint.text = [NSString stringWithFormat:@"转场在全局倍率基础上再 ×%g。仅影响导航 push/pop、模态 present/dismiss 等转场动画。", TransitionBoostForIndex(idx)];
    }
}

- (void)dragChanged { [self updateDragHint]; }
- (void)updateDragHint {
    int idx = (int)_segDrag.selectedSegmentIndex;
    double coeff = DragCoeffForIndex(idx);
    if (idx == 0) {
        _dragHint.text = @"未启用。选 ×5 / ×10 / ×20 可全系统加速，不建议与 dylib 加速同时拉满（两机制叠加）。";
    } else if (idx == 4) {
        _dragHint.text = [NSString stringWithFormat:@"⚠️ 极端档（写入 %.4f）：所有 UIKit 动画时长≈归零，会绕过 dylib 下限，可能触发回调配对错乱（如微信图片预览卡死）。", coeff];
    } else {
        _dragHint.text = [NSString stringWithFormat:@"当前已启用 %.2f（≈×%d，全系统生效，需注销/重启目标 App）。", coeff, DragMultiplierForCoeff(coeff)];
    }
}

#pragma mark - 高级 overrides handlers

- (void)ovBundleChanged {
    NSString *bid = _ovBundle.text ?: @"";
    NSDictionary *cfg = ReadConfig();
    NSDictionary *ovAll = [cfg[@"AppOverrides"] isKindOfClass:[NSDictionary class]] ? cfg[@"AppOverrides"] : @{};
    NSDictionary *mine = [ovAll[bid] isKindOfClass:[NSDictionary class]] ? ovAll[bid] : nil;
    if (mine) {
        _ovOn.on = [mine[@"Enabled"] boolValue];
        _ovMode.selectedSegmentIndex = [mine[@"Mode"] intValue];
        _ovSpeed.value = [mine[@"Speed"] doubleValue];
        _ovSpeedLabel.text = [NSString stringWithFormat:@"×%.1f", _ovSpeed.value];
        _ovSpring.on = [mine[@"Spring"] boolValue];
        _ovExtra.on = [mine[@"Extra"] boolValue];
        _ovList.on = [mine[@"ListAccel"] boolValue];
        _ovZoom.on = [mine[@"ZoomAccel"] boolValue];
        _ovLayout.on = [mine[@"LayoutAccel"] boolValue];
        _ovFastScroll.on = [mine[@"FastScroll"] boolValue];
        _ovFastTap.on = [mine[@"FastTap"] boolValue];
        _ovLongPress.on = [mine[@"LongPress"] boolValue];
        _ovLayer.selectedSegmentIndex = LayerIndexForBoost([mine[@"LayerBoost"] doubleValue]);
        _ovFloor.selectedSegmentIndex = FloorIndexForValue([mine[@"Floor"] doubleValue]);
        _ovTrans.selectedSegmentIndex = TransitionBoostIndexForValue([mine[@"TransitionBoost"] doubleValue]);
        _ovLongPressDur.selectedSegmentIndex = LongPressDurationIndexForValue([mine[@"LongPressDuration"] doubleValue]);
    } else {
        // v2.0.1：该 Bundle 无专属配置时，控件镜像当前【全局】值作为默认，
        // 避免残留上一个 Bundle 的设置（旧代码切换 Bundle 后显示/保存的都是上个 App 的值）
        _ovOn.on = NO;
        _ovMode.selectedSegmentIndex = [cfg[@"Mode"] intValue];
        _ovSpeed.value = [cfg[@"Speed"] doubleValue];
        _ovSpeedLabel.text = [NSString stringWithFormat:@"×%.1f", _ovSpeed.value];
        _ovSpring.on = [cfg[@"Spring"] boolValue];
        _ovExtra.on = [cfg[@"Extra"] boolValue];
        _ovList.on = [cfg[@"ListAccel"] boolValue];
        _ovZoom.on = [cfg[@"ZoomAccel"] boolValue];
        _ovLayout.on = [cfg[@"LayoutAccel"] boolValue];
        _ovFastScroll.on = [cfg[@"FastScroll"] boolValue];
        _ovFastTap.on = [cfg[@"FastTap"] boolValue];
        _ovLongPress.on = [cfg[@"LongPress"] boolValue];
        _ovLayer.selectedSegmentIndex = LayerIndexForBoost([cfg[@"LayerBoost"] doubleValue]);
        _ovFloor.selectedSegmentIndex = FloorIndexForValue([cfg[@"Floor"] doubleValue]);
        _ovTrans.selectedSegmentIndex = TransitionBoostIndexForValue([cfg[@"TransitionBoost"] doubleValue]);
        _ovLongPressDur.selectedSegmentIndex = LongPressDurationIndexForValue([cfg[@"LongPressDuration"] doubleValue]);
    }
    BOOL guarded = [HardGuardBundles() containsObject:bid];
    if (guarded) {
        _ovGuard.text = [NSString stringWithFormat:@"⚠️ %@ 在列表 hook 硬保护名单：列表加速恒关，无法打开（dylib 启动时 listGuard=1）。其余 hook 正常加速。", bid];
        _ovList.on = NO;
        _ovList.enabled = NO;
    } else {
        _ovGuard.text = @"";
        _ovList.enabled = YES;
    }
    [self ovToggled];
    [self ovModeChanged];
}

- (void)ovSliderChanged {
    _ovSpeedLabel.text = [NSString stringWithFormat:@"×%.1f", _ovSpeed.value];
}

- (void)ovModeChanged {
    int m = (int)_ovMode.selectedSegmentIndex;
    BOOL accel = (m == 0);
    _ovSpeed.enabled = accel;
    _ovSpeed.alpha = accel ? 1.0 : 0.4;
    _ovSpeedLabel.alpha = accel ? 1.0 : 0.4;
}

- (void)ovToggled {
    BOOL on = _ovOn.on;
    NSArray *ovControls = @[ _ovMode, _ovSpeed, _ovSpring, _ovExtra,
                             _ovList, _ovZoom, _ovLayout, _ovFastScroll, _ovFastTap,
                             _ovLongPress, _ovLayer, _ovFloor, _ovTrans, _ovLongPressDur ];
    for (UIControl *c in ovControls) {
        c.enabled = on;
        c.alpha = on ? 1.0 : 0.4;
    }
    if ([HardGuardBundles() containsObject:_ovBundle.text ?: @""]) {
        _ovList.enabled = NO;
    }
}

#pragma mark - 保存 / 电源

- (void)onSave {
    NSMutableDictionary *cfg = ReadConfig();
    // 引擎 tab
    if (_swEnabled) { cfg[@"Enabled"] = @(_swEnabled.on); }
    if (_segMode) { cfg[@"Mode"] = @((int)_segMode.selectedSegmentIndex); }
    if (_slider) { cfg[@"Speed"] = @((double)_slider.value); }
    if (_sliderSlow) { cfg[@"SlowFactor"] = @((double)_sliderSlow.value); }
    if (_segFloor) { cfg[@"Floor"] = @(FloorForIndex((int)_segFloor.selectedSegmentIndex)); }
    if (_segLayer) { cfg[@"LayerBoost"] = @(LayerBoostForIndex((int)_segLayer.selectedSegmentIndex)); }
    if (_segTrans) { cfg[@"TransitionBoost"] = @(TransitionBoostForIndex((int)_segTrans.selectedSegmentIndex)); }
    // 手感 tab
    if (_swFastScroll) { cfg[@"FastScroll"] = @(_swFastScroll.on); }
    if (_swFastTap) { cfg[@"FastTap"] = @(_swFastTap.on); }
    if (_swLongPress) { cfg[@"LongPress"] = @(_swLongPress.on); }
    if (_segLongPress) { cfg[@"LongPressDuration"] = @(LongPressDurationForIndex((int)_segLongPress.selectedSegmentIndex)); }
    if (_swZoom) { cfg[@"ZoomAccel"] = @(_swZoom.on); }
    if (_swLayout) { cfg[@"LayoutAccel"] = @(_swLayout.on); }
    if (_swList) { cfg[@"ListAccel"] = @(_swList.on); }
    if (_swNotify) { cfg[@"Notify"] = @(_swNotify.on); }
    // 系统 tab
    if (_swFUBG) { cfg[@"FUBGEnabled"] = @(_swFUBG.on); }
    if (_swFUBGScene) { cfg[@"FUBGSceneFake"] = @(_swFUBGScene.on); }
    if (_swFUBGAudio) { cfg[@"FUBGAudioKeep"] = @(_swFUBGAudio.on); }
    if (_swFUBGBall) { cfg[@"FUBGFloatingBall"] = @(_swFUBGBall.on); }
    // 黑名单
    if (_blacklist) {
        NSMutableArray *bl = [NSMutableArray array];
        for (NSString *line in [_blacklist.text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (t.length) [bl addObject:t];
        }
        cfg[@"Blacklist"] = bl;
    }
    // App 覆盖
    if (_ovBundle) {
        NSString *bid = _ovBundle.text ?: @"";
        if (bid.length) {
            NSMutableDictionary *ovAll = [cfg[@"AppOverrides"] isKindOfClass:[NSDictionary class]]
                                         ? [cfg[@"AppOverrides"] mutableCopy] : [NSMutableDictionary dictionary];
            if (_ovOn.on) {
                NSMutableDictionary *mine = [ovAll[bid] isKindOfClass:[NSDictionary class]]
                                            ? [ovAll[bid] mutableCopy] : [NSMutableDictionary dictionary];
                mine[@"Enabled"] = @(_ovOn.on);
                mine[@"Mode"] = @((int)_ovMode.selectedSegmentIndex);
                mine[@"Speed"] = @((double)_ovSpeed.value);
                mine[@"Spring"] = @(_ovSpring.on);
                mine[@"Extra"] = @(_ovExtra.on);
                mine[@"ListAccel"] = @(_ovList.on);
                mine[@"ZoomAccel"] = @(_ovZoom.on);
                mine[@"LayoutAccel"] = @(_ovLayout.on);
                mine[@"FastScroll"] = @(_ovFastScroll.on);
                mine[@"FastTap"] = @(_ovFastTap.on);
                mine[@"LongPress"] = @(_ovLongPress.on);
                mine[@"LongPressDuration"] = @(LongPressDurationForIndex((int)_ovLongPressDur.selectedSegmentIndex));
                mine[@"LayerBoost"] = @(LayerBoostForIndex((int)_ovLayer.selectedSegmentIndex));
                mine[@"Floor"] = @(FloorForIndex((int)_ovFloor.selectedSegmentIndex));
                mine[@"TransitionBoost"] = @(TransitionBoostForIndex((int)_ovTrans.selectedSegmentIndex));
                ovAll[bid] = mine;
            } else {
                // v2.0.1：关闭「为该 App 启用专属配置」必须删除整条覆盖。
                // 旧代码此时什么都不写，旧字典（Enabled 仍是旧值，通常为 YES）
                // 继续被 dylib 命中——开关关掉后专属参数依旧生效，等于关不掉。
                [ovAll removeObjectForKey:bid];
            }
            cfg[@"AppOverrides"] = ovAll;
        }
    }

    BOOL ok = WriteConfig(cfg);
    if (_swRM) WriteAx(@"ReduceMotionEnabled", _swRM.on);
    if (_swCF) WriteAx(@"PreferCrossFadeTransitions", _swCF.on);
    if (_swRT) WriteAx(@"ReduceTransparencyEnabled", _swRT.on);
    if (_segDrag) WriteUIKitDrag(DragCoeffForIndex((int)_segDrag.selectedSegmentIndex));

    UINotificationFeedbackGenerator *fg = [[UINotificationFeedbackGenerator alloc] init];
    [fg prepare];
    if (ok) {
        [fg notificationOccurred:UINotificationFeedbackTypeSuccess];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"保存成功"
                            message:@"配置已写入并发送 Darwin 通知，目标 App 重启或注销后生效。"
                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } else {
        [fg notificationOccurred:UINotificationFeedbackTypeError];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"保存失败"
                            message:@"无法写入配置文件，请检查权限或路径。"
                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

- (void)onExport {
    NSMutableDictionary *cfg = ReadConfig();
    NSError *err;
    NSData *data = [NSJSONSerialization dataWithJSONObject:cfg options:NSJSONWritingPrettyPrinted error:&err];
    if (!data) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"导出失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [UIPasteboard generalPasteboard].string = json;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已导出" message:@"配置 JSON 已复制到剪贴板。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)onImport {
    NSString *json = [UIPasteboard generalPasteboard].string;
    if (!json.length) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"导入失败" message:@"剪贴板为空。" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    NSError *err;
    id obj = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&err];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"导入失败" message:@"剪贴板内容不是合法配置 JSON。" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    NSMutableDictionary *cfg = [(NSDictionary *)obj mutableCopy];
    BOOL ok = WriteConfig(cfg);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:(ok ? @"导入成功" : @"导入失败")
                        message:(ok ? @"配置已写入，重启目标 App 生效。" : @"写入配置文件失败。")
                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)onSelfCheck {
    UIImpactFeedbackGenerator *impact = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [impact impactOccurred];
    NSMutableDictionary *cfg = ReadConfig();
    BOOL prefsOK = [[NSFileManager defaultManager] isWritableFileAtPath:PrefPath];
    BOOL uikitOK = [[NSFileManager defaultManager] fileExistsAtPath:UIKitPath];
    BOOL axOK = [[NSFileManager defaultManager] fileExistsAtPath:AxPath];
    int mode = [cfg[@"Mode"] intValue];
    double floor = [cfg[@"Floor"] doubleValue];
    double layer = [cfg[@"LayerBoost"] doubleValue];
    double trans = [cfg[@"TransitionBoost"] doubleValue];
    BOOL fubg = [cfg[@"FUBGEnabled"] boolValue];
    NSString *engine = [NSString stringWithFormat:@"已启用，瞬切（下限 %.3gs），显式×%g，转场×%g，%@弹簧，%@点按，%@长按",
                        floor, layer, trans,
                        [cfg[@"Spring"] boolValue] ? @"开" : @"关",
                        [cfg[@"FastTap"] boolValue] ? @"开" : @"关",
                        [cfg[@"LongPress"] boolValue] ? @"开" : @"关"];
    if (mode == 0) engine = [NSString stringWithFormat:@"已启用，加速 ×%g（下限 %.3gs），显式×%g，转场×%g", [cfg[@"Speed"] doubleValue], floor, layer, trans];
    else if (mode == 1) engine = [NSString stringWithFormat:@"已启用，慢放 ×%g（下限 %.3gs）", [cfg[@"SlowFactor"] doubleValue], floor];
    _selfCheck.text = [NSString stringWithFormat:
        @"SIOriginal 配置器 2.0.7 (build 51)\nBundle ID: com.local.sioriginal\n\n"
        @"【权限/路径自检】\n"
        @"/var/Managed Preferences/mobile 配置目录：%@\n"
        @"UIKit.plist 存在：%@\n"
        @"辅助功能目录可写：%@\n\n"
        @"【当前引擎配置】\n%@\n"
        @"保活：%@\n\n"
        @"【注入方式提醒】\n"
        @"本 App 只负责写配置并发 Darwin 热重载通知；动画引擎 SIOriginal.dylib 需用 TrollFools 注入目标 App。保存配置后，前台目标 App 顶部会出现 1.5 秒生效提示（可在「手感」页关闭）。",
        prefsOK ? @"✅" : @"❌",
        uikitOK ? @"✅" : @"❌",
        axOK ? @"✅" : @"❌",
        engine,
        fubg ? @"开启" : @"关闭"];
}

- (void)onRespring {
    [self onSave];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ Respring(); });
}

- (void)onReboot {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"确认重启"
                        message:@"将以 root 权限重启设备"
                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"重启" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *x) {
        [self onSave];
        NSString *way = SIOReboot();
        _selfCheck.text = [NSString stringWithFormat:@"重启：%@", way];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - App Delegate

@interface SIOAppDelegate : UIResponder <UIApplicationDelegate, UITabBarControllerDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation SIOAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    SIOVC *engine = [[SIOVC alloc] initWithTab:SIOTabEngine];
    SIOVC *feel   = [[SIOVC alloc] initWithTab:SIOTabFeel];
    SIOVC *system = [[SIOVC alloc] initWithTab:SIOTabSystem];
    SIOVC *adv    = [[SIOVC alloc] initWithTab:SIOTabAdvanced];

    UINavigationController *n1 = [[UINavigationController alloc] initWithRootViewController:engine];
    UINavigationController *n2 = [[UINavigationController alloc] initWithRootViewController:feel];
    UINavigationController *n3 = [[UINavigationController alloc] initWithRootViewController:system];
    UINavigationController *n4 = [[UINavigationController alloc] initWithRootViewController:adv];

    n1.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"引擎" image:[UIImage systemImageNamed:@"bolt.fill"] selectedImage:nil];
    n2.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"手感" image:[UIImage systemImageNamed:@"hand.tap.fill"] selectedImage:nil];
    n3.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"系统" image:[UIImage systemImageNamed:@"gearshape.fill"] selectedImage:nil];
    n4.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"高级" image:[UIImage systemImageNamed:@"wrench.fill"] selectedImage:nil];

    UITabBarController *tab = [[UITabBarController alloc] init];
    tab.viewControllers = @[n1, n2, n3, n4];
    tab.delegate = self;

    // 全局保存按钮
    for (UINavigationController *nav in @[n1, n2, n3, n4]) {
        nav.topViewController.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:nav.topViewController action:@selector(onSave)];
    }

    self.window.rootViewController = tab;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if ([[NSProcessInfo processInfo].arguments containsObject:@"--sio-reboot-helper"]) {
            reboot(RB_AUTOBOOT);
            pid_t pid;
            posix_spawnattr_t attr;
            posix_spawnattr_init(&attr);
            posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
            posix_spawnattr_set_persona_uid_np(&attr, 0);
            posix_spawnattr_set_persona_gid_np(&attr, 0);
            char *a[] = { "/usr/bin/killall", "-9", "launchd", NULL };
            posix_spawn(&pid, "/usr/bin/killall", NULL, &attr, a, environ);
            posix_spawnattr_destroy(&attr);
            return 0;
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SIOAppDelegate class]));
    }
}
