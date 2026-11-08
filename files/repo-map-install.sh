#!/usr/bin/env bash
# repo-map-install.sh — 在任何機器安裝 repo-map skill
#
#   用法：
#     curl -O https://kilroy-utb.github.io/hub/files/repo-map-install.sh
#     bash repo-map-install.sh /path/to/your/repo
#
# 做什麼：
#   1. 下載並解開 repo-map skill
#   2. 裝到 ~/.hermes/skills、~/.codex/skills、/workspace/.codex/skills
#   3. 在目標 repo 寫入 .github/instructions/repo-map.instructions.md
#      → VS Code Copilot Chat 每個 session 自動先讀 repo 地圖
#   4. 在目標 repo 的 AGENTS.md / .clinerules / .roorules 追加同一段（不覆蓋）
#   5. 產生第一次地圖（沒有模型金鑰也會產骨架）
set -euo pipefail

PAGES="${PAGES:-https://kilroy-utb.github.io/hub/files}"
SKILL="repo-map"
TARGET="${1:-$PWD}"

say(){ printf '\033[36m==>\033[0m %s\n' "$*"; }
die(){ printf '\033[31m錯誤：\033[0m %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/reposkill.XXXXXX")"
cleanup(){ [ -d "${WORK:-}" ] && rm -rf -- "$WORK"; }
trap cleanup EXIT

say "下載 skill（$PAGES/repo-map-skill.tar.gz）"
curl -fsSL -m 120 -o "$WORK/skill.tar.gz" "$PAGES/repo-map-skill.tar.gz" \
  || die "下載失敗，請確認網路"
tar -xzf "$WORK/skill.tar.gz" -C "$WORK" || die "解壓失敗"
[ -f "$WORK/$SKILL/SKILL.md" ] || die "解壓後找不到 $SKILL/SKILL.md"

say "安裝到 $TARGET"
bash "$WORK/$SKILL/scripts/install.sh" "$TARGET"
