#!/usr/bin/env bash
# =============================================================================
#  Strata LLM × ASUS Ascent GX10 (NVIDIA GB10 / aarch64) — step-by-step 安裝腳本
#
#  模型：Qwen3.8-Flash-Next 125B / IQ3_S（唯一在真實 DGX Spark 驗證過的完整 125B 量化）
#
#  用法：
#    bash gx10-strata-install.sh                # 全部 7 步
#    bash gx10-strata-install.sh --only 0       # 只跑環境檢查
#    bash gx10-strata-install.sh --from 3       # 從第 3 步開始
#    bash gx10-strata-install.sh --skip 6,7     # 跳過指定步驟
#    bash gx10-strata-install.sh --resume       # 自動跳過已完成的步驟
#    bash gx10-strata-install.sh --no-systemd   # 不建立 systemd 服務
#
#  可覆寫的環境變數：
#    STRATA_DIR   程式碼位置            預設 $HOME/Strata
#    DATA_DIR     模型資料夾           預設 /data/strata
#    MODEL        量化                  預設 IQ3_S
#    CTX          context 長度          預設 262144
#    PORT         API 埠號              預設 8080
#    API_HOST     監聽位址              預設 127.0.0.1（要給別台機器接就設 0.0.0.0）
#    API_KEY      API 金鑰              預設空
#    BRANCH_REPO  程式碼來源
#    BRANCH_SHA   要鎖定的 commit
# =============================================================================
set -uo pipefail

# 腳本版本：改了內容請一併 bump，現場對版本時看這行
SCRIPT_VERSION="2026-10-27.5"

# ---------------------------------------------------------------- 設定值
STRATA_DIR="${STRATA_DIR:-$HOME/Strata}"
DATA_DIR="${DATA_DIR:-/data/strata}"
MODEL="${MODEL:-IQ3_S}"
CTX="${CTX:-262144}"
PORT="${PORT:-8080}"
API_HOST="${API_HOST:-127.0.0.1}"
API_KEY="${API_KEY:-}"
BRANCH_REPO="${BRANCH_REPO:-https://github.com/ccatzin-zumwalt/Strata.git}"
BRANCH_SHA="${BRANCH_SHA:-ce16205d8b72fd489c7a2717f872133dcdbf3bd8}"
UMA_HEADROOM_GIB="${UMA_HEADROOM_GIB:-8}"

TAG="$(echo "$MODEL" | tr 'A-Z' 'a-z')"
CFG="$STRATA_DIR/strata-$TAG.json"
STATE_DIR="$STRATA_DIR/.install-state"
STEP_NAMES=(
  "環境檢查"
  "取得程式碼"
  "安裝相依套件"
  "編譯引擎"
  "下載模型與產生設定"
  "套用設定調整"
  "建立 systemd 服務並啟動"
)

ONLY=""
FROM=""
SKIP=""
RESUME=0
NO_SYSTEMD=0
PLE_RAM=1
DIAG=0

# ---------------------------------------------------------------- 輸出格式
step_title() { printf '\n\033[1;36m--- 步驟 %s：%s ---\033[0m\n' "$1" "$2"; }
step_end()   { printf '\033[1;36m--- 步驟完成 ---\033[0m\n'; }
ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m[XX]\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m[!!]\033[0m %s\n' "$*"; }
info() { printf '  - %s\n' "$*"; }
die()  { bad "$*"; exit 1; }

mark_done() { mkdir -p "$STATE_DIR"; : > "$STATE_DIR/step$1.done"; }
is_done()   { [ -f "$STATE_DIR/step$1.done" ]; }

should_run() {
  local n="$1"
  if [ -n "$ONLY" ]; then
    case ",$ONLY," in *",$n,"*) return 0 ;; *) return 1 ;; esac
  fi
  case ",$SKIP," in *",$n,"*) return 1 ;; esac
  if [ -n "$FROM" ] && [ "$n" -lt "$FROM" ]; then return 1; fi
  if [ "$RESUME" = "1" ] && is_done "$n"; then info "（已標記完成，略過）"; return 1; fi
  return 0
}

