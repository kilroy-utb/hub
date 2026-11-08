#!/usr/bin/env bash
# kilroy-hub-skill.sh — 在任何新容器安裝 kilroy-hub skill
#
# 用法（三選一）：
#   curl -O https://kilroy-utb.github.io/hub/files/kilroy-hub-skill.sh
#   GITHUB_TOKEN=ghp_xxx bash kilroy-hub-skill.sh      ← 憑證走環境變數（推論不會留在 chat）
#   bash kilroy-hub-skill.sh ghp_xxx                   ← 參數
#   bash kilroy-hub-skill.sh                           ← 互動式詢問
#
# 這個腳本本身不含任何憑證，可以放在公開的地方。PAT 只會寫進本機的 skill 目錄。
set -euo pipefail

PAGES="${PAGES:-https://kilroy-utb.github.io/hub/files}"
SKILL="kilroy-hub"
DEST_DIRS="${SKILL_DEST:-/workspace/.codex/skills}"
PAT="${GITHUB_TOKEN:-${1:-}}"

say(){ printf '\033[36m==>\033[0m %s\n' "$*"; }
die(){ printf '\033[31m錯誤：\033[0m %s\n' "$*" >&2; exit 1; }

if [ -z "$PAT" ] && [ -t 0 ]; then
  printf 'GitHub PAT（輸入不會顯示）：'
  read -r -s PAT
  echo
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/khskill.XXXXXX")"
cleanup(){ [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf -- "$WORK"; }
trap cleanup EXIT

say "下載 skill（$PAGES/kilroy-hub-skill.tar.gz）"
curl -fsSL -m 120 -o "$WORK/skill.tar.gz" "$PAGES/kilroy-hub-skill.tar.gz" \
  || die "下載失敗，請確認網路"
tar -xzf "$WORK/skill.tar.gz" -C "$WORK" || die "解壓失敗"
[ -f "$WORK/$SKILL/SKILL.md" ] || die "解壓後找不到 $SKILL/SKILL.md"

if [ -n "$PAT" ]; then
  say "注入 PAT 到 push_to_hub.sh"
  python3 - "$WORK/$SKILL/scripts/push_to_hub.sh" "$PAT" <<'PYEOF'
import re, sys
path, pat = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
new = 'PAT="${GITHUB_TOKEN:-%s}"' % pat
s2, n = re.subn(r'^PAT="\$\{GITHUB_TOKEN:-[^}]*\}"', new, s, count=1, flags=re.M)
if n == 0:
    s2 = new + "\n" + s
open(path, "w", encoding="utf-8").write(s2)
print("   已寫入（PAT 長度 %d，不顯示內容）" % len(pat))
PYEOF
else
  say "沒給 PAT：拉檔案仍可用，推送會失敗"
  echo "   之後補上：編輯 scripts/push_to_hub.sh 的 PAT= 那行，或設 GITHUB_TOKEN"
fi

for dest in $DEST_DIRS "$HOME/.codex/skills"; do
  [ -d "$(dirname "$dest")" ] || continue
  mkdir -p "$dest/$SKILL"
  rm -rf "${dest:?}/$SKILL"
  cp -r "$WORK/$SKILL" "$dest/$SKILL"
  chmod +x "$dest/$SKILL"/scripts/*.sh 2>/dev/null || true
  say "已安裝 → $dest/$SKILL"
done

say "驗證"
if command -v curl >/dev/null 2>&1; then
  curl -fsS -m 10 http://localhost:8080/get-skills 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    names=[s['name'] for s in d['skills']]
    print('   runner 已看到:', 'kilroy-hub ✓' if 'kilroy-hub' in names else '（尚未重新掃描，重開 session 就會出現）')
except Exception:
    print('   （無法連到 runner，稍後用 curl localhost:8080/get-skills 確認）')
" 2>/dev/null || echo "   （跳過 runner 檢查）"
fi

cat <<TXT

完成。新 session 的 agent 直接說「推到 hub」或「同步 hub 檔案」就會觸發。

自查指令：
  curl -s localhost:8080/get-skills | grep -o '"name":"kilroy-hub"'

TXT
