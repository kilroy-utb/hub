#!/usr/bin/env python3
"""gx10-patch-bind.py — 改 Strata 的監聽位址與 API 金鑰。

用來讓另一台機器（VS Code / Cline / Continue）連進 GX10 上的 Strata。

  python3 gx10-patch-bind.py --run ~/Strata/run-iq3_s.sh \
                             --cfg ~/Strata/strata-iq3_s.json \
                             --bind 0.0.0.0 --api-key sk-xxxx

  python3 gx10-patch-bind.py --run ... --cfg ... \
                             --bind 127.0.0.1 --clear-api-key

為什麼要同時改兩個檔案：
  - run-<tag>.sh 是 setup.py 產生的啟動腳本，裡面的 --host 是 CLI 參數，
    會蓋掉設定檔的 host。CLI 優先，所以一定要一起改。
  - strata-<tag>.json 是引擎設定檔，放 host / api_key。

兩個檔案都會先備份成 .bak-<時間戳>。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil
import sys
import time


def patch_run_script(path: pathlib.Path, bind: str, api_key: str | None,
                     clear: bool) -> list[str]:
    """改 run 腳本：--host 換位址、--api-key 加上／更新／移除。"""
    text = path.read_text()
    changed: list[str] = []

    if re.search(r"--host[ =]", text):
        text = re.sub(r"(--host[ =]+)\S+", lambda m: m.group(1) + bind, text)
        changed.append(f"--host -> {bind}")
    else:
        changed.append("(沒有 --host，由 JSON 控制)")

    if api_key:
        if "--api-key" in text:
            text = re.sub(r'(--api-key[ =]+)("[^"]*"|\S+)',
                          lambda m: m.group(1) + '"%s"' % api_key, text)
            changed.append("--api-key 已更新")
        else:
            mark = re.search(r"(--port[ =]+\d+)", text)
            if mark:
                text = (text[:mark.end()] + ' --api-key "%s"' % api_key
                        + text[mark.end():])
                changed.append("--api-key 已新增")
            else:
                lines = text.splitlines(True)
                for index, line in enumerate(lines):
                    if "--config" in line:
                        lines[index] = (line.rstrip("\n")
                                        + ' --api-key "%s"\n' % api_key)
                        changed.append("--api-key 已新增")
                        break
                else:
                    print("！ 找不到可以插入 --api-key 的位置，請手動確認", file=sys.stderr)
                    return changed
    elif clear and "--api-key" in text:
        text = re.sub(r'\s*--api-key[ =]+("[^"]*"|\S+)', '', text)
        changed.append("--api-key 已移除")

    path.write_text(text)
    return changed


def patch_config(path: pathlib.Path, bind: str, api_key: str | None,
                 clear: bool) -> list[str]:
    """改 JSON：host 換位址、api_key 加上／更新／移除。"""
    data = json.loads(path.read_text())
    changed: list[str] = []

    if data.get("host") != bind:
        changed.append(f"host -> {bind}")
    data["host"] = bind

    if api_key:
        data["api_key"] = api_key
        changed.append("api_key 已寫入")
    elif clear:
        if data.pop("api_key", None) is not None:
            changed.append("api_key 已移除")

    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return changed


def main() -> int:
    parser = argparse.ArgumentParser(description="改 Strata 的監聽位址與金鑰")
    parser.add_argument("--run", required=True, help="run-<tag>.sh 的路徑")
    parser.add_argument("--cfg", required=True, help="strata-<tag>.json 的路徑")
    parser.add_argument("--bind", required=True, help="監聽位址（0.0.0.0 / 127.0.0.1）")
    parser.add_argument("--api-key", default="", help="API 金鑰")
    parser.add_argument("--clear-api-key", action="store_true",
                        help="把金鑰拿掉（收回成只給本機用）")
    parser.add_argument("--no-backup", action="store_true", help="不要備份")
    args = parser.parse_args()

    run_path = pathlib.Path(args.run).expanduser()
    cfg_path = pathlib.Path(args.cfg).expanduser()

    for path in (run_path, cfg_path):
        if not path.is_file():
            print(f"找不到 {path}", file=sys.stderr)
            return 1

    if not args.no_backup:
        stamp = time.strftime("%Y-%m-%d-%H%M")
        for path in (run_path, cfg_path):
            backup = path.with_name(path.name + ".bak-" + stamp)
            counter = 1
            while backup.exists():
                backup = path.with_name(path.name + ".bak-%s-%d" % (stamp, counter))
                counter += 1
            shutil.copy2(path, backup)
            print(f"備份 → {backup}")

    print("run 腳本：")
    for item in patch_run_script(run_path, args.bind, args.api_key,
                                 args.clear_api_key):
        print(f"  - {item}")

    print("JSON：")
    for item in patch_config(cfg_path, args.bind, args.api_key, args.clear_api_key):
        print(f"  - {item}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
