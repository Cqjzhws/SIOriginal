// SIOriginal — 配置 App（TrollStore 安装）
// v1.8.19：修复 iOS 14 上 systemCyanColor/systemMintColor 崩溃；随 tweak ABI 修复同步发版
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

// v1.8.19：systemCyanColor / systemMintColor 是 iOS 15+ API，在 iOS 14 上调用会
// unrecognized selector 直接崩溃（README 声明支持 iOS 14）。用 @available 守卫，
// 旧系统回退到等价的 RGB 颜色。
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
    dispatch_once(&once, ^{ a = @[ @"com.sfic.knight" ]; });
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
    if (!d[@"Enabled"])    d[@"Enabled"]    = @YES;
    if (!d[@"Mode"])       d[@"Mode"]       = @2;
    if (!d[@"Speed"])      d[@"Speed"]      = @5.0;
    if (!d[@"SlowFactor"]) d[@"SlowFactor"] = @2.0;
    if (!d[@"Spring"])     d[@"Spring"]     = @YES;
    if (!d[@"Extra"])      d[@"Extra"]      = @YES;
    if (!d[@"ListAccel"])  d[@"ListAccel"]  = @NO;
    if (!d[@"ZoomAccel"])  d[@"ZoomAccel"]  = @NO;
    if (!d[@"FastScroll"]) d[@"FastScroll"] = @NO;
    if (!d[@"FastTap"])    d[@"FastTap"]    = @NO;
    if (!d[@"LayerBoost"]) d[@"LayerBoost"] = @1.0;
    if (!d[@"Blacklist"])  d[@"Blacklist"]  = @[ @"com.tencent.wework" ];
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
                          @"FastScroll", @"FastTap", @"LayerBoost",
                          @"FUBGEnabled", @"FUBGSceneFake", @"FUBGAudioKeep",
                          @"FUBGFloatingBall", @"FUBGExcludeApps", @"AppOverrides" ];
    for (NSString *k in sioKeys) {
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
    return m == 1 ? @"慢放" : (m == 2 ? @"瞬切 0.01s" : @"加速");
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
        _titleLabel.text = [title uppercaseString];
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

@interface SIOVC : UIViewController
@end

@implementation SIOVC {
    UISwitch *_swEnabled, *_swSpring, *_swExtra, *_swList, *_swZoom, *_swFastScroll, *_swFastTap;
    UISegmentedControl *_segMode;
    UISlider *_slider, *_sliderSlow;
    UILabel *_sliderLabel, *_sliderSlowLabel;
    UITextView *_blacklist;
    UILabel *_status;
    UISwitch *_swRM, *_swCF, *_swRT;
    UISegmentedControl *_segDrag, *_segLayer;
    UILabel *_dragLabel, *_layerLabel;
    UISwitch *_swFUBG, *_swFUBGScene, *_swFUBGAudio, *_swFUBGBall;
    UITextField *_ovBundle;
    UISwitch *_ovOn, *_ovSpring, *_ovExtra, *_ovList, *_ovZoom, *_ovFastScroll, *_ovFastTap;
    UISegmentedControl *_ovLayer, *_ovMode;
    UISlider *_ovSpeed;
    UILabel *_ovSpeedLabel, *_ovGuard;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"SI Original";
    
    NSMutableDictionary *cfg = ReadConfig();
    int mode = [cfg[@"Mode"] intValue];
    double speed = [cfg[@"Speed"] doubleValue];
    double slowFactor = [cfg[@"SlowFactor"] doubleValue];
    
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    
    UIStackView *mainStack = [[UIStackView alloc] init];
    mainStack.axis = UILayoutConstraintAxisVertical;
    mainStack.spacing = 20;
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:mainStack];
    
    // Header
    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    
    UILabel *title = [[UILabel alloc] init];
    title.text = @"SI Original";
    title.font = [UIFont boldSystemFontOfSize:32];
    title.textColor = [UIColor labelColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:title];
    
    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"v1.8.18 · 系统级增强";
    sub.font = [UIFont systemFontOfSize:14];
    sub.textColor = [UIColor secondaryLabelColor];
    sub.textAlignment = NSTextAlignmentCenter;
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:sub];
    
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:header.topAnchor constant:20],
        [title.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [sub.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [sub.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8],
    ]];
    [mainStack addArrangedSubview:header];
    
    // Section 1: 基础设置
    [mainStack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"基础设置" subtitle:nil]];
    SIOCardView *card1 = [[SIOCardView alloc] init];
    
    _swEnabled = [[UISwitch alloc] init];
    _swEnabled.on = [cfg[@"Enabled"] boolValue];
    SIOSettingRow *r1 = [[SIOSettingRow alloc] initWithTitle:@"启用加速" icon:@"bolt.fill" iconColor:[UIColor systemYellowColor] control:_swEnabled];
    [card1 addRow:r1 isLast:NO];
    
    UILabel *lblMode = [self label:@"模式" size:17 dim:NO];
    _segMode = [[UISegmentedControl alloc] initWithItems:@[ @"加速", @"慢放", @"瞬切" ]];
    _segMode.selectedSegmentIndex = (mode >= 0 && mode <= 2) ? mode : 0;
    [_segMode addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    SIOSettingRow *r2 = [[SIOSettingRow alloc] initWithTitle:@"运行模式" icon:@"gearshape.fill" iconColor:[UIColor systemBlueColor] control:_segMode];
    [card1 addRow:r2 isLast:NO];
    
    _sliderLabel = [self label:[NSString stringWithFormat:@"×%.1f", speed] size:15 dim:YES];
    _slider = [[UISlider alloc] init];
    _slider.minimumValue = 1.0;
    _slider.maximumValue = 50.0;
    _slider.continuous = YES;
    _slider.value = speed;
    [_slider addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
    [_slider.widthAnchor constraintEqualToConstant:120].active = YES;
    SIOSettingRow *r3 = [[SIOSettingRow alloc] initWithTitle:@"加速倍率" icon:@"speedometer" iconColor:[UIColor systemGreenColor] control:_slider];
    [card1 addRow:r3 isLast:NO];
    
    _sliderSlowLabel = [self label:[NSString stringWithFormat:@"×%.1f", slowFactor] size:15 dim:YES];
    _sliderSlow = [[UISlider alloc] init];
    _sliderSlow.minimumValue = 1.0;
    _sliderSlow.maximumValue = 10.0;
    _sliderSlow.continuous = YES;
    _sliderSlow.value = slowFactor;
    [_sliderSlow addTarget:self action:@selector(slowSliderChanged) forControlEvents:UIControlEventValueChanged];
    [_sliderSlow.widthAnchor constraintEqualToConstant:120].active = YES;
    SIOSettingRow *r4 = [[SIOSettingRow alloc] initWithTitle:@"慢放倍率" icon:@"tortoise.fill" iconColor:[UIColor systemOrangeColor] control:_sliderSlow];
    [card1 addRow:r4 isLast:YES];
    
    [mainStack addArrangedSubview:card1];
    
    // Section 2: 动画选项
    [mainStack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"动画选项" subtitle:nil]];
    SIOCardView *card2 = [[SIOCardView alloc] init];
    
    _swSpring = [[UISwitch alloc] init];
    _swSpring.on = [cfg[@"Spring"] boolValue];
    [card2 addRow:[[SIOSettingRow alloc] initWithTitle:@"弹簧参数缩放" icon:@"circle.hexagongrid.fill" iconColor:[UIColor systemPurpleColor] control:_swSpring] isLast:NO];
    
    _swExtra = [[UISwitch alloc] init];
    _swExtra.on = [cfg[@"Extra"] boolValue];
    [card2 addRow:[[SIOSettingRow alloc] initWithTitle:@"进阶转场" icon:@"rectangle.on.rectangle" iconColor:[UIColor systemIndigoColor] control:_swExtra] isLast:NO];
    
    _swList = [[UISwitch alloc] init];
    _swList.on = [cfg[@"ListAccel"] boolValue];
    _swList.onTintColor = [UIColor systemRedColor];
    [card2 addRow:[[SIOSettingRow alloc] initWithTitle:@"列表加速 (高危)" icon:@"list.bullet" iconColor:[UIColor systemRedColor] control:_swList] isLast:NO];
    
    UILabel *listHint = [self label:@"重列表 App（顺丰同城骑士等）保持关闭，否则会卡死/崩溃" size:12 dim:YES];
    listHint.numberOfLines = 0;
    UIView *hintRow = [[UIView alloc] init];
    hintRow.translatesAutoresizingMaskIntoConstraints = NO;
    [hintRow addSubview:listHint];
    [NSLayoutConstraint activateConstraints:@[
        [listHint.topAnchor constraintEqualToAnchor:hintRow.topAnchor constant:8],
        [listHint.leadingAnchor constraintEqualToAnchor:hintRow.leadingAnchor constant:16],
        [listHint.trailingAnchor constraintEqualToAnchor:hintRow.trailingAnchor constant:-16],
        [listHint.bottomAnchor constraintEqualToAnchor:hintRow.bottomAnchor constant:-8],
    ]];
    [card2 addRow:hintRow isLast:NO];
    
    _swZoom = [[UISwitch alloc] init];
    _swZoom.on = [cfg[@"ZoomAccel"] boolValue];
    [card2 addRow:[[SIOSettingRow alloc] initWithTitle:@"缩放动画 (实验)" icon:@"magnifyingglass" iconColor:[UIColor systemTealColor] control:_swZoom] isLast:NO];
    
    _swFastScroll = [[UISwitch alloc] init];
    _swFastScroll.on = [cfg[@"FastScroll"] boolValue];
    [card2 addRow:[[SIOSettingRow alloc] initWithTitle:@"滑行惯性加急" icon:@"hand.swipe.left.fill" iconColor:[UIColor systemOrangeColor] control:_swFastScroll] isLast:NO];
    
    _swFastTap = [[UISwitch alloc] init];
    _swFastTap.on = [cfg[@"FastTap"] boolValue];
    [card2 addRow:[[SIOSettingRow alloc] initWithTitle:@"点击零延迟" icon:@"hand.tap.fill" iconColor:[UIColor systemPinkColor] control:_swFastTap] isLast:YES];
    
    [mainStack addArrangedSubview:card2];
    
    // Section 3: LayerBoost
    [mainStack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"显式动画" subtitle:@"转圈/进度/旋转等 CAAnimation 路径额外倍率"]];
    SIOCardView *card3 = [[SIOCardView alloc] init];
    
    _segLayer = [[UISegmentedControl alloc] initWithItems:@[ @"×1", @"×2", @"×3", @"×5", @"×10" ]];
    _segLayer.selectedSegmentIndex = LayerIndexForBoost([cfg[@"LayerBoost"] doubleValue]);
    [_segLayer addTarget:self action:@selector(layerChanged) forControlEvents:UIControlEventValueChanged];
    SIOSettingRow *rLayer = [[SIOSettingRow alloc] initWithTitle:@"显式动画倍率" icon:@"layers.fill" iconColor:SIOCyanColor() control:_segLayer];
    [card3 addRow:rLayer isLast:NO];
    
    _layerLabel = [self label:@"" size:12 dim:YES];
    _layerLabel.textColor = [UIColor systemOrangeColor];
    _layerLabel.numberOfLines = 0;
    UIView *layerHintRow = [[UIView alloc] init];
    layerHintRow.translatesAutoresizingMaskIntoConstraints = NO;
    [layerHintRow addSubview:_layerLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_layerLabel.topAnchor constraintEqualToAnchor:layerHintRow.topAnchor constant:8],
        [_layerLabel.leadingAnchor constraintEqualToAnchor:layerHintRow.leadingAnchor constant:16],
        [_layerLabel.trailingAnchor constraintEqualToAnchor:layerHintRow.trailingAnchor constant:-16],
        [_layerLabel.bottomAnchor constraintEqualToAnchor:layerHintRow.bottomAnchor constant:-8],
    ]];
    [card3 addRow:layerHintRow isLast:YES];
    
    [mainStack addArrangedSubview:card3];
    
    // Section 4: 系统效果
    [mainStack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"系统动态效果" subtitle:@"写入辅助功能，需注销生效"]];
    SIOCardView *card4 = [[SIOCardView alloc] init];
    
    _swRM = [[UISwitch alloc] init];
    _swRM.on = ReadAx(@"ReduceMotionEnabled");
    [card4 addRow:[[SIOSettingRow alloc] initWithTitle:@"减弱动态效果" icon:@"tortoise.fill" iconColor:[UIColor systemGrayColor] control:_swRM] isLast:NO];
    
    _swCF = [[UISwitch alloc] init];
    _swCF.on = ReadAx(@"PreferCrossFadeTransitions");
    [card4 addRow:[[SIOSettingRow alloc] initWithTitle:@"交叉淡出过渡" icon:@"arrow.triangle.2.circlepath" iconColor:[UIColor systemGrayColor] control:_swCF] isLast:NO];
    
    _swRT = [[UISwitch alloc] init];
    _swRT.on = ReadAx(@"ReduceTransparencyEnabled");
    [card4 addRow:[[SIOSettingRow alloc] initWithTitle:@"减少透明度" icon:@"circle.lefthalf.filled" iconColor:[UIColor systemGrayColor] control:_swRT] isLast:YES];
    
    [mainStack addArrangedSubview:card4];
    
    // Section 5: UIKit 全局系数
    [mainStack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"UIKit 全局动画系数" subtitle:@"写入 com.apple.UIKit，需注销/重启目标 App"]];
    SIOCardView *card5 = [[SIOCardView alloc] init];
    
    double curDrag = ReadUIKitDrag();
    int curDragIdx = DragIndexForCoeff(curDrag);
    _segDrag = [[UISegmentedControl alloc] initWithItems:@[ @"关", @"×5", @"×10", @"×20", @"极端" ]];
    _segDrag.selectedSegmentIndex = curDragIdx;
    [_segDrag addTarget:self action:@selector(dragChanged) forControlEvents:UIControlEventValueChanged];
    SIOSettingRow *rDrag = [[SIOSettingRow alloc] initWithTitle:@"全局动画系数" icon:@"slider.horizontal.3" iconColor:SIOMintColor() control:_segDrag];
    [card5 addRow:rDrag isLast:NO];
    
    _dragLabel = [self label:@"" size:12 dim:YES];
    _dragLabel.textColor = [UIColor systemOrangeColor];
    _dragLabel.numberOfLines = 0;
    [self updateDragLabel];
    UIView *dragHintRow = [[UIView alloc] init];
    dragHintRow.translatesAutoresizingMaskIntoConstraints = NO;
    [dragHintRow addSubview:_dragLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_dragLabel.topAnchor constraintEqualToAnchor:dragHintRow.topAnchor constant:8],
        [_dragLabel.leadingAnchor constraintEqualToAnchor:dragHintRow.leadingAnchor constant:16],
        [_dragLabel.trailingAnchor constraintEqualToAnchor:dragHintRow.trailingAnchor constant:-16],
        [_dragLabel.bottomAnchor constraintEqualToAnchor:dragHintRow.bottomAnchor constant:-8],
    ]];
    [card5 addRow:dragHintRow isLast:YES];
    
    [mainStack addArrangedSubview:card5];
    
    // Section 6: 保活
    [mainStack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"真后台保活" subtitle:@"FUBackground 引擎"]];
    SIOCardView *card6 = [[SIOCardView alloc] init];
    
    _swFUBG = [[UISwitch alloc] init];
    _swFUBG.on = [cfg[@"FUBGEnabled"] boolValue];
    [card6 addRow:[[SIOSettingRow alloc] initWithTitle:@"启用真后台保活" icon:@"battery.100.bolt" iconColor:[UIColor systemGreenColor] control:_swFUBG] isLast:NO];
    
    _swFUBGScene = [[UISwitch alloc] init];
    _swFUBGScene.on = [cfg[@"FUBGSceneFake"] boolValue];
    [card6 addRow:[[SIOSettingRow alloc] initWithTitle:@"场景伪装引擎" icon:@"theatermasks.fill" iconColor:[UIColor systemIndigoColor] control:_swFUBGScene] isLast:NO];
    
    _swFUBGAudio = [[UISwitch alloc] init];
    _swFUBGAudio.on = [cfg[@"FUBGAudioKeep"] boolValue];
    [card6 addRow:[[SIOSettingRow alloc] initWithTitle:@"音频断言兜底" icon:@"speaker.wave.2.fill" iconColor:[UIColor systemOrangeColor] control:_swFUBGAudio] isLast:NO];
    
    _swFUBGBall = [[UISwitch alloc] init];
    _swFUBGBall.on = [cfg[@"FUBGFloatingBall"] boolValue];
    _swFUBGBall.enabled = NO;
    [card6 addRow:[[SIOSettingRow alloc] initWithTitle:@"悬浮球 (已全局禁用)" icon:@"circle.fill" iconColor:[UIColor systemGrayColor] control:_swFUBGBall] isLast:YES];
    
    [mainStack addArrangedSubview:card6];
    
    // Section 7: App 专属覆盖
    [mainStack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"App 专属覆盖" subtitle:@"为指定 Bundle ID 单独配置，不影响其他 App"]];
    SIOCardView *card7 = [[SIOCardView alloc] init];
    
    NSDictionary *ovAllCfg = [cfg[@"AppOverrides"] isKindOfClass:[NSDictionary class]]
                             ? cfg[@"AppOverrides"] : @{};
    NSString *ovFirst = ovAllCfg[@"com.sfic.knight"] ? @"com.sfic.knight"
                      : ([ovAllCfg.allKeys sortedArrayUsingSelector:@selector(compare:)].firstObject
                         ?: @"com.sfic.knight");
    
    _ovBundle = [[UITextField alloc] init];
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
    [card7 addRow:bundleRow isLast:NO];
    
    _ovOn = [[UISwitch alloc] init];
    [_ovOn addTarget:self action:@selector(ovToggled) forControlEvents:UIControlEventValueChanged];
    [card7 addRow:[[SIOSettingRow alloc] initWithTitle:@"启用专属配置" icon:@"toggleswitch.fill" iconColor:[UIColor systemBlueColor] control:_ovOn] isLast:NO];
    
    _ovMode = [[UISegmentedControl alloc] initWithItems:@[ @"加速", @"慢放", @"瞬切" ]];
    _ovMode.selectedSegmentIndex = 0;
    [card7 addRow:[[SIOSettingRow alloc] initWithTitle:@"专属模式" icon:@"gearshape.fill" iconColor:[UIColor systemBlueColor] control:_ovMode] isLast:NO];
    
    _ovSpeedLabel = [self label:@"×5.0" size:15 dim:YES];
    _ovSpeed = [[UISlider alloc] init];
    _ovSpeed.minimumValue = 1.0;
    _ovSpeed.maximumValue = 50.0;
    _ovSpeed.value = 5.0;
    _ovSpeed.continuous = YES;
    [_ovSpeed addTarget:self action:@selector(ovSliderChanged) forControlEvents:UIControlEventValueChanged];
    [_ovSpeed.widthAnchor constraintEqualToConstant:120].active = YES;
    [card7 addRow:[[SIOSettingRow alloc] initWithTitle:@"专属倍率" icon:@"speedometer" iconColor:[UIColor systemGreenColor] control:_ovSpeed] isLast:NO];
    
    _ovSpring = [[UISwitch alloc] init];
    _ovSpring.on = YES;
    [card7 addRow:[[SIOSettingRow alloc] initWithTitle:@"弹簧参数缩放" icon:@"circle.hexagongrid.fill" iconColor:[UIColor systemPurpleColor] control:_ovSpring] isLast:NO];
    
    _ovExtra = [[UISwitch alloc] init];
    _ovExtra.on = YES;
    [card7 addRow:[[SIOSettingRow alloc] initWithTitle:@"进阶转场" icon:@"rectangle.on.rectangle" iconColor:[UIColor systemIndigoColor] control:_ovExtra] isLast:NO];
    
    _ovList = [[UISwitch alloc] init];
    _ovList.on = NO;
    _ovList.onTintColor = [UIColor systemRedColor];
    [card7 addRow:[[SIOSettingRow alloc] initWithTitle:@"列表加速" icon:@"list.bullet" iconColor:[UIColor systemRedColor] control:_ovList] isLast:NO];
    
    _ovZoom = [[UISwitch alloc] init];
    _ovZoom.on = NO;
    [card7 addRow:[[SIOSettingRow alloc] initWithTitle:@"缩放动画" icon:@"magnifyingglass" iconColor:[UIColor systemTealColor] control:_ovZoom] isLast:NO];
    
    _ovFastScroll = [[UISwitch alloc] init];
    _ovFastScroll.on = NO;
    [card7 addRow:[[SIOSettingRow alloc] initWithTitle:@"滑行惯性加急" icon:@"hand.swipe.left.fill" iconColor:[UIColor systemOrangeColor] control:_ovFastScroll] isLast:NO];
    
    _ovFastTap = [[UISwitch alloc] init];
    _ovFastTap.on = NO;
    [card7 addRow:[[SIOSettingRow alloc] initWithTitle:@"点击零延迟" icon:@"hand.tap.fill" iconColor:[UIColor systemPinkColor] control:_ovFastTap] isLast:NO];
    
    _ovLayer = [[UISegmentedControl alloc] initWithItems:@[ @"×1", @"×2", @"×3", @"×5", @"×10" ]];
    _ovLayer.selectedSegmentIndex = 0;
    [card7 addRow:[[SIOSettingRow alloc] initWithTitle:@"显式动画倍率" icon:@"layers.fill" iconColor:SIOCyanColor() control:_ovLayer] isLast:NO];
    
    _ovGuard = [self label:@"" size:12 dim:YES];
    _ovGuard.textColor = [UIColor systemRedColor];
    _ovGuard.numberOfLines = 0;
    UIView *ovGuardRow = [[UIView alloc] init];
    ovGuardRow.translatesAutoresizingMaskIntoConstraints = NO;
    [ovGuardRow addSubview:_ovGuard];
    [NSLayoutConstraint activateConstraints:@[
        [_ovGuard.topAnchor constraintEqualToAnchor:ovGuardRow.topAnchor constant:8],
        [_ovGuard.leadingAnchor constraintEqualToAnchor:ovGuardRow.leadingAnchor constant:16],
        [_ovGuard.trailingAnchor constraintEqualToAnchor:ovGuardRow.trailingAnchor constant:-16],
        [_ovGuard.bottomAnchor constraintEqualToAnchor:ovGuardRow.bottomAnchor constant:-8],
    ]];
    [card7 addRow:ovGuardRow isLast:YES];
    
    [mainStack addArrangedSubview:card7];
    
    // Section 8: 黑名单
    [mainStack addArrangedSubview:[[SIOSectionHeader alloc] initWithTitle:@"黑名单" subtitle:@"每行一个 Bundle ID，不加速这些 App"]];
    SIOCardView *card8 = [[SIOCardView alloc] init];
    
    _blacklist = [[UITextView alloc] init];
    _blacklist.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _blacklist.layer.borderColor = [UIColor separatorColor].CGColor;
    _blacklist.layer.borderWidth = 0.5;
    _blacklist.layer.cornerRadius = 8;
    _blacklist.text = [cfg[@"Blacklist"] componentsJoinedByString:@"\n"];
    [_blacklist.heightAnchor constraintEqualToConstant:80].active = YES;
    
    UIView *blRow = [[UIView alloc] init];
    blRow.translatesAutoresizingMaskIntoConstraints = NO;
    [blRow addSubview:_blacklist];
    [NSLayoutConstraint activateConstraints:@[
        [_blacklist.topAnchor constraintEqualToAnchor:blRow.topAnchor constant:12],
        [_blacklist.leadingAnchor constraintEqualToAnchor:blRow.leadingAnchor constant:16],
        [_blacklist.trailingAnchor constraintEqualToAnchor:blRow.trailingAnchor constant:-16],
        [_blacklist.bottomAnchor constraintEqualToAnchor:blRow.bottomAnchor constant:-12],
    ]];
    [card8 addRow:blRow isLast:YES];
    
    [mainStack addArrangedSubview:card8];
    
    // Buttons
    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setTitle:@"保存配置" forState:UIControlStateNormal];
    save.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    save.backgroundColor = [UIColor systemBlueColor];
    [save setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    save.layer.cornerRadius = 14;
    save.translatesAutoresizingMaskIntoConstraints = NO;
    [save.heightAnchor constraintEqualToConstant:50].active = YES;
    [save addTarget:self action:@selector(onSave) forControlEvents:UIControlEventTouchUpInside];
    [mainStack addArrangedSubview:save];
    
    UIStackView *btnRow = [[UIStackView alloc] init];
    btnRow.axis = UILayoutConstraintAxisHorizontal;
    btnRow.spacing = 12;
    btnRow.distribution = UIStackViewDistributionFillEqually;
    
    UIButton *rs = [UIButton buttonWithType:UIButtonTypeSystem];
    [rs setTitle:@"注销" forState:UIControlStateNormal];
    rs.layer.cornerRadius = 12;
    rs.layer.borderWidth = 1;
    rs.layer.borderColor = [UIColor systemBlueColor].CGColor;
    rs.translatesAutoresizingMaskIntoConstraints = NO;
    [rs.heightAnchor constraintEqualToConstant:44].active = YES;
    [rs addTarget:self action:@selector(onRespring) forControlEvents:UIControlEventTouchUpInside];
    
    UIButton *rb = [UIButton buttonWithType:UIButtonTypeSystem];
    [rb setTitle:@"重启" forState:UIControlStateNormal];
    [rb setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    rb.layer.cornerRadius = 12;
    rb.layer.borderWidth = 1;
    rb.layer.borderColor = [UIColor systemRedColor].CGColor;
    rb.translatesAutoresizingMaskIntoConstraints = NO;
    [rb.heightAnchor constraintEqualToConstant:44].active = YES;
    [rb addTarget:self action:@selector(onReboot) forControlEvents:UIControlEventTouchUpInside];
    
    [btnRow addArrangedSubview:rs];
    [btnRow addArrangedSubview:rb];
    [mainStack addArrangedSubview:btnRow];
    
    _status = [[UILabel alloc] init];
    _status.font = [UIFont systemFontOfSize:13];
    _status.textColor = [UIColor secondaryLabelColor];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 0;
    [mainStack addArrangedSubview:_status];
    
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
    
    [self modeChanged];
    [self updateLayerLabel];
    [self ovBundleChanged];
}

- (UILabel *)label:(NSString *)t size:(CGFloat)s dim:(BOOL)dim {
    UILabel *l = [[UILabel alloc] init];
    l.text = t;
    l.font = [UIFont systemFontOfSize:s];
    l.textColor = dim ? [UIColor secondaryLabelColor] : [UIColor labelColor];
    l.numberOfLines = 0;
    return l;
}

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

- (void)layerChanged {
    [self updateLayerLabel];
}

- (void)updateLayerLabel {
    int idx = (int)_segLayer.selectedSegmentIndex;
    if (idx == 0) {
        _layerLabel.text = @"×1：不额外加速，显式动画按全局倍率缩放";
    } else {
        _layerLabel.text = [NSString stringWithFormat:@"×%d：转圈/进度/旋转等 CAAnimation 额外加速，不影响块动画", (int)LayerBoostForIndex(idx)];
    }
}

- (void)dragChanged {
    [self updateDragLabel];
}

- (void)updateDragLabel {
    int idx = (int)_segDrag.selectedSegmentIndex;
    double coeff = DragCoeffForIndex(idx);
    if (idx == 0) {
        _dragLabel.text = @"未启用。要全系统加速请选 ×5 / ×10 / ×20；不建议与 dylib 加速同时开到最大（两个机制会叠加）。";
    } else if (idx == 4) {
        _dragLabel.text = [NSString stringWithFormat:@"⚠️ 极端档（写入 %.4f）：所有 UIKit 动画时长≈归零，等于全系统无动画。它会绕过 dylib 的 0.01s 安全下限，可能触发\"动画完成回调配对错乱\"类故障（例如微信图片预览卡死），并且会与 dylib 加速叠加。只在明确知道代价时使用。", coeff];
    } else {
        _dragLabel.text = [NSString stringWithFormat:@"当前已启用 %.2f（≈×%d，全系统生效，需注销/重启目标 App）。", coeff, DragMultiplierForCoeff(coeff)];
    }
}

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
        _ovFastScroll.on = [mine[@"FastScroll"] boolValue];
        _ovFastTap.on = [mine[@"FastTap"] boolValue];
        _ovLayer.selectedSegmentIndex = LayerIndexForBoost([mine[@"LayerBoost"] doubleValue]);
    }
    
    BOOL guarded = [HardGuardBundles() containsObject:bid];
    if (guarded) {
        _ovGuard.text = [NSString stringWithFormat:@"⚠️ %@ 在硬保护名单内：列表加速恒为关闭，配置界面无法打开（该 App 的列表状态机与 TV/CV hook 冲突，打开会卡死/崩溃）", bid];
        _ovList.on = NO;
        _ovList.enabled = NO;
    } else {
        _ovGuard.text = @"";
        _ovList.enabled = YES;
    }
}

