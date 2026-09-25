#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把若干 PNG 打包成 Windows .ico（Vista+ 允许在 ICO 里直接放 PNG）。
用法: makeico.py out.ico 16.png 32.png 48.png ...
"""
import struct
import sys
import os


def build(paths, out):
    entries = []
    blobs = []
    for p in paths:
        with open(p, "rb") as f:
            data = f.read()
        # PNG 尺寸从 IHDR 读（第 16..24 字节）
        w = struct.unpack(">I", data[16:20])[0]
        h = struct.unpack(">I", data[20:24])[0]
        entries.append((w, h, len(data)))
        blobs.append(data)

    n = len(entries)
    header = struct.pack("<HHH", 0, 1, n)          # reserved, type=1(icon), count
    offset = 6 + 16 * n
    dirs = b""
    for (w, h, size) in entries:
        dirs += struct.pack(
            "<BBBBHHII",
            0 if w >= 256 else w,                  # 256 记作 0
            0 if h >= 256 else h,
            0, 0, 1, 32, size, offset)
        offset += size

    with open(out, "wb") as f:
        f.write(header + dirs + b"".join(blobs))
    return out


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    out = sys.argv[1]
    srcs = [p for p in sys.argv[2:] if os.path.exists(p)]
    build(srcs, out)
    print("ico ok:", out, os.path.getsize(out), "bytes,", len(srcs), "sizes")
