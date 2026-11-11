#!/usr/bin/env bash
# trail-setup-wsl.sh — WSL 上安裝 Trail（舊名 Graft）+ 接到 Codex / GitHub Copilot
#
# 用法：
#   bash trail-setup-wsl.sh                          # 只檢查 + 安裝 trail
#   bash trail-setup-wsl.sh --check                  # 只檢查，不動任何東西
#   bash trail-setup-wsl.sh --repo ~/我的專案         # 順便在該 repo 啟用 Codex + Copilot
#   bash trail-setup-wsl.sh --repo ~/我的專案 --deep  # 再用 GX10 的 Strata 做深度摘要
#   bash trail-setup-wsl.sh --gx10-host gx10-37a8    # 指定 GX10 主機名或 100.x.y.z
#
# 設計原則：
#   - 不動 /usr/lib/node_modules，改用 ~/.local 前綴（避免 EACCES）
#   - 已有設定一定先備份，絕不覆蓋 ~/.codex/config.toml 裡的 Strata provider
#   - 每一步都有明確的 PASS / FAIL 訊息，最後給總結
#
# 套件版本：2026-11-11.1

set -uo pipefail

GREEN=""; RED=""; YELLOW=""; BLUE=""; RESET=""
if [ -t 1 ]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
fi

pass() { printf '  %s[OK]%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %s[!!]%s %s\n' "$YELLOW" "$RESET" "$1"; }
fail() { printf '  %s[XX]%s %s\n' "$RED" "$RESET" "$1"; FAILURES=$((FAILURES + 1)); }
info() { printf '  %s--%s %s\n' "$BLUE" "$RESET" "$1"; }
step() { printf '\n%s== %s ==%s\n' "$BLUE" "$1" "$RESET"; }

FAILURES=0

MODE="install"
REPO=""
DO_DEEP=0
GX10_HOST="gx10-37a8"
GX10_PORT="8080"
GX10_MODEL="qwen3.8-flash-next-iq3_s"
TRAIL_PKG="@trailhq/trail-code"

while [ $# -gt 0 ]; do
  case "$1" in
    --check)      MODE="check" ;;
    --repo)       REPO="${2:-}"; shift ;;
    --deep)       DO_DEEP=1 ;;
    --gx10-host)  GX10_HOST="${2:-}"; shift ;;
    --gx10-port)  GX10_PORT="${2:-}"; shift ;;
    --model)      GX10_MODEL="${2:-}"; shift ;;
    -h|--help)    sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "不认识的參數：$1"; exit 2 ;;
  esac
  shift
done

printf '%s\n' "==============================================="
printf '  WSL × Trail（code context graph）安裝\n'
printf '  腳本版本：2026-11-11.1\n'
printf '==============================================='

# ---------- 安全護欄 ----------
case "$HOME" in
  *".codex-home"*)
    printf '%s\n' "[XX] 偵測到 HOME 位於 Codex session 目錄，為安全起見中止。"
    printf '%s\n' "     請在一般用户家目录（/home/<user>）执行本脚本。"
    exit 1
    ;;
esac

# ---------- 步驟 1：系統環境 ----------
step "步驟 1：系統環境"

if [ -r /etc/os-release ]; then
  . /etc/os-release
  os_desc="${PRETTY_NAME:-$NAME}"
else
  os_desc="未知"
fi
pass "作業系統：$os_desc"

arch="$(uname -m)"
case "$arch" in
  x86_64)  pass "架構：x86_64" ;;
  aarch64) pass "架構：aarch64" ;;
  *)       warn "架構：$arch" ;;
esac

if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
  pass "確認運行於 WSL"
else
  warn "不像是 WSL 環境（/proc/version 沒看到 microsoft），後續指令仍可執行"
fi

# ---------- 步驟 2：Node.js（Trail 需要 ^20.16.0 || >=22.3.0） ----------
step "步驟 2：Node.js 與 npm"

if ! command -v node >/dev/null 2>&1; then
  fail "找不到 node —— Trail 需要 Node ^20.16.0 或 >=22.3.0"
  info "先跑 codex-setup-wsl.sh 裝好 Node，再回來執行本腳本"
  printf '\n%s== 總結 ==%s\n' "$BLUE" "$RESET"
  fail "Node 缺失，無法繼續"
  exit 1
