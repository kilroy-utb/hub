#!/usr/bin/env bash
# gx10-verify.sh — Strata on ASUS Ascent GX10：只做驗收（不 build / 不 setup / 不重啟服務）
#
# 用法：
#   bash gx10-verify.sh                        # 自動找 log 與設定檔
#   LOG=... CFG=... bash gx10-verify.sh        # 手動指定
#   API_KEY=xxx bash gx10-verify.sh            # 有設 API key 時
#
# 門檻可用環境變數覆寫：
#   MIN_DECODE=45   MIN_PREFILL=800   MIN_MEM=10   MAX_CPU=20   PORT=8080
#
# 結束碼：0 = 全部通過；1 = 有項目未達門檻

set -uo pipefail

PORT="${PORT:-8080}"
MODEL="${MODEL:-IQ3_S}"
TAG="$(echo "$MODEL" | tr 'A-Z' 'a-z')"
STRATA_DIR="${STRATA_DIR:-$HOME/Strata}"
LOG="${LOG:-}"
CFG="${CFG:-}"
API_KEY="${API_KEY:-}"
MIN_DECODE="${MIN_DECODE:-45}"
MIN_PREFILL="${MIN_PREFILL:-800}"
MIN_MEM="${MIN_MEM:-10}"
MAX_CPU="${MAX_CPU:-20}"
FAILED=0
JOURNAL=0

