#!/usr/bin/env python3
"""
SIOriginal v2.5.0 性能改动 —— 语义级交叉引用核查
================================================
定位：与 `static_check.py`（括号配平 / 原 IMP 判空 / hook 符号配对）互补。
本脚本只针对 v2.5.0 这一轮性能改动中**容易悄悄回退**的不变量做核查。

为什么需要它：本轮的几项优化都是「把某件昂贵的事挪走 / 少做一次」，
一旦后续有人改动代码把它们挪回来，编译不会报错、功能也不会坏，
只是性能悄悄退化 —— 而这类退化在真机上是很难归因的。
这些不变量必须变成 CI 里会失败的断言。

覆盖的 14 条不变量（1–9 为 v2.5.0 性能轮，10–14 为 v2.6.0 TimeMode 轮）：

  V250-1  构造函数内不得直接调用 SIO_framePeriod() / SIO_reduceMotionOn()
          （会触发 UIScreen 初始化与 dlopen 私有框架，见 P0-1）
  V250-2  SIO_installLayerCoreHooks 必须前向声明（构造期调用点在定义之前）
  V250-3  gPrefCache 不得在锁外裸赋值（ARC 下并发赋值 = 悬垂指针，见 P2）
  V250-4  watchdog 必须成对启停（进后台起 / 回前台停）
  V250-5  SIODoubleBox 必须含 scaled 字段（关联对象合并的前提）
  V250-6  SIO_animScaled / SIO_markAnimScaled 必须走盒子，不得再用独立关联键
  V250-7  gImplicitActionDur 必须在 SIO_reload 的两个分支里都赋值
  V250-8  os/lock.h 必须已 import（os_unfair_lock 依赖）
  V250-9  启动日志不得再内联调用惰性求值函数（参数表里不得出现）
  V250-10 sio_CACurrentMediaTime 必须有线程局部重入保护
          （门控走 SIO_blocked() → 微信放大态探测 → 又调 CACurrentMediaTime()
            → 无限递归栈溢出，见文件头 v2.6.0 [4]）
  V250-11 重绑定目标只允许 CACurrentMediaTime —— 绝不许碰墙钟时间源
          （mach_absolute_time / gettimeofday / clock_gettime /
           CFAbsoluteTimeGetCurrent 会搞坏 TLS 证书校验、JWT 过期、DRM 租期）
  V250-12 TimeMode 三个开关的默认值必须全为 NO（fail-safe）
  V250-13 白名单为空必须判定为「无人启用」
  V250-14 SIO_timeModeRefresh() 必须在 SIO_reload 的两个分支里都调用

用法：
    python3 tools/check_v250.py [源码根目录]
退出码 0 = 通过，1 = 发现问题
"""
import os
import re
import sys

DEFAULT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def read(root, rel):
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        return None
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_comments(src: str) -> str:
    """
    去掉 // 与 /* */ 注释内容，但**保留换行**。

    保留换行的原因：问题报告里的行号必须对得上原始文件，否则使用者要自己去
    猜「注释被剥掉之后偏移了多少行」。用等量的空白/换行替换注释内容，
    脱注释后的文本与原文行号一一对应，报告里的行号可直接跳转。
    （本项目文件里有大量中文注释块，若不保留行号，偏移可达数百行。）
    """
    out, i, n = [], 0, len(src)
    while i < n:
        if src[i] == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                out.append(' ')
                i += 1
        elif src[i] == '/' and i + 1 < n and src[i + 1] == '*':
            i += 2
            out.append('  ')
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                out.append('\n' if src[i] == '\n' else ' ')
                i += 1
            i += 2
            out.append('  ')
        else:
            out.append(src[i])
            i += 1
    return ''.join(out)


