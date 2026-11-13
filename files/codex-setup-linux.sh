#!/usr/bin/env bash
# =============================================================================
# codex-setup-linux.sh — 一般 Linux 環境檢查 + 補齊套件 + 安裝 Codex CLI
#
# 用法：
#   bash codex-setup-linux.sh              # 完整流程（檢查 → 補套件 → 裝 codex）
#   bash codex-setup-linux.sh --check      # 只檢查，不動任何東西
#   bash codex-setup-linux.sh --dry-run    # 顯示會做什麼，但不真的安裝
#   bash codex-setup-linux.sh --log-file /tmp/x.log
#   bash codex-setup-linux.sh --upgrade         # 強制升級到最新版
#   bash codex-setup-linux.sh --with-config --provider openai
#
# 設計原則：
#   - 冪等：已經有的東西不重裝
#   - 不寫死 distro，自動偵測 apt / dnf / yum / apk / zypper / pacman
#   - 沒有 root 也能跑：Node.js 走 ~/.local 的 tarball 安裝
#   - 全程 log：每個指令、每個輸出都寫進 log 檔
#
# 腳本版本：2026-11-13.1
# =============================================================================

set -uo pipefail

# ────────────────────────────── 全域設定 ──────────────────────────────
SCRIPT_VERSION="2026-11-13.1"
SCRIPT_NAME="$(basename "$0")"
MIN_NODE_MAJOR=16          # Codex CLI 官方最低需求
RECOMMEND_NODE_MAJOR=18    # 建議版本，低於此會額外提示
NODE_INSTALL_VERSION="22"  # 缺 Node 時裝的 LTS 大版本

MODE="install"              # install | check | dry-run
WITH_CONFIG=0
UPGRADE=0
PROVIDER="openai"
LOG_FILE="${LOG_FILE:-$HOME/codex-setup-linux.log}"
FAILURES=0
WARNINGS=0
PKG_MANAGER=""
MISSING_PKGS=()

# ────────────────────────────── 顏色 ──────────────────────────────
GREEN=""; RED=""; YELLOW=""; BLUE=""; CYAN=""; RESET=""
if [ -t 1 ]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
fi

# ────────────────────────────── Logging ──────────────────────────────
# 所有訊息同時寫到終端機 + log 檔；log 檔不含 ANSI 色碼。
init_log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  {
    printf '\n============================================================\n'
    printf ' 會話開始：%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf ' 腳本：%s（版本 %s）\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf ' 模式：%s\n' "$MODE"
    printf ' 主機：%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf ' 使用者：%s（uid=%s）\n' "${USER:-$(id -un)}" "$(id -u)"
    printf '============================================================\n'
  } >> "$LOG_FILE" 2>/dev/null || true
}

_log() {
  local level="$1"; shift
  local color="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] %-5s %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
  if [ -t 1 ]; then
    printf '  %s[%-5s]%s %s\n' "$color" "$level" "$RESET" "$msg"
  else
    printf '  [%-5s] %s\n' "$level" "$msg"
  fi
}

pass() { _log "PASS" "$GREEN" "$@"; }
warn() { _log "WARN" "$YELLOW" "$@"; WARNINGS=$((WARNINGS + 1)); }
fail() { _log "FAIL" "$RED" "$@"; FAILURES=$((FAILURES + 1)); }
info() { _log "INFO" "$BLUE" "$@"; }
note() { _log "NOTE" "$CYAN" "$@"; }

step() {
  local title="$1"
  printf '\n[%s] ===== %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$title" >> "$LOG_FILE" 2>/dev/null || true
  if [ -t 1 ]; then
    printf '\n%s╭─ %s %s\n' "$BLUE" "$title" "$RESET"
  else
    printf '\n=== %s ===\n' "$title"
  fi
}

