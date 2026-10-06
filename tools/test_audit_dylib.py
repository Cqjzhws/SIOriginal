#!/usr/bin/env python3
"""
audit_dylib.py 回归测试
=======================
用 struct 手工构造合法/畸形的 Mach-O 与 FAT 样本，驱动 audit_dylib.main()
并断言退出码与关键输出。

存在的理由（历史教训）：审计脚本 v1 曾把 Apple 标准的 20 字节 fat_arch 条目
误按 24 字节步长解析，把健康的 arm64+arm64e 产物误报为「FAT 第 2 条目畸形」
并误杀 CI。本套件的核心用例（test_valid_fat_dual_arch）就是当时的真实参数：
arm64@16384/238016 + arm64e@262144/235920，cpusubtype 0x80000002。

用法：python3 tools/test_audit_dylib.py
退出码 0 = 全部通过，1 = 有失败
"""
import contextlib
import io
import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import audit_dylib  # noqa: E402

ARM64 = 0x0100000C
ARM64E_SUB = 0x80000002
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
LC_SEGMENT_64 = 0x19
MH_EXECUTE = 2
MH_DYLIB = 6


def s32(v):
    """无符号 32 位转有符号（struct '<i' 打包用）"""
    return v - (1 << 32) if v >= (1 << 31) else v


def macho_slice(cputype=ARM64, cpusubtype=0x0, filetype=MH_DYLIB,
                seg_fileoff=0, seg_filesize=4096):
    """最小合法 Mach-O 64：mach_header_64 + 1 个 LC_SEGMENT_64（72B）"""
    hdr = struct.pack("<IiiIIIII", MH_MAGIC_64, s32(cputype), s32(cpusubtype),
                      filetype, 1, 72, 0, 0)
    seg = struct.pack("<II16sQQQQiiII", LC_SEGMENT_64, 72, b"__TEXT\0\0",
                      0x100000000, 0x4000, seg_fileoff, seg_filesize, 5, 1, 0, 0)
    return hdr + seg


def fat_binary(entries):
    """entries: [(cputype, cpusubtype, data, align_pow), ...] → 完整 FAT 文件"""
    n = len(entries)
    out = io.BytesIO()
    out.write(struct.pack(">II", FAT_MAGIC, n))
    cur = 8 + 20 * n
    metas = []
    for ct, cs, data, ap in entries:
        a = 1 << ap
        off = (cur + a - 1) // a * a
        metas.append((ct, cs, off, len(data), ap))
        cur = off + len(data)
    for m in metas:
        out.write(struct.pack(">IIIII", *m))
    for (_, _, data, _), (_, _, off, _, _) in zip(entries, metas):
        if out.tell() < off:
            out.write(b"\0" * (off - out.tell()))
        out.write(data)
    return out.getvalue()


def run_audit(data: bytes):
    """把样本写入临时文件并运行 audit_dylib.main()，返回 (退出码, 输出)"""
    fd, path = tempfile.mkstemp(suffix=".dylib")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        argv = sys.argv
        buf = io.StringIO()
        try:
            sys.argv = ["audit_dylib.py", path]
            with contextlib.redirect_stdout(buf):
                rc = audit_dylib.main()
        finally:
            sys.argv = argv
        return rc, buf.getvalue()
    finally:
        os.unlink(path)


CASES = []


def case(name, expect_rc, expect_in_output=(), forbid_in_output=()):
    def deco(fn):
        CASES.append((name, fn, expect_rc, expect_in_output, forbid_in_output))
        return fn
    return deco


# ---------------- 合法样本 ----------------

@case("合法 FAT 双架构（v2.0.6 真实参数）", 0, ("结构健康", "arm64e", "arm64"))
def valid_fat_dual_arch():
    # 就是当年被误报畸形的真实布局：20 字节条目、arm64e subtype=0x80000002
    a = macho_slice(ARM64, 0x0, MH_DYLIB, 0, 238016 - 104)
    b = macho_slice(ARM64, ARM64E_SUB, MH_DYLIB, 0, 235920 - 104)
    # 补齐到真实 size，让 align=2^14 的第二个 offset 落在 262144
    a = a + b"\0" * (238016 - len(a))
    b = b + b"\0" * (235920 - len(b))
    return fat_binary([(ARM64, 0x0, a, 14), (ARM64, ARM64E_SUB, b, 14)])


