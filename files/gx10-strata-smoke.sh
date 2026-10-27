#!/usr/bin/env bash
# =============================================================================
#  GX10 (NVIDIA GB10 / aarch64) × Strata LLM 煙霧測試腳本
#  模型：Qwen3.8-Flash-Next 125B / IQ3_S
#  用法：bash gx10-strata-smoke.sh <env|build|setup|serve|verify|all>
#  環境變數（可覆寫）：STRATA_DIR / DATA_DIR / CTX / PORT / MODEL
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRATA_DIR="${STRATA_DIR:-$HOME/Strata}"
DATA_DIR="${DATA_DIR:-/data/strata}"
MODEL="${MODEL:-IQ3_S}"
CTX="${CTX:-262144}"
PORT="${PORT:-8080}"
LOG="${LOG:-/tmp/strata-smoke.log}"
MEMLOG="${MEMLOG:-/tmp/strata-mem.log}"
TAG="$(echo "$MODEL" | tr 'A-Z' 'a-z')"
CFG="$STRATA_DIR/strata-$TAG.json"

ok()   { printf '  \033[32mOK\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mXX\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!!\033[0m %s\n' "$*"; }
info() { printf '  - %s\n' "$*"; }
head2() { printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------- stage: env
stage_env() {
  head2 "Stage A | 環境盤點"
  local arch cc drv nvcc memavail disk feats miss f nproc_out
  arch=$(uname -m)
  if [ "$arch" = "aarch64" ]; then ok "架構 aarch64"; else bad "架構是 $arch，必須是 aarch64"; fi

  cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
  if [ "$cc" = "12.1" ]; then ok "compute_cap 12.1（GB10 / sm_121）"; else bad "compute_cap = $cc，應為 12.1"; fi

  drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
  if [ -n "$drv" ]; then ok "driver $drv"; else bad "讀不到 driver 版本"; fi

  nvcc=$(nvcc --version 2>/dev/null | grep -oE 'release [0-9]+\.[0-9]+' | head -1 | awk '{print $2}')
  if [ "${nvcc%%.*}" = "13" ]; then ok "CUDA toolkit $nvcc"; else bad "CUDA toolkit 是 '${nvcc:-未安裝}'，需要 13.x"; fi

  memavail=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo)
  if awk "BEGIN{exit !($memavail >= 100)}"; then ok "MemAvailable ${memavail} GiB"; else bad "MemAvailable 只有 ${memavail} GiB"; fi

  disk=$(df -BG --output=avail "$DATA_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [ -n "$disk" ] && [ "$disk" -ge 120 ]; then ok "磁碟可用 ${disk} GB"; else bad "磁碟可用 ${disk:-0} GB，需要 >= 120 GB"; fi

  feats=$(grep -m1 '^Features' /proc/cpuinfo)
  miss=""
  for f in i8mm asimddp asimdhp; do echo "$feats" | grep -q "$f" || miss="$miss $f"; done
  if [ -z "$miss" ]; then ok "CPU 具備 i8mm / asimddp / asimdhp"; else bad "CPU 缺少:$miss"; fi

  nproc_out=$(nproc); info "CPU 核心數：$nproc_out"
}

# --------------------------------------------------------------- stage: build
stage_build() {
  head2 "Stage A | 編譯引擎（GB10 sm_121）"
  cd "$STRATA_DIR" || { bad "找不到 $STRATA_DIR"; return 1; }
  cmake -G Ninja -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DSTRATA_ENABLE_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES=121 \
    -DSTRATA_GGML_DIR=third_party/llama.cpp \
    -DGGML_CPU_ARM_ARCH=armv8.6-a+dotprod+i8mm+fp16 || { bad "cmake 設定失敗"; return 1; }
  cmake --build build --target strata -j"$(nproc)" || { bad "編譯失敗"; return 1; }
  ok "引擎編譯完成：$("$STRATA_DIR/build/strata" --version 2>&1 | head -1)"
}

# --------------------------------------------------------------- stage: setup
stage_setup() {
  head2 "Stage B | 下載模型並產生設定（約 90 GB）"
  cd "$STRATA_DIR" || { bad "找不到 $STRATA_DIR"; return 1; }
  python3 setup.py \
    --model "$MODEL" \
    --context "$CTX" \
    --kv int8 \
    --parallel 4 \
    --mtp on \
    --cuda 13 \
    --build \
    --data-dir "$DATA_DIR" \
    --yes || { bad "setup.py 失敗"; return 1; }

  if [ -f "$CFG" ]; then
    python3 "$SCRIPT_DIR/gx10-patch-ple.py" "$CFG"
  else
    bad "找不到設定檔 $CFG"
  fi
}

# --------------------------------------------------------------- stage: serve
stage_serve() {
  head2 "Stage C | 啟動服務"
  cd "$STRATA_DIR" || { bad "找不到 $STRATA_DIR"; return 1; }
  : > "$LOG"
  nohup "./run-$TAG.sh" > "$LOG" 2>&1 &
  echo $! > /tmp/strata.pid
  info "PID $(cat /tmp/strata.pid)，日誌 $LOG"
  local i
  for i in $(seq 1 120); do
    if curl -s -o /dev/null -m 2 "http://127.0.0.1:$PORT/health"; then
      ok "服務已就緒"; return 0
    fi
    if grep -q "illegal memory access" "$LOG" 2>/dev/null; then
      bad "偵測到 CUDA error 77（illegal memory access）— 這就是 issue #3525"
      grep -n "illegal memory access" "$LOG" | head -3
      return 1
    fi
    sleep 10
  done
  bad "1200 秒內服務未就緒，請看 $LOG"
  tail -30 "$LOG"
  return 1
}

# -------------------------------------------------------------- stage: verify
stage_verify() {
  head2 "Stage D | 驗證"
  if [ ! -f "$LOG" ]; then bad "沒有日誌 $LOG"; return 1; fi

  if grep -q "illegal memory access" "$LOG"; then
    bad "CUDA error 77 出現（#3525）"
    return 1
  else ok "沒有 illegal memory access"; fi

  head2 "expert 常駐狀態（關鍵：CPU 接手會慢 4.2 倍）"
  grep -iE "expert|cache" "$LOG" | grep -iE "24576|24,576|resident|slot" | head -8
  if grep -qiE "all .*experts|24576 .*resident|experts.*resident" "$LOG"; then
    ok "日誌顯示 experts 已常駐"
  else
    warn "未能從日誌確認 24,576 experts 全常駐 —— 請用下面的 CPU 忙碌度判斷"
  fi

  : > "$MEMLOG"
  ( while true; do
      echo "$(date +%T) avail=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo) GiB" >> "$MEMLOG"
      sleep 2
    done ) &
  echo $! > /tmp/strata-mem.pid

  head2 "請求測試"
  local t0 t1 cpu0 cpu1 busy resp
  cpu0=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
  t0=$(date +%s.%N)
  resp=$(curl -s -m 600 -X POST "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"local","messages":[{"role":"user","content":"寫一個 Python 函式，判斷字串是否為回文，只回程式碼。"}],"max_tokens":128}' 2>&1)
  t1=$(date +%s.%N)
  cpu1=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)

  busy=$(awk -v a="$cpu0" -v b="$cpu1" 'BEGIN{
      split(a,x," "); split(b,y," ");
      dt=y[1]-x[1]; di=y[2]-x[2];
      if (dt>0) printf "%.1f", 100*(dt-di)/dt; else print "n/a"}')
  echo "$resp" | head -c 400; echo
  info "整段請求耗時：$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}') 秒"
  info "期間 CPU 忙碌度：${busy}%（全 GPU 常駐時應接近 0%）"

  head2 "伺服器自報速度"
  grep -oE "[0-9.]+ tok/s" "$LOG" | tail -5 || warn "日誌沒抓到 tok/s"

  head2 "記憶體"
  awk -F'avail=' '{gsub(/ GiB/,"",$2); if(m==""||$2+0<m) m=$2+0} END{printf "  - MemAvailable 最低：%.1f GiB\n", m}' "$MEMLOG"
  info "驗收門檻：>= 10 GiB；低於 5 GiB 就要拿掉 --ple-io ram"

  kill "$(cat /tmp/strata-mem.pid)" 2>/dev/null
  echo
  info "服務仍在背景執行（PID $(cat /tmp/strata.pid)）；停止：kill $(cat /tmp/strata.pid)"
}

# ------------------------------------------------------------------- driver
case "${1:-all}" in
  env)    stage_env ;;
  build)  stage_env; stage_build ;;
  setup)  stage_setup ;;
  serve)  stage_serve ;;
  verify) stage_verify ;;
  all)    stage_env; stage_build; stage_setup; stage_serve; stage_verify ;;
  *)      echo "用法：bash $0 <env|build|setup|serve|verify|all>"; exit 1 ;;
esac