# 執行外部指令：指令與完整輸出都進 log，並在終端機顯示
run_cmd() {
  local rc=0
  {
    printf '\n[%s] $ %s\n' "$(date '+%H:%M:%S')" "$*"
  } >> "$LOG_FILE" 2>/dev/null || true
  if [ -t 1 ]; then
    printf '  %s$%s %s\n' "$BLUE" "$RESET" "$*"
  else
    printf '  $ %s\n' "$*"
  fi
  "$@" 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
    printf '      %s\n' "$line"
    printf '      %s\n' "$line" >> "$LOG_FILE"
  done
  rc=${PIPESTATUS[0]}
  return $rc
}

# 把一段 shell 字串當指令跑（用於管線，例如 curl | bash）
run_shell() {
  local code="$1"
  local rc=0
  {
    printf '\n[%s] $ %s\n' "$(date '+%H:%M:%S')" "$code"
  } >> "$LOG_FILE" 2>/dev/null || true
  if [ -t 1 ]; then
    printf '  %s$%s %s\n' "$BLUE" "$RESET" "$code"
  else
    printf '  $ %s\n' "$code"
  fi
  bash -c "$code" 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
    printf '      %s\n' "$line"
    printf '      %s\n' "$line" >> "$LOG_FILE"
  done
  rc=${PIPESTATUS[0]}
  return $rc
}

# ────────────────────────────── 參數 ──────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --check)       MODE="check" ;;
    --dry-run)     MODE="dry-run" ;;
    --with-config) WITH_CONFIG=1 ;;
    --upgrade)     UPGRADE=1 ;;
    --provider)    PROVIDER="${2:-openai}"; shift ;;
    --log-file)    LOG_FILE="${2:-$LOG_FILE}"; shift ;;
    -h|--help)
      sed -n '2,24p' "$0"
      exit 0
      ;;
    *) echo "不認識的參數：$1" >&2; exit 2 ;;
  esac
  shift
done

init_log

if [ -t 1 ]; then
  printf '%s\n' "${BLUE}============================================================${RESET}"
  printf '  %sCodex CLI — Linux 安裝腳本%s\n' "$CYAN" "$RESET"
  printf '  版本 %s ｜ 模式 %s ｜ log：%s\n' "$SCRIPT_VERSION" "$MODE" "$LOG_FILE"
  printf '%s\n' "${BLUE}============================================================${RESET}"
fi
info "腳本啟動，完整 log：$LOG_FILE"

# ────────────────────────────── 安全護欄 ──────────────────────────────
# Codex session 的 home 絕不能被污染
case "$HOME" in
  *".codex-home"*)
    fail "HOME 位於 Codex session 目錄（$HOME），為安全起見中止"
    info "請在一般使用者家目錄（例：/home/<user>）執行本腳本"
    exit 1
    ;;
esac

# ────────────────────────────── 步驟 1：系統環境 ──────────────────────────────
step "步驟 1：系統環境盤點"

if [ -r /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_NAME="${PRETTY_NAME:-$NAME}"
else
  OS_ID="unknown"; OS_NAME="未知"
fi
pass "作業系統：$OS_NAME（ID=$OS_ID）"

KERNEL="$(uname -r)"
ARCH="$(uname -m)"
pass "核心版本：$KERNEL"

case "$ARCH" in
  x86_64|amd64)
    pass "CPU 架構：x86_64（對應 linux-x64 套件）"
    NODE_ARCH="x64" ;;
  aarch64|arm64)
    pass "CPU 架構：aarch64（對應 linux-arm64 套件）"
    NODE_ARCH="arm64" ;;
  *)
    fail "CPU 架構：$ARCH 不在官方支援範圍（x86_64 / aarch64）"
    NODE_ARCH="" ;;
esac

if [ -r /etc/os-release ] && grep -qiE 'WSL|microsoft' /etc/os-release 2>/dev/null; then
  warn "偵測到 WSL —— 若你是要接 GX10 Strata，請改用 codex-setup-wsl.sh"
fi

MEM_GB="$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')"
[ -n "${MEM_GB:-}" ] && info "記憶體：${MEM_GB} GiB"
DISK_FREE_GB="$(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9')"
[ -n "${DISK_FREE_GB:-}" ] && info "家目錄可用空間：約 ${DISK_FREE_GB} GiB"

