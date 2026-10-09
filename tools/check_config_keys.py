#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SIOriginal v3.0 — 配置键闭环核查

背景：本项目历史上多次踩到同一类事故 —— 「界面有开关，但功能无效」。
根因是配置键要在两侧同时成立，漏一侧不会报错，只会静默失效：

  ① 配置 App 侧：键必须写进 `NSArray *sioKeys` 白名单，否则 `WriteConfig()`
     在合并时会把它丢掉（用户点了保存，plist 里却没这个键）。
  ② dylib 侧：`SIOApply()` 必须真的读这个键。

本脚本按 `SIOInternal.h` 定义的「三类契约」逐项校验：

  A. 双向键    ：保存 ↔ 读取 必须闭环（缺任一侧 → FAIL）
  B. 单侧键    ：专用代码路径读取，显式豁免列表
  C. dylib 内部键：必须在头文件的契约注释里登记（缺 → FAIL，防止悄悄加键）

用法：python3 tools/check_config_keys.py [工程根目录]
退出码：0 全部通过；1 存在违规
"""

import os
import re
import sys

# ---- B 类：单侧写入 / 专用路径读取，不参与通用闭环校验 ----
EXEMPT_APP_SIDE = {
    'AppOverrides',              # dylib 用 SIOAppOverrideLookup 专用路径读取
    'Blacklist',                 # dylib 用 SIOBundleMatches 专用路径读取
    'FUBGExcludeApps',           # 保活排除表，专用路径
    'FUBGEnabled', 'FUBGSceneFake', 'FUBGAudioKeep', 'FUBGFloatingBall',
    'DragCoef',                  # App 写 UIAnimationDragCoefficient，dylib 读该键补偿
}

# ---- C 类：dylib 内部高级键（无 UI，安全默认值），必须在头文件契约里登记 ----
INTERNAL_KEYS = [
    'SystemSpeedCompensate',
    'FastColdStart',
    'LegacyKitMode',
    'SwapBudget',
    'PrivilegeGated',
]

OK = []
FAIL = []


def ok(m):
    OK.append(m)


def fail(m):
    FAIL.append(m)


def read_text(p):
    with open(p, 'rb') as f:
        return f.read().decode('utf-8', 'replace')


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..')
    root = os.path.abspath(root)
    app_p = os.path.join(root, 'App', 'main.m')
    cfg_p = os.path.join(root, 'Tweak', 'SIOConfig.m')
    hdr_p = os.path.join(root, 'Tweak', 'include', 'SIOInternal.h')

    for p in (app_p, cfg_p, hdr_p):
        if not os.path.exists(p):
            fail('缺少文件：%s' % os.path.relpath(p, root))
            return report()

    app = read_text(app_p)
    cfg = read_text(cfg_p)
    hdr = read_text(hdr_p)

    # ① App 白名单
    m = re.search(r'NSArray\s*\*sioKeys\s*=\s*@\[(.*?)\];', app, re.S)
    if not m:
        fail('在 App/main.m 中找不到 NSArray *sioKeys 白名单声明')
        return report()
    whitelist = set(re.findall(r'@"([A-Za-z][A-Za-z0-9]*)"', m.group(1)))

    # ② App 实际保存的键
    saved = set(re.findall(r'cfg\[@"([A-Za-z][A-Za-z0-9]*)"\]\s*=', app))

    # ③ dylib 读取的键
    read = set(re.findall(r'SIO(?:Bool|Num)\(\s*\w+\s*,\s*@"([A-Za-z][A-Za-z0-9]*)"', cfg))
    read |= set(re.findall(r'd\[@"([A-Za-z][A-Za-z0-9]*)"\]', cfg))

    ok('配置 App 白名单 %d 键 / 保存 %d 键 / dylib 读取 %d 键'
       % (len(whitelist), len(saved), len(read)))

    # ---- 校验 A1：保存的键必须在白名单内 ----
    dropped = sorted(k for k in saved if k not in whitelist)
    if dropped:
        fail('App 保存但不在白名单（保存时被静默丢弃 → 假功能）：%s' % dropped)
    else:
        ok('App 保存的 %d 个键全部在白名单内' % len(saved))

    # ---- 校验 A2：白名单内「应被读取」的键必须真被读取 ----
    not_read = sorted(
        k for k in whitelist
        if k not in read and k not in EXEMPT_APP_SIDE)
    if not_read:
        fail('白名单内但 dylib 不读取（界面有开关但无效）：%s' % not_read)
    else:
        ok('白名单内非豁免键全部被 dylib 读取')

    # ---- 校验 A3：dylib 读取的键必须能由 UI 设置（或在豁免/内部清单内） ----
    orphan = sorted(
        k for k in read
        if k not in whitelist
        and k not in EXEMPT_APP_SIDE
        and k not in INTERNAL_KEYS)
    if orphan:
        fail('dylib 读取但既无 UI 开关、也未登记为内部键（需三选一：加 UI / 加豁免 / 登记）:%s'
             % orphan)
    else:
        ok('dylib 读取的键全部有归属（UI 开关 / 豁免 / 内部键）')

    # ---- 校验 C：内部键必须在头文件契约注释里登记 ----
    contract = re.search(r'配置键的三类契约(.*?)(?=\n#pragma|\Z)', hdr, re.S)
    if not contract:
        fail('SIOInternal.h 缺少「配置键的三类契约」说明块')
    else:
        # 头文件里用 camelCase（systemSpeedCompensate）描述，plist 键是
        # PascalCase（SystemSpeedCompensate），故按大小写不敏感比对。
        body_l = contract.group(1).lower()
        unregistered = [k for k in INTERNAL_KEYS if k.lower() not in body_l]
        if unregistered:
            fail('内部键未在头文件契约中登记（新增键必须登记）：%s' % unregistered)
        else:
            ok('dylib 内部高级键 %d 个全部已在头文件契约中登记' % len(INTERNAL_KEYS))

    # ---- 附带：键名拼写一致性（防大小写/拼写漂移） ----
    lower = {}
    for k in sorted(read | saved | whitelist):
        lower.setdefault(k.lower(), []).append(k)
    drift = {kk: vv for kk, vv in lower.items() if len(set(vv)) > 1}
    if drift:
        fail('键名存在大小写/拼写漂移：%s' % drift)
    else:
        ok('键名无大小写漂移')

    return report()


def report():
    print('=' * 66)
    print('SIOriginal v3.0 配置键闭环核查')
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
