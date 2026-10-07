#!/usr/bin/env python3
"""
SIOriginal dylib 结构审计
=========================
对构建产物做 Mach-O 级体检，定位会拖慢 dyld 加载或导致注入失败的结构缺陷。

校验内容：FAT 头逐条目的 magic 校验（条目指向的偏移处必须是合法 Mach-O 头，
lipo -info 只读架构名列表、不查这个）、段覆盖与 FAT 声明 size 的自洽性、
slice 间空隙 / 尾部冗余这类可直接消除的加载开销。

历史教训（本工具 v1 的解析 bug，不是产物的 bug）：
v1 把标准的 20 字节 fat_arch 条目误按 24 字节步长解析，导致第 2 个架构条目
整体错位 4 字节 —— 把 arm64e 的 cpusubtype 0x80000002 读成 cputype、把
size 读成 offset，进而误报「条目指向 ASCII 字符串、dylib 畸形」。实际上
v2.0.6 发布的 dylib 完全健康（arm64 + arm64e 双架构）。fat_arch 的 Apple
标准布局就是 20 字节、无 reserved（reserved 只存在于 fat_arch_64 的 32 字节
条目）。回归测试见 tools/test_audit_dylib.py。

用法：
    python3 tools/audit_dylib.py <dylib路径>
退出码 0 = 结构健康，1 = 发现问题
"""
import os
import struct
import sys

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF   # fat_arch_64：offset/size 为 8 字节，条目 32 字节
MH_MAGIC_64 = 0xFEEDFACF
CPU_ARCH_ABI64 = 0x01000000
CPU_TYPE_X86 = 0x00000007
CPU_TYPE_X86_64 = 0x01000007
CPU_TYPE_ARM = 12
CPU_TYPE_ARM64 = 0x0100000C
CPU_TYPE_ARM64_32 = 0x0200000C   # watchOS 的 arm64_32（ILP32）；与 arm64e 无关

ARCH_NAMES = {
    CPU_TYPE_ARM: "armv7",
    CPU_TYPE_ARM64: "arm64",
    CPU_TYPE_ARM64_32: "arm64_32",
    CPU_TYPE_X86: "i386",
    CPU_TYPE_X86_64: "x86_64",
}

LC_SEGMENT_64 = 0x19
LC_ID_DYLIB = 0xD
LC_LOAD_DYLIB = 0xC
LC_BUILD_VERSION = 0x32
LC_CODE_SIGNATURE = 0x1D
LC_ENCRYPTION_INFO_64 = 0x2C

# arm64e 的 cpusubtype 高位带 0x80000000
CPU_SUBTYPE_MASK = 0x00FFFFFF


def cputype_name(ct, cs):
    # arm64 与 arm64e 的 cputype 相同（0x0100000C），靠 cpusubtype 区分：
    # arm64e 的 subtype 低 24 位为 2 且带能力位 0x80000000
    if ct == CPU_TYPE_ARM64 and (cs & 0x00FFFFFF) == 2 and (cs & 0x80000000):
        return "arm64e"
    return ARCH_NAMES.get(ct, f"unknown(0x{ct:x})")


