# SIOriginal v3.0

> iOS 动画加速 Tweak + 配置 App。在 v2.5.0 / v2.5.1 基础上**重构架构**，
> 目标是「性能最强、兼容性最全」，并保持「只加速不变慢」的行为正确性。

---

## 这是什么

- **Tweak（`SIOriginal.dylib`）**：注入到目标 App，把 UI 动画时长按倍率缩短。
  覆盖 CoreAnimation、UIView 动画、导航/模态转场、控件、列表、滚动等 100+ 个入口。
- **配置 App（`SIOriginal.ipa`）**：图形化设置界面。写入
  `/var/Managed Preferences/mobile/com.apple.UIKit.plist`，通过 Darwin 通知热重载。

**部署目标**：iOS 14.0+（兼顾 iOS 11 起的兼容路径）。
**架构**：`arm64` + `arm64e` 双架构（A12+ 设备主程序加载 arm64e slice，缺了会被 dyld 拒绝）。

---

## v3.0 相对 v2.5.1 的改动

### 架构层面（主要价值）

| 改动 | 具体内容 |
|---|---|
| **模块化** | 4772 行单文件 → 15 个模块。配置 / 引擎 / 平台 / 调度 / 安装 / UI / 保活各自唯一职责 |
| **单一配置入口** | `SIOConfigState gSIOCfg` 唯一状态；`SIOPrefSnapshot()` 唯一读盘出口；`SIOBundleMatches()` 唯一匹配实现 |
| **单一交换入口** | `SIOExchange()` 唯一实现，内建重复安装保护、继承污染防护、交换预算 |
| **声明式安装表** | `SIOHookEntry[]`：每个 hook 自声明 `stage/gate/minOS/maxOS/needCaps`，`SIOInstaller` 统一编排 |
| **三档安装栅栏** | `Boot`（pre-main 19 条）/ `PostLaunch` / `OnDemand`（默认关闭项零交换） |
| **能力位图** | `SIOCaps` 运行时探测，**不靠版本号猜 API** |

### 功能层面

| 改动 | 具体内容 |
|---|---|
| **内存护栏** | 双路径监听（内存压力源 + 内存告警通知），两级降级、压力解除后按快照还原 |
| **调度策略** | 内部工作队列 QoS = `UTILITY`，不与首屏/滚动抢 CPU |
| **系统系数补偿** | 修掉「hook 缩放 × `UIAnimationDragCoefficient`」的双重加速（用户设 ×5 实际 ≈×8.6） |
| **120Hz 高刷** | 从 v2.5.1 的「无条件全局生效」迁移为独立模块 `SIOHighRefresh.m` + 可开关（默认关），60Hz 屏恒等零影响 |
| **保活重构** | 生命周期只用 `NSNotificationCenter` 一条路径；配置复用唯一快照；定时器随前后台启停 |
| **保留** | v2.x 全部 hook、帧对齐引擎、速率模式、全局兜底系数、SB 编辑模式护栏 |

> 每个优化项的**适用系统 / 预期收益 / 风险点 / 验证方式**见 [OPTIMIZATIONS.md](OPTIMIZATIONS.md)。

---

## 工程结构

```
SIOriginal-v3/
├── Tweak/
│   ├── include/SIOInternal.h      ← 全项目唯一内部契约（配置状态 / 时长换算 / 门控 / 能力位 / 安装表类型）
│   ├── SIOCore.m                  ← TLS + 唯一方法交换实现 + 交换计数
│   ├── SIOPlatform.m              ← 版本 / 能力位 / 巨魔探测（零磁盘 IO）
│   ├── SIOConfig.m                ← 唯一配置入口（缓存 + 热重载 + App 覆盖）
│   ├── SIOEngine.m                ← 派生量 + 门控唯一实现
│   ├── SIOScheduler.m             ← 启动栅栏 / 内存护栏 / QoS
│   ├── SIOUI.m                    ← Toast / 悬浮提示（自绘 UI 旁路）
│   ├── SIOInstaller.m             ← 三档安装编排 + 唯一 constructor
│   ├── SIOBackground.m            ← 真后台保活（场景伪装 + 音频断言）
│   ├── hooks/
│   │   ├── SIOCoreAnimation.m     ← CAAnimation / CATransaction / CALayer / CASpring（Boot 19 条）
│   │   ├── SIOUIViewAnim.m        ← UIView 类方法 / UIViewPropertyAnimator / UIWindow
│   │   ├── SIOViewControllers.m   ← 33 个导航/模态/栏/Item 转场
│   │   ├── SIOControls.m          ← 控件族 + Cell
│   │   ├── SIOCollections.m       ← 列表族 27 条（默认关）
│   │   ├── SIOScrollView.m        ← 滚动/缩放/长按
│   │   ├── SIOHighRefresh.m       ← 120Hz 高刷解锁（3 条 PostLaunch，默认关）
│   │   └── SIOSpringBoard.m       ← 桌面/Switcher 编辑态护栏
│   └── support/FUBGNoiseData.h    ← 静音白噪声（音频断言用）
├── App/
│   ├── main.m                     ← 配置 App（纯 UIKit）
│   ├── Info.plist
│   └── assets/                    ← 图标
├── tools/
│   ├── check_v300.py              ← v3.0 架构不变量核查（15 项）
│   ├── check_symbols.py           ← 跨模块符号一致性（声明↔定义、重复定义、全局变量）
│   ├── check_config_keys.py       ← 配置键闭环（防「界面有开关但无效」）
│   ├── static_check.py            ← 括号配平 / IMP 判空 / 符号配对
│   ├── test_frame_align.py        ← 帧对齐算法验证
│   ├── audit_dylib.py             ← FAT 结构审计
│   └── ...
├── .github/workflows/build.yml    ← CI：静态核查 → 编译 → 审计 → 打 IPA → Release
├── Makefile                       ← Theos 入口（可选）
├── control                        ← deb 元数据
└── entitlements.plist             ← 配置 App 私有 entitlement
```

