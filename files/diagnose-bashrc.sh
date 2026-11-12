#!/usr/bin/env bash
# diagnose-bashrc.sh — 唯讀診斷：為什麼 ~/.bashrc 的 export 沒有生效
# 不修改任何檔案、不顯示金鑰、不啟動 Codex。
set -uo pipefail

REDACT='s/sk-[A-Za-z0-9_-]{4,}/<REDACTED>/g; s/[A-Za-z0-9]{24,}/<REDACTED>/g'

redact() { sed -E "$REDACT"; }

echo "=== ~/.bashrc 診斷 v1 ==="
echo "唯讀：不會修改任何檔案，不會顯示金鑰。"

RC="$HOME/.bashrc"

echo
echo "[1] 檔案基本資料"
if [ ! -f "$RC" ]; then
  echo "  !! ~/.bashrc 不存在"
  echo "  指令：printf '\nexport PATH=\"\$HOME/.local/bin:\$PATH\"\nexport STRATA_API_KEY=\"你的金鑰\"\n' >> ~/.bashrc"
  exit 1
fi
echo "  路徑: $RC"
echo "  大小: $(wc -c < "$RC") bytes"
echo "  修改時間: $(date -r "$RC" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c '%y' "$RC" 2>/dev/null)"

echo
echo "[2] 換行格式（CRLF 會讓 export 行尾多一個 \\r，導致變數名稱失效）"
CRLF=$(grep -c $'\r$' "$RC" 2>/dev/null | head -1)
CRLF=${CRLF:-0}
TOTAL=$(wc -l < "$RC")
echo "  含 CR 的行數: $CRLF / $TOTAL"
if [ "$CRLF" -gt 0 ]; then
  echo "  !! 偵測到 Windows 換行（CRLF）—— 這是 WSL 上 export 失效最常見的原因"
  echo "  修法：sed -i 's/\r$//' ~/.bashrc"
fi

echo
echo "[3] 語法檢查（bash -n）"
SYNTAX_OUT="$(bash -n "$RC" 2>&1 | redact)"
if [ -z "$SYNTAX_OUT" ]; then
  echo "  OK 沒有語法錯誤"
else
  echo "  !! 有語法錯誤（下面已遮蔽可能的金鑰）："
  printf '%s\n' "$SYNTAX_OUT" | sed 's/^/     /'
  echo "  影響：bash 讀到第一個錯誤就停止，後面的 export 全部不會執行。"
fi

echo
echo "[4] 相關行的位置（只列行號，不顯示金鑰內容）"
grep -n 'export[[:space:]]*PATH=' "$RC" 2>/dev/null | cut -d: -f1 | while read -r n; do
  echo "  export PATH= 在第 $n 行"
done
grep -n 'export[[:space:]]*STRATA_API_KEY=' "$RC" 2>/dev/null | cut -d: -f1 | while read -r n; do
  echo "  export STRATA_API_KEY= 在第 $n 行"
done
grep -n 'local/bin' "$RC" 2>/dev/null | cut -d: -f1 | while read -r n; do
  echo "  含 local/bin 的行：第 $n 行"
done
grep -nE '^[[:space:]]*return[[:space:]]*$|^[[:space:]]*case[[:space:]]+\$-' "$RC" 2>/dev/null | cut -d: -f1 | while read -r n; do
  echo "  return / case \$- 守衛：第 $n 行"
done

echo
echo "[5] 決定性測試：在互動式子 shell 裡 source ~/.bashrc，看結果"
bash -ic '
  source "$HOME/.bashrc" >/dev/null 2>&1
  if printf "%s" "$PATH" | tr ":" "\n" | grep -qx "$HOME/.local/bin"; then
    echo "  source 後 PATH 有 ~/.local/bin: 是"
  else
    echo "  source 後 PATH 有 ~/.local/bin: 否"
  fi
  if [ -n "${STRATA_API_KEY:-}" ]; then
    echo "  source 後 STRATA_API_KEY 非空: 是"
  else
    echo "  source 後 STRATA_API_KEY 非空: 否"
  fi
' 2>/dev/null

echo
echo "[5b] 互動式 shell 自動啟動時（不手動 source）有沒有讀到 ~/.bashrc"
AUTO_PATH="$(printf 'printf "%%s\\n" "$PATH"\nexit\n' | bash -i 2>/dev/null | grep -v '^bash:' | head -1)"
if printf '%s' "$AUTO_PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
  echo "  自動啟動的互動 shell 有 ~/.local/bin: 是"
else
  echo "  自動啟動的互動 shell 有 ~/.local/bin: 否"
  echo "  → 內容對但自動啟動沒套用：檢查 BASH_ENV / 啟動參數 / ~/.profile"
fi

echo
echo "[5c] 其他可能覆寫 PATH 的來源"
echo "  BASH_ENV: ${BASH_ENV:-（未設定）}"
echo "  ENV: ${ENV:-（未設定）}"
for f in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bash_login"; do
  if [ -f "$f" ]; then
    echo "  $f 存在，其中 PATH 相關行號：$(grep -n 'PATH=' "$f" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')"
  fi
done
PROF=$(grep -ln 'PATH=' /etc/profile /etc/profile.d/*.sh 2>/dev/null | tr '\n' ' ')
echo "  /etc 底下會設 PATH 的檔案：${PROF:-（無）}"

echo
echo "[6] 結論"
if [ -n "$SYNTAX_OUT" ]; then
  echo "  根因：~/.bashrc 有語法錯誤，bash 讀到那裡就停止，後面的 export 全部沒執行。"
  echo "  修法：先修掉語法錯誤（bash -n ~/.bashrc 看行號），再 source ~/.bashrc"
elif [ "$CRLF" -gt 0 ]; then
  echo "  注意：~/.bashrc 有 CRLF 換行。某些情況會讓 export 失效，建議先清掉。"
  echo "  修法：sed -i 's/\r\$//' ~/.bashrc"
fi
if [ -z "$SYNTAX_OUT" ]; then
  echo "  .bashrc 可正常解析。請依 [5] 與 [5b] 判斷："
  echo "    - [5] 有、[5b] 沒有 → .bashrc 內容對，但互動 shell 沒自動讀它（看 [5c]）。"
  echo "    - [5] 沒有         → export 那行有問題或位置太前面（看 [4] 的行號）。"
  echo "    - [5] 有、[5b] 有   → .bashrc 正常；問題在啟動 Codex 的那個行程環境是舊的。"
  echo "                         請完全退出 Codex（不是只關對話框）再重新執行 codex。"
fi
echo
echo "=== 報告結束；可貼回此報告，勿貼金鑰或完整 env ==="