@case("合法瘦 Mach-O（MH_DYLIB 单 slice）", 0, ("结构健康", "单一 arm64"))
def valid_thin_dylib():
    return macho_slice(ARM64, 0x0, MH_DYLIB) + b"\0" * 4096


@case("合法瘦 Mach-O（MH_EXECUTE）", 0, ("结构健康",))
def valid_thin_execute():
    return macho_slice(ARM64, 0x0, MH_EXECUTE) + b"\0" * 4096


# ---------------- 畸形样本 ----------------

@case("条目 offset 指向 ASCII 字符串区", 1, ("不是 Mach-O",))
def bad_offset_to_ascii():
    good = macho_slice(ARM64, 0x0, MH_DYLIB) + b"\0" * 4096
    ascii_blob = b"ppOverride\0_SIO_bundleID\0" + b"\0" * 4096
    return fat_binary([(ARM64, 0x0, good, 12), (ARM64, ARM64E_SUB, ascii_blob, 12)])


@case("条目 offset 越出文件末尾", 1, ("超出文件末尾",))
def bad_offset_oob():
    good = macho_slice(ARM64, 0x0, MH_DYLIB) + b"\0" * 4096
    data = fat_binary([(ARM64, 0x0, good, 12), (ARM64, ARM64E_SUB, good, 12)])
    # 把第 2 条目的 offset 改成远超 EOF 的值（条目 2 起始 = 8+20，offset 字段在 +8）
    return data[:28 + 8] + struct.pack(">I", len(data) + 0x1000) + data[28 + 12:]


@case("段覆盖超出 FAT 声明 size", 1, ("超出 FAT 声明",))
def bad_segment_overrun():
    big = macho_slice(ARM64, 0x0, MH_DYLIB, 0, 0x8000) + b"\0" * 4096
    small = macho_slice(ARM64, 0x0, MH_DYLIB, 0, 0x100) + b"\0" * 64
    data = fat_binary([(ARM64, 0x0, big, 12), (ARM64, ARM64E_SUB, small, 12)])
    # 第 1 条目 size 谎报为很小（段实际覆盖 0x8000 > offset + size）
    return data[:8 + 12] + struct.pack(">I", 0x40) + data[8 + 16:]


@case("根 magic 是垃圾", 1, ("既非 FAT 也非 Mach-O",))
def bad_root_magic():
    return b"\xde\xad\xbe\xef" + b"\0" * 4096


@case("空文件", 1, ())
def bad_empty():
    return b""


@case("FAT 架构表被截断", 1, ("截断",))
def bad_truncated_table():
    # 声明 2 个架构，但文件只有头部一半
    return struct.pack(">II", FAT_MAGIC, 2) + struct.pack(">IIIII", ARM64, 0, 0x4000, 0x1000, 12)


@case("slice magic 半损坏", 1, ())
def bad_slice_magic():
    broken = b"\xcf\xfa\xed\x00" + macho_slice(ARM64)[4:] + b"\0" * 4096
    return fat_binary([(ARM64, 0x0, broken, 12)])


def main():
    failed = 0
    for name, fn, expect_rc, exp_in, forbid_in in CASES:
        data = fn()
        try:
            rc, out = run_audit(data)
        except Exception as e:  # 审计器对畸形输入抛异常本身就是失败
            print(f"✗ {name}: 审计器抛异常 {type(e).__name__}: {e}")
            failed += 1
            continue
        ok = rc == expect_rc
        for s in exp_in:
            if s not in out:
                ok = False
                print(f"  · 缺少期望输出: {s!r}")
        for s in forbid_in:
            if s in out:
                ok = False
                print(f"  · 出现禁止输出: {s!r}")
        if ok:
            print(f"✓ {name} (rc={rc})")
        else:
            print(f"✗ {name}: 期望 rc={expect_rc} 实际 rc={rc}")
            failed += 1
    print()
    if failed:
        print(f"失败 {failed}/{len(CASES)}")
        return 1
    print(f"全部通过 {len(CASES)}/{len(CASES)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