# ============================================================ 步驟 0：環境檢查
step0_env() {
  step_title 0 "${STEP_NAMES[0]}"
  local fails=0 arch cc drv nvcc memavail disk feats miss f

  arch=$(uname -m)
  if [ "$arch" = "aarch64" ]; then ok "架構 aarch64"; else bad "架構是 $arch，必須是 aarch64"; fails=$((fails+1)); fi

  cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
  if [ "$cc" = "12.1" ]; then ok "compute_cap 12.1（GB10 / sm_121）"; else bad "compute_cap = ${cc:-無}，應為 12.1"; fails=$((fails+1)); fi

  drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
  if [ -n "$drv" ]; then ok "driver $drv（需 >= 580）"; else bad "讀不到 driver 版本"; fails=$((fails+1)); fi

  nvcc=$(nvcc --version 2>/dev/null | grep -oE 'release [0-9]+\.[0-9]+' | head -1 | awk '{print $2}')
  if [ "${nvcc%%.*}" = "13" ]; then ok "CUDA toolkit $nvcc"; else bad "CUDA toolkit 是 ${nvcc:-未安裝}，需要 13.x"; fails=$((fails+1)); fi

  memavail=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo)
  memtotal=$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)
  if awk "BEGIN{exit !($memtotal >= 120)}"; then
    ok "記憶體總量 ${memtotal} GiB"
  else
    bad "記憶體總量只有 ${memtotal} GiB，GX10 應該是 128 GB"; fails=$((fails+1))
  fi
  if awk "BEGIN{exit !($memavail >= 90)}"; then
    ok "MemAvailable ${memavail} GiB"
    if awk "BEGIN{exit !($memavail >= 115)}"; then
      ok "  → 記憶體夠，PLE 放 RAM（--ple-io ram），prompt 快 9–18%"
      PLE_RAM=1
    else
      warn "  → 記憶體不夠，PLE 留在 SSD（不加 --ple-io ram），prompt 慢 9–18%"
      PLE_RAM=0
    fi
  else
    bad "MemAvailable 只有 ${memavail} GiB，需要 >= 90 GiB 才能安全載入 IQ3_S"
    info "  總量有 ${memtotal} GiB，是「被占用了」而不是「沒有記憶體」。常見吃貨："
    info "    · 還在跑的 Ollama / llama-server（你原本的 30B coder、27B）"
    info "    · Docker 容器、背景的模型服務"
    info "    · NVIDIA 驅動對統一記憶體的保留"
    info "  用 bash $0 --diag 看是誰占的；停掉之後再跑一次本步驟。"
    fails=$((fails+1))
  fi

  local probe="$DATA_DIR"
  while [ ! -d "$probe" ] && [ "$probe" != "/" ]; do probe=$(dirname "$probe"); done
  disk=$(df -BG --output=avail "$probe" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [ -n "$disk" ] && [ "$disk" -ge 120 ]; then ok "磁碟可用 ${disk} GB"; else bad "磁碟可用 ${disk:-0} GB，需要 >= 120"; fails=$((fails+1)); fi

  feats=$(grep -m1 '^Features' /proc/cpuinfo)
  miss=""
  for f in i8mm asimddp asimdhp; do echo "$feats" | grep -q "$f" || miss="$miss $f"; done
  if [ -z "$miss" ]; then ok "CPU 具備 i8mm / asimddp / asimdhp"; else bad "CPU 缺少:$miss"; fails=$((fails+1)); fi

  info "CPU 核心數：$(nproc)"
  if [ "$fails" -gt 0 ]; then die "有 $fails 項前置條件不過，先修好再往下（不要硬跑）"; fi
  ok "全部前置條件通過"
  step_end
}

