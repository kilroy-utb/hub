#!/usr/bin/env bash
# sync_github_files.sh — 同步 GitHub repo 的檔案到本機（新增 / 更新 / 刪除）
#
# 刪除安全機制：只刪「同步清單裡有、遠端現在沒有」的檔案，且刪前先備份。
# --prune 只清理「孤兒 .sh」（遠端已無、清單也沒有的腳本），其他自用檔案不動。
# 用法：bash sync_github_files.sh [--dir DIR] [--flatten] [--dry-run] [--list]
#       [--prefix PATH] [--exclude PAT] [--repo OWNER/NAME] [--branch BR] [--prune] [--yes]
set -uo pipefail
REPO="${REPO:-kilroy-utb/hub}"; BRANCH="${BRANCH:-main}"; PAGES="${PAGES:-https://kilroy-utb.github.io/hub}"
API="https://api.github.com"; TOKEN="${GITHUB_TOKEN:-}"; MANIFEST=".github-files.manifest"; KEEP=5
DRY=0; FLAT=0; PRUNE=0; YES=0; LIST=0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; PFX=(files); EXC=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2;; --repo) REPO="$2"; shift 2;; --branch) BRANCH="$2"; shift 2;;
    --prefix) PFX+=("$2"); shift 2;; --exclude) EXC+=("$2"); shift 2;; --token) TOKEN="$2"; shift 2;;
    --flatten) FLAT=1; shift;; --dry-run) DRY=1; shift;; --prune) PRUNE=1; shift;;
    --yes) YES=1; shift;; --list) LIST=1; shift;; --keep-backups) KEEP="$2"; shift 2;;
    *) echo "未知選項：$1"; exit 1;;
  esac
done
mkdir -p "$DIR" || exit 1; DIR="$(cd "$DIR" && pwd)"
M="$DIR/$MANIFEST"; BK="$DIR/.sync_backup"
ok(){ printf '  + %s\n' "$*"; }; del(){ printf '  - %s\n' "$*"; }; up(){ printf '  ~ %s\n' "$*"; }
eq(){ printf '  = %s\n' "$*"; }; wa(){ printf '  ! %s\n' "$*"; }
wr(){ printf '  ! %s\n' "$*" >&2; }; er(){ printf '  x %s\n' "$*" >&2; }
have_git=0; command -v git >/dev/null 2>&1 && have_git=1
sha(){ [ "$have_git" = 1 ] && git hash-object "$1" 2>/dev/null; }
confirm(){ [ "$YES" = 1 ] && return 0; [ "$DRY" = 1 ] && return 0; printf '%s [y/N] ' "$1"; read -r a
  case "$a" in y|Y|yes|YES) return 0;; *) return 1;; esac; }

# 遠端清單 → <rel>\t<sha|->\t<url>
rlist(){
  for p in "${PFX[@]}"; do
    h=(); [ -n "$TOKEN" ] && h=(-H "Authorization: Bearer $TOKEN")
    j="$(curl -fsSL -m 30 "${h[@]}" "$API/repos/$REPO/contents/$p?ref=$BRANCH" 2>/dev/null)"
    if [ -n "$j" ] && printf %s "$j" | python3 -c 'import json,sys;json.load(sys.stdin)' 2>/dev/null; then
      printf %s "$j" | P="$p" R="$REPO" B="$BRANCH" python3 -c '
import json,os,sys
p=os.environ["P"];it=json.load(sys.stdin)
if not isinstance(it,list):sys.exit(4)
for f in it:
  if f.get("type")!="file":continue
  n=f.get("name","")
  if n.startswith("."):continue
  print("%s/%s\t%s\t%s"%(p,n,f.get("sha") or "-",f.get("download_url") or "https://raw.githubusercontent.com/%s/%s/%s/%s"%(os.environ["R"],os.environ["B"],p,n)))'
    else
      wr "API 取不到 $p，改用 $PAGES/$p/index.html"
      curl -fsSL -m 30 "$PAGES/$p/index.html" 2>/dev/null | P="$p" G="$PAGES" python3 -c '
import os,re,sys
p=os.environ["P"];g=os.environ["G"];h=sys.stdin.read();s=set()
pat=re.compile(r"href=[\x22\x27]([^\x22\x27]+)[\x22\x27]")
for m in pat.finditer(h):
  u=m.group(1).strip()
  while u.startswith("./"):u=u[2:]
  if u.startswith("../") or "/" in u or u.startswith(("http","#","mailto:")):continue
  if not u.endswith((".sh",".py",".md",".html",".txt",".json",".yaml",".yml")):continue
  if u.startswith("."):continue
  s.add(u)
for n in sorted(s):print("%s/%s\t-\t%s/%s/%s"%(p,n,g,p,n))'
    fi
  done
}