if [ "$(id -u)" -eq 0 ]; then
  pass "目前身分：root（可直接安裝系統套件）"
  SUDO=""; HAVE_PRIV=1
elif command -v sudo >/dev/null 2>&1; then
  pass "目前身分：一般使用者（可用 sudo 提升權限）"
  SUDO="sudo"; HAVE_PRIV=1
else
  warn "目前身分：一般使用者，且沒有 sudo —— 系統套件將跳過（改用使用者層級安裝）"
  SUDO=""; HAVE_PRIV=0
fi

# ────────────────────────────── 步驟 2：套件管理器 ──────────────────────────────
step "步驟 2：偵測套件管理器"

detect_pkg_manager() {
  for c in apt-get dnf yum apk zypper pacman; do
    if command -v "$c" >/dev/null 2>&1; then
      case "$c" in
        apt-get)   PKG_MANAGER="apt-get";   PKG_INSTALL="apt-get install -y";  PKG_UPDATE="apt-get update" ;;
        dnf)       PKG_MANAGER="dnf";       PKG_INSTALL="dnf install -y";       PKG_UPDATE="dnf makecache" ;;
        yum)       PKG_MANAGER="yum";       PKG_INSTALL="yum install -y";       PKG_UPDATE="yum makecache" ;;
        apk)       PKG_MANAGER="apk";       PKG_INSTALL="apk add";             PKG_UPDATE="apk update" ;;
        zypper)    PKG_MANAGER="zypper";    PKG_INSTALL="zypper install -y";    PKG_UPDATE="zypper refresh" ;;
        pacman)    PKG_MANAGER="pacman";    PKG_INSTALL="pacman -S --noconfirm"; PKG_UPDATE="pacman -Sy --noconfirm" ;;
      esac
      return 0
    fi
  done
  return 1
}

if detect_pkg_manager; then
  pass "套件管理器：$PKG_MANAGER"
  if [ "$(id -u)" -eq 0 ]; then
    info "以 root 身分執行，系統套件可直接安裝"
  elif [ -n "$SUDO" ]; then
    info "安裝系統套件會自動加上 sudo 提權"
  else
    warn "沒有提權能力，系統套件安裝會被跳過"
  fi
else
  warn "找不到支援的套件管理器（apt-get/dnf/yum/apk/zypper/pacman）"
  info "將改用 Node.js 官方 tarball 安裝到 ~/.local（不需要 root）"
  PKG_MANAGER=""
fi

# ────────────────────────────── 步驟 3：檢查必要套件 ──────────────────────────────
step "步驟 3：檢查必要套件"

# 套件名在各族管理器不同，用「命令存在」判定最準
declare -A PKG_MAP=(
  [curl]="curl"
  [ca-certificates]="ca-certificates"
  [tar]="tar"
  [gzip]="gzip"
  [git]="git"
  [xz]="xz"
)

check_required_tools() {
  local tool pkg
  for tool in curl tar gzip; do
    if command -v "$tool" >/dev/null 2>&1; then
      pass "必要工具已存在：$tool"
    else
      fail "缺少必要工具：$tool"
      MISSING_PKGS+=("${PKG_MAP[$tool]}")
    fi
  done

  # ca-certificates：用檔案判斷（部分系統沒有獨立指令）
  if [ -e /etc/ssl/certs/ca-certificates.crt ] || [ -e /etc/pki/tls/certs/ca-bundle.crt ] \
     || command -v update-ca-certificates >/dev/null 2>&1; then
    pass "必要工具已存在：ca-certificates"
  else
    fail "缺少必要工具：ca-certificates（HTTPS 會失敗）"
    MISSING_PKGS+=("ca-certificates")
  fi

  if command -v git >/dev/null 2>&1; then
    pass "選用工具已存在：git（$(git --version 2>/dev/null | awk '{print $3}')）"
  else
    warn "缺少選用工具：git（不影響安裝，但建議裝上）"
    MISSING_PKGS+=("git")
  fi

  if command -v xz >/dev/null 2>&1; then
    pass "選用工具已存在：xz（解壓 Node.js tar.xz 用）"
  else
    warn "缺少選用工具：xz（改用 tar.gz 也能裝 Node.js）"
  fi
}