fi

node_ver="$(node --version)"
node_ver_num="${node_ver#v}"
node_major="${node_ver_num%%.*}"
node_rest="${node_ver_num#*.}"
node_minor="${node_rest%%.*}"

node_ok=0
if [ "$node_major" -gt 22 ]; then
  node_ok=1
elif [ "$node_major" -eq 22 ]; then
  if [ "$node_minor" -ge 3 ]; then node_ok=1; fi
elif [ "$node_major" -eq 20 ]; then
  if [ "$node_minor" -ge 16 ]; then node_ok=1; fi
fi

if [ "$node_ok" -eq 1 ]; then
  pass "Node $node_ver（Trail 要求 ^20.16.0 || >=22.3.0）"
else
  fail "Node $node_ver 太舊，Trail 要求 ^20.16.0 || >=22.3.0"
  info "升級 Node 到 20.16+ 或 22.3+："
  info "  nvm install 22 && nvm use 22"
  info "  （或直接下載 nodejs.org 的 22.x LTS tarball）"
fi

if command -v npm >/dev/null 2>&1; then
  pass "npm：$(npm --version)"
else
  fail "找不到 npm"
fi

# ---------- 步驟 3：npm 前綴 ----------
step "步驟 3：npm 全域安裝位置"

npm_prefix="$(npm config get prefix 2>/dev/null || echo "$HOME/.local")"
prefix_bin="${npm_prefix%/}/bin"
mkdir -p "$prefix_bin" 2>/dev/null

# 真正該看的是「能不能寫」，不是路徑好不好看：
# 很多機器預設 prefix 是 /usr 或 /usr/local，非 root 使用者 npm i -g 一定 EACCES。
if ! [ -w "$prefix_bin" ] || ! [ -w "$npm_prefix" ]; then
  warn "npm 前綴 $npm_prefix 不可寫，npm i -g 會 EACCES"
  mkdir -p "$HOME/.local/bin"
  npm config set prefix "$HOME/.local" >/dev/null 2>&1
  npm_prefix="$(npm config get prefix 2>/dev/null || echo "$HOME/.local")"
  prefix_bin="${npm_prefix%/}/bin"
  mkdir -p "$prefix_bin" 2>/dev/null
  pass "npm 前綴已改為 $npm_prefix（家目錄，不需 root）"
else
  pass "npm 前綴：$npm_prefix（可寫）"
fi

if ! printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$prefix_bin"; then
  if ! grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.bashrc"
    pass "已寫入 ~/.bashrc（PATH 加入 $prefix_bin）"
  else
    pass "~/.bashrc 已有 PATH 設定"
  fi
  export PATH="$prefix_bin:$PATH"
fi
printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$prefix_bin" \
  && pass "PATH 已指向 $prefix_bin" \
  || warn "PATH 沒有 $prefix_bin（重開終端機讓 ~/.bashrc 生效）"

# ---------- 步驟 4：安裝 Trail ----------
step "步驟 4：安裝 Trail"

TRAIL_BIN="$prefix_bin/trail"
if [ -e "$TRAIL_BIN" ] || [ -L "$TRAIL_BIN" ]; then
  if [ -L "$TRAIL_BIN" ] && readlink "$TRAIL_BIN" | grep -q "node_modules/@trailhq/trail-code"; then
    info "家目錄已有（npm 管理）：$("$TRAIL_BIN" --version 2>&1 | head -1)"
  else
    old_ver="(無法執行)"
    [ -x "$TRAIL_BIN" ] && old_ver="$("$TRAIL_BIN" --version 2>&1 | head -1)"
    stash="$TRAIL_BIN.pre-npm-$(date +%Y%m%d-%H%M%S)"
    mv -f "$TRAIL_BIN" "$stash" && pass "既有檔案已移到 $(basename "$stash")（$old_ver）"
  fi
fi