def region_of_constructor(code: str):
    """
    取出 SIOriginalInit 构造函数体。

    返回 (region_text, base_line)：base_line 是该 region 在**原始文件**中的
    起始行号，用于把 region 内的相对行号换算成可直接跳转的绝对行号。
    少了这一步，报告里的行号会指到构造函数开头附近而不是真正的出错处。
    """
    m = re.search(r'__attribute__\(\(constructor\)\)\s*\n?\s*static\s+void\s+SIOriginalInit\s*\([^)]*\)\s*\{',
                  code)
    if not m:
        return "", 0
    base_line = code[:m.start()].count('\n') + 1
    start = m.end() - 1
    depth, i = 0, start
    while i < len(code):
        if code[i] == '{':
            depth += 1
        elif code[i] == '}':
            depth -= 1
            if depth == 0:
                return code[start:i + 1], base_line
        i += 1
    return code[start:], base_line


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_ROOT
    tweak = read(root, os.path.join("Tweak", "SIOriginal.m"))
    app = read(root, os.path.join("App", "main.m"))
    problems = []

    if tweak is None:
        print("[FATAL] 找不到 Tweak/SIOriginal.m")
        return 1

    raw = tweak
    code = strip_comments(raw)

    # ---------- V250-1 / V250-9：启动日志不得内联惰性求值 ----------
    ctor, ctor_base = region_of_constructor(code)
    if not ctor:
        problems.append("V250-1  未能定位 SIOriginalInit 构造函数体，无法核查")
    else:
        for fn in ("SIO_framePeriod", "SIO_reduceMotionOn"):
            # 允许出现在调用 SIO_logFingerprintLater() 的语句里，
            # 但不允许在构造体内被直接求值（尤其不能出现在 NSLog 参数表）
            for m in re.finditer(r'\b%s\s*\(' % re.escape(fn), ctor):
                line = ctor_base + ctor[:m.start()].count('\n')
                problems.append(
                    f"V250-1  构造函数体内直接调用了 {fn}()（第 {line} 行附近）—— "
                    f"该函数是惰性入口，在 pre-main 求值会触发 UIScreen 初始化 / dlopen "
                    f"私有框架，抵消启动优化。应改为只在 SIO_logFingerprintLater() 里调用。")

        # NSLog 参数表里不得出现惰性求值调用
        for m in re.finditer(r'NSLog\s*\(', ctor):
            # 取该 NSLog 调用的括号范围
            i, depth = m.end() - 1, 0
            while i < len(ctor):
                if ctor[i] == '(':
                    depth += 1
                elif ctor[i] == ')':
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            stmt = ctor[m.start():i + 1]
            for fn in ("SIO_framePeriod", "SIO_reduceMotionOn"):
                if re.search(r'\b%s\s*\(' % re.escape(fn), stmt):
                    line = ctor_base + ctor[:m.start()].count('\n')
                    problems.append(
                        f"V250-9  构造函数里的 NSLog 参数表包含 {fn}()（第 {line} 行附近）—— "
                        f"NSLog 参数必须先求值才能调用，等于在 pre-main 强制执行该惰性入口。")

    # ---------- V250-2：前向声明 ----------
    if "static void SIO_installLayerCoreHooks(void);" not in code:
        problems.append(
            "V250-2  缺少 `static void SIO_installLayerCoreHooks(void);` 前向声明 —— "
            "它在构造函数中被调用但定义位于文件后部，缺声明会导致 "
            "implicit declaration 编译错误（本项目历史上出过同类问题）。")

    # ---------- V250-3：gPrefCache 不得裸赋值 ----------
    head = code.split("static void SIO_reload")[0]
    # 允许的赋值点：SIO_prefSnapshot 内、SIO_invalidatePrefCache 内
    allowed = 0
    for fn in ("SIO_prefSnapshot", "SIO_invalidatePrefCache"):
        m = re.search(r'\b%s\s*\([^)]*\)\s*\{' % re.escape(fn), code)
        if m:
            allowed += 1
    assigns = re.findall(r'^\s*gPrefCache\s*=', code, re.M)
    # 允许出现的次数：prefsnapshot 里 1 次 + invalidate 里 1 次
    if len(assigns) > 2:
        problems.append(
            f"V250-3  gPrefCache 被赋值 {len(assigns)} 次（预期最多 2 次："
            f"SIO_prefSnapshot / SIO_invalidatePrefCache）—— "
            f"锁外裸赋值在 ARC 下与并发读取构成 release 竞争，可致悬垂指针崩溃。")
    if allowed < 2:
        problems.append(
            "V250-3  未找到 SIO_prefSnapshot / SIO_invalidatePrefCache 的定义，"
            "无法确认 gPrefCache 的加锁访问路径完整。")

    # ---------- V250-4：watchdog 成对启停 ----------
    if not re.search(r'_fbg_startWatchdog\s*\(\s*\)', code):
        problems.append("V250-4  未找到 _fbg_startWatchdog() 的调用点")
    if not re.search(r'_fbg_stopWatchdog\s*\(\s*\)', code):
        problems.append("V250-4  未找到 _fbg_stopWatchdog() 的调用点")
    # 启停必须分别落在进后台 / 回前台通知块里
    bg = code.find("UIApplicationDidEnterBackgroundNotification")
    fg = code.find("UIApplicationWillEnterForegroundNotification")
    if bg > 0 and fg > 0:
        lo, hi = sorted((bg, fg))
        seg_bg = code[lo:hi]
        seg_fg = code[hi:hi + 3000]
        if "UIApplicationDidEnterBackgroundNotification" in seg_bg:
            if not re.search(r'_fbg_startWatchdog\s*\(\s*\)', seg_bg):
                problems.append("V250-4  进后台分支里没有 _fbg_startWatchdog()")
            if re.search(r'_fbg_stopWatchdog\s*\(\s*\)', seg_bg):
                problems.append("V250-4  进后台分支里出现了 _fbg_stopWatchdog()（应在回前台分支）")
        if not re.search(r'_fbg_stopWatchdog\s*\(\s*\)', seg_fg):
            problems.append("V250-4  回前台分支里没有 _fbg_stopWatchdog()")

    # ---------- V250-5：盒子字段 ----------
    if not re.search(r'@interface\s+SIODoubleBox\s*:\s*NSObject\s*\{\s*@public\s+double\s+value\s*;\s*BOOL\s+scaled\s*;',
                     code):
        problems.append(
            "V250-5  SIODoubleBox 缺少 `BOOL scaled` 字段 —— "
            "「已缩放」标记与原时长必须共用同一个盒子，否则每次显式动画要触碰 "
            "关联对象表三次（全局自旋锁竞争）。")

    # ---------- V250-6：不得再用独立关联键 ----------
    if re.search(r'\bkSIOScaledMark\b', code):
        problems.append(
            "V250-6  代码中仍出现 kSIOScaledMark —— 该关联键应已废弃，"
            "标记改存 SIODoubleBox.scaled。")
    if not re.search(r'static\s+inline\s+SIODoubleBox\s*\*\s*SIO_boxFor', code):
        problems.append("V250-6  未找到 SIO_boxFor()（合并后的关联对象访问入口）")

    # ---------- V250-7：gImplicitActionDur 两个分支都赋值 ----------
    n_assign = len(re.findall(r'gImplicitActionDur\s*=\s*SIO_targetDuration\s*\(\s*0\.25\s*\)', code))
    if n_assign < 2:
        problems.append(
            f"V250-7  gImplicitActionDur 只在 {n_assign} 处赋值（应为 2 处："
            f"SIO_reload 的正常分支与 plist 缺失分支）—— "
            f"少一处会导致该配置路径下隐式动画用旧值换算。")

    # ---------- V250-8：os/lock.h ----------
    if '#import <os/lock.h>' not in raw:
        problems.append("V250-8  未 import <os/lock.h> —— os_unfair_lock 无法使用")

    # ---------- V250-10：时间钩的重入保护 ----------
    m = re.search(r'static\s+CFTimeInterval\s+sio_CACurrentMediaTime\s*\(\s*void\s*\)\s*\{', code)
    if not m:
        problems.append("V250-10 未找到 sio_CACurrentMediaTime 的定义（TimeMode 的时间钩）")
    else:
        i, depth = m.end() - 1, 0
        while i < len(code):
            if code[i] == '{':
                depth += 1
            elif code[i] == '}':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = code[m.end() - 1:i + 1]
        if 'gInTimeHookTLS' not in body:
            problems.append(
                "V250-10 sio_CACurrentMediaTime 内没有 gInTimeHookTLS 重入保护 —— "
                "门控 SIO_timeModeActive() → SIO_blocked() → SIO_wechatZoomPreviewActive() "
                "会再次调用 CACurrentMediaTime()，无保护即无限递归、栈溢出（微信里必然触发）。")
        else:
            if not re.search(r'if\s*\(\s*gInTimeHookTLS\s*\)', body):
                problems.append("V250-10 缺少 `if (gInTimeHookTLS) return real;` 重入短路分支")
            if not re.search(r'gInTimeHookTLS\s*=\s*YES', body):
                problems.append("V250-10 重入标记从未被置位（gInTimeHookTLS = YES）")
            if not re.search(r'gInTimeHookTLS\s*=\s*NO', body):
                problems.append("V250-10 重入标记从未被清除（gInTimeHookTLS = NO）")
        if not re.search(r'if\s*\(\s*!o_CACurrentMediaTime\s*\)', body):
            problems.append(
                "V250-10 时间钩未对 o_CACurrentMediaTime 判空 —— 项目红线 #4；"
                "且此处不能回退去调 CACurrentMediaTime()（那就是本函数，自递归）。")

    # ---------- V250-11：重绑定目标白名单 ----------
    rb_names = re.findall(r'rb\.name\s*=\s*@?"([^"]+)"', code)
    if not rb_names:
        problems.append("V250-11 未找到 TimeMode 的重绑定目标符号")
    for nm in rb_names:
        if nm != "CACurrentMediaTime":
            problems.append(
                f"V250-11 TimeMode 重绑定了非预期符号 `{nm}` —— "
                f"只允许 CACurrentMediaTime。缩放墙钟时间源（mach_absolute_time / "
                f"gettimeofday / clock_gettime / CFAbsoluteTimeGetCurrent）会搞坏 "
                f"TLS 证书校验、JWT 过期、HTTP 缓存、FairPlay DRM 与自动锁屏。")
    rb_repl = re.findall(r'rb\.replacement\s*=\s*\(void\s*\*\)\s*(\w+)', code)
    for rp in rb_repl:
        if rp != "sio_CACurrentMediaTime":
            problems.append(f"V250-11 重绑定的替换函数不是 sio_CACurrentMediaTime：`{rp}`")

    # ---------- V250-12：三个开关默认全关 ----------
    for var in ("gTimeModeOn", "gTimeWhitelisted", "gTimeDeepRebind"):
        if not re.search(r'static\s+BOOL\s+%s\s*=\s*NO\s*;' % var, code):
            problems.append(
                f"V250-12 {var} 的静态默认值不是 NO —— 时间膨胀是侵入性最强的手段，"
                f"任何一项默认打开都会让「改了配置却全进程加速」成为默认值。")
    if not re.search(r'd\[@"TimeMode"\]\s*\?\s*\[d\[@"TimeMode"\]\s*boolValue\]\s*:\s*NO', code):
        problems.append(
            'V250-12 TimeMode 缺键时必须回落 NO（当前写法不是 `d[@"TimeMode"] ? ... : NO`）')

    # ---------- V250-13：白名单为空 = 无人启用 ----------
    if not re.search(r'if\s*\(\s*!items\.count\s*\)\s*return\s+NO\s*;', code):
        problems.append(
            "V250-13 SIO_timeWhitelistedFrom 缺少 `if (!items.count) return NO;` —— "
            "白名单为空必须判定为「无人启用」，否则打开总开关就等于全进程加速。")

    # ---------- V250-14：两个分支都要刷新倍率 ----------
    # 注意：前向声明是 `SIO_timeModeRefresh(void);`（括号里有 void），不会被这条正则命中。
    n_refresh = len(re.findall(r'SIO_timeModeRefresh\s*\(\s*\)\s*;', code))
    if n_refresh < 2:
        problems.append(
            f"V250-14 SIO_timeModeRefresh() 只有 {n_refresh} 处调用（应为 2 处："
            f"SIO_reload 的正常分支与 plist 缺失分支）—— "
            f"少一处会让该配置路径下虚拟时钟沿用上一个倍率。")

    # ---------- App 侧：主线程零 IO ----------
    if app:
        acode = strip_comments(app)
        # onSave 内不得直接同步调用 WriteConfig（必须走 IO 队列）
        m = re.search(r'-\s*\(void\)\s*onSave\s*\{', acode)
        if m:
            i, depth = m.end() - 1, 0
            while i < len(acode):
                if acode[i] == '{':
                    depth += 1
                elif acode[i] == '}':
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            body = acode[m.end() - 1:i + 1]
            # 允许在 dispatch_async 内部调用；把 dispatch_async 块挖掉后再看
            stripped = re.sub(r'dispatch_async\s*\(', 'DISPATCHED(', body)
            # 简易判断：onSave 主体里若直接出现 WriteConfig( 而前面没有 dispatch_async 包裹则告警
            if re.search(r'(?<!DISPATCHED\()\bWriteConfig\s*\(', body) and \
               'SIOIOQueue' not in body:
                problems.append(
                    "V250-A  onSave 直接在主线程调用 WriteConfig —— "
                    "保存路径的磁盘 IO 应排到 SIOIOQueue，避免主线程卡顿。")
        if 'gCfgSnapshot' not in acode:
            problems.append("V250-A  未找到配置读取缓存 gCfgSnapshot")

    print(f"[OK]   已核查 Tweak/SIOriginal.m ({len(raw.splitlines())} 行)")
    if app:
        print(f"[OK]   已核查 App/main.m ({len(app.splitlines())} 行)")
    print()

    if problems:
        print(f"发现 {len(problems)} 个 v2.5.0 不变量问题：")
        for p in problems:
            print("  - " + p)
        return 1

    print("v2.5.0 语义核查通过：启动惰性化、配置缓存加锁、watchdog 成对启停、"
          "关联对象合并、关联键清理、隐式动画预计算、主线程零 IO 均无异常。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