check_required_tools

# 去重
if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
  UNIQUE_MISSING="$(printf '%s\n' "${MISSING_PKGS[@]}" | sort -u | tr '\n' ' ')"
  note "缺少的套件清單：$UNIQUE_MISSING"
else
  pass "所有必要套件都齊全"
fi

# ────────────────────────────── 步驟 4：安裝缺少的套件 ──────────────────────────────
step "步驟 4：安裝缺少的系統套件"

install_missing_packages() {
  if [ "${#MISSING_PKGS[@]}" -eq 0 ]; then
    pass "沒有需要安裝的系統套件"
    return 0
  fi

  if [ -z "$PKG_MANAGER" ]; then
    warn "沒有套件管理器，無法安裝：$UNIQUE_MISSING"
    info "請手動安裝後重新執行本腳本"
    return 1
  fi

  if [ "${HAVE_PRIV:-0}" -ne 1 ]; then
    warn "沒有 root/sudo 權限，略過系統套件安裝：$UNIQUE_MISSING"
    info "如果 curl/tar 也不存在，Node.js 與 Codex CLI 都會安裝失敗"
    return 1
  fi

  if [ "$MODE" = "dry-run" ]; then
    info "[dry-run] 將執行：$SUDO $PKG_UPDATE"
    info "[dry-run] 將執行：$SUDO $PKG_INSTALL $UNIQUE_MISSING"
    return 0
  fi

  if [ "$MODE" = "check" ]; then
    info "[check] 略過實際安裝"
    return 1
  fi

  info "更新套件索引……"
  run_cmd $SUDO $PKG_UPDATE || warn "更新索引失敗（可能沒網路或需要 sudo 密碼），仍嘗試安裝"

  info "安裝：$UNIQUE_MISSING"
  # shellcheck disable=SC2086
  if run_cmd $SUDO $PKG_INSTALL $UNIQUE_MISSING; then
    pass "系統套件安裝完成"
    return 0
  fi
  fail "系統套件安裝失敗"
  return 1
}

install_missing_packages

# ────────────────────────────── 步驟 5：Node.js / npm ──────────────────────────────
step "步驟 5：檢查 Node.js 與 npm"

node_major() {
  command -v node >/dev/null 2>&1 || { echo ""; return; }
  node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1
}