if [ "$MODE" = "install" ]; then
  if npm install -g "$TRAIL_PKG" --registry=https://registry.npmjs.org/ 2>&1 | tail -4; then
    pass "npm 安裝完成"
  else
    warn "npm 安裝失敗，試試鏡像站"
    if npm install -g "$TRAIL_PKG" --registry=https://registry.npmmirror.com/ 2>&1 | tail -4; then
      pass "鏡像站安裝完成"
    else
      fail "npm 安裝失敗，請手動執行："
      info "npm install -g $TRAIL_PKG"
    fi
  fi
else
  info "check 模式，略過安裝"
fi

hash -r 2>/dev/null || true

if [ -x "$TRAIL_BIN" ]; then
  pass "trail 版本：$("$TRAIL_BIN" --version 2>&1 | head -1)"
  pass "trail 路徑：$TRAIL_BIN"
else
  fail "找不到 $TRAIL_BIN"
  info "重開終端機讓 ~/.bashrc 生效後再試：trail --version"
fi

# Codex 是被 shell 啟動的，PATH 必須在「登入 shell」裡也找得到 trail，
# 否則 config.toml 裡的 command = "trail" 會啟動失敗。
if bash -lc 'command -v trail' >/dev/null 2>&1; then
  pass "登入 shell 也能找到 trail（$(bash -lc 'command -v trail' 2>/dev/null)）"
else
  warn "登入 shell 找不到 trail —— Codex 啟動 MCP 會失敗"
  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    if [ -f "$rc" ] && ! grep -q '.local/bin' "$rc" 2>/dev/null; then
      printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
      pass "已寫入 $rc"
    fi
  done
  if bash -lc 'command -v trail' >/dev/null 2>&1; then
    pass "已修正，登入 shell 可以找到 trail"
  else
    fail "還是找不到 trail，請手動把 $prefix_bin 加進 PATH，或把 config.toml 裡的 command 改成絕對路徑"
  fi
fi

# ---------- 步驟 5：Codex 環境 ----------
step "步驟 5：Codex CLI"

# Codex 讀的是 CODEX_HOME（沒設就是 <OS 家目錄>/.codex），
# Trail 寫的是 <$HOME>/.codex。兩者不一致的話 Codex 會讀不到。
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
if [ -n "${CODEX_HOME:-}" ] && [ "$CODEX_DIR" != "$HOME/.codex" ]; then
  warn "你設了 CODEX_HOME=$CODEX_DIR，但 Trail 寫入的位置是 $HOME/.codex"
  info "兩者不一致，Codex 可能讀不到 MCP/hooks。建議：unset CODEX_HOME"
fi

if command -v codex >/dev/null 2>&1; then
  pass "codex：$(codex --version 2>&1 | grep -v '^WARNING' | head -1)"
else
  warn "這台機器沒裝 Codex CLI —— Trail 的 MCP/hook 接不上去"
  info "先跑 codex-setup-wsl.sh 裝好 Codex"
fi

# Trail 的 Codex 接線（config.toml / hooks.json）只有在 ~/.codex 存在時才會寫入，
# 所以這裡先把它建好，否則會被靜靜略過。
if [ -d "$HOME/.codex" ]; then
  pass "Codex 設定目錄：$HOME/.codex"
else
  mkdir -p "$HOME/.codex" 2>/dev/null
  if [ -d "$HOME/.codex" ]; then
    pass "已建立 $HOME/.codex（Trail 的 MCP 與 hook 需要它）"
  else
    warn "無法建立 $HOME/.codex，Trail 會略過 Codex 的 MCP 與 hook 接線"
  fi
fi

# ---------- 步驟 6：備份 ----------
step "步驟 6：備份 Codex 設定"

mkdir -p "$CODEX_DIR"
ts="$(date +%Y%m%d-%H%M%S)"
for f in config.toml hooks.json; do
  if [ -f "$CODEX_DIR/$f" ]; then
    cp "$CODEX_DIR/$f" "$CODEX_DIR/$f.bak-$ts"
    pass "已備份 $f → $f.bak-$ts"
  else
    info "$f 不存在，無需備份"
  fi
done
info "Trail 只會「附加」區段，不會重寫整份 config.toml，你的 Strata provider 設定會保留"

