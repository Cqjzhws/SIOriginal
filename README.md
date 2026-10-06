# SIOriginal — iOS 动画加速 + 真后台保活

面向 iOS 14–17（含 iOS 16/17）的动画加速方案，共 **100+ 个 Hook**，适配 TrollStore / TrollFools，无需 CydiaSubstrate。

## v2.0.8 ProMotion 120Hz 强制

- **[新功能] ProMotion120 开关（默认关，全局）**：很多 App 用 CADisplayLink 把渲染
  循环锁在 60Hz —— `setPreferredFramesPerSecond:60` 或 iOS 15+ 的
  `setPreferredFrameRateRange:`（上限 60）。开关打开后：
  - `setPreferredFramesPerSecond:` 恰好 60 的请求改写为设备实际上限（ProMotion 120）；
  - `setPreferredFrameRateRange:` 上限 ≤60 的区间把 maximum/preferred 拓宽到设备上限；
  - **安全边界**：刻意低帧（视频同步 30/24，<60）一律不动；60Hz 机型
    `maximumFramesPerSecond=60`，整个功能自动无效、零开销；iOS 14 无 range 入口，
    swizzle 静默跳过；
  - `CAFrameRateRange` 在 SDK 头文件带 iOS 15 可用性标注，dylib 用 ABI 一致的
    3×float 结构体副本（arm64 HFA）编译，部署目标仍为 iOS 14；
  - 副作用：全局 120Hz 增加功耗，依赖 60 帧节奏的动画计步可能变化 —— 默认关。

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