# ============================================================ 步驟 1：取得程式碼
step1_clone() {
  step_title 1 "${STEP_NAMES[1]}"
  case "$STRATA_DIR" in
    */.codex-home/*) die "拒絕在 $STRATA_DIR 安裝（此路徑是對話歷史目錄，不可寫入）" ;;
  esac
  if [ -d "$STRATA_DIR/.git" ]; then
    info "已存在 $STRATA_DIR，改為切換到指定版本"
    cd "$STRATA_DIR" || die "進不去 $STRATA_DIR"
    git fetch --all --tags >/dev/null 2>&1
    git checkout "$BRANCH_SHA" || die "checkout $BRANCH_SHA 失敗"
  else
    if [ -d "$STRATA_DIR" ]; then
      # 資料夾已存在但不是 git repo（例如抓 zip 解壓的）→ 搬到旁邊保留，不刪任何東西
      local backup="${STRATA_DIR}.pre-$(date +%Y%m%d-%H%M%S)"
      warn "$STRATA_DIR 已存在，但不是 git repo"
      info "裡面有：$(ls -A "$STRATA_DIR" 2>/dev/null | head -8 | tr '\n' ' ')"
      info "搬到 $backup 保留（不刪除），再重新 clone"
      mv "$STRATA_DIR" "$backup" || die "搬移失敗（可能是權限問題）"
    fi
    git clone "$BRANCH_REPO" "$STRATA_DIR" || die "clone 失敗"
    ok "clone 完成"
    cd "$STRATA_DIR" || die "進不去 $STRATA_DIR"
    git checkout "$BRANCH_SHA" || die "checkout $BRANCH_SHA 失敗"
  fi
  ok "已鎖定 commit：$(git rev-parse HEAD)"
  info "（記錄這個 SHA，日後要回滾就靠它）"
  chmod +x setup.sh 2>/dev/null
  step_end
}

# ============================================================ 步驟 2：相依套件
step2_deps() {
  step_title 2 "${STEP_NAMES[2]}"
  local SUDO=""
  command -v sudo >/dev/null 2>&1 && SUDO="sudo"
  $SUDO apt-get update -qq || die "apt-get update 失敗"
  $SUDO apt-get install -y build-essential cmake ninja-build git curl python3 python3-pip python3-venv || die "安裝相依套件失敗"
  ok "系統相依套件已安裝"
  if ! command -v nvcc >/dev/null 2>&1; then
    warn "找不到 nvcc（CUDA 13 toolkit）。"
    info "官方安裝指令：sudo apt-get install -y cuda-toolkit-13-0"
    info "或從 NVIDIA 官網下載 runfile 安裝：https://developer.nvidia.com/cuda-downloads"
    die "請先裝好 CUDA 13 toolkit 再續跑（用 --from 2 從這裡繼續）"
  fi
  ok "CUDA toolkit：$(nvcc --version | grep -oE 'release [0-9.]+' | head -1)"

  # Debian/Ubuntu 把 ensurepip 放在 python3-venv 套件裡，沒裝的話 venv 建出來是空的（沒有 pip）
  if ! python3 -c 'import ensurepip' >/dev/null 2>&1; then
    warn "ensurepip 不可用（python3-venv 沒裝好）"
    info "請執行：sudo apt-get install -y python3-venv python3.12-venv"
    die "裝好後用 --from 2 續跑"
  fi

  # Strata 的 Python 環境放在 Strata 資料夾內的 .venv/
  # （Ubuntu 24.04 的系統 Python 是 externally-managed，PEP 668 不允許全域 pip；
  #   官方 setup.sh 也是這樣做的：「system Python stays untouched」）
  if [ ! -x "$STRATA_DIR/.venv/bin/python" ]; then
    info "建立私有 Python 環境 $STRATA_DIR/.venv"
    python3 -m venv "$STRATA_DIR/.venv" || die "建立 .venv 失敗（需要 python3-venv）"
  fi
  ok "venv 就緒：$("$STRATA_DIR/.venv/bin/python" -V 2>&1)"
  step_end
}

# ============================================================ 步驟 3：編譯引擎
step3_build() {
  step_title 3 "${STEP_NAMES[3]}"
  cd "$STRATA_DIR" || die "進不去 $STRATA_DIR"
  info "三個不可省略的參數："
  info "  -DCMAKE_CUDA_ARCHITECTURES=121   （專案預設是 120，GB10 是 sm_121）"
  info "  -DGGML_CPU_ARM_ARCH=armv8.6-a+dotprod+i8mm+fp16   （-mcpu=native 在 big.LITTLE 上失效）"
  info "  -DSTRATA_GGML_DIR=third_party/llama.cpp"

  # llama.cpp 原始碼是 setup.py 另外抓的 zip（不是 submodule）。
  # 沒有它，-DSTRATA_GGML_DIR 會指到不存在的路徑；先讓 setup.py 抓一份 pinned 版本。
  if [ ! -d "$STRATA_DIR/third_party/llama.cpp/ggml" ]; then
    info "抓取 pinned llama.cpp 原始碼（setup.py 的 get_llama_cpp）…"
    local prepy="python3"
    [ -x "$STRATA_DIR/.venv/bin/python" ] && prepy="$STRATA_DIR/.venv/bin/python"
    if (cd "$STRATA_DIR" && "$prepy" -c "import importlib.util,pathlib;s=importlib.util.spec_from_file_location('st',pathlib.Path('setup.py'));m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(m.get_llama_cpp())"); then
      ok "llama.cpp 原始碼就緒"
    else
      warn "抓取 llama.cpp 失敗，改讓 cmake 自己 FetchContent（會多花幾分鐘）"
    fi
  else
    ok "llama.cpp 原始碼已存在"
  fi

  cmake -G Ninja -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DSTRATA_ENABLE_CUDA=ON \
    -DSTRATA_BUILD_TESTS=OFF \
    -DCMAKE_CUDA_ARCHITECTURES=121 \
    -DGGML_CPU_ARM_ARCH=armv8.6-a+dotprod+i8mm+fp16 || die "cmake 設定失敗"
  if [ -d "$STRATA_DIR/third_party/llama.cpp/ggml" ]; then
    cmake -S . -B build -DSTRATA_GGML_DIR=third_party/llama.cpp || die "cmake 設定失敗"
  fi
  cmake --build build --target strata -j"$(nproc)" || die "編譯失敗"
  ok "引擎編譯完成：$(./build/strata --version 2>&1 | head -1)"
  step_end
}

# ============================================================ 步驟 4：下載模型
step4_model() {
  step_title 4 "${STEP_NAMES[4]}"
  cd "$STRATA_DIR" || die "進不去 $STRATA_DIR"
  info "下載量約 90 GB（pack 54.8 + PLE n-gram 表 28.8 + MTP draft 6）"
  info "設定：$MODEL / context $CTX / KV int8 / 併發 4（官方實測設定）"
  info "MTP 推測解碼由 setup.py 自動抓取與啟用，不需要額外參數"

  # 預檢：確認這個 setup.py 認得我們要傳的每個參數，避免又撞到 unrecognized arguments
  local help_out bad_flag="" flag
  help_out=$(cd "$STRATA_DIR" && python3 setup.py --help 2>&1)
  for flag in --model --context --kv --parallel --cuda --build --data-dir --host --port --no-browser --no-start --yes; do
    echo "$help_out" | grep -q -- "$flag" || bad_flag="$bad_flag $flag"
  done
  if [ -n "$API_KEY" ]; then
    echo "$help_out" | grep -q -- "--api-key" || bad_flag="$bad_flag --api-key"
  fi
  if [ -n "$bad_flag" ]; then
    bad "這個 setup.py 不支援：$bad_flag"
    info "腳本版本：$SCRIPT_VERSION"
    info "八成是腳本版本太舊，重新下載："
    info "  curl -O https://kilroy-utb.github.io/hub/files/gx10-strata-install.sh"
    die "更新腳本後再續跑（其他步驟不受影響）"
  fi
  ok "setup.py 參數預檢通過"

  local extra=()
  [ -n "$API_KEY" ] && extra+=(--api-key "$API_KEY")
  # 走官方 setup.sh：它會確保 .venv 存在，再以 .venv 的 python 執行 setup.py
  local runner=()
  if [ -x "$STRATA_DIR/setup.sh" ]; then
    runner=("$STRATA_DIR/setup.sh")
  elif [ -x "$STRATA_DIR/.venv/bin/python" ]; then
    runner=("$STRATA_DIR/.venv/bin/python" "$STRATA_DIR/setup.py")
  else
    die "找不到 setup.sh 或 .venv，請先跑步驟 2（--from 2）"
  fi
  "${runner[@]}" \
    --model "$MODEL" \
    --context "$CTX" \
    --kv int8 \
    --parallel 4 \
    --cuda 13 \
    --build \
    --data-dir "$DATA_DIR" \
    --host "$API_HOST" \
    --port "$PORT" \
    --no-browser \
    --no-start \
    --yes \
    "${extra[@]}" || die "setup.py 失敗"
  ok "模型與設定已就緒"
  step_end
}

# ============================================================ 步驟 5：設定調整
step5_config() {
  step_title 5 "${STEP_NAMES[5]}"
  [ -f "$CFG" ] || die "找不到設定檔 $CFG"
  if [ "$PLE_RAM" != "1" ]; then
    warn "步驟 0 判定記憶體不夠，不加 --ple-io ram（PLE 留在 SSD）"
    info "設定檔：$CFG"
    step_end
    return 0
  fi
  local helper="$STRATA_DIR/gx10-patch-ple.py"
  if [ -f "$helper" ]; then
    python3 "$helper" "$CFG" || warn "設定調整失敗，可手動處理"
  elif [ -f "$SCRIPT_DIR/gx10-patch-ple.py" ]; then
    python3 "$SCRIPT_DIR/gx10-patch-ple.py" "$CFG" || warn "設定調整失敗，可手動處理"
  else
    warn "找不到 gx10-patch-ple.py，跳過 --ple-io ram（prompt 會慢 9–18%）"
  fi
  info "設定檔：$CFG"
  step_end
}

# ============================================================ 步驟 6：systemd
step6_systemd() {
  step_title 6 "${STEP_NAMES[6]}"
  if [ "$NO_SYSTEMD" = "1" ]; then
    info "已指定 --no-systemd，略過（本機手動啟動：cd $STRATA_DIR && ./run-$TAG.sh）"
    step_end
    return 0
  fi
  local unit=/etc/systemd/system/strata.service
  local run_script="$STRATA_DIR/run-$TAG.sh"
  [ -f "$run_script" ] || die "找不到啟動腳本 $run_script"
  local SUDO=""
  command -v sudo >/dev/null 2>&1 && SUDO="sudo"
  $SUDO tee "$unit" >/dev/null <<UNIT
[Unit]
Description=Strata LLM (Qwen3.8-Flash-Next $MODEL)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$STRATA_DIR
Environment=STRATA_UMA_HEADROOM_GIB=$UMA_HEADROOM_GIB
ExecStart=$run_script
Restart=on-failure
RestartSec=10
LimitMEMLOCK=infinity
TimeoutStartSec=3600

[Install]
WantedBy=multi-user.target
UNIT
  $SUDO systemctl daemon-reload || die "systemctl daemon-reload 失敗"
  $SUDO systemctl enable --now strata || die "systemctl 啟動失敗"
  ok "systemd 服務已建立並啟動（STRATA_UMA_HEADROOM_GIB=$UMA_HEADROOM_GIB）"
  info "看日誌：journalctl -u strata -f"
  step_end
}

# ============================================================ 步驟 7：啟動與驗收
step7_verify() {
  step_title 7 "${STEP_NAMES[7]}"
  if [ "$NO_SYSTEMD" = "1" ]; then
    ( cd "$STRATA_DIR" && nohup "./run-$TAG.sh" >/tmp/strata-install.log 2>&1 & )
    info "已背景啟動，日誌 /tmp/strata-install.log"
  fi
  local i
  for i in $(seq 1 120); do
    if curl -s -o /dev/null -m 2 "http://127.0.0.1:$PORT/health"; then
      ok "服務已就緒"
      break
    fi
    if [ "$i" = "120" ]; then
      bad "等待 20 分鐘仍未就緒"
      info "看日誌：journalctl -u strata -n 60"
      return 1
    fi
    sleep 10
  done

  info "送出測試請求（模型會先思考，可能數十秒）…"
  local resp
  resp=$(curl -s -m 900 -X POST "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"local","messages":[{"role":"user","content":"寫一個 Python 函式判斷回文，只回程式碼。"}],"max_tokens":128}' 2>&1)
  if echo "$resp" | grep -q '"content"'; then
    ok "API 回應正常"
    echo "$resp" | head -c 300; echo
  else
    bad "API 沒有正常回應"
    echo "$resp" | head -c 300; echo
    info "若出現 illegal memory access（CUDA error 77）＝ GitHub issue #3525"
    return 1
  fi
  step_end
}

# ============================================================ 參數解析
while [ $# -gt 0 ]; do
  case "$1" in
    --only)       ONLY="$2"; shift 2 ;;
    --from)       FROM="$2"; shift 2 ;;
    --skip)       SKIP="$2"; shift 2 ;;
    --resume)     RESUME=1; shift ;;
    --no-systemd) NO_SYSTEMD=1; shift ;;
    --diag)       DIAG=1; shift ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知參數：$1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================ 記憶體診斷
diag_mem() {
  printf '\n\033[1;36m=== 記憶體診斷 ===\033[0m\n'
  printf '\n-- /proc/meminfo 重點（GiB）--\n'
  awk '/^(MemTotal|MemFree|MemAvailable|Buffers|Cached|Dirty|Writeback|Shmem|SReclaimable):/{
        printf "  %-16s %8.1f GiB\n", $1, $2/1048576 }' /proc/meminfo
  printf '\n-- free -h --\n'
  free -h | sed 's/^/  /'
  printf '\n-- 記憶體用量前 10 名行程 --\n'
  ps -eo pid,user,rss,comm --sort=-rss | head -11 | awk '{printf "  %-8s %-8s %8.1f GiB  %s\n", $1, $2, $3/1048576, $4}'
  printf '\n-- 常見的模型服務 --\n'
  local found=0 svc
  for svc in ollama llama-server llama-server-cpu vllm sglang docker containerd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      printf '  服務在跑：%s   （停掉：sudo systemctl stop %s）\n' "$svc" "$svc"; found=1
    fi
  done
  if command -v docker >/dev/null 2>&1; then
    docker ps --format '  容器：{{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null || true
  fi
  [ "$found" = "0" ] && printf '  （沒有發現 ollama / llama-server / vllm 等服務）\n'
  printf '\n-- NVIDIA 驅動 --\n'
  nvidia-smi --query-gpu=name,memory.total,memory.used,driver_version --format=csv 2>&1 | sed 's/^/  /'
  printf '\n-- 最近的核心記憶體訊息 --\n'
  dmesg 2>/dev/null | grep -iE "oom|killed process|memory" | tail -8 | sed 's/^/  /' || printf '  （無 dmesg 權限或無紀錄）\n'
  printf '\n-- 建議動作 --\n'
  printf '  1. 先停掉還在跑的模型服務（Ollama 等），這通常能立刻釋放數十 GB\n'
  printf '  2. sync; echo 3 > /proc/sys/vm/drop_caches   （清 page cache，需 root）\n'
  printf '  3. 若還是低，重開機後立刻再跑一次 --only 0\n'
}

# ============================================================ 執行
printf '\033[1mStrata LLM × GX10 安裝\033[0m\n'
info "腳本版本：$SCRIPT_VERSION"
info "程式碼：$STRATA_DIR"
info "模型資料：$DATA_DIR"
info "設定：$MODEL / ctx $CTX / 埠號 $PORT / 監聽 $API_HOST"

if [ "$DIAG" = "1" ]; then diag_mem; exit 0; fi

if should_run 0; then step0_env;    mark_done 0; fi
if should_run 1; then step1_clone;  mark_done 1; fi
if should_run 2; then step2_deps;   mark_done 2; fi
if should_run 3; then step3_build;  mark_done 3; fi
if should_run 4; then step4_model;  mark_done 4; fi
if should_run 5; then step5_config; mark_done 5; fi
if should_run 6; then step6_systemd; mark_done 6; fi
if should_run 7; then step7_verify; mark_done 7; fi

printf '\n\033[1;32m全部步驟完成\033[0m\n'
info "API： http://$API_HOST:$PORT/v1/chat/completions"
info "服務狀態：systemctl status strata"
info "日誌： journalctl -u strata -f"
info "疑難排解：strata-gx10-runbook.md"
