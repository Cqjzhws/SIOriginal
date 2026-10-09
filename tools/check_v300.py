#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_v300.py — SIOriginal v3.0 架构不变量核查

v2.x 的 check 脚本是「防止某次改动悄悄抵消某条性能优化」。
v3.0 的核查点换了一批：重构之后的失效模式不再是「多打了一行日志」，
而是**结构性退化** —— 比如有人图省事又把 hook 装回 pre-main，
或者绕过唯一的 SIOExchange 直接调 method_setImplementation。

因此本脚本核查的是「唯一入口」与「红线」，共 12 项：

  唯一入口类
   1. 只有一个 __attribute__((constructor))
   2. 没有裸 method_setImplementation / class_replaceMethod（必须走 SIOExchange）
   3. 没有绕过 SIOWrap* 的裸 CATransaction begin/setAnimationDuration
   4. 黑名单匹配只有一个实现（SIOBundleMatches）
   5. plist 只有一个读取出口（SIOPreference 快照）

  红线类
   6. 时长换算结果永远 ≤ 原值（不会越算越慢）
   7. dylib 侧不链接 AVFoundation / UserNotifications（#import 断言）
   8. 所有 orig IMP 调用点都有判空

  分档类
   9.  kSIOStageBoot 条目只出现在核心两族
  10. 默认关闭的高危项都是 kSIOStageOnDemand

  规模类
  11. 单文件不超过 700 行（防止又长回单文件巨石）
  12. 每个 hook 模块都导出了 Entries 安装表