install_node_from_tarball() {
  # Node.js 官方 tarball —— 不需要 root，安裝到 ~/.local
  local ver url home_dir
  home_dir="$HOME/.local/lib/nodejs"

  if [ -z "$NODE_ARCH" ]; then
    fail "無法判定 CPU 架構，略過 tarball 安裝"
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    fail "缺少 curl 或 tar，無法用 tarball 安裝 Node.js"
    return 1
  fi

  info "從 nodejs.org 查最新 LTS 版本……"
  local index_json ver
  index_json="$(curl -fsSL --max-time 30 https://nodejs.org/dist/index.json 2>/dev/null)"
  ver="$(printf '%s' "$index_json" | tr '{' '\n' | grep -m1 '"lts":"' \
         | grep -o '"version":"v[^"]*"' | cut -d'"' -f4)"
  if [ -z "$ver" ]; then
    ver="v${NODE_INSTALL_VERSION}.0.0"
    warn "查不到最新 LTS，改用預設版本 $ver"
  fi
  pass "目標版本：$ver"

  local fname
  if command -v xz >/dev/null 2>&1; then
    fname="node-${ver}-linux-${NODE_ARCH}.tar.xz"
    url="https://nodejs.org/dist/${ver}/${fname}"
    info "下載：$url"
    if [ "$MODE" = "dry-run" ]; then echo "[dry-run] 下載 $url"; return 0; fi
    if ! run_cmd curl -fsSL --max-time 300 -o "/tmp/$fname" "$url"; then
      fail "下載失敗：$url"
      return 1
    fi
    run_cmd tar -xJf "/tmp/$fname" -C /tmp || { fail "解壓失敗"; return 1; }
  else
    fname="node-${ver}-linux-${NODE_ARCH}.tar.gz"
    url="https://nodejs.org/dist/${ver}/${fname}"
    info "下載：$url"
    if [ "$MODE" = "dry-run" ]; then echo "[dry-run] 下載 $url"; return 0; fi
    if ! run_cmd curl -fsSL --max-time 300 -o "/tmp/$fname" "$url"; then
      fail "下載失敗：$url"
      return 1
    fi
    run_cmd tar -xzf "/tmp/$fname" -C /tmp || { fail "解壓失敗"; return 1; }
  fi

  local src="/tmp/node-${ver}-linux-${NODE_ARCH}"
  [ -d "$src" ] || { fail "解壓後找不到 $src"; return 1; }

  mkdir -p "$home_dir"
  # 只清理本腳本自己建的版本目錄，且必須在家目錄底下
  target_dir="$home_dir/$ver"
  case "$target_dir" in
    "$HOME"/.local/lib/nodejs/*)
      if [ -e "$target_dir" ]; then
        mv -f "$target_dir" "${target_dir}.old-$(date +%Y%m%d-%H%M%S)" 2>/dev/null           || rm -rf -- "$target_dir"
      fi
      ;;
  esac
  if ! run_cmd cp -a "$src" "$home_dir/$ver"; then
    fail "安裝到 $home_dir 失敗"
    return 1
  fi

  mkdir -p "$HOME/.local/bin"
  ln -sf "$home_dir/$ver/bin/node" "$HOME/.local/bin/node"
  ln -sf "$home_dir/$ver/bin/npm"  "$HOME/.local/bin/npm"
  ln -sf "$home_dir/$ver/bin/npx"  "$HOME/.local/bin/npx"
  pass "Node.js $ver 已安裝到 $home_dir/$ver"
  export PATH="$HOME/.local/bin:$PATH"
  hash -r 2>/dev/null || true
  return 0
}

install_node_from_nodesource() {
  # NodeSource —— 適合需要新版 Node 的 Debian/RHEL 家族
  local setup_url
  case "$OS_ID" in
    debian|ubuntu|linuxmint|pop)
      setup_url="https://deb.nodesource.com/setup_${NODE_INSTALL_VERSION}.x" ;;
    fedora|rhel|centos|rocky|alma|ol)
      setup_url="https://rpm.nodesource.com/setup_${NODE_INSTALL_VERSION}.x" ;;
    *)
      return 1 ;;
  esac

  if [ "${HAVE_PRIV:-0}" -ne 1 ]; then
    info "沒有提權權限，改用 tarball 安裝"
    install_node_from_tarball
    return $?
  fi

  info "使用 NodeSource 安裝 Node.js ${NODE_INSTALL_VERSION}.x"
  if [ "$MODE" = "dry-run" ]; then
    echo "[dry-run] curl -fsSL $setup_url | bash -"
    return 0
  fi
  if [ "$MODE" = "check" ]; then
    info "[check] 略過實際安裝"
    return 1
  fi

  if run_shell "curl -fsSL $setup_url | bash -"; then
    pass "NodeSource 安裝腳本執行完成"
    run_cmd $SUDO $PKG_INSTALL nodejs || warn "安裝 nodejs 套件時有警告"
    return 0
  fi
  fail "NodeSource 安裝失敗"
  return 1
}

CURRENT_NODE_MAJOR="$(node_major)"

if command -v node >/dev/null 2>&1; then
  pass "node：$(node --version)（路徑 $(command -v node)）"
  if [ -n "$CURRENT_NODE_MAJOR" ] && [ "$CURRENT_NODE_MAJOR" -ge "$MIN_NODE_MAJOR" ] 2>/dev/null; then
    pass "Node 版本 ≥ $MIN_NODE_MAJOR，Codex CLI 可直接安裝"
    if [ "$CURRENT_NODE_MAJOR" -lt "$RECOMMEND_NODE_MAJOR" ] 2>/dev/null; then
      warn "Node 版本低於建議的 $RECOMMEND_NODE_MAJOR，功能可能受限"
    fi
  else
    fail "Node 版本 $CURRENT_NODE_MAJOR < $MIN_NODE_MAJOR（Codex CLI 官方要求）"
    if [ "$MODE" = "install" ]; then
      install_node_from_nodesource || install_node_from_tarball
      hash -r 2>/dev/null || true
      CURRENT_NODE_MAJOR="$(node_major)"
    fi
  fi
else
  fail "找不到 node"
  if [ "$MODE" = "install" ]; then
    # 先試套件管理器（若 OS 套件版本夠新），再試 tarball
    if [ -n "$PKG_MANAGER" ] && [ "${HAVE_PRIV:-0}" -eq 1 ]; then
      info "嘗試從 $PKG_MANAGER 安裝 nodejs/npm……"
      run_cmd $SUDO $PKG_INSTALL nodejs npm || true
      hash -r 2>/dev/null || true
    fi
    if ! command -v node >/dev/null 2>&1; then
      install_node_from_tarball
      hash -r 2>/dev/null || true
    fi
    CURRENT_NODE_MAJOR="$(node_major)"
  fi
fi

# npm
if command -v npm >/dev/null 2>&1; then
  pass "npm：$(npm --version)"
else
  fail "找不到 npm"
  if [ "$MODE" = "install" ] && [ -n "$PKG_MANAGER" ] && [ "${HAVE_PRIV:-0}" -eq 1 ]; then
    info "嘗試安裝 npm……"
    run_cmd $SUDO $PKG_INSTALL npm || true
    hash -r 2>/dev/null || true
  fi
  if command -v npm >/dev/null 2>&1; then
    pass "npm 補裝完成：$(npm --version)"
  else
    fail "npm 仍然找不到，Codex CLI 無法安裝"
  fi
fi

# ────────────────────────────── 步驟 6：npm 前綴 ──────────────────────────────
step "步驟 6：修正 npm 全域前綴"

ORIG_PATH="$PATH"
NPM_PREFIX=""

if command -v npm >/dev/null 2>&1; then
  NPM_PREFIX="$(npm config get prefix 2>/dev/null || echo "")"
  info "目前 npm 全域前綴：$NPM_PREFIX"

  case "$NPM_PREFIX" in
    "$HOME"/*)
      pass "前綴在 home 底下，不會撞 EACCES" ;;
    /usr/lib*|/usr/local/lib*|/usr/local/share*|/usr/*)
      warn "前綴在系統目錄，全域安裝需要 root —— 將改用 \$HOME/.local"
      if [ "$MODE" = "install" ]; then
        run_cmd npm config set prefix "$HOME/.local" || warn "設定 prefix 失敗"
        NPM_PREFIX="$(npm config get prefix 2>/dev/null || echo "$HOME/.local")"
        pass "npm 全域前綴已改為 $NPM_PREFIX"
      fi ;;
    *)
      info "前綴位置中性" ;;
  esac

  PREFIX_BIN="${NPM_PREFIX%/}/bin"
  if printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$PREFIX_BIN"; then
    pass "PATH 已包含 $PREFIX_BIN"
  else
    warn "PATH 沒有包含 $PREFIX_BIN"
    if [ "$MODE" = "install" ]; then
      BASHRC="$HOME/.bashrc"
      touch "$BASHRC"
      # 先清掉舊的同類匯出（註解掉的也算），再統一寫到檔案最後
      sed -i -E \
        -e '/^[[:space:]]*export[[:space:]]+PATH=.*\.local\/bin/d' \
        -e '/^#[[:space:]]*(>>>|<<<)[[:space:]]*codex-cli PATH/d' \
        "$BASHRC"
      printf '\n# >>> codex-cli PATH >>>\nexport PATH="$HOME/.local/bin:$PATH"\n# <<< codex-cli PATH <<<\n' >> "$BASHRC"
      pass "已在 ~/.bashrc 最後寫入 .local/bin 的 PATH 匯出"
      export PATH="$PREFIX_BIN:$PATH"
    fi
  fi
fi

# ────────────────────────────── 步驟 7：安裝 Codex CLI ──────────────────────────────
step "步驟 7：安裝 Codex CLI"

CODEX_BIN=""
if [ -n "$NPM_PREFIX" ]; then
  CODEX_BIN="${NPM_PREFIX%/}/bin/codex"
fi

# 已存在就跳過（冪等）
if [ -n "$CODEX_BIN" ] && [ -x "$CODEX_BIN" ] && [ "$UPGRADE" -ne 1 ]; then
  existing_ver="$("$CODEX_BIN" --version 2>&1 | head -1)"
  pass "已安裝：$existing_ver（$CODEX_BIN）"
  # 順便比對 npm registry 上的最新版（需要網路，失敗不影響流程）
  if command -v npm >/dev/null 2>&1; then
    latest_ver="$(npm view @openai/codex version 2>/dev/null | tail -1)"
    cur_num="$(printf '%s' "$existing_ver" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ -n "$latest_ver" ] && [ -n "$cur_num" ]; then
      if [ "$latest_ver" != "$cur_num" ]; then
        warn "registry 最新版是 $latest_ver，目前是 $cur_num"
        info "要升級請執行：bash $SCRIPT_NAME --upgrade"
      else
        pass "已是最新版本（$cur_num）"
      fi
    fi
  fi
elif [ "$MODE" = "check" ]; then
  fail "尚未安裝 Codex CLI（$CODEX_BIN 不存在）"
else
  if command -v codex >/dev/null 2>&1; then
    info "其他位置已有 codex：$(command -v codex) —— 仍會裝一份到家目錄前綴下"
  fi
  if [ "$MODE" = "dry-run" ]; then
    info "[dry-run] 將執行：npm install -g @openai/codex"
  elif ! command -v npm >/dev/null 2>&1; then
    fail "沒有 npm，無法安裝 Codex CLI"
  else
    # npm 會在 prefix/bin 建 symlink；若已有殘留檔會報 EEXIST —— 先移到旁邊保留
    if [ -n "$CODEX_BIN" ] && { [ -e "$CODEX_BIN" ] || [ -L "$CODEX_BIN" ]; }; then
      stash="${CODEX_BIN}.pre-npm-$(date +%Y%m%d-%H%M%S)"
      mv -f "$CODEX_BIN" "$stash" 2>/dev/null && pass "既有檔案已移到 $(basename "$stash")"
    fi

    if [ "$UPGRADE" -eq 1 ]; then
      info "升級 @openai/codex 到最新版……"
      PKG_SPEC="@openai/codex@latest"
    else
      info "安裝 @openai/codex（最新版）……"
      PKG_SPEC="@openai/codex"
    fi
    if run_cmd npm install -g "$PKG_SPEC" --registry=https://registry.npmjs.org/; then
      pass "npm 安裝完成"
    else
      warn "官方 registry 安裝失敗，改用 npmmirror 鏡像"
      if run_cmd npm install -g "$PKG_SPEC" --registry=https://registry.npmmirror.com/; then
        pass "鏡像安裝完成"
      else
        fail "Codex CLI 安裝失敗（兩個 registry 都試過）"
      fi
    fi
    hash -r 2>/dev/null || true
  fi
fi

# ────────────────────────────── 步驟 8：驗證 ──────────────────────────────
step "步驟 8：驗證安裝"

CODEX_FOUND=""
if [ -n "$CODEX_BIN" ] && [ -x "$CODEX_BIN" ]; then
  CODEX_FOUND="$CODEX_BIN"
elif command -v codex >/dev/null 2>&1; then
  CODEX_FOUND="$(command -v codex)"
fi

if [ -n "$CODEX_FOUND" ]; then
  pass "codex 版本：$("$CODEX_FOUND" --version 2>&1 | head -1)"
  pass "codex 路徑：$CODEX_FOUND"
  # 用「原本的 PATH」判斷，腳本自己 export 的不算數
  if printf '%s' "$ORIG_PATH" | tr ':' '\n' | grep -qx "${NPM_PREFIX%/}/bin"; then
    pass "目前終端機的 PATH 已指向家目錄版本"
  else
    warn "目前這個終端機還看不到 codex（腳本的 export 只對自己有效）"
    note "貼上這行即可：export PATH=\"$HOME/.local/bin:\$PATH\""
  fi
else
  fail "驗證失敗：找不到 codex 執行檔"
fi

# ────────────────────────────── 步驟 9：設定檔（選用） ──────────────────────────────
if [ "$WITH_CONFIG" -eq 1 ]; then
  step "步驟 9：寫入 ~/.codex/config.toml"

  if [ "$MODE" = "check" ]; then
    info "[check] 略過寫設定"
  elif [ "$MODE" = "dry-run" ]; then
    info "[dry-run] 將寫入 ~/.codex/config.toml（provider=$PROVIDER）"
  else
    mkdir -p "$HOME/.codex"
    CFG="$HOME/.codex/config.toml"
    if [ -f "$CFG" ]; then
      cp "$CFG" "$CFG.bak-$(date +%Y%m%d-%H%M%S)"
      pass "已備份原設定到 $CFG.bak-*"
    fi
    case "$PROVIDER" in
      openai)
        cat > "$CFG" <<'EOF'
# 由 codex-setup-linux.sh 產生
# 使用 OpenAI 官方服務（預設）；請用 `codex login` 登入
model = "gpt-5-codex"
EOF
        ;;
      *)
        info "provider=$PROVIDER 為自訂 provider，需自行補上 base_url / env_key"
        cat > "$CFG" <<EOF
# 由 codex-setup-linux.sh 產生
# 自訂 provider：$PROVIDER
model_provider = "$PROVIDER"

[model_providers.$PROVIDER]
name = "$PROVIDER"
EOF
        ;;
    esac
    pass "已寫入 $CFG"
  fi
fi

# ────────────────────────────── 總結 ──────────────────────────────
step "總結"

{
  printf ' 套件管理器：%s\n' "${PKG_MANAGER:-（無）}"
  printf ' Node.js   ：%s\n' "$(command -v node >/dev/null 2>&1 && node --version || echo '未安裝')"
  printf ' npm       ：%s\n' "$(command -v npm  >/dev/null 2>&1 && npm --version  || echo '未安裝')"
  printf ' Codex CLI ：%s\n' "${CODEX_FOUND:-未安裝}"
  printf ' 失敗項目  ：%s\n' "$FAILURES"
  printf ' 提醒項目  ：%s\n' "$WARNINGS"
  printf ' 完整 log  ：%s\n' "$LOG_FILE"
} >> "$LOG_FILE"

if [ -n "$CODEX_FOUND" ] && [ "$FAILURES" -eq 0 ]; then
  pass "全部完成 —— Codex CLI 已就緒"
else
  warn "有 $FAILURES 項失敗、$WARNINGS 項提醒（見上面 FAIL / WARN 標記）"
fi

cat <<'EOF'

下一步：
  1. 讓目前這個終端機認得 codex
       export PATH="$HOME/.local/bin:$PATH"
  2. 登入（使用 OpenAI 官方服務）
       codex login
  3. 測試
       codex "用繁體中文回一句話，確認連線正常"
  4. 進專案開工
       cd ~/你的專案 && codex

完整紀錄：見上方 log 檔路徑

EOF

exit $(( FAILURES > 0 ? 1 : 0 ))
