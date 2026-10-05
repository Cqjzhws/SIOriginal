# SIOriginal — iOS 动画加速 + 真后台保活

面向 iOS 14–17（含 iOS 16/17）的动画加速方案，v1.8.18 共 **50+ 个 Hook**，适配 TrollStore / TrollFools，无需 CydiaSubstrate。

## 特性

**动画加速**
- 三种模式：加速（×1–×50）、慢放（×1–×10）、瞬切（0.01s）
- 弹簧参数缩放（保持物理一致性）
- 进阶转场（导航栈 / 模态弹窗）
- 显式动画额外倍率 LayerBoost（转圈/进度/旋转单独加速 ×1–×10）
- 列表加速（TV/CV 全家桶，高危，默认关）
- 缩放动画加速（UIScrollView，实验性，默认关）
- 交互手感：滑行惯性加急 + 点击零延迟
- UIKit 全局动画系数（×5/×10/×20/极端档）
- 系统动态效果：减弱动态效果 / 交叉淡出 / 减少透明度

**v1.8.18 新增 hook**
- UIRefreshControl：beginTracking / endTracking
- UINavigationBar：大标题过渡动画
- UIPageViewController：页面切换
- UIDocumentInteractionController：预览动画

**安全防护**
- CAAnimation 幂等缩放标记（修双重缩放 bug）
- 列表 hook 硬保护名单（顺丰同城骑士 / SpringBoard 永不开启）
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
<key>FastScroll</key><false/>
<key>FastTap</key><false/>
<key>LayerBoost</key><real>1.0</real>
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
- dylib：纯 clang 直编（-O2）+ ad-hoc 签名
- IPA：clang 直编 .app + `codesign --entitlements`（含 no-sandbox）后打包 Payload
- 推送 `v*` tag 自动发布 GitHub Release

## 安装
1. TrollStore 安装 `SIOriginal.ipa`（配置 App）
2. TrollFools 选择目标 App → 注入 `SIOriginal.dylib` → 重开 App 生效
3. 在配置 App 中调整参数 → 保存 → 注销/重启
