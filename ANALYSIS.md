# SIOriginal v2.0.6 二进制审计报告

审计对象：`SIOriginal.dylib`（498,064 字节）、`SIOriginal.ipa`（109,532 字节）
审计方式：Mach-O 逐字节结构解析 + 源码静态核查（无编译环境，故未做符号级反汇编）

---

## 一、dylib 文件布局

v2.0.6 发布的 dylib 采用双 slice 结构，其中**只有第一个是 FAT 头指向的有效 slice**：

```
偏移        大小         内容
0x00000     56 B         FAT 头（声明 2 个架构）
0x00038     16,346 B     零填充（对齐到 2^14）
0x04000     238,016 B    slice A — arm64，FAT 条目 [0] 指向此处
0x3E000     7,744 B      零填充
0x40000     235,920 B    slice B — arm64e，含 __auth_stubs / __auth_got
0x79BB0     —            文件结束
```

两个 slice 各含 **139 个 `_sio_*` 符号**，功能完全相同（日志文案逐字一致：
`[SIOriginal] v2.0.6 hooks installed in %@ (enabled=%d mode=%d speed=%.1f ...)`），
差别仅在 slice B 多了 arm64e 指针认证段。`arm64` 与 `arm64e` 在 139 个功能符号上
**逐一对应，无一方独有**。

### 确认的缺陷：FAT 头第 2 个架构条目畸形

```
[0] cputype=0x0100000C (arm64)  subtype=0x0        offset=16,384  size=238,016  align=2^14
[1] cputype=0x80000002 (x86_64) subtype=0x40000    offset=235,920  size=14      align=2^0
```

第 2 条目指向的偏移 235,920 处并非 Mach-O 头，而是 ASCII 文本：

```
70 70 4f 76 65 72 72 69 64 65 00  =  "ppOverride\0"
5f 53 49 4f 5f 62 75 6e 64 6c 65  =  "_SIO_bundleID"
```

即该条目落在 `__objc_methname` 字符串区中间。`0x80000002` 也不是合法的
`CPU_ARCH_ABI64|CPU_TYPE_X86_64`（应为 `0x01000007`）。

**影响**：`lipo -info` 只读取 FAT 头里的架构名列表、不校验每个条目能否解析，
所以这个缺陷能一路通过 CI 的 `lipo -info | grep arm64` 检查，直到注入器实际
遍历 slice 时才暴露。`tools/audit_dylib.py` 已加入构建流程拦截此类问题。

### 冗余数据

- FAT 条目合计声明 238,030 字节，实际有效内容到 254,400 字节
- 文件尾部 243,664 字节（占 48.9%）未被任何 slice 覆盖
- slice A 与 slice B 之间有 7,744 字节零填充

这些不导致功能故障，但会让 dyld 多映射近一半文件。对应你提的「加载提速」：
产物瘦身是有效方向，详见第五节。

---

## 二、IPA 结构

```
Payload/SIOriginal.app/
├── SIOriginal                    373,920 B   主程序
├── Info.plist                     1,633 B
├── _CodeSignature/CodeResources    2,874 B
├── AppIcon.png / Icon-60@2x / Icon-60@3x / Icon-76@2x / Icon-83.5@2x
```

| 检查项 | 结果 |
|---|---|
| 主程序架构 | FAT，2 条目（同样存在畸形 x86_64 条目，offset=177,312 size=14） |
| 主程序 filetype | 2 = `MH_EXECUTE`，正常 |
| 最低系统 | iOS 14.0（`minos=0xe0000`），SDK 18.5（`sdk=0x120500`） |
| `embedded.mobileprovision` | **不存在** |
| `Frameworks/` 目录 | **不存在** |
| IPA 内是否含 dylib | **否** |

### 关键：IPA 与 dylib 无引用关系

主程序 23 条 load command 中**没有任何 `LC_LOAD_DYLIB` 指向 `SIOriginal.dylib`**，
二进制内也搜不到 `SIOriginal.dylib`、`DYLD_INSERT_LIBRARIES`、`dlopen` 字样。
主程序与 dylib 之间唯一的通信通道是 Darwin 通知
`com.local.sioriginal.settingschanged`。

结论：IPA 是纯配置 App（写入 `/var/Managed Preferences/mobile/com.apple.UIKit.plist`），
dylib 需由 TrollFools 注入目标 App 生效。二者是**独立交付物**，不存在
「IPA 内应打包 dylib」的关系。

### 签名

entitlements（主程序）：

```xml
<key>get-task-allow</key><true/>
<key>platform-application</key><true/>
<key>com.apple.private.security.no-sandbox</key><true/>
<key>com.apple.private.persona-mgmt</key><true/>
<key>com.apple.private.security.storage.AppDataContainers</key><true/>
```

平台应用级私有授权，配合无 mobileprovision —— TrollStore 式伪签。
注意主程序**确实带**这些私有授权，这是正确的（配置 App 需要写
`/var/Managed Preferences` 与提权重启）；`build.sh` 与 CI 均已确保
**dylib 侧不带任何 entitlement**（`ldid -S` 无参数），这一点当前实现是对的。

---

## 三、源码修复

环境限制：当前为 Windows（`win32`，Git Bash），无 Xcode / iOS SDK /
`ldid` / `codesign`，**无法编译验证**，因此以下改动均经过静态核查与逻辑推演，
但未经真机运行验证。

### 修复 1：转圈动画缺少缩放标记（真实缺陷）