# ---------- 步驟 7：在 repo 啟用 ----------
step "步驟 7：在專案啟用 Trail"

if [ -z "$REPO" ]; then
  if [ -d "$PWD/.git" ]; then
    REPO="$PWD"
    info "未指定 --repo，使用目前目錄：$REPO"
  else
    info "未指定 --repo，且目前目錄不是 git 專案"
    info "啟用指令（換成你的專案路徑）："
    info "  cd ~/你的專案 && trail init --agents agents copilot"
    REPO=""
  fi
else
  REPO="$(cd "$REPO" 2>/dev/null && pwd)"
  if [ -z "$REPO" ]; then
    fail "指定的 --repo 目錄不存在"
  else
    info "目標專案：$REPO"
  fi
fi

if [ -n "$REPO" ]; then
  if [ ! -d "$REPO/.git" ]; then
    warn "$REPO 沒有 .git（不是 git 專案），仍可建立地圖，但 teammates 拿不到"
  fi
  if [ "$MODE" = "install" ]; then
    if [ -x "$TRAIL_BIN" ]; then
      ( cd "$REPO" && "$TRAIL_BIN" init --agents agents copilot ) 2>&1 | tail -12
      rc=$?
      if [ $rc -eq 0 ]; then
        pass "trail init 完成"
      else
        fail "trail init 失敗（退出碼 $rc）"
      fi
      info "產生的東西："
      info "  $REPO/AGENTS.md                        （Codex 會讀）"
      info "  $REPO/.github/copilot-instructions.md （VS Code Copilot 會讀）"
      info "  $REPO/.trail/                         （地圖 + 學習紀錄）"
      info "  $HOME/.codex/config.toml              （新增 [mcp_servers.trail]）"
      info "  $HOME/.codex/hooks.json               （自動更新地圖的 hooks）"
    else
      fail "trail 沒裝好，無法 init"
    fi
  else
    info "check 模式，實際會寫入的檔案："
    ( cd "$REPO" && "$TRAIL_BIN" init --agents agents copilot --dry-run ) 2>&1 | sed 's/^/    /'
  fi
fi

# ---------- 步驟 8：驗收 ----------
step "步驟 8：驗收"