ok(){   printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad(){  printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
warn(){ printf '  \033[33mWARN\033[0m %s\n' "$*"; }
info(){ printf '  -    %s\n' "$*"; }
h2(){  printf '\n== %s ==\n' "$*"; }

# ---------- 定位 log：檔案優先，其次 systemd journal ----------
if [ -z "$LOG" ]; then
  for c in "$STRATA_DIR/strata-$TAG.log" "$STRATA_DIR/Strata-data/strata-$TAG.log" \
           "/data/strata/strata-$TAG.log" "$HOME/.local/share/strata/strata-$TAG.log"; do
    [ -f "$c" ] && { LOG="$c"; break; }
  done
  if [ -z "$LOG" ]; then
    LOG="$(find "$STRATA_DIR" /data/strata -maxdepth 3 -name "strata-*.log" -newermt '-12 hours' 2>/dev/null | head -1)"
  fi
  if [ -z "$LOG" ] && command -v journalctl >/dev/null 2>&1 && \
     systemctl list-units --type=service --all 2>/dev/null | grep -qi strata; then
    JOURNAL=1
  fi
fi

loggrep(){   # loggrep <pattern>
  if [ "$JOURNAL" != "1" ] && [ -z "${LOG:-}" ]; then return 1; fi
  if [ "$JOURNAL" = "1" ]; then
    journalctl -u strata --since "-40 min" --no-pager 2>/dev/null | grep -iE "$1"
  else
    grep -iE "$1" "$LOG" 2>/dev/null
  fi
}

auth=(); [ -n "$API_KEY" ] && auth=(-H "Authorization: Bearer $API_KEY")

# ---------- 1. 服務狀態 ----------
h2 "1. 服務狀態"
if curl -fsS -m 8 "http://127.0.0.1:$PORT/health" "${auth[@]+"${auth[@]}"}" >/dev/null 2>&1; then
  ok "health 有回應（port $PORT）"
else
  bad "health 沒回應 —— 服務沒起來，或 port 不是 $PORT"
fi
MODEL_ID="$(curl -fsS -m 8 "http://127.0.0.1:$PORT/v1/models" "${auth[@]+"${auth[@]}"}" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)"
if [ -n "$MODEL_ID" ]; then ok "model id = $MODEL_ID"; else warn "讀不到 model id，後續用 \"local\""; MODEL_ID="local"; fi
if [ -n "$LOG" ]; then info "log：$LOG"; elif [ "$JOURNAL" = "1" ]; then info "log：journalctl -u strata"; else warn "找不到 log，Step 2/3 會用動態方式判斷"; fi

# ---------- 2. CUDA error 77 ----------
h2 "2. CUDA error 77（issue #3525）"
if loggrep "illegal memory access" | head -3 | grep -q .; then
  bad "log 出現 illegal memory access —— 換分支或換量化（Q2_0/Gyro 在 ARM 上不可用）"
  loggrep "illegal memory access" | head -3 | sed 's/^/       /'
else
  ok "沒有 illegal memory access"
fi

# ---------- 3. Expert 常駐 ----------
h2 "3. Expert 常駐（關鍵：CPU 接手會慢 4.2 倍）"
EXPLINE="$(loggrep "24,?576" | grep -iE "expert|cache|resident|slot" | head -3)"
if [ -n "$EXPLINE" ]; then
  ok "日誌：$(echo "$EXPLINE" | head -1 | cut -c1-120)"
else
  warn "日誌沒有明寫 24,576 —— 以 Step 4 的 CPU 忙碌度為準"
fi

# ---------- 4. 真實請求：CPU 忙碌度 + server 端計時 ----------
h2 "4. 真實請求（thinking off）"
MEMLOG=/tmp/gx10-verify-mem.log; : > "$MEMLOG"
( while true; do
    echo "$(date +%T) $(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo)" >> "$MEMLOG"
    sleep 2
  done ) &
MEMPID=$!

CPU0=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
T0=$(date +%s.%N)
curl -s -m 900 -X POST "http://127.0.0.1:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' "${auth[@]+"${auth[@]}"}" \
  -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"寫一個 Python 函式判斷字串是否為回文，只回程式碼。\"}],\"max_tokens\":256,\"reasoning_effort\":\"none\"}" \
  > /tmp/gx10-verify-out.json 2>/dev/null
RC=$?
T1=$(date +%s.%N)
CPU1=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)

ELAPSED=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.1f", b-a}')
BUSY=$(awk -v a="$CPU0" -v b="$CPU1" 'BEGIN{split(a,x," ");split(b,y," ");dt=y[1]-x[1];di=y[2]-x[2];if(dt>0)printf "%.1f",100*(dt-di)/dt;else print "n/a"}')

if [ "$RC" = "0" ] && [ -s /tmp/gx10-verify-out.json ]; then
  ok "請求成功，整段耗時 ${ELAPSED}s"
  head -c 300 /tmp/gx10-verify-out.json | sed 's/^/       /'; echo
else
  bad "請求失敗（curl exit $RC）"; head -c 300 /tmp/gx10-verify-out.json 2>/dev/null | sed 's/^/       /'
fi

if awk "BEGIN{exit !($BUSY <= $MAX_CPU)}"; then ok "CPU 忙碌度 ${BUSY}%（門檻 ≤ ${MAX_CPU}%）→ experts 全在 GPU"
else bad "CPU 忙碌度 ${BUSY}% 偏高 → CPU 在算 expert，調 STRATA_UMA_HEADROOM_GIB 或拿掉 --ple-io ram"; fi

info "server 端計時（/v1/status）："
curl -fsS -m 10 "http://127.0.0.1:$PORT/v1/status" "${auth[@]+"${auth[@]}"}" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('       (讀不到 /v1/status)'); raise SystemExit
t = d.get('timings') if isinstance(d.get('timings'), dict) else d
for k in ('prompt_n','prompt_ms','prompt_per_second','predicted_n','predicted_ms','predicted_per_second','cache_n','draft_accepted','draft_total'):
    if k in t:
        print(f'       {k}: {t[k]}')
def num(*ks):
    for k in ks:
        if k in t:
            try: return float(t[k])
            except Exception: pass
    return None
pp = num('prompt_per_second'); pd = num('predicted_per_second')
import os
md = float(os.environ.get('MIN_PREFILL','800')); mn = float(os.environ.get('MIN_DECODE','45'))
if pp is not None:
    print(('       [PASS] ' if pp >= md else '       [FAIL] ') + f'prefill {pp:.0f} tok/s（門檻 ≥ {md:.0f}）')
if pd is not None:
    print(('       [PASS] ' if pd >= mn else '       [FAIL] ') + f'decode {pd:.1f} tok/s（門檻 ≥ {mn:.0f}）')
" 2>/dev/null || echo "       (解析失敗)"

# ---------- 5. 記憶體 ----------
h2 "5. 記憶體"
kill "$MEMPID" 2>/dev/null; sleep 1
MINAVAIL=$(awk '{v=$2+0; if(m==""||v<m) m=v} END{printf "%.1f", m}' "$MEMLOG")
if awk "BEGIN{exit !($MINAVAIL >= $MIN_MEM)}"; then ok "MemAvailable 最低 ${MINAVAIL} GiB（門檻 ≥ ${MIN_MEM}）"
else bad "MemAvailable 最低 ${MINAVAIL} GiB —— 低於 5 GiB 就從設定檔拿掉 --ple-io ram"; fi

# ---------- 6. 設定檔內容 ----------
h2 "6. 設定檔"
if [ -n "$CFG" ] && [ -f "$CFG" ]; then
  info "設定檔：$CFG"
  python3 - "$CFG" <<'PY' 2>/dev/null
import json, sys
a = json.load(open(sys.argv[1]))["args"]
def val(flag):
    return a[a.index(flag)+1] if flag in a and a.index(flag)+1 < len(a) else None
print(f"       --max-context : {val('--max-context')}")
print(f"       --prefill      : {val('--prefill')}")
print(f"       --kv           : {val('--kv')}")
print(f"       --ple-io 次數  : {sum(1 for x in a if x=='--ple-io')}  (值 {val('--ple-io')})")
for f in ('--mmap-experts','--mtp-q4','--mtp-hnorm'):
    print(f"       {f:14s}: {'有' if f in a else '無'}")
PY
else
  warn "找不到設定檔（CFG 沒給或路徑不對）"
fi

# ---------- 總結 ----------
h2 "總結"
if [ "$FAILED" = "0" ]; then printf '\033[32m全部通過\033[0m\n'; else printf '\033[31m有項目未達門檻\033[0m\n'; fi
exit "$FAILED"
