#!/usr/bin/env python3
"""把降低 TTFT（首字等待）的引擎參數加進 Strata 的設定檔。

背景：coding agent 每輪都要重送整段對話歷史。沒有 conversation cache 時，
官方社群實測會「重讀約 90% 的 prompt」；開了之後只讀 checkpoint 之後的增量。

會先跑一次引擎的 --help，確認這個引擎版本真的支援該參數才加，避免服務起不來。
"""
import json
import os
import shutil
import subprocess
import sys

# (引擎參數, 說明)。None 代表純開關。
CANDIDATES = [
    (["--prefill", "auto:32768"], "長 prompt 分塊讀取，社群實測快 21–35%（需 RAM ≥ 96 GB）"),
    (["--prompt-cache-spread"], "checkpoint 由新到舊分散保存，agent 改寫舊 history 時仍能命中"),
    (["--conversation-cache-mib", "8192"], "保留每個 client 的對話快取（8 GiB 主機 RAM）"),
    (["--conversation-cache-slots", "4"], "最多同時保留 4 個對話"),
]

ENV_FLAGS = [
    ("STRATA_CACHE_MESSAGE_BOUNDARY", "1", "agent 改寫最後一段訊息時，保留上一輪邊界的 checkpoint"),
]


def engine_help(exe: str) -> str:
    """引擎的 --help 輸出；拿不到就回空字串。"""
    if not exe or not os.path.isfile(exe):
        return ""
    try:
        proc = subprocess.run([exe, "--help"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return ""
    return (proc.stdout or "") + (proc.stderr or "")


def has_flag(help_text: str, flag: str) -> bool:
    return flag in help_text


def main() -> int:
    if len(sys.argv) < 2:
        print("用法：python3 gx10-patch-ttft.py <strata-<model>.json>")
        return 1
    path = sys.argv[1]
    with open(path, encoding="utf-8") as handle:
        cfg = json.load(handle)

    args = cfg.setdefault("args", [])
    env = cfg.setdefault("env", {})

    help_text = engine_help(cfg.get("exe", ""))
    if not help_text:
        print("  ! 拿不到引擎 --help（引擎還沒編譯？），無法確認參數是否支援")
        print("  ! 為安全起見不做任何修改")
        return 1
    print(f"  · 引擎 --help 取到 {len(help_text)} 字元")

    added = []
    notes = {}
    for flag_args, note in CANDIDATES:
        flag = flag_args[0]
        notes[flag] = note
        if not has_flag(help_text, flag):
            print(f"  · 略過 {flag}（這個引擎版本不支援）")
            continue
        # --prefill 是「取代值」而不是「append」，且 auto 要升級成 auto:32768
        if flag == "--prefill" and "--prefill" in args:
            index = args.index("--prefill")
            current = args[index + 1] if index + 1 < len(args) else ""
            if current == flag_args[1]:
                print(f"  · 已有 {flag} {current}，維持原值")
                continue
            args[index + 1] = flag_args[1]
            added.append((flag, flag_args[1]))
            continue
        if flag in args:
            print(f"  · 已有 {flag}，維持原值")
            continue
        args.extend(flag_args)
        added.append((flag, flag_args[1] if len(flag_args) > 1 else ""))

    for key, value, _ in ENV_FLAGS:
        if key in env:
            continue
        env[key] = value
        added.append((key, value))

    if not added:
        print("  · 沒有可加的項目（可能已經套用過）")
        return 0

    backup = path + ".bak-ttft"
    shutil.copy2(path, backup)

    with open(path, "w", encoding="utf-8") as handle:
        json.dump(cfg, handle, indent=2)

    for flag, value in added:
        print(f"  · 已加入 {flag}{' ' + value if value else ''}")
        if flag in notes:
            print(f"      {notes[flag]}")
    print(f"  · 備份：{backup}")
    print("  · 若引擎回報不認得某個選項，把備份改回來即可：")
    print(f"      cp {backup} {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