def parse_slice(d: bytes, off: int, problems: list, label: str):
    """
    解析单个 Mach-O slice 的头部与 load commands。

    注意字节序：FAT 头及其架构表是大端（FAT_MAGIC / FAT_CIGAM 决定），
    但**每个 slice 内部的小端/大端由该 slice 自己的 magic 决定**。
    实践中 arm64 iOS 产物一律是小端（MH_MAGIC_64 = 0xfeedfacf，磁盘序为
    cf fa ed fe），所以此处按小端读 magic 与 load commands。
    若读到的 magic 反过来（0xcffaedfe），说明该 slice 是大端，需整体换序解析。
    """
    if off + 32 > len(d):
        problems.append(f"{label}: slice 偏移 {off} 超出文件末尾（文件仅 {len(d)} 字节）")
        return None

    magic_le, = struct.unpack_from("<I", d, off)
    if magic_le == MH_MAGIC_64:
        end = "<"
    elif struct.unpack_from(">I", d, off)[0] == MH_MAGIC_64:
        end = ">"          # 大端 slice
    else:
        sample = d[off:off + 16]
        printable = all(32 <= b < 127 or b == 0 for b in sample)
        if printable:
            nul = d.find(b"\x00", off)
            txt = d[off:nul if nul != -1 else off + 32].decode("ascii", "replace")
            problems.append(
                f"{label}: slice 偏移 {off} 处不是 Mach-O（magic=0x{magic_le:08x}），"
                f"实际内容是 ASCII 文本 {txt!r} —— 这是畸形架构条目")
        else:
            problems.append(
                f"{label}: slice 偏移 {off} 处 magic=0x{magic_le:08x}，"
                f"期望 0x{MH_MAGIC_64:08x}（小端）/ 大端等价值")
        return None

    # mach_header_64: magic(4) | cputype(4) cpusubtype(4) filetype(4) ncmds(4)
    # sizeofcmds(4) flags(4) reserved(4)。magic 已在上面判定，字段从 off+4 读。
    # （v1 曾从 off 读起，全部字段错位 4 字节：magic 被当 cputype、filetype 被当
    #  ncmds —— 对真实 dylib 只读到 6 条 load command 且 thin 模式架构名全错。）
    cput, cpus, ftype, ncmds, sizeofcmds, flags, _ = struct.unpack_from(
        f"{end}iiIIIII", d, off + 4)
    info = {
        "offset": off, "cputype": cput, "cpusubtype": cpus, "filetype": ftype,
        "ncmds": ncmds, "flags": flags, "end": 0, "segments": [],
        "dylibs": [], "encrypted": False, "signed": False, "minos": None, "sdk": None,
    }

    p = off + 32
    for _ in range(ncmds):
        if p + 8 > len(d):
            problems.append(f"{label}: load command 越界")
            break
        cmd, cmdsize = struct.unpack_from(f"{end}II", d, p)
        if cmdsize == 0:
            problems.append(f"{label}: 出现 cmdsize=0 的 load command，解析中止")
            break
        if cmd == LC_SEGMENT_64:
            segname = d[p + 8:p + 24].split(b"\x00")[0].decode("ascii", "replace")
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from(f"{end}QQQQ", d, p + 24)
            info["segments"].append((segname, fileoff, filesize))
            info["end"] = max(info["end"], fileoff + filesize)
        elif cmd in (LC_LOAD_DYLIB, LC_ID_DYLIB):
            nameoff, = struct.unpack_from(f"{end}I", d, p + 8)
            s = p + nameoff
            e = d.index(b"\x00", s)
            info["dylibs"].append(d[s:e].decode("utf-8", "replace"))
        elif cmd == LC_BUILD_VERSION:
            _plat, minos, sdk, _n = struct.unpack_from(f"{end}IIII", d, p + 8)
            info["minos"] = minos
            info["sdk"] = sdk
        elif cmd == LC_ENCRYPTION_INFO_64:
            info["encrypted"] = True
        elif cmd == LC_CODE_SIGNATURE:
            info["signed"] = True
        p += cmdsize
    return info


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]
    if not os.path.isfile(path):
        print(f"[错误] 文件不存在: {path}")
        return 1

    d = open(path, "rb").read()
    size = len(d)
    problems: list = []
    notes: list = []

    print(f"文件: {path}")
    print(f"大小: {size:,} 字节 ({size / 1024:.1f} KB)")
    print()

    if size < 8:
        problems.append(f"文件仅 {size} 字节，连 FAT/Mach-O 魔数都放不下")
        magic, narch = 0, 0
    else:
        magic, narch = struct.unpack_from(">II", d, 0)
    # 瘦 Mach-O 的小端 magic 在磁盘上是 cf fa ed fe，按大端读是 0xcffaedfe ——
    # 根判定必须同时认两种读法（FAT 魔数天然大端存储，瘦 slice 魔数小端存储）。
    thin_le = size >= 8 and struct.unpack_from("<I", d, 0)[0] == MH_MAGIC_64
    if not problems and magic not in (FAT_MAGIC, FAT_MAGIC_64):
        print("非 FAT 二进制（单一 slice）")
        if thin_le:
            info = parse_slice(d, 0, problems, "slice0")
            if info:
                notes.append(f"单一 {cputype_name(info['cputype'], info['cpusubtype'])} slice，"
                             f"覆盖 {info['end']:,}/{size:,} 字节")
        else:
            problems.append(f"根 magic=0x{magic:08x} 既非 FAT 也非 Mach-O 64")
    elif not problems:
        print(f"FAT 头: 声明 {narch} 个架构")
        # fat_arch 条目 20 字节（cputype/subtype/offset/size/align，各 4 字节）；
        # fat_arch_64 条目 32 字节（offset/size 为 8 字节 + reserved）。
        # 老版本误按 24 字节步长解析，导致第 2 个条目错位 4 字节、误报畸形。
        is64 = magic == FAT_MAGIC_64
        stride = 32 if is64 else 20
        tbl_end = 8 + stride * narch
        if narch == 0 or narch > 64:
            problems.append(f"FAT 头声明的架构数 {narch} 不合理")
        elif size < tbl_end:
            problems.append(f"FAT 头声明 {narch} 个架构（表需 {tbl_end} 字节），"
                            f"但文件仅 {size} 字节 —— 架构表被截断")
        narch_ok = not problems
        slices = []
        if narch_ok:
            for i in range(narch):
                base = 8 + stride * i
                ct, cs = struct.unpack_from(">II", d, base)
                if is64:
                    off, sz, align, _res = struct.unpack_from(">QQII", d, base + 8)
                else:
                    off, sz, align = struct.unpack_from(">III", d, base + 8)
                print(f"  [{i}] {cputype_name(ct, cs):10s} offset={off:>8,} size={sz:>8,} align=2^{align}")
                slices.append((i, ct, cs, off, sz))
        print()

        parsed = []
        for i, ct, cs, off, sz in slices:
            info = parse_slice(d, off, problems, f"arch[{i}] {cputype_name(ct, cs)}")
            if info:
                info["declared_size"] = sz
                parsed.append(info)

        for i, ct, cs, off, sz in slices:
            info = next((x for x in parsed if x["offset"] == off), None)
            if info and info["end"] > off + sz:
                problems.append(
                    f"arch[{i}] {cputype_name(ct, cs)}: 段覆盖到 {info['end']:,}，"
                    f"超出 FAT 声明的 size={sz:,}（多出 {info['end'] - (off + sz):,} 字节）")

        # 统计未被任何 FAT 条目覆盖的区间 —— 纯加载开销
        if parsed:
            reach = max(x["offset"] + x["end"] for x in parsed)
            covered = sum(s[4] for s in slices)
            if reach < size:
                notes.append(f"FAT 条目合计声明 {covered:,} 字节，"
                             f"实际有效内容到 {reach:,}，文件总长 {size:,}")
            # 找 slice 之间的空隙
            ordered = sorted(parsed, key=lambda x: x["offset"])
            for a, b in zip(ordered, ordered[1:]):
                gap_start = a["offset"] + a["end"]
                gap = b["offset"] - gap_start
                if gap > 0:
                    notes.append(f"arch 间存在 {gap:,} 字节对齐空隙 "
                                 f"({gap_start:,}..{b['offset']:,}) —— 2^14 段对齐的必然结果，正常现象")
            tail = size - reach
            if tail > 512:
                notes.append(f"文件尾部有 {tail:,} 字节未被任何 slice 覆盖（冗余数据）")

    if notes:
        print("提示:")
        for n in notes:
            print("  · " + n)
        print()

    if problems:
        print(f"发现 {len(problems)} 个结构问题：")
        for p in problems:
            print("  ✗ " + p)
        print()
        print("影响：畸形架构条目会让 lipo/otool/注入器的架构探测读到垃圾 slice，")
        print("      部分注入器会直接放弃注入或抛错。")
        return 1

    print("✓ 结构健康：所有 FAT 条目均指向合法 Mach-O，段覆盖自洽。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