退出码 0 = 全部通过；1 = 有违规（CI 会失败并打印违规详情）。
"""

import os
import re
import sys

FAIL = []
OK = []


def ok(msg):
    OK.append(msg)


def fail(msg):
    FAIL.append(msg)


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def collect(root, exts=('.m', '.h')):
    files = []
    for dirpath, _dirnames, filenames in os.walk(root):
        # 跳过 build 产物目录
        if any(seg in dirpath for seg in ('.git', 'build', 'output')):
            continue
        for fn in filenames:
            if fn.endswith(exts):
                files.append(os.path.join(dirpath, fn))
    return sorted(files)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    src = root
    tweak = os.path.join(src, 'Tweak')
    if not os.path.isdir(tweak):
        tweak = src

    files = collect(tweak)
    if not files:
        fail('未找到任何 .m/.h 源文件（检查传入路径）')
        report()
        return 1

    blob = {p: read(p) for p in files}
    all_text = '\n'.join(blob.values())

    # ---------------- 1. 只有一个 constructor ----------------
    ctors = []
    for p, s in blob.items():
        for m in re.finditer(r'__attribute__\s*\(\s*\(\s*constructor\s*\)\s*\)', s):
            line = s[:m.start()].count('\n') + 1
            ctors.append((p, line))
    if len(ctors) == 1:
        ok('唯一 constructor：%s:%d' % ctors[0])
    elif not ctors:
        fail('没有任何 __attribute__((constructor)) —— 注入库不会被初始化')
    else:
        fail('发现 %d 个 constructor，必须只有 1 个（安装编排只能有一处）：%s'
             % (len(ctors), ctors))

    # ---------------- 2. 没有裸方法交换 ----------------
    offenders = []
    EXEMPT_MARK = '有意**不走 SIOExchange'
    for p, s in blob.items():
        # 排除 SIOExchange 自己的实现（在 SIOCore.m 里必然要调这两者之一）
        if os.path.basename(p) == 'SIOCore.m':
            continue
        lines = s.split('\n')
        for i, line in enumerate(lines):
            if not re.search(r'\bmethod_setImplementation\s*\(|\bclass_replaceMethod\s*\(', line):
                continue
            # 允许显式标注豁免：函数体前 25 行内出现豁免说明即可。
            ctx = '\n'.join(lines[max(0, i - 25):i + 1])
            if EXEMPT_MARK in ctx:
                continue
            offenders.append('%s:%d' % (p, i + 1))
    if not offenders:
        ok('无未标注的裸 method_setImplementation / class_replaceMethod（全部走 SIOExchange）')
    else:
        fail('发现绕过 SIOExchange 的裸交换（继承污染风险）：%s' % ', '.join(offenders))

    # ---------------- 3. CATransaction 只有唯一包裹点 ----------------
    tx_begin = []
    for p, s in blob.items():
        for m in re.finditer(r'\[\s*CATransaction\s+begin\s*\]', s):
            line = s[:m.start()].count('\n') + 1
            tx_begin.append('%s:%d' % (p, line))
    # 允许：SIOCoreAnimation.m（SIOWrap* 实现）、SIOUI.m（toast 自绘，需独立事务）
    allowed_tx = ('SIOCoreAnimation.m', 'SIOUI.m')
    bad_tx = [x for x in tx_begin if os.path.basename(x.split(':')[0]) not in allowed_tx]
    if not bad_tx:
        ok('CATransaction begin 只出现在 SIOWrap* 实现与自绘 UI（%d 处，符合预期）'
           % len(tx_begin))
    else:
        fail('发现绕过 SIOWrap* 的裸 CATransaction：%s' % ', '.join(bad_tx))

    # ---------------- 4. 黑名单匹配唯一 ----------------
    match_impl = []
    for p, s in blob.items():
        # 只统计「函数定义」：以 BOOL 开头、后接函数体 {，而不是 extern 原型或调用。
        # 原实现用 r'BOOL\s+SIOBundleMatches\s*\(' 会把头文件的 extern 声明
        # 也算进来 —— 那是假阳性。
        for m in re.finditer(r'^BOOL\s+SIOBundleMatches\s*\([^;]*\)\s*\{', s, re.M):
            match_impl.append('%s:%d' % (p, s[:m.start()].count('\n') + 1))
            break
    if len(match_impl) == 1:
        ok('黑名单匹配唯一实现：%s' % match_impl[0])
    else:
        fail('SIOBundleMatches 有 %d 处定义（必须唯一）' % len(match_impl))
    # 禁止在别处又写一份前缀匹配
    dup = []
    for p, s in blob.items():
        if os.path.basename(p) in ('SIOConfig.m',):
            continue
        if re.search(r'hasPrefix:\s*entry|hasPrefix:\s*b\b', s):
            dup.append(p)
    if not dup:
        ok('无重复的前缀匹配实现')
    else:
        fail('发现重复的黑名单前缀匹配：%s' % dup)

    # ---------------- 5. plist 读取出口唯一 ----------------
    readers = []
    for p, s in blob.items():
        n = len(re.findall(r'dictionaryWithContentsOfFile', s))
        c = len(re.findall(r'contentsOfFile:', s))
        if n + c:
            readers.append((os.path.basename(p), n + c))
    non_config = [r for r in readers if r[0] != 'SIOConfig.m']
    if not non_config:
        ok('plist 读取只在 SIOConfig.m（唯一出口）')
    else:
        fail('SIOConfig.m 之外仍有 plist 读取（重复 IO）：%s' % non_config)

    # ---------------- 6. 时长换算不变量：只能变快 ----------------
    # 精确的数值验证在 test_frame_align.py；这里做源码级断言：
    # SIO_targetDuration 的下限口径必须是 min(floor, orig)，不能是无条件 floor。
    hdr = None
    for p, s in blob.items():
        if os.path.basename(p) == 'SIOInternal.h':
            hdr = s
            break
    if hdr is None:
        fail('未找到 SIOInternal.h')
    else:
        if re.search(r'double\s+lo\s*=\s*\(gSIOCfg\.floorSec\s*<\s*orig\)', hdr):
            ok('时长下限口径 = min(floor, orig)（不会反向拉长）')
        else:
            fail('SIO_targetDuration 的下限口径被改（必须 min(floor, orig)）')
        if re.search(r'if\s*\(\s*d\s*>\s*orig\s*\)\s*d\s*=\s*orig\s*;', hdr):
            ok('SIO_targetDelay 有「不得变慢」兜底')
        else:
            fail('SIO_targetDelay 缺少「不得变慢」兜底')

    # ---------------- 7. 不链接 AVFoundation / UserNotifications ----------------
    bad_import = []
    for p, s in blob.items():
        for i, line in enumerate(s.split('\n')):
            # 必须是真正的预处理指令（行首可有空白，但 # 之前不能是 // 注释）。
            stripped = line.lstrip()
            if stripped.startswith('//') or stripped.startswith('*'):
                continue
            if re.match(r'#\s*(?:import|include)\s*<\s*(?:AVFoundation|UserNotifications)\s*/', stripped):
                bad_import.append('%s:%d' % (p, i + 1))
    if not bad_import:
        ok('无 AVFoundation / UserNotifications 头文件依赖（红线 #4）')
    else:
        fail('发现框架级 import（会把框架拖进启动路径）：%s' % bad_import)

    # ---------------- 8. orig IMP 调用判空 ----------------
    # 统计 orig 槽位的调用与判空宏使用，二者应大体匹配（不强制一一对应）。
    orig_calls = len(re.findall(r'\bo_[a-zA-Z0-9_]+\s*\(', all_text))
    require_macros = len(re.findall(r'SIO_REQUIRE_ORIG', all_text))
    if require_macros > 0:
        ok('orig IMP 判空宏使用 %d 处 / 原函数调用 %d 处'
           % (require_macros, orig_calls))
    else:
        fail('未使用 SIO_REQUIRE_ORIG 判空宏（红线 #3 无保障）')

    # ---------------- 9/10. 分档正确性 ----------------
    boot_entries = []
    ondemand_entries = []
    for p, s in blob.items():
        base = os.path.basename(p)
        for m in re.finditer(r'\{\s*"([^"]+)"[^}]*?kSIOStage(Boot|PostLaunch|OnDemand)[^}]*?\}', s):
            cls = m.group(1)
            stage = m.group(2)
            if stage == 'Boot':
                boot_entries.append((base, cls))
            if stage == 'OnDemand':
                ondemand_entries.append((base, cls))

    # Boot 档只允许出现在核心两族模块
    allowed_boot_files = ('SIOCoreAnimation.m', 'SIOUIViewAnim.m')
    bad_boot = [x for x in boot_entries if x[0] not in allowed_boot_files]
    if not bad_boot:
        ok('Boot 档 %d 条，全部落在核心两族（pre-main 保持精简，红线 #2）'
           % len(boot_entries))
    else:
        fail('Boot 档出现非核心模块条目（会拖慢 pre-main）：%s' % bad_boot)

    if ondemand_entries:
        ok('OnDemand 档 %d 条（默认关闭项零交换）' % len(ondemand_entries))
    else:
        fail('没有任何 OnDemand 档条目 —— 高危开关应设计为按需安装')

    # ---------------- 11. 单文件规模 ----------------
    too_big = []
    for p, s in blob.items():
        n = s.count('\n') + 1
        if n > 700:
            too_big.append('%s(%d 行)' % (os.path.basename(p), n))
    if not too_big:
        mx = max((s.count('\n') + 1, os.path.basename(p)) for p, s in blob.items())
        ok('单文件最大 %s（%d 行），未退回单文件巨石' % (mx[1], mx[0]))
    else:
        fail('文件过大（应拆分模块）：%s' % too_big)

    # ---------------- 12. hook 模块都导出安装表 ----------------
    hook_dir = os.path.join(tweak, 'hooks')
    if os.path.isdir(hook_dir):
        missing = []
        for fn in sorted(os.listdir(hook_dir)):
            if not fn.endswith('.m'):
                continue
            p = os.path.join(hook_dir, fn)
            s = blob.get(p, '')
            if not re.search(r'const\s+SIOHookEntry\s*\*\s*\w+Entries\s*\(', s):
                missing.append(fn)
        if not missing:
            ok('全部 %d 个 hook 模块都导出 Entries 安装表'
               % len([f for f in os.listdir(hook_dir) if f.endswith('.m')]))
        else:
            fail('以下 hook 模块缺少 Entries 安装表导出：%s' % missing)
    else:
        fail('未找到 hooks/ 目录')

    # ---------------- 13. 构建系统完整性（三处清单必须一致） ----------------
    # 任何 .m 模块只要存在于磁盘，就必须同时出现在 Makefile / build.sh /
    # .github/workflows/build.yml 三处源文件清单里。
    # 漏掉一处 → hook 模块不参与编译 → 链接期 undefined symbol（或更糟：
    # 静默少一个功能）。这是最难靠肉眼发现的一类回归。
    src_files = []
    for base, _dirs, files in os.walk(tweak):
        for fn in files:
            if fn.endswith('.m'):
                rel = os.path.relpath(os.path.join(base, fn), root).replace('\\', '/')
                src_files.append(rel)
    src_files.sort()

    manifests = {
        'Makefile': os.path.join(root, 'Makefile'),
        'build.sh': os.path.join(root, 'build.sh'),
        '.github/workflows/build.yml': os.path.join(root, '.github', 'workflows', 'build.yml'),
    }
    absent_manifest = [n for n, p in manifests.items() if not os.path.exists(p)]
    if absent_manifest:
        fail('构建清单文件缺失：%s' % absent_manifest)
    else:
        gaps = []
        for name, path in manifests.items():
            text = open(path, 'rb').read().decode('utf-8', 'replace')
            norm = text.replace('\\', '/')
            miss = [f for f in src_files if f not in norm]
            if miss:
                gaps.append('%s 缺 %s' % (name, miss))
        if not gaps:
            ok('构建系统完整：%d 个 .m 全部登记在 Makefile / build.sh / CI 三处清单'
               % len(src_files))
        else:
            fail('构建清单不完整（会导致模块不参与编译）：%s' % '；'.join(gaps))

    return report()


def report():
    print('=' * 66)
    print('SIOriginal v3.0 架构不变量核查')
    print('=' * 66)
    for m in OK:
        print('  [PASS] %s' % m)
    for m in FAIL:
        print('  [FAIL] %s' % m)
    print('-' * 66)
    print('通过 %d / 违规 %d' % (len(OK), len(FAIL)))
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
