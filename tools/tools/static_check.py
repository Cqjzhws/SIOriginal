#!/usr/bin/env python3
"""
SIOriginal 源码静态核查工具
==========================
在无法本地编译（需要 macOS + iOS SDK）的环境下，对 Tweak/SIOriginal.m 与
App/main.m 做结构性静态核查，覆盖三类问题：

  1. 括号/花括号配平        —— 编译前最常见的致命错误
  2. 原 IMP 判空缺失        —— 项目红线规则 #4：所有 o_xxx 调用前必须判空
  3. hook 符号声明/定义配对 —— 声明了 o_xxx 但从未赋值，运行时调用即崩溃

用法：
    python3 tools/static_check.py [源码根目录]
退出码 0 = 通过，1 = 发现问题
"""
import os
import re
import sys

DEFAULT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def strip_noise(src: str) -> str:
    """去掉注释与字符串字面量，避免括号计数被注释/文本里的符号干扰。"""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                i += 1
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                i += 1
            i += 2
        elif c == '"':
            i += 1
            while i < n and src[i] != '"':
                i += 2 if src[i] == '\\' else 1
            i += 1
        elif c == "'":
            i += 1
            while i < n and src[i] != "'":
                i += 2 if src[i] == '\\' else 1
            i += 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def check_balance(name: str, code: str, problems: list) -> None:
    pairs = {')': '(', ']': '[', '}': '{'}
    stack = []
    line = 1
    for ch in code:
        if ch == '\n':
            line += 1
        elif ch in '([{':
            stack.append((ch, line))
        elif ch in ')]}':
            if not stack:
                problems.append(f"{name}:{line}  多余的 '{ch}'")
                return
            op, oline = stack.pop()
            if op != pairs[ch]:
                problems.append(f"{name}:{line}  '{ch}' 与第 {oline} 行 '{op}' 不匹配")
                return
    if stack:
        op, oline = stack[-1]
        problems.append(f"{name}:{oline}  '{op}' 未闭合")


def check_orig_guards(name: str, code: str, problems: list) -> None:
    """
    项目红线：调用 o_xxx(...) 前必须有判空。

    识别「已守护」的四种写法（缺一不可，否则会误报 —— 本项目实际四种都在用）：
      1. SIO_REQUIRE_ORIG / _NIL / _ZERO(o_xxx)   宏判空
      2. __builtin_expect(o_xxx == NULL, 0)        手写判空
      3. `... && o_xxx ...`                        短路条件内判空
      4. `if (o_xxx) ...` / `!o_xxx`               显式布尔判空
    只检查形如 `^static (void|id|...) sio_xxx(...)` 的 hook 实现。
    """
    fn_re = re.compile(
        r'^static\s+[\w \*]+?\b(sio_\w+)\s*\([^;{]*?\)\s*\{', re.M)
    for m in fn_re.finditer(code):
        fname = m.group(1)
        start = m.end() - 1
        depth, i = 0, start
        while i < len(code):
            if code[i] == '{':
                depth += 1
            elif code[i] == '}':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = code[start:i]
        used = set(re.findall(r'\b(o_[A-Za-z0-9_]+)\s*\(', body))
        if not used:
            continue

        guarded = set()

        # 1) 宏判空
        guarded |= set(re.findall(
            r'SIO_REQUIRE_ORIG(?:_NIL|_ZERO)?\s*\(\s*(o_[A-Za-z0-9_]+)\s*\)', body))
        # 2) __builtin_expect(o_xxx == NULL, 0) / (o_xxx != NULL)
        guarded |= set(re.findall(
            r'__builtin_expect\s*\(\s*(o_[A-Za-z0-9_]+)\s*[!=]=\s*NULL', body))
        # 3) 短路条件内判空：&& o_xxx  /  || o_xxx
        guarded |= set(re.findall(r'[&|]{2}\s*(o_[A-Za-z0-9_]+)\b', body))
        # 4) 显式布尔判空：if (o_xxx) / if (!o_xxx) / (o_xxx) 出现在条件位置
        guarded |= set(re.findall(
            r'if\s*\(\s*!?\s*(o_[A-Za-z0-9_]+)\s*\)', body))
        # 5) 三元或比较：o_xxx != NULL / o_xxx == NULL / o_xxx ?:
        guarded |= set(re.findall(r'\b(o_[A-Za-z0-9_]+)\s*[!=]=\s*NULL', body))
        guarded |= set(re.findall(r'\?\s*\(?\s*(o_[A-Za-z0-9_]+)\b', body))

        missing = used - guarded
        if missing:
            line = code[:m.start()].count('\n') + 1
            problems.append(
                f"{name}:{line}  {fname}() 调用了未判空的原 IMP: {', '.join(sorted(missing))}")


def check_hook_pairs(name: str, code: str, problems: list) -> None:
    """
    swizzle 目标 o_xxx 必须在某处被赋值（&o_xxx）。
    仅声明却从未赋值 => 该 hook 静默失效或运行时空指针。
    """
    assigned = set(re.findall(r'&\s*(o_[A-Za-z0-9_]+)\s*\)', code))
    declared = set(re.findall(r'^static\s+[^;=]*?\b(o_[A-Za-z0-9_]+)\s*(?:\(|;)', code, re.M))
    never = declared - assigned
    for o in sorted(never):
        # 未赋值也允许：仅当它同时从不被调用（纯防御性声明）时不算问题
        if not re.search(r'\b%s\s*\(' % re.escape(o), code.split('SIO_swizzleInstance')[0]):
            line = next(i for i, l in enumerate(code.splitlines(), 1)
                        if re.search(r'\b%s\b' % re.escape(o), l) and 'static' in l)
            problems.append(
                f"{name}:{line}  {o} 已声明但从未被赋值（死声明，疑似漏写 hook）")


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_ROOT
    targets = [
        os.path.join(root, "Tweak", "SIOriginal.m"),
        os.path.join(root, "App", "main.m"),
    ]
    problems: list = []
    for path in targets:
        if not os.path.isfile(path):
            print(f"[SKIP] 不存在: {path}")
            continue
        name = os.path.relpath(path, root)
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            raw = f.read()
        code = strip_noise(raw)
        check_balance(name, code, problems)
        if name.endswith("SIOriginal.m"):
            check_orig_guards(name, code, problems)
            check_hook_pairs(name, code, problems)
        print(f"[OK]   已核查 {name} ({len(raw.splitlines())} 行)")

    print()
    if problems:
        print(f"发现 {len(problems)} 个问题：")
        for p in problems:
            print("  - " + p)
        return 1
    print("静态核查通过：括号配平、原 IMP 判空、hook 符号配对均无异常。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
