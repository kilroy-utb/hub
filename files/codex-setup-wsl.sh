#!/usr/bin/env bash
# codex-setup-wsl.sh — WSL 環境檢查 + 自動安裝 Codex CLI +（選用）接上 GX10 Strata
#
# 用法：
#   bash codex-setup-wsl.sh                    # 檢查 + 修好環境 + 安裝 codex
#   bash codex-setup-wsl.sh --check            # 只檢查，不動任何東西
#   bash codex-setup-wsl.sh --with-config      # 順便寫 ~/.codex/config.toml（接 GX10）
#   bash codex-setup-wsl.sh --with-config --gx10-ip 100.x.y.z
#
# 設計原則：
#   - 不動 /usr/lib/node_modules，改用 ~/.local 前綴（避免 EACCES）
#   - 已經是 Node >= 16 就不碰 Node，Codex CLI 只需要 >=16
#   - 每一步都有明確的 PASS / FAIL 訊息，最後給總結

set -uo pipefail

# ---------- 小工具 ----------
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

# ---------- 參數 ----------
MODE="install"
WITH_CONFIG=0
GX10_IP=""
GX10_PORT="8080"
GX10_MODEL="qwen3.8-flash-next-iq3_s"

while [ $# -gt 0 ]; do
  case "$1" in
    --check)       MODE="check" ;;
    --with-config) WITH_CONFIG=1 ;;
    --gx10-ip)     GX10_IP="${2:-}"; shift ;;
    --gx10-port)   GX10_PORT="${2:-}"; shift ;;
    --model)       GX10_MODEL="${2:-}"; shift ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "不认识的參數：$1"; exit 2 ;;
  esac
  shift
done

printf '%s\n' "==============================================="
printf '  WSL × Codex CLI 環境檢查與安裝\n'
printf '  腳本版本：2026-11-10.1\n'
printf '==============================================='

# ---------- 安全護欄 ----------
# Codex 對話 session 的 home（.codex-home）絕不能被污染
case "$HOME" in
  *".codex-home"*)
    printf '%s\n' "[XX] 偵測到 HOME 位於 Codex session 目錄，為安全起見中止。"
    printf '%s\n' "     请在一般用户家目录（/home/<user>）执行本脚本。"
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
  x86_64)  pass "架構：x86_64（Codex CLI 有 linux-x64 官方套件）" ;;
  aarch64) pass "架構：aarch64（Codex CLI 有 linux-arm64 官方套件）" ;;
  *)       warn "架構：$arch（官方套件可能沒有對應版本）" ;;
esac

if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
  pass "確認運行於 WSL"
else
  warn "不像是 WSL 環境（/proc/version 沒看到 microsoft），後續指令仍可執行"
fi

# 記憶體
mem_gb="$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')"
if [ -n "${mem_gb:-}" ]; then
  info "WSL 可見記憶體：${mem_gb} GiB"
fi

# 有沒有 WSL 通往 Windows 的通道（後面要給 Windows 端設定參考用）
if command -v powershell.exe >/dev/null 2>&1; then
  pass "可呼叫 powershell.exe（WSL ↔ Windows 互通 OK）"
else
  info "找不到 powershell.exe（純 Linux 環境或未啟用 interop）"
fi

# ---------- 步驟 2：Node / npm ----------
step "步驟 2：Node.js 與 npm"

need_node_install=0
if command -v node >/dev/null 2>&1; then
  node_ver="$(node --version)"
  node_major="$(printf '%s' "$node_ver" | sed 's/^v//' | cut -d. -f1)"
  info "node：$node_ver（路徑 $(command -v node)）"
  if [ "$node_major" -ge 16 ] 2>/dev/null; then
    pass "Node 版本 $node_ver ≥ 16，Codex CLI 可直接安裝"
  else
    fail "Node 版本 $node_ver < 16，Codex CLI 官方要求 >=16"
    need_node_install=1
  fi
else
  fail "找不到 node"
  need_node_install=1
fi

if command -v npm >/dev/null 2>&1; then
  pass "npm：$(npm --version)"
else
  fail "找不到 npm"
  need_node_install=1
fi

