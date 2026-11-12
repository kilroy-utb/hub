#!/usr/bin/env bash
# fix-wsl-login-shell.sh — 修好 WSL 終端機（login shell）沒有載入 ~/.bashrc 的問題
#
# 根因：bash 的 login shell 只讀 ~/.bash_profile → ~/.bash_login → ~/.profile，
#       存在哪個就用哪個，後面的完全不讀。WSL 終端機預設是 login shell，
#       所以只要 ~/.bash_profile 存在，~/.bashrc 就永遠不會被載入，
#       裡面的 export PATH / export STRATA_API_KEY 也就全部失效。
#
# 本腳本會：備份 ~/.bash_profile → 追加載入 ~/.bashrc 的區塊 → 用 login shell 驗證。
set -uo pipefail

echo "=== WSL login shell 修正 ==="
echo "只修改 ~/.bash_profile（會先備份），不碰金鑰內容、不改 ~/.bashrc。"
echo

HOME_DIR="$HOME"
BASHRC="$HOME_DIR/.bashrc"

echo "[1] 目前有哪些啟動檔"
for name in .bash_profile .bash_login .profile .bashrc; do
  path="$HOME_DIR/$name"
  if [ -f "$path" ]; then
    echo "  存在 $name（$(wc -c < "$path") bytes）"
  else
    echo "  不存在 $name"
  fi
done

echo
echo "[2] login shell 實際會讀哪一個"
first=""
for name in .bash_profile .bash_login .profile; do
  if [ -f "$HOME_DIR/$name" ]; then
    first="$HOME_DIR/$name"
    break
  fi
done
if [ -z "$first" ]; then
  echo "  （沒有任何一個，需要自己建立）"
else
  echo "  → $first"
  if grep -q '\.bashrc' "$first" 2>/dev/null; then
    echo "  狀態：已經有引用 .bashrc"
  else
    echo "  狀態：★ 沒有引用 .bashrc —— 這就是 export 沒生效的原因"
    echo "        （後面的 .profile 因此也不會被讀）"
  fi
fi

echo
echo "[3] 修正"
target="$HOME_DIR/.bash_profile"
if [ ! -f "$target" ]; then
  : > "$target"
  echo "  建立 ~/.bash_profile"
fi
if grep -q 'codex-login-shell' "$target" 2>/dev/null; then
  echo "  ~/.bash_profile 已經有修正區塊，略過（冪等）"
else
  backup="$target.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$target" "$backup"
  echo "  已備份：$backup"
  {
    echo ''
    echo '# >>> codex-login-shell >>>'
    echo '# WSL 終端機預設是 login shell，只讀 ~/.bash_profile。'
    echo '# 必須明確載入 ~/.bashrc，裡面的 export PATH / STRATA_API_KEY 才會生效。'
    if [ -f "$HOME/.profile" ] && grep -q '\.bashrc' "$HOME/.profile" 2>/dev/null; then
      echo '[ -f "$HOME/.profile" ] && . "$HOME/.profile"'
    else
      echo '[ -f "$HOME/.profile" ] && . "$HOME/.profile"'
      echo '[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"'
    fi
    echo '# <<< codex-login-shell <<<'
  } >> "$target"
  echo "  已把載入 .bashrc 的區塊寫進 ~/.bash_profile"
fi

echo
echo "[4] 用 login shell 驗證（bash -lic = 登入 + 互動，跟 WSL 終端機一致）"
bash -lic '
  if printf "%s" "$PATH" | tr ":" "\n" | grep -qx "$HOME/.local/bin"; then
    echo "  login shell 的 PATH 有 ~/.local/bin: 是"
  else
    echo "  login shell 的 PATH 有 ~/.local/bin: 否"
  fi
  if [ -n "${STRATA_API_KEY:-}" ]; then
    echo "  login shell 的 STRATA_API_KEY 非空: 是"
  else
    echo "  login shell 的 STRATA_API_KEY 非空: 否"
  fi
  if command -v codex >/dev/null 2>&1; then
    echo "  login shell 找得到 codex: 是（$(command -v codex)）"
  else
    echo "  login shell 找得到 codex: 否"
  fi
' 2>/dev/null

echo
echo "[5] 下一步"
echo "  關掉目前這個終端機，重新開一個（或執行 exec bash -l），然後："
echo "    command -v codex"
echo "    codex --version"
echo "  已經開著的 Codex 行程環境是舊的，必須完全退出後重開。"
echo "=== 結束 ==="
