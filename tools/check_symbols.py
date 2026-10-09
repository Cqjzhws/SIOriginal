#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SIOriginal v3.0 — 跨模块符号一致性核查

目标：在**没有编译器**的环境（Windows / 纯源码评审 / CI 的第一步）里，
提前发现「头文件声明了但没人实现」这类会在链接期炸掉的错误。

覆盖三类：
  1. `SIOInternal.h` 里的函数原型 —— 每个都必须有且只有一处定义；
  2. 同一函数**被定义了两次**（链接期 duplicate symbol）；
  3. 跨模块共享的全局变量 —— `extern` 声明必须有对应定义。

为什么要写这个：
  本项目的 hook 分散在 16 个 .m 里，靠人工核对「声明 ↔ 定义」几乎必然漏。
  v3.0 开发过程中真的踩过两次同类问题（`SIOHookSwapCount` 重复定义、
  `SIOHighRefresh.m` 漏登记进构建清单），所以把它们固化成机械检查。

用法：python3 tools/check_symbols.py [工程根目录]
退出码：0 全部通过；1 存在违规
"""

import os
import re
import sys

# ObjC / C 运行时与 libc 符号：头文件里可能被引用，但不是本项目定义的
SYSTEM_SYMBOLS = {
    'objc_getClass', 'objc_getMetaClass', 'objc_allocateClassPair',
    'class_getInstanceMethod', 'class_getClassMethod', 'class_addMethod',
    'class_replaceMethod', 'class_getSuperclass', 'class_getName',
    'class_respondsToSelector', 'method_setImplementation',
    'method_getImplementation', 'method_getTypeEncoding',
    'method_exchangeImplementations', 'method_getName',
    'object_getClass', 'object_setClass', 'sel_registerName',
    'imp_implementationWithBlock', 'imp_removeBlock',
    'NSClassFromString', 'NSStringFromClass', 'NSStringFromSelector',
    'dispatch_once', 'dispatch_async', 'dispatch_sync', 'dispatch_after',
    'dispatch_source_create', 'dispatch_source_set_event_handler',
    'dispatch_resume', 'dispatch_suspend', 'dispatch_cancel',
    'dispatch_get_main_queue', 'dispatch_get_global_queue',
    'dlopen', 'dlsym', 'dlclose', 'dlerror',
    'pthread_key_create', 'pthread_getspecific', 'pthread_setspecific',
    'pthread_main_np', 'pthread_self',
    'strstr', 'strcmp', 'strncmp', 'strlen', 'strcpy', 'strncpy',
    'memcpy', 'memset', 'memcmp', 'malloc', 'calloc', 'realloc', 'free',
    'printf', 'fprintf', 'snprintf', 'abort', 'exit', 'atexit',
    'CFRelease', 'CFRetain', 'CFStringCreateWithCString',
    'os_unfair_lock_lock', 'os_unfair_lock_unlock',
    'sysctl', 'sysctlbyname', 'getpid', 'time', 'clock_gettime',
    'if', 'for', 'while', 'switch', 'return', 'sizeof', 'typedef',
    'defined', '__attribute__', 'static_assert', 'assert',
}

OK = []
FAIL = []
ROOT = None


def ok(msg):
    OK.append(msg)


def fail(msg):
    FAIL.append(msg)


def strip_comments_and_strings(src):
    """去掉注释与字符串字面量，避免它们被当成代码匹配。"""
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if c == '/' and nxt == '/':                 # 行注释
            j = src.find('\n', i)
            i = n if j < 0 else j
        elif c == '/' and nxt == '*':               # 块注释
            j = src.find('*/', i + 2)
            i = n if j < 0 else j + 2
        elif c == '"':                              # 字符串
            i += 1
            while i < n and src[i] != '"':
                i += 2 if src[i] == '\\' else 1
            i += 1
        elif c == "'":                              # 字符字面量
            i += 1
            while i < n and src[i] != "'":
                i += 2 if src[i] == '\\' else 1
            i += 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def collect_sources(tweak_dir):
    sources = {}
    for base, _dirs, files in os.walk(tweak_dir):
        for fn in files:
            if fn.endswith('.m'):
                p = os.path.join(base, fn)
                with open(p, 'rb') as f:
                    sources[p] = f.read().decode('utf-8', 'replace')
    return sources


# 函数定义：返回类型 + 函数名 + 参数表（允许参数表里含括号，如 block 指针）+ {
#   —— 参数表用「非贪婪到最后一个 ) 再跟 {」的方式匹配，才能吃掉
#      void (^block)(void) 这种嵌套括号。
DEF_RE = re.compile(
    r'^[ \t]*(?:__attribute__\s*\(\([^)]*\)\)\s*)?'
    r'(?:static\s+|inline\s+|extern\s+|const\s+)*'
    r'[A-Za-z_][\w \t\*]*?[\s\*]'
    r'(\w+)\s*'
    r'\(([^{;]*)\)\s*\{',
    re.M)


def main():
    global ROOT
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..')
    ROOT = os.path.abspath(root)
    tweak = os.path.join(ROOT, 'Tweak')
    hdr_path = os.path.join(tweak, 'include', 'SIOInternal.h')

    if not os.path.exists(hdr_path):
        fail('找不到 %s' % hdr_path)
        return report()

    with open(hdr_path, 'rb') as f:
        hdr_raw = f.read().decode('utf-8', 'replace')
    hdr = strip_comments_and_strings(hdr_raw)

    sources = collect_sources(tweak)
    if not sources:
        fail('Tweak/ 下没有找到任何 .m 源文件')
        return report()

    # 把所有源码的行为单文件粒度保留，便于「重复定义」定位
    defs_by_name = {}          # name -> [最先出现的文件, 出现次数]
    defs_all = set()
    for p, raw in sources.items():
        clean = strip_comments_and_strings(raw)
        for m in DEF_RE.finditer(clean):
            name = m.group(1)
            defs_all.add(name)
            rel = os.path.relpath(p, ROOT).replace('\\', '/')
            if name in defs_by_name:
                defs_by_name[name][1] += 1
            else:
                defs_by_name[name] = [rel, 1]

    # ---- 1. 头文件原型 ↔ 定义 ----
    # 只在「像函数原型」的行上取名字：以 ; 结尾、含 ( )
    prototypes = set()
    for m in re.finditer(r'^[ \t]*extern\s+([^;]*?)\b(\w+)\s*\((.*?)\)\s*;',
                         hdr, re.M | re.S):
        name = m.group(2)
        if name not in ('if', 'for', 'while', 'switch', 'return'):
            prototypes.add(name)
    # 无 extern 前缀的（少数）也收进来
    for m in re.finditer(r'^[ \t]*(?!extern)([A-Za-z_][\w \t\*]*?)\b(SIO\w+)\s*\(([^;{]*?)\)\s*;',
                         hdr, re.M):
        prototypes.add(m.group(2))

    prototypes -= SYSTEM_SYMBOLS
    undefined = sorted(n for n in prototypes if n not in defs_all)

    if 'SIOInternal.h' not in ' '.join(sources):
        pass  # 头文件本身不参与定义统计

    if undefined:
        fail('头文件声明但无处定义（链接期 undefined symbol）：%s' % undefined)
    else:
        ok('头文件 %d 个函数原型全部有定义' % len(prototypes))

    # ---- 2. 重复定义（链接期 duplicate symbol） ----
    dups = {n: v for n, v in defs_by_name.items()
            if v[1] > 1 and n not in SYSTEM_SYMBOLS}
    # 静态函数可以同名出现在不同文件（各自 internal linkage），
    # 这里只对「非 static」的报错。保守起见：同名超过 1 次就列出，
    # 但若全部出现都带 static 则视为合法。
    static_ok = set()
    for p, raw in sources.items():
        clean = strip_comments_and_strings(raw)
        for m in re.finditer(r'^[ \t]*static\s+[A-Za-z_][\w \t\*]*?[\s\*](\w+)\s*\([^{;]*\)\s*\{',
                             clean, re.M):
            static_ok.add(m.group(1))
    real_dups = sorted(n for n in dups if n not in static_ok)
    if real_dups:
        detail = ', '.join('%s(%d 处: %s)' % (n, dups[n][1], dups[n][0])
                           for n in real_dups)
        fail('疑似重复定义（链接期 duplicate symbol）：%s' % detail)
    else:
        ok('无重复的非 static 函数定义')

    # ---- 3. 跨模块全局变量 ----
    gvars = set(re.findall(
        r'^[ \t]*extern\s+[A-Za-z_][\w \t\*]*?[\s\*]([gk]SIO\w+)\s*(?:\[[^\]]*\])?\s*;',
        hdr, re.M))
    allsrc = strip_comments_and_strings('\n'.join(sources.values()))
    gmissing = []
    for g in sorted(gvars):
        # 定义形态：可选 static/const + 类型 + 名字 + (= ... 或 ; 或 [N] =)
        if not re.search(r'\b%s\s*(\[[^\]]*\])?\s*([=;]|\{)'
                         % re.escape(g), allsrc):
            gmissing.append(g)
    if gmissing:
        fail('全局变量声明但无定义：%s' % gmissing)
    else:
        ok('跨模块全局变量 %d 个全部有定义' % len(gvars))

    return report()


def report():
    print('=' * 66)
    print('SIOriginal v3.0 跨模块符号一致性核查')
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