- (void)ovSliderChanged {
    _ovSpeedLabel.text = [NSString stringWithFormat:@"×%.1f", _ovSpeed.value];
}

- (void)ovToggled {
    // 只刷新提示文案，绝不回读 plist
}

- (void)onSave {
    NSMutableDictionary *cfg = ReadConfig();
    cfg[@"Enabled"] = @(_swEnabled.on);
    cfg[@"Mode"] = @((int)_segMode.selectedSegmentIndex);
    cfg[@"Speed"] = @((double)_slider.value);
    cfg[@"SlowFactor"] = @((double)_sliderSlow.value);
    cfg[@"Spring"] = @(_swSpring.on);
    cfg[@"Extra"] = @(_swExtra.on);
    cfg[@"ListAccel"] = @(_swList.on);
    cfg[@"ZoomAccel"] = @(_swZoom.on);
    cfg[@"FastScroll"] = @(_swFastScroll.on);
    cfg[@"FastTap"] = @(_swFastTap.on);
    cfg[@"LayerBoost"] = @(LayerBoostForIndex((int)_segLayer.selectedSegmentIndex));
    cfg[@"FUBGEnabled"] = @(_swFUBG.on);
    cfg[@"FUBGSceneFake"] = @(_swFUBGScene.on);
    cfg[@"FUBGAudioKeep"] = @(_swFUBGAudio.on);
    cfg[@"FUBGFloatingBall"] = @(_swFUBGBall.on);
    
    NSMutableArray *bl = [NSMutableArray array];
    for (NSString *line in [_blacklist.text componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [bl addObject:t];
    }
    cfg[@"Blacklist"] = bl;
    
    // App 覆盖
    NSString *bid = _ovBundle.text ?: @"";
    if (bid.length && _ovOn.on) {
        NSMutableDictionary *ovAll = [cfg[@"AppOverrides"] isKindOfClass:[NSDictionary class]]
                                     ? [cfg[@"AppOverrides"] mutableCopy] : [NSMutableDictionary dictionary];
        NSMutableDictionary *mine = [ovAll[bid] isKindOfClass:[NSDictionary class]]
                                    ? [ovAll[bid] mutableCopy] : [NSMutableDictionary dictionary];
        mine[@"Enabled"] = @(_ovOn.on);
        mine[@"Mode"] = @((int)_ovMode.selectedSegmentIndex);
        mine[@"Speed"] = @((double)_ovSpeed.value);
        mine[@"Spring"] = @(_ovSpring.on);
        mine[@"Extra"] = @(_ovExtra.on);
        mine[@"ListAccel"] = @(_ovList.on);
        mine[@"ZoomAccel"] = @(_ovZoom.on);
        mine[@"FastScroll"] = @(_ovFastScroll.on);
        mine[@"FastTap"] = @(_ovFastTap.on);
        mine[@"LayerBoost"] = @(LayerBoostForIndex((int)_ovLayer.selectedSegmentIndex));
        ovAll[bid] = mine;
        cfg[@"AppOverrides"] = ovAll;
    }
    
    BOOL ok = WriteConfig(cfg);
    WriteAx(@"ReduceMotionEnabled", _swRM.on);
    WriteAx(@"PreferCrossFadeTransitions", _swCF.on);
    WriteAx(@"ReduceTransparencyEnabled", _swRT.on);
    WriteUIKitDrag(DragCoeffForIndex((int)_segDrag.selectedSegmentIndex));
    
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
        _status.text = [NSString stringWithFormat:@"重启：%@", way];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

@interface SIOAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation SIOAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[SIOVC alloc] init]];
    nav.navigationBar.prefersLargeTitles = YES;
    self.window.rootViewController = nav;
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
