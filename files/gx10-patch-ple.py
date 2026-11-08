#!/usr/bin/env python3
"""把 --ple-io ram 加進 Strata 的設定檔。

GX10 是 NVMe（非機械碟），setup.py 的 rotational_disk() 會回 None，
所以 PLE n-gram 表（28.8 GB）預設留在 SSD。手動加進 RAM 可讓 prompt 快 9–18%。
"""
import json
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("用法：python3 gx10-patch-ple.py <strata-<model>.json>")
        return 1
    path = sys.argv[1]
    with open(path, encoding="utf-8") as handle:
        cfg = json.load(handle)

    args = cfg.setdefault("args", [])
    if "--ple-io" in args:
        index = args.index("--ple-io")
        print("  · 已有 --ple-io =", args[index + 1] if index + 1 < len(args) else "?")
        return 0

    resident_flags = ("--mmap-experts", "--resident-experts")
    if not any(flag in args for flag in resident_flags):
        print("  · args 中沒有 --mmap-experts / --resident-experts，維持原樣")
        return 0

    args.extend(["--ple-io", "ram"])
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(cfg, handle, indent=2)
    print("  · 已加入 --ple-io ram")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
