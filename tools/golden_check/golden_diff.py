#!/usr/bin/env python3
#
#  golden_diff.py — JIT 内核 golden-bytes 对比
#
#  流程：
#    1. clang 交叉汇编 kernel_ref.s（ARMv8-A 权威参考，与 JITKernels.swift 逐条对应）
#    2. 解析 ELF64 提取 .text 字节
#    3. 与 jit_check.swift 生成的 jit_code.bin 逐字节对比
#
#  任何差异都会以指令偏移 + 两侧字节 + 上下文打印，用于定位 JITAssembler 编码错误。
#  历史教训：手写编码器曾编出不存在的 GP SMAX/SMIN（0x1B004000 基族，真机 SIGILL）。
#
#  依赖：clang（支持 aarch64-linux-gnu 目标）+ python3（无第三方库，纯标准库 ELF 解析）
#
#  用法：python3 golden_diff.py [jit_code.bin 路径]
#

import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REF_S = os.path.join(HERE, "kernel_ref.s")


def find_clang():
    candidates = [
        "clang",
        "/tmp/swift-5.9.2-RELEASE-ubuntu22.04/usr/bin/clang",
        "/usr/bin/clang",
    ]
    for c in candidates:
        try:
            subprocess.run([c, "--version"], capture_output=True, check=True)
            return c
        except Exception:
            continue
    sys.exit("找不到可用 clang（需支持 aarch64-linux-gnu）")


def elf64_text(path):
    """纯标准库解析 ELF64 little-endian，返回 .text 字节"""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF":
        sys.exit(f"{path}: 不是 ELF 文件")
    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]

    def shdr(i):
        off = e_shoff + i * e_shentsize
        name, typ, flags, addr, offset, size = struct.unpack_from("<IIQQQQ", data, off)
        return name, typ, offset, size

    _, _, str_off, str_size = shdr(e_shstrndx)
    strtab = data[str_off:str_off + str_size]

    for i in range(e_shnum):
        name, typ, offset, size = shdr(i)
        end = strtab.find(b"\0", name)
        sec = strtab[name:end].decode()
        if sec == ".text":
            return data[offset:offset + size]
    sys.exit(f"{path}: 找不到 .text 节")


def main():
    jit_bin = sys.argv[1] if len(sys.argv) > 1 else "jit_code.bin"
    if not os.path.exists(jit_bin):
        sys.exit(f"找不到 {jit_bin}（先运行 jit_check 生成）")

    clang = find_clang()
    obj = os.path.join(HERE, "kernel_ref.o")
    r = subprocess.run(
        [clang, "-target", "aarch64-linux-gnu", "-c", REF_S, "-o", obj],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        sys.exit(f"kernel_ref.s 汇编失败（参考文件本身有错？）:\n{r.stderr}")

    ref = elf64_text(obj)
    with open(jit_bin, "rb") as f:
        got = f.read()

    print(f"参考(clang) .text: {len(ref)} 字节   Swift(JITAssembler): {len(got)} 字节")

    if ref == got:
        print(f"GOLDEN-BYTES: IDENTICAL ({len(ref)} bytes, {len(ref)//4} 条指令)")
        return 0

    print("GOLDEN-BYTES: MISMATCH")
    n = min(len(ref), len(got))
    diffs = 0
    for i in range(0, n, 4):
        a = ref[i:i + 4]
        b = got[i:i + 4]
        if a != b:
            diffs += 1
            if diffs <= 20:
                # 打印差异指令及其前一条（上下文）
                prev = ref[max(0, i - 4):i]
                print(f"  @{i:4d}: clang={a.hex()} swift={b.hex()}"
                      f"  (前一条参考: {prev.hex()})")
    if len(ref) != len(got):
        print(f"  长度不同: clang={len(ref)} swift={len(got)}")
    if diffs == 0:
        print("  内容前缀相同，仅长度不同")
    print(f"共 {diffs} 条指令编码不一致")
    return 1


if __name__ == "__main__":
    sys.exit(main())