# npm 全域前綴
npm_prefix="$(npm config get prefix 2>/dev/null || echo "未知")"
info "npm 全域前綴：$npm_prefix"
case "$npm_prefix" in
  "$HOME"/*) pass "前綴在 home 底下，不會撞 EACCES" ;;
  /usr/lib*|/usr/local/lib*|/usr/local/share*)
    warn "前綴在系統目錄，全域安裝會需要 root 權限" ;;
  *) info "前綴位置中性" ;;
esac

# PATH 是否含前綴 bin（此時先看原本的前綴，步驟 4 改完會重算）
current_prefix_bin="${npm_prefix%/}/bin"
if printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$current_prefix_bin"; then
  pass "PATH 已包含 $current_prefix_bin"
else
  warn "PATH 尚未包含 $current_prefix_bin（安裝後 codex 會找不到）"
fi

# node 缺或多版本
if command -v node >/dev/null 2>&1; then
  node_paths="$(which -a node 2>/dev/null | while read -r n; do readlink -f "$n" 2>/dev/null || echo "$n"; done | sort -u | tr '\n' ' ')"
  count_paths="$(printf '%s' "$node_paths" | wc -w)"
  if [ "$count_paths" -gt 1 ]; then
    warn "發現多個 node：$node_paths（PATH 順序決定實際使用哪個）"
  else
    pass "只有單一 node，沒有版本打架"
  fi
fi

# ---------- 步驟 3：WSL → GX10 連線 ----------
step "步驟 3：WSL → GX10 連線檢查"

gx10_reachable=0
if [ -n "$GX10_IP" ]; then
  info "測試 $GX10_IP:$GX10_PORT/health"
  if curl -s -m 8 "http://$GX10_IP:$GX10_PORT/health" >/dev/null 2>&1; then
    pass "GX10 可連線（用 IP，不需要 DNS）"
    gx10_reachable=1
  else
    fail "連不到 $GX10_IP:$GX10_PORT"
    info "先在 Windows 端確認 Tailscale 連線，再用 ping 測試"
  fi
else
  warn "未提供 --gx10-ip，跳過連線測試"
  info "取得方式（GX10 上執行）：tailscale ip -4"
fi

# ---------- 步驟 4：動作（check 模式到此結束） ----------
if [ "$MODE" = "check" ]; then
  step "總結（檢查模式，未變更任何檔案）"
  if [ "$FAILURES" -eq 0 ]; then
    pass "環境檢查通過，可以執行安裝"
  else
    fail "有 $FAILURES 項需要處理"
  fi
  exit 0
fi

step "步驟 4：修正環境"

if [ "$need_node_install" -eq 1 ]; then
  warn "需要安裝 Node.js 22（NodeSource）"
  if command -v sudo >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y curl ca-certificates
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
    pass "Node.js 安裝完成：$(node --version)"
  else
    fail "沒有 sudo，無法用 apt 安裝；請改用 nvm"
  fi
fi

mkdir -p "$HOME/.local"
npm config set prefix "$HOME/.local" >/dev/null 2>&1
npm_prefix="$(npm config get prefix 2>/dev/null || echo "$HOME/.local")"
prefix_bin="${npm_prefix%/}/bin"
pass "npm 前綴設為 $npm_prefix"

if ! grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.bashrc"
  pass "已寫入 ~/.bashrc"
else
  pass "~/.bashrc 已有 PATH 設定"
fi
export PATH="$prefix_bin:$PATH"

if printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$prefix_bin"; then
  pass "PATH 已指向 $prefix_bin"
else
  fail "PATH 沒指向 $prefix_bin"
fi

# ---------- 步驟 5：安裝 Codex CLI ----------
step "步驟 5：安裝 Codex CLI"

# 以「家目錄裡的那份」為準，避免誤認到系統其他位置的舊版
prefix_bin="${npm_prefix%/}/bin"
CODEX_BIN="$prefix_bin/codex"

# npm 會在 $prefix_bin 建 symlink。若那裡已經有檔案（官方 standalone 腳本裝的
# 執行檔、或前一次殘留），npm 會報 EEXIST 而中止 —— 先移到旁邊保留，不刪除。
if [ -e "$CODEX_BIN" ] || [ -L "$CODEX_BIN" ]; then
  if [ -L "$CODEX_BIN" ] && readlink "$CODEX_BIN" | grep -q "node_modules/@openai/codex"; then
    info "家目錄已有（npm 管理）：$("$CODEX_BIN" --version 2>&1 | head -1)"
  else
    old_ver="(無法執行)"
    [ -x "$CODEX_BIN" ] && old_ver="$("$CODEX_BIN" --version 2>&1 | head -1)"
    stash="$CODEX_BIN.pre-npm-$(date +%Y%m%d-%H%M%S)"
    mv -f "$CODEX_BIN" "$stash" && pass "既有檔案已移到 $(basename "$stash")（$old_ver）"
    info "保留著，需要時可以 mv 回來"
  fi
elif command -v codex >/dev/null 2>&1; then
  info "其他位置已有：$(command -v codex)（將改安裝到家目錄）"
fi

if npm install -g @openai/codex --registry=https://registry.npmjs.org/ 2>&1 | tail -5; then
  pass "npm 安裝完成"
else
  fail "npm 安裝失敗，試試鏡像站："
  info "npm install -g @openai/codex --registry=https://registry.npmmirror.com/"
fi

hash -r 2>/dev/null || true

if [ -x "$CODEX_BIN" ]; then
  pass "codex 版本：$("$CODEX_BIN" --version 2>&1 | head -1)"
  pass "codex 路徑：$CODEX_BIN"
  pass "PATH 已優先指向家目錄版本"
else
  fail "找不到 $CODEX_BIN"
  info "重開終端機讓 ~/.bashrc 生效後再試：codex --version"
fi

# ---------- 步驟 6：寫 Codex 設定（選用） ----------
if [ "$WITH_CONFIG" -eq 1 ]; then
  step "步驟 6：寫入 ~/.codex/config.toml"

  if [ -z "$GX10_IP" ]; then
    fail "需要 --gx10-ip 100.x.y.z 才能寫設定"
  else
    mkdir -p "$HOME/.codex"
    cfg="$HOME/.codex/config.toml"
    if [ -f "$cfg" ]; then
      cp "$cfg" "$cfg.bak-$(date +%Y%m%d-%H%M%S)"
      pass "已備份原設定"
    fi

    cat > "$cfg" <<EOF
# 由 codex-setup-wsl.sh 產生
model = "$GX10_MODEL"
model_provider = "strata"
model_context_window = 262144
model_auto_compact_token_limit = 200000

[model_providers.strata]
name = "Strata GX10"
base_url = "http://$GX10_IP:$GX10_PORT/v1"
wire_api = "responses"
env_key = "STRATA_API_KEY"
EOF
    pass "已寫入 $cfg"
    info "金鑰設定（不要貼到聊天裡）："
    info "export STRATA_API_KEY=\"sk-...\""
    info "並加到 ~/.bashrc 讓每次開啟都生效"
  fi
fi

# ---------- 總結 ----------
step "總結"

# 沒寫設定檔就要大聲講，否則 codex 會默默走預設的 OpenAI provider
if [ ! -f "$HOME/.codex/config.toml" ]; then
  warn "還沒有 ~/.codex/config.toml —— codex 會走預設 OpenAI provider，呼叫 api.openai.com 必然 401"
  info "請執行：bash $(basename "$0") --with-config --gx10-ip 100.x.y.z"
  info "（100.x.y.z 是 GX10 的 Tailscale IP，在 GX10 上跑 tailscale ip -4 取得）"
  FAILURES=$((FAILURES + 1))
fi
if [ "$FAILURES" -eq 0 ]; then
  pass "全部完成"
else
  warn "有 $FAILURES 項需要留意（見上面 XX 標記）"
fi

cat <<'EOF'

下一步：
  1. 設定金鑰
       export STRATA_API_KEY="sk-你的金鑰"
       echo 'export STRATA_API_KEY="sk-你的金鑰"' >> ~/.bashrc
  2. 測試
       codex "用繁體中文回一句話，確認連線正常"
  3. 進專案開工
       cd ~/你的專案 && codex
EOF
