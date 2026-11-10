#!/usr/bin/env python3
"""gx10-patch-ctx.py — 調整 Strata 的 context / parallel / kv cache，降低統一記憶體用量。

為什麼需要：GX10 只有一顆 128GB 統一記憶體，IQ3_S 模型本身已佔掉一半以上。
如果 context 開太大、parallel 開太多，KV cache 會在長對話中把記憶體吃乾，
觸發 OOM killer（常見受害者是 tailscaled），結果就是 Tailscale DNS 整個消失、
VS Code 突然出現 ERR_NAME_NOT_RESOLVED。

  python3 gx10-patch-ctx.py --context 131072 --parallel 2
  python3 gx10-patch-ctx.py --context 65536 --parallel 1 --dry-run
  python3 gx10-patch-ctx.py --context 131072 --parallel 2 --restart

同時修改兩個地方（理由跟 gx10-patch-bind.py 相同）：
  - run-<tag>.sh  是 setup.py 產生的啟動腳本，--context/--parallel 是 CLI 參數，
    優先於設定檔，所以一定要一起改。
  - strata-<tag>.json 是引擎設定檔。

兩個檔案都會先備份成 .bak-<時間戳>。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import time

# 每 token 每 slot 的 KV 用量估算（int8: 64 KiB / token / slot）
KV_BYTES_PER_TOKEN = 64 * 1024


def default_paths() -> tuple[pathlib.Path, pathlib.Path]:
    home = pathlib.Path.home()
    return home / "Strata" / "run-iq3_s.sh", home / "Strata" / "strata-iq3_s.json"


def backup(path: pathlib.Path) -> pathlib.Path:
    bak = path.with_suffix(path.suffix + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(path, bak)
    return bak


def patch_run_script(path: pathlib.Path, context: int | None, parallel: int | None,
                     kv: str | None) -> list[str]:
    text = path.read_text()
    changed: list[str] = []

    def sub_flag(flag: str, value: str, label: str) -> None:
        nonlocal text
        pattern = re.compile(r"(--%s[ =]+)(\S+)" % flag)
        if pattern.search(text):
            text = pattern.sub(lambda m: m.group(1) + value, text, count=1)
            changed.append(f"{label} -> {value}")

    if context is not None:
        sub_flag("context", str(context), "context")
    if parallel is not None:
        sub_flag("parallel", str(parallel), "parallel")
    if kv is not None:
        sub_flag("kv", kv, "kv")

    if changed:
        path.write_text(text)
    return changed


def patch_config(path: pathlib.Path, context: int | None, parallel: int | None,
                 kv: str | None) -> list[str]:
    data = json.loads(path.read_text())
    changed: list[str] = []

    def set_key(candidates: tuple[str, ...], value, label: str) -> None:
        for key in candidates:
            if key in data:
                if data[key] != value:
                    data[key] = value
                    changed.append(f"{key} -> {value}")
                return
        data[candidates[0]] = value
        changed.append(f"{candidates[0]} -> {value} (新增)")

    if context is not None:
        set_key(("context", "context_size", "n_ctx"), context, "context")
    if parallel is not None:
        set_key(("parallel", "n_parallel", "n_parallel_seq"), parallel, "parallel")
    if kv is not None:
        set_key(("kv_cache_type", "kv_type"), kv, "kv")

    if changed:
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    return changed


def estimate(ctx: int, parallel: int) -> str:
    total = ctx * parallel * KV_BYTES_PER_TOKEN
    return f"{total / 1024 ** 3:.1f} GiB（估算：{ctx} tok × {parallel} slot × 64 KiB）"


def main() -> int:
    parser = argparse.ArgumentParser(description="調整 Strata 的 context / parallel / kv")
    default_run, default_cfg = default_paths()
    parser.add_argument("--run", type=pathlib.Path, default=default_run, help="啟動腳本路徑")
    parser.add_argument("--cfg", type=pathlib.Path, default=default_cfg, help="設定檔路徑")
    parser.add_argument("--context", type=int, help="新的 context 長度，例如 131072")
    parser.add_argument("--parallel", type=int, help="新的併發數，例如 2")
    parser.add_argument("--kv", help="新的 KV cache 型別，例如 int8 / q8_0 / f16")
    parser.add_argument("--dry-run", action="store_true", help="只顯示會改什麼，不寫檔")
    parser.add_argument("--restart", action="store_true", help="改完直接 sudo systemctl restart strata")
    args = parser.parse_args()

    if args.context is None and args.parallel is None and args.kv is None:
        print("請至少指定一個：--context / --parallel / --kv", file=sys.stderr)
        return 2

    for path in (args.run, args.cfg):
        if not path.exists():
            print(f"[XX] 找不到檔案：{path}", file=sys.stderr)
            return 1

    print("== 目前設定 ==")
    for path in (args.run, args.cfg):
        print(f"-- {path}")
        if path.suffix == ".json":
            data = json.loads(path.read_text())
            for key in ("context", "context_size", "n_ctx", "parallel",
                        "n_parallel", "kv_cache_type", "kv_type", "host", "port"):
                if key in data:
                    print(f"     {key} = {data[key]}")
        else:
            for line in path.read_text().splitlines():
                if re.search(r"--(context|parallel|kv|host|port)", line):
                    print(f"     {line.strip()}")

    print()
    print("== 變更 ==")
    if args.dry_run:
        print("  [dry-run] 不寫入任何檔案")
        if args.context and args.parallel:
            print(f"  KV 記憶體估算：{estimate(args.context, args.parallel)}")
        return 0

    for path in (args.run, args.cfg):
        bak = backup(path)
        print(f"  備份 → {bak}")

    for path, fn in ((args.run, patch_run_script), (args.cfg, patch_config)):
        changes = fn(path, args.context, args.parallel, args.kv)
        if changes:
            print(f"-- {path}")
            for item in changes:
                print(f"     {item}")
        else:
            print(f"-- {path}\n     （沒有變更）")

    if args.context and args.parallel:
        print(f"\n  KV 記憶體估算：{estimate(args.context, args.parallel)}")

    if args.restart:
        print("\n== 重啟服務 ==")
        result = subprocess.run(["sudo", "systemctl", "restart", "strata"])
        if result.returncode != 0:
            print("[XX] 重啟失敗，請手動檢查：sudo systemctl status strata", file=sys.stderr)
            return 1
        print("  已重啟，等 5 秒後驗收")
        time.sleep(5)
        subprocess.run(["systemctl", "is-active", "strata"])

    print("\n接著驗收：")
    print("  curl -s http://127.0.0.1:8080/health")
    print("  free -g")
    print("  sudo journalctl -u strata --since '-5 min' --no-pager | grep -i 'KV self size'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
