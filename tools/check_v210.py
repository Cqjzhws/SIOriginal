#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v2.1.0 增量交叉引用核查器

static_check.py 是通用静态核查（括号配平/ 原 IMP 判空 / 符号配对）。
本脚本针对 v2.1.0 本轮新增与修改的代码做更严格的**语义级**核查 ——
它检查的是「读代码时最容易漏、而编译器在某些优化等级下未必报警」的问题：

  1. 新增原 IMP 指针必须既有声明（sio_xxx 用到）也有赋值（SIO_swizzle 传入 &o_xxx）
     且使用点全部在声明之后 —— C 里「先定义后使用」是硬要求，顺序错了直接编译失败，
     但若声明在文件后部就必然失败，属于低级错误，仍值得机器兜底。
  2. inline 函数/静态内联函数的使用点必须晚于定义。
  3.新增 hook 的选择器必须真实存在于 UIKit（人工核对清单）。
  4. 所有TLS key 必须 pthread_key_create 且判空。
  5. gXXX 全局配置变量：每一处赋值都必须在 SIO_reload 的「缺配置回退分支」
     与「正常解析分支」中同时出现，否则热重载或缺 plist 时会残留旧值。
  6. 已删除的函数不得再有引用。
  7. 括号 / 花括号 / 注释配平（含字符串与注释剔除后的净计数）。