**设计原则**：跨模块共享的一切，在 `SIOInternal.h` 里**只有一处声明**。
每个 hook 只需回答两个问题：① 要不要旁路？（`SIO_blocked`）② 目标时长是多少？（`SIO_targetDuration`）。

---

## 构建

### 方式一：GitHub Actions（推荐，产出 IPA）

推送到任意分支即触发构建，产物在 Actions 的 Artifacts 里；
推 `v*` tag 会额外创建 Release（可直接下载 IPA）。

CI 流程：**静态核查 → 编译 dylib（双架构）→ 产物结构审计 → 编译 App → 签 IPA → 上传**。

### 方式二：本地（需 macOS + Xcode）

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

clang -dynamiclib -O2 -arch arm64 -arch arm64e \
  -isysroot "$SDK" -target arm64-apple-ios14.0 \
  -framework UIKit -framework QuartzCore -framework CoreGraphics \
  -fobjc-arc -I Tweak/include -I Tweak \
  -Wl,-no_fixup_chains -install_name @rpath/SIOriginal.dylib \
  -o SIOriginal.dylib Tweak/*.m Tweak/hooks/*.m

ldid -S SIOriginal.dylib        # 注意：不嵌入 entitlement
```

### 方式三：Theos（可选）

`make` 即可（见 `Makefile`）。编译选项与 CI 保持一致。

---

## 关键约束（改动前必读）

1. **dylib 必须无 entitlement 签名**。用 `ldid -Sentitlements.plist` 会嵌入
   `platform-application` / `no-sandbox` 等私有授权；TrollFools 把库注入普通 App 后
   AMFI 会直接 SIGKILL —— 表现为目标 App 启动即闪退。**只能 `ldid -S`**。

2. **必须双架构**（`arm64` + `arm64e`）。A12+ 设备主程序加载 arm64e slice，
   单架构 dylib 注入后 dyld 拒绝加载 —— 表现为「注入成功但功能完全不生效」。

3. **不使用保活的 App，启动路径不得出现 AVFoundation / UserNotifications**。
   二者一律 `dlopen` + `objc_getClass` 运行时解析。

4. **加速只能变快不能变慢**。时长下限口径必须是 `min(floor, orig)`。

5. **不要给 Boot 档添加条目**，除非它真的是首屏正确性所必需。
   pre-main 每多一次交换都算启动耗时。

6. **列表 hook 绝不改写 `animated` 语义**。这是黑屏级事故的入口。

---

## 验证

```bash
python3 tools/static_check.py .      # 括号配平 / IMP 判空 / 符号配对
python3 tools/check_v300.py .       # 架构不变量 15 项（含构建清单完整性）
python3 tools/check_symbols.py .    # 跨模块符号：声明↔定义 / 重复定义 / 全局变量
python3 tools/check_config_keys.py .# 配置键闭环：白名单 ↔ dylib 读取
python3 tools/test_frame_align.py   # 帧对齐数值不变量（60/90/120Hz）
```

> 五个脚本都是**零依赖纯 Python**，在 Windows / Linux / macOS 上均可运行，
> 也是 CI 的第一步 —— 编译之前先把结构问题挡掉。
> 其中 `check_config_keys.py` 专门防「界面有开关但功能无效」这类静默失效。单侧写入键
> （`AppOverrides` / `Blacklist` / `FUBG*` / `DragCoef`）与 dylib 内部高级键的契约见
> `SIOInternal.h` 的「配置键的三类契约」。

真机验证顺序见 [OPTIMIZATIONS.md §7](OPTIMIZATIONS.md)。

---

## 致谢

- 保活场景伪装思路移植自 **ImmortalizerJailed**（GPLv3, Serge Alagon），致谢 @khanhduytran0。
- 静音白噪声波形取自同上项目并作了修改。
- 帧对齐 / 速率模式 / 时长换算的三条安全边界为本项目在 v2.x 迭代中逐步总结。

## 许可

跟随上游项目（GPLv3）。