T=$(mktemp); O=$(mktemp); P=$(mktemp); trap 'rm -f "$T" "$O" "$P"' EXIT
REPO="$REPO" BRANCH="$BRANCH" PAGES="$PAGES" rlist > "$T"
[ "$(grep -c . "$T")" -gt 0 ] || { er "抓不到遠端檔案"; exit 1; }
echo "遠端 $(grep -c . "$T") 個檔案"
[ $LIST = 1 ] && { cat "$T"; exit 0; }
[ -f "$M" ] && grep -v '^#' "$M" | grep -v '^$' > "$O" || : > "$O"

ADD=""; UPD=""; DEL=""; SAME=0
while IFS=$'\t' read -r rel rsha url; do
  [ -z "$rel" ] && continue
  lr="$rel"; [ $FLAT = 1 ] && lr="${rel##*/}"; base="${rel##*/}"
  sk=0
  for e in ${EXC[@]+"${EXC[@]}"}; do
    case "$rel" in $e) sk=1;; esac; case "$lr" in $e) sk=1;; esac; case "$base" in $e) sk=1;; esac
  done
  [ $sk = 1 ] && continue
  printf '%s\t%s\t%s\t%s\n' "$rel" "$lr" "$rsha" "$url" >> "$P"
  f="$DIR/$lr"
  if [ ! -f "$f" ]; then ADD="$ADD$lr"$'\n'; ok "新增 $lr"
  else
    s="$(sha "$f")"
    if [ -n "$rsha" ] && [ "$rsha" != "-" ] && [ "$s" = "$rsha" ]; then SAME=$((SAME+1)); eq "未變 $lr"
    else UPD="$UPD$lr"$'\n'; up "更新 $lr"; fi
  fi
done < "$T"
while IFS=$'\t' read -r rr rl rs; do
  [ -z "$rr" ] && continue
  awk -F'\t' -v r="$rr" '$1==r{f=1} END{exit !f}' "$T" || { DEL="$DEL$rl"$'\n'; del "刪除 $rl（遠端已無）"; }
done < "$O"
PRUNE_L=""
if [ $PRUNE = 1 ]; then
  while IFS= read -r f; do
    b="$(basename "$f")"; case "$b" in "$MANIFEST"|sync_github_files.sh) continue;; esac
    case "$b" in *.sh) ;; *) continue;; esac
    awk -F'\t' -v b="$b" '{n=split($1,a,"/"); if(a[n]==b)f=1} END{exit !f}' "$T" && continue
    awk -F'\t' -v b="$b" '$2==b{f=1} END{exit !f}' "$O" && continue
    PRUNE_L="$PRUNE_L$f"$'\n'
  done < <(find "$DIR" -maxdepth 2 -type f -not -path "$BK/*" -not -path "$DIR/.git/*" 2>/dev/null | sort)
  [ -n "$PRUNE_L" ] && { echo "--prune 將刪除："; printf %s "$PRUNE_L" | sed "s|$DIR/|    |"; }
fi
[ $DRY = 1 ] && { echo "dry-run：未實際寫入"; exit 0; }

TS="$(date +%Y%m%d-%H%M%S)"; RC=0
bk(){ [ -f "$DIR/$1" ] && { mkdir -p "$BK/$TS/$(dirname "$1")" 2>/dev/null && cp -p "$DIR/$1" "$BK/$TS/$1" 2>/dev/null; }; }
while IFS= read -r lr; do
  [ -z "$lr" ] && continue
  line="$(awk -F'\t' -v l="$lr" '$2==l{print;exit}' "$P")"
  rsha="$(printf %s "$line" | cut -f3)"; url="$(printf %s "$line" | cut -f4)"
  [ -z "$url" ] && { er "缺下載網址：$lr"; RC=1; continue; }
  mkdir -p "$(dirname "$DIR/$lr")" 2>/dev/null; t="$DIR/$lr.part"; rm -f "$t"
  curl -fsSL -m 120 -o "$t" "$url" || { er "下載失敗：$lr"; rm -f "$t"; RC=1; continue; }
  if [ -n "$rsha" ] && [ "$rsha" != "-" ] && [ "$have_git" = 1 ]; then
    g="$(sha "$t")"; [ -n "$g" ] && [ "$g" != "$rsha" ] && { er "sha 不符，放棄：$lr"; rm -f "$t"; RC=1; continue; }
  fi
  if [ "$rsha" = "-" ] && [ -f "$DIR/$lr" ] && [ "$have_git" = 1 ]; then
    g="$(sha "$t")"; h="$(sha "$DIR/$lr")"
    if [ -n "$g" ] && [ "$g" = "$h" ]; then
      rm -f "$t"; SAME=$((SAME+1)); UPD="$(printf %s "$UPD" | grep -vxF "$lr" || true)"
      eq "未變 $lr（內容相同）"; continue
    fi
  fi
  bk "$lr"; mv -f "$t" "$DIR/$lr"; case "$lr" in *.sh) chmod +x "$DIR/$lr";; esac; ok "寫入 $lr"
done <<< "$ADD$UPD"
while IFS= read -r lr; do
  [ -z "$lr" ] && continue
  [ -f "$DIR/$lr" ] && { bk "$lr"; rm -f "$DIR/$lr"; del "已刪除 $lr"; }
  d="$(dirname "$DIR/$lr")"; while [ "$d" != "$DIR" ] && [ -d "$d" ]; do rmdir "$d" 2>/dev/null || break; d="$(dirname "$d")"; done
done <<< "$DEL"
if [ -n "$PRUNE_L" ]; then
  if confirm "確定刪除上面列出的孤兒檔？"; then
    while IFS= read -r f; do [ -n "$f" ] && { bk "${f#$DIR/}"; rm -f "$f"; del "已刪除 ${f#$DIR/}"; }; done <<< "$PRUNE_L"
  else wa "略過 --prune"; fi
fi
{ echo "# sync_github_files.sh — repo=$REPO branch=$BRANCH synced=$(date -Is)"
  echo "# 格式：<遠端路徑>\t<本機路徑>\t<blob sha>"
  while IFS=$'\t' read -r rr lr rs ru; do printf '%s\t%s\t%s\n' "$rr" "$lr" "$(sha "$DIR/$lr")"; done < "$P"
} > "$M"
ok "清單已更新：$M"
if [ -d "$BK" ]; then
  mapfile -t bs < <(ls -1d "$BK"/*/ 2>/dev/null | sort -r)
  [ "${#bs[@]}" -gt "$KEEP" ] && for b in "${bs[@]:$KEEP}"; do rm -rf "$b"; done
fi
printf '新增 %s ｜ 更新 %s ｜ 刪除 %s ｜ 未變 %s\n' \
  "$(printf %s "$ADD" | grep -c . || true)" "$(printf %s "$UPD" | grep -c . || true)" \
  "$(printf %s "$DEL" | grep -c . || true)" "$SAME"
exit "$RC"