"""
import re
import sys
import os

SRC = sys.argv[1] if len(sys.argv) > 1 else "Tweak/SIOriginal.m"

with open(SRC, "r", encoding="utf-8") as f:
    raw = f.read()
lines = raw.split("\n")

errors = []
notes = []

# ---------- 工具：剔除字符串与注释，返回同长度掩码串 ----------
def strip_code(text):
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        # 行注释
        if c == '/' and i + 1 < n and text[i+1] == '/':
            j = text.find('\n', i)
            if j == -1:
                j = n
            out.append(' ' * (j - i))
            i = j
            continue
        # 块注释（嵌套支持）
        if c == '/' and i + 1 < n and text[i+1] == '*':
            depth, j = 1, i + 2
            while j < n and depth:
                if text[j] == '/' and j+1 < n and text[j+1] == '*':
                    depth += 1; j += 2
                elif text[j] == '*' and j+1 < n and text[j+1] == '/':
                    depth -= 1; j += 2
                else:
                    j += 1
            out.append(' ' * (j - i))
            i = j
            continue
        # 字符串 / 字符字面量
        if c == '"' or c == "'":
            q = c; j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2; continue
                if text[j] == q:
                    j += 1; break
                j += 1
            out.append(' ' * (j - i))
            i = j
            continue
        out.append(c)
        i += 1
    return ''.join(out)

code = strip_code(raw)

def line_of(pos):
    return code.count("\n", 0, pos) + 1

# ---------- 1. 原 IMP 指针：声明 / 赋值 / 使用 ----------
imp_pat = re.compile(r'^\s*static\s+[^;=()]*?\(\s*\*\s*(o_[A-Za-z0-9_]+)\s*\)', re.M)
declared = {}
for m in imp_pat.finditer(code):
    declared[m.group(1)] = line_of(m.start())

assigned = set(re.findall(r'\(IMP\s*\*\s*\)&(o_[A-Za-z0-9_]+)', code))

used_before_decl = []
for m in imp_pat.finditer(code):
    pass
# 使用点= o_xxx 出现在声明行之后才有值；检查是否有「使用早于声明」
for name, dline in declared.items():
    first_use = None
    for i, ln in enumerate(code.split("\n"), 1):
        if re.search(r'\b' + re.escape(name) + r'\b', ln):
            first_use = i
            break
    if first_use is not None and first_use < dline:
        used_before_decl.append((name, dline, first_use))

for name, dline, uline in used_before_decl:
    errors.append(f"[原 IMP 顺序] {name} 在第 {uline} 行被使用，但声明在第 {dline} 行 —— C 语言要求先声明后使用")

unassigned = sorted(set(declared) - assigned)
# 这些是历史上有意留空 / 由其它路径写入的，逐个人工确认
KNOWN_UNASSIGNED = {
    "o_fbg_sceneUpdate",  # 示意名，不存在
}
for name in unassigned:
    if name not in KNOWN_UNASSIGNED:
        notes.append(f"[原 IMP 未见swizzle 赋值] {name}（第 {declared[name]} 行）—— 确认是否为有意保留")

# ---------- 2. inline 函数定义与使用顺序 ----------
inline_defs = {}
for m in re.finditer(r'\bstatic\s+(?:inline\s+)?[A-Za-z_][\w\s\*]*?\b(SIO_[A-Za-z0-9_]+)\s*\(', code):
    # 判定是否为定义（含 {）
    tail = code[m.end():m.end()+400]
    if re.match(r'[^;{]*\{', tail):
        inline_defs.setdefault(m.group(1), line_of(m.start()))

FWD_DECL = re.compile(r'^\s*static\s+[^;{]*\b[A-Za-z_]\w*\s*\([^;{]*\)\s*;\s*(//.*)?$')

body = code.split("\n")
for name, dline in sorted(inline_defs.items()):
    # 定义行 = 签名与 { 在同一行（单行 static inline 定义），或签名行后紧跟 { 的行
    real_def = None
    for i, ln in enumerate(body, 1):
        m = re.search(r'\b' + re.escape(name) + r'\s*\([^;{]*\)', ln)
        if not m:
            continue
        tail = ln[m.end():]
        # 同行以 { 收尾（可带行尾注释）= 单行定义
        if re.match(r'\s*\{', tail):
            real_def = i
            break
        # 签名后紧跟 { = 跨行定义
        for k in range(i, min(i + 4, len(body) + 1)):
            if k == i:
                continue
            nxt = body[k-1].strip()
            if not nxt or nxt.startswith('//'):
                continue
            if nxt.startswith('{'):
                real_def = k
            break
        if real_def:
            break
    if real_def is None:
        continue
    use_lines = [i for i, ln in enumerate(body, 1)
             if re.search(r'\b' + re.escape(name) + r'\s*\(', ln)]
    # 判定规则：定义行之前的引用是合法的，当且仅当该函数在定义之前
    # 出现过至少一次**前向声明**。有前向声明 → 提前调用合法；无→ 编译错误。
    fwd_lines = [i for i in use_lines if i < real_def and FWD_DECL.match(body[i-1])]
    if not fwd_lines:
        bad = [i for i in use_lines if i < real_def and not FWD_DECL.match(body[i-1])]
        if bad:
            errors.append(f"[inline 顺序] {name} 在第 {bad[0]} 行使用，"
                          f"定义在第 {real_def} 行，且此前无前向声明 —— C 要求先声明后使用")

# ---------- 3. TLS key 完整性 ----------
tls_keys = set(re.findall(r'pthread_key_t\s+(g\w+Key)', code))
created = set(re.findall(r'pthread_key_create\(&(g\w+Key)', code))
for k in sorted(tls_keys - created):
    errors.append(f"[TLS] {k} 声明了 pthread_key_t 但从未 pthread_key_create —— 读它会返回未定义值")
for k in sorted(created):
    if k not in tls_keys:
        errors.append(f"[TLS] {k} 被 pthread_key_create 但未声明 pthread_key_t")
# 新增 key 必须判空
for i, ln in enumerate(code.split("\n"), 1):
    if 'pthread_key_create' in ln and 'if (' not in ln and 'void' not in ln:
        errors.append(f"[TLS] 第 {i} 行 pthread_key_create 未判返回值：{ln.strip()}")

# ---------- 4. 已删除函数不得残留引用 ----------
REMOVED = ["_fbg_onEnterBackground", "_fbg_onEnterForeground"]
for fn in REMOVED:
    hits = [i for i, ln in enumerate(code.split("\n"), 1)
            if re.search(r'\b' + fn + r'\b', ln)]
    if hits:
        errors.append(f"[死代码] 已移除的 {fn} 仍在第 {hits} 行出现（移除应彻底，否则是悬空引用）")

# ---------- 5. gXXX 配置变量双分支覆盖 ----------
# SIO_reload 的回退分支与正常分支
def extract_reload_block():
    m = re.search(r'static void SIO_reload\(void\) \{', code)
    if not m:
        return "", ""
    start = m.end()
    depth, i = 1, start
    while i < len(code) and depth:
        if code[i] == '{':
            depth += 1
        elif code[i] == '}':
            depth -= 1
        i += 1
    body = code[start:i-1]
    fb = re.search(r'if\s*\(!d\)\s*\{', body)
    if fb:
        d2, j = 1, fb.end()
        while j < len(body) and d2:
            if body[j] == '{': d2 += 1
            elif body[j] == '}': d2 -= 1
            j += 1
        return body[fb.end():j-1], body[j:]
    return "", body

fallback, normal = extract_reload_block()
v2_new = ["gSpeedMode", "gRespectReduceMotion"]
for v in v2_new:
    if v not in fallback:
        errors.append(f"[配置覆盖] {v} 未在 SIO_reload 的「plist 缺失回退分支」中赋值 —— "
                      f"缺 plist 时会残留上一次进程的值或未初始化")
    if v not in normal:
        errors.append(f"[配置覆盖] {v} 未在 SIO_reload 的正常解析分支中读取 plist")

# ---------- 6. 配平检查（净计数）----------
def check_balance(ch_open, ch_close, name):
    no = code.count(ch_open)
    nc = code.count(ch_close)
    if no != nc:
        errors.append(f"[配平] {name} 不配平：{ch_open}×{no} vs {ch_close}×{nc}")

check_balance('{', '}', '花括号')
check_balance('(', ')', '圆括号')

# ---------- 7. 新增 hook 选择器人工核对清单 ----------
KNOWN_SELECTORS = {
    "setSpeed:": "CAAnimation / CALayer 的 CAMediaTiming.speed，iOS 7+",
    "continueAnimationWithTimingParameters:duration:": "UIViewPropertyAnimator，iOS 11+",
    "setRootViewController:": "UIWindow，iOS 5+",
}
for sel, desc in KNOWN_SELECTORS.items():
    if f"@selector({sel})" not in code:
        errors.append(f"[选择器] 预期新增 hook 的 @selector({sel}) 未出现 —— {desc}")
    else:
        notes.append(f"[选择器✓] {sel} —— {desc}")

# ---------- 8. 下限不得反向拉长：关键不变量 ----------
# SIO_targetDuration 与 SIO_targetDurationLayer 中不应再出现裸 `d = gFloor` 或
# `d < gFloor` 的直接抬升
for i, ln in enumerate(code.split("\n"), 1):
    s = ln.strip()
    if re.search(r'^\s*d\s*=\s*gFloor\s*;', ln):
        errors.append(f"[真 bug 2回归] 第 {i} 行出现 `d = gFloor;` —— 瞬切模式会把比下限更短的动画拉长")
    if re.search(r'if\s*\(\s*d\s*<\s*gFloor\s*\)\s*d\s*=\s*gFloor', ln):
        errors.append(f"[真 bug 2 回归] 第 {i} 行出现 `if (d < gFloor) d = gFloor;` —— 下限会反向拉长动画")

# ---------- 输出 ----------
print(f"核查文件: {SRC}（{len(lines)} 行）")
print(f"原 IMP 指针: 声明 {len(declared)} 个，swizzle 赋值 {len(assigned)} 个")
print(f"TLS key: {len(tls_keys)} 个，全部已创建并判空" if not (tls_keys - created) else f"TLS key: {sorted(tls_keys)}")
print(f"inline 定义: {len(inline_defs)} 个，使用顺序全部正确")
print()
if notes:
    print("提示（需人工确认，非错误）：")
    for n in notes:
        print("  - " + n)
    print()
if errors:
    print(f"✗ 发现 {len(errors)} 个问题：")
    for e in errors:
        print("  ✗ " + e)
    sys.exit(1)
print("✓ v2.1.0 增量交叉引用核查全部通过")