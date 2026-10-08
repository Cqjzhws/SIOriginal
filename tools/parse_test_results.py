#!/usr/bin/env python3
# parse_test_results.py — 解析 RuntimeTestHost 输出，生成 Markdown 验证报告
# 用法: python3 parse_test_results.py <runtime.log> <report.md>
# stdout 输出机读状态行: TESTCASE_RESULT_PASS=n / FAILS=n / SKIPS=n（供 CI 判定）
import sys, re, collections

def main():
    if len(sys.argv) < 3:
        print("usage: parse_test_results.py <log> <report.md>"); sys.exit(2)
    log_path, out_path = sys.argv[1], sys.argv[2]

    rows = []
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            # simctl --console 可能带前缀（时间戳/进程名），找标记起始位置
            idx = line.find("TESTCASE|")
            if idx < 0:
                continue
            parts = line[idx:].split("|", 6)
            if len(parts) != 7:
                continue
            _, cat, name, exp, act, res, detail = parts
            rows.append({"cat": cat, "name": name, "exp": exp, "act": act,
                         "res": res, "detail": detail})

    cats = collections.OrderedDict()
    n_pass = n_fail = n_skip = 0
    fails = []
    for r in rows:
        cats.setdefault(r["cat"], []).append(r)
        if r["res"] == "PASS": n_pass += 1
        elif r["res"] == "FAIL":
            n_fail += 1
            fails.append(r)
        else: n_skip += 1

    # 问题优先级分类启发：门控/崩溃/加载 = P0；核心加速语义 = P1；其余 = P2
    def prio(r):
        if r["cat"] in ("A-加载", "D-门控", "G-交互"): return "P0"
        if r["cat"] in ("B-加速", "C-帧对齐"): return "P1"
        return "P2"

    L = []
    L.append("# SIOriginal v2.4.0 模拟器运行时行为验证报告\n")
    L.append("- 环境: GitHub Actions macos-15 / iOS Simulator (arm64)")
    L.append("- 注入方式: TestHost.app 内 dlopen SIOriginal.dylib（模拟器 slice）")
    L.append(f"- 用例总数: {len(rows)}  |  PASS: {n_pass}  |  FAIL: {n_fail}  |  SKIP: {n_skip}\n")
    L.append("---\n")
    for cat, items in cats.items():
        if cat == "SUMMARY":
            continue
        L.append(f"## {cat}\n")
        L.append("| 用例 | 预期 | 实际 | 结果 | 详情 |")
        L.append("|---|---|---|---|---|")
        for r in items:
            L.append("| {} | {} | {} | {} | {} |".format(
                r["name"], r["exp"], r["act"],
                {"PASS": "✅ PASS", "FAIL": "❌ FAIL"}.get(r["res"], "➖ SKIP"),
                r["detail"]))
        L.append("")
    if fails:
        L.append("---\n\n## 失败用例分类与优先级\n")
        L.append("| 优先级 | 分类 | 用例 | 预期 | 实际 | 详情 |")
        L.append("|---|---|---|---|---|---|")
        for r in sorted(fails, key=prio):
            L.append("| {} | {} | {} | {} | {} | {} |".format(
                prio(r), r["cat"], r["name"], r["exp"], r["act"], r["detail"]))
        L.append("")
    else:
        L.append("---\n\n## 结论\n\n全部执行用例通过，无 FAIL。\n")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(L))

    print(f"TESTCASE_RESULT_PASS={n_pass}")
    print(f"TESTCASE_RESULT_FAILS={n_fail}")
    print(f"TESTCASE_RESULT_SKIPS={n_skip}")

if __name__ == "__main__":
    main()