`sio_layer_addAnim` 的 `isSpinner` 分支改完时长后**没有调用
`SIO_markAnimScaled`**，而通用分支的防重复缩放守卫
`![REDACTED_EMAIL](anim)` 正是依赖这个标记。

`UIActivityIndicatorView` 的 `-setAnimating:` 会把**同一个 CAAnimation 实例**
反复 `addAnimation:`。没有标记意味着该守卫对这个动画永久失效。

同时补上原始时长的取值判据：`SIO_getOrigDur` 存的是 App 上一次
`setDuration:` 传入的值，仅当它与当前 `duration` 一致时才采信，否则用当前值重算。

```objc
double cur    = ((CAAnimation *)anim).duration;
double saved  = SIO_getOrigDur(anim);
double orig   = (saved > 0.0 && fabs(saved - cur) < 1e-9) ? saved : cur;
...
SIO_markAnimScaled(anim);
```

**诚实说明**：我最初判断这里存在「逐轮累积加速」的严重 bug，并写了长注释。
随后用数值模拟逐轮推演，发现**该判断是错的**——`kSIOSpinnerFloor = 0.4` 的钳制
本已吸收全部漂移（只要 `orig/speed < 0.4`，结果恒为 0.4，与 `orig` 具体值无关；
不触发钳制时 App 每轮都重新 `setDuration:`，`saved == cur` 恒成立）。
因此已撤回那段不实注释，只保留「打标」这一项确有价值的改动。
**教训记录在案**：0.4s 钳制是个吸收器，推断 bug 前应先确认兜底逻辑是否已覆盖。

### 修复 2：注入确认提示的重试退避（体验缺陷）

`SIO_showInjectToast` 固定 0.6s 重试 5 次，全部挤在头 3 秒内。
但 `SIO_showToast` 失败的主因是「App 尚未起完 / 无 active scene」，
属秒级以上事件 —— 0.6s 连打 5 次必然全部落空，等于没有重试。

改为指数退避 `0.5 → 0.75 → 1.1 → 1.7 → 2.5` 秒，累计约 6.5s，
覆盖真实冷启动窗口，总次数不变（仍为 5 次，不增加打扰）。

### 修复 3：配置缺失的可观测性

`SIO_reload` 在 plist 不可读时静默 `return` 并回落默认值。用户看到
「配置没生效」时无从判断是 plist 缺失、路径错、还是权限不足 ——
而这三者处理方式完全不同。补一条日志说明回落到了默认值及原因。

### 未改动但加了防呆注释

`App/main.m` 的 `WriteConfig` 中 `if (cfg[k])` 曾被我误判为 bug
（以为 `if (id)` 会按 NSNumber 的**值**判真假，导致 `@NO` 写不进 plist）。
**这是错的**：Objective-C 裸 `id` 条件只判**指针非空**，而 `@NO` 是
tagged pointer（arm64 上为 `0x4`，非 nil），因此 `@NO` 能正确写入。
已在源码加注释固化此认知，防止后人误改成值判断而引入真实 bug。

---

## 四、新增工具

### `tools/static_check.py`

编译前的静态核查，覆盖项目历史上反复出现的三类错误：

- 括号 / 花括号配平（先剥离注释与字符串字面量，避免误计）
- 原 IMP 判空：识别宏判空、`__builtin_expect`、短路条件内判空、
  显式布尔判空四种写法（初版只认宏，产生 4 处误报，已修正）
- hook 符号配对：声明了 `o_xxx` 却从未被赋值

当前结果：**通过**（SIOriginal.m 3033 行、main.m 1410 行均无异常）。

### `tools/audit_dylib.py`

Mach-O 结构审计，逐条目校验 FAT 架构表。已接入 `build.sh` 与
`.github/workflows/build.yml`，畸形架构条目会直接让构建失败。

对当前 v2.0.6 产物运行的结果：

```
[0] arm64      offset=16,384  size=238,016  align=2^14
[1] x86_64(h)  offset=235,920 size=14       align=2^0
✗ arch[1]: slice 偏移 235920 处不是 Mach-O，实际内容是 ASCII 文本 'ppOverride'
```

---

## 五、后续建议

**加载提速（产物瘦身）**

当前 498KB 中约 49% 是未被任何 slice 覆盖的尾部数据。可行方向：

1. 用 `ldid` 重新签名后追加的签名区（`LC_CODE_SIGNATURE`）是否可压缩
2. 确认构建产物为何比源码逻辑所需体积大 2 倍——两个 slice 功能完全相同，
   理论上只需保留 arm64e 一个（A12+ 为主流），但会牺牲 armv8 老设备兼容性
3. 剥离调试段：`__DWARF` 不存在，但可检查 `LC_FUNCTION_STARTS` 覆盖范围

这三项都需要真机验证取舍，不建议盲改。

**功能增强的合理方向**

代码注释里已列出两条线索，值得优先跟进：

- `_gIsWeChat` 特判只覆盖 `com.tencent.xin`，而同类预览放大态问题
  在其他 App（小红书、淘宝图片预览等）同样存在 —— 可考虑改为
  「通用放大态探测 + 按 bundle id 灰名单」
- 注释 [7] 明确列出了**无法用改时长加速**的引擎（SVGA / Lottie /
  RN Reanimated / Ugen），这些是当前能力边界。若要覆盖需换机制
  （CADisplayLink 层介入），属独立课题

---

*本报告基于静态分析生成，未经编译或真机验证。修复 1、2、3 建议在 macOS 上
构建后于真机确认。*