if [ -x "$TRAIL_BIN" ]; then
  probe_out="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1.0"}}}' \
    | timeout 30 "$TRAIL_BIN" mcp 2>/dev/null | head -1)"
  if printf '%s' "$probe_out" | grep -q 'serverInfo'; then
    pass "MCP server 握手成功（$(printf '%s' "$probe_out" | grep -o '"name":"[^"]*"' | head -1)）"
  else
    fail "MCP server 握手失敗 —— Codex 的地圖查詢工具會不能用"
    info "手動測試：printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"p","version":"1"}}}' | trail mcp"
  fi
fi

if command -v codex >/dev/null 2>&1; then
  info "Codex 已註冊的 MCP server："
  # 明確指定 CODEX_HOME，否則 Codex 會用 OS 家目錄去找，檢查結果會失真
  CODEX_HOME="$CODEX_DIR" codex mcp list 2>&1 | grep -v '^WARNING' | sed 's/^/      /'
fi

if [ -f "$CODEX_DIR/config.toml" ] && grep -q 'mcp_servers' "$CODEX_DIR/config.toml"; then
  pass "config.toml 已含 [mcp_servers.trail]"
  info "你的 Strata provider 區段原封不動（附加式寫入，非覆蓋）"
else
  warn "config.toml 沒有 [mcp_servers.trail] —— 重新執行本腳本並帶 --repo"
fi

if [ -n "$REPO" ] && [ -f "$REPO/AGENTS.md" ]; then
  pass "AGENTS.md 已寫入（Codex 每次開 session 都會讀）"
fi

if [ -f "$CODEX_DIR/hooks.json" ]; then
  warn "Codex 預設不執行別人寫的 hook —— 必須手動信任一次"
  info "開 Codex 後輸入：/hooks  →  找到 graft-hooks.cjs  → 信任"
  info "沒信任的話，hook 不會自動更新地圖（其他功能照常可用）"
fi

# ---------- 步驟 9：深度摘要（選用，接 GX10 Strata） ----------
step "步驟 9：深度摘要（--deep）"

find_api_key() {
  # 依序找：環境變數 → shell 設定檔
  if [ -n "${STRATA_API_KEY:-}" ]; then printf '%s' "$STRATA_API_KEY"; return 0; fi
  for f in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zshrc"; do
    [ -r "$f" ] || continue
    v="$(grep -oE 'STRATA_API_KEY="?[^"[:space:]]+"?' "$f" 2>/dev/null | tail -1 | sed 's/.*=//; s/^"//; s/"$//')"
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  return 1
}

if [ "$DO_DEEP" -ne 1 ]; then
  info "未加 --deep，略過（地圖本身不需要 LLM，照樣能用）"
elif [ -z "$REPO" ]; then
  warn "--deep 需要 --repo 指定專案"
else
  base="http://$GX10_HOST:$GX10_PORT"
  info "測試 GX10：$base/health"
  if curl -sS -m 8 -o /dev/null -w '%{http_code}' "$base/health" 2>/dev/null | grep -q '^200$'; then
    pass "GX10 Strata 可連線"
  else
    warn "連不上 $base/health —— 請確認 GX10 正在跑、且已 --expose"
    info "在 WSL 測試：curl -s $base/health"
    info "若 MagicDNS 抓不到，改用 Tailscale IP：--gx10-host 100.x.y.z"
  fi

  api_key="$(find_api_key)" || api_key=""
  if [ -z "$api_key" ]; then
    if [ -t 0 ]; then
      printf '  請輸入 Strata api_key（輸入時不顯示）：'
      read -rs api_key < /dev/tty
      printf '\n'
    fi
  fi
  if [ -z "$api_key" ]; then
    warn "沒有 api_key，略過 --deep"
    info "設定方式：export STRATA_API_KEY=...（寫進 ~/.bashrc 後重跑本腳本）"
  else
    export GRAFT_PROVIDER="openai"
    export GRAFT_BASE_URL="$base/v1"
    export GRAFT_API_KEY="$api_key"
    export GRAFT_MODEL="$GX10_MODEL"
    info "測試模型端點（$GRAFT_BASE_URL）"
    code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -X POST "$base/v1/chat/completions" \
      -H 'Content-Type: application/json' -H "Authorization: Bearer $api_key" \
      -d "{\"model\":\"$GX10_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" 2>/dev/null)"
    if [ "$code" = "200" ]; then
      pass "模型端點可呼叫"
      info "開始深度摘要（會跑一陣子，視專案大小）"
      ( cd "$REPO" && "$TRAIL_BIN" build --deep ) 2>&1 | tail -15
      pass "深度摘要完成"
    else
      warn "模型端點回 HTTP $code —— 金鑰或模型名可能不對"
      info "先測試：curl -s $base/v1/models -H \"Authorization: Bearer \$STRATA_API_KEY\""
    fi
  fi
fi

# ---------- 總結 ----------
step "總結"

if [ "$FAILURES" -eq 0 ]; then
  pass "全部完成"
else
  warn "有 $FAILURES 項需要留意（見上面 XX 標記）"
fi

cat <<'EOF'

下一步：
  1. 重開終端機（讓 PATH 生效），確認：
       trail --version
       codex --version
  2. 進你的專案，開 Codex：
       cd ~/你的專案
       codex
  3. 開 codex 後輸入 /hooks，把 graft-hooks.cjs 的項目信任掉
     （不信任的話，hook 不會自動更新地圖）
  4. 讓 agent 用地圖的方式（AGENTS.md 已寫好，也可以直接說）：
       「先跑 trail map，再 trail ask "<你的問題>" --source」
  5. VS Code Copilot 也會讀 .github/copilot-instructions.md，重新開一個
     Copilot Chat 視窗即可。
  6. 建議把這些檔案 commit 進 repo（ teammates 沒裝工具也能讀 learnings）：
       git add AGENTS.md .github .trail && git commit -m "chore: add trail context graph"
EOF
