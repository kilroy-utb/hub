#!/usr/bin/env bash
# =============================================================================
#  GX10 記憶體釋放工具
#  用途：卸載 Ollama 模型、停掉殘留的推論行程、清 page cache
#  用法：bash gx10-free-mem.sh          # 檢查 + 停 Ollama + 清 cache
#        bash gx10-free-mem.sh --kill-pid <PID>   # 額外指定要收掉的行程
#  安全：只會收掉 llama-server / 指定 PID / Ollama 服務，其他行程只列出不動作
# =============================================================================
set -uo pipefail

KILL_PID=""
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --kill-pid) KILL_PID="$2"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "未知參數：$1"; exit 1 ;;
  esac
done

ok()   { printf '  [OK] %s\n' "$*"; }
bad()  { printf '  [XX] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*"; }
info() { printf '  - %s\n' "$*"; }
head2() { printf '\n== %s ==\n' "$*"; }

memline() { awk "/^$1:/{printf \"%.1f\", \$2/1048576}" /proc/meminfo; }

# ---------------------------------------------------------------- 1. 現況
head2 "1. 釋放前"
info "MemTotal    $(memline MemTotal) GiB"
info "MemAvailable $(memline MemAvailable) GiB"

head2 "GPU 行程清單（GB10 統一記憶體，這裡看得到真實佔用）"
nvidia-smi 2>/dev/null | sed -n '/Processes:/,$p' | sed 's/^/  /' || info "（讀不到 nvidia-smi）"

# ---------------------------------------------------------------- 2. Ollama
head2 "2. 卸載 Ollama 模型"
if command -v ollama >/dev/null 2>&1; then
  models=$(ollama ps 2>/dev/null | tail -n +2 | awk '{print $1}')
  if [ -z "$models" ]; then
    ok "目前沒有載入中的模型"
  else
    info "載入中的模型：$(echo "$models" | tr '\n' ' ')"
    for m in $models; do
      if [ "$DRY" = "1" ]; then
        info "[dry-run] 會執行：ollama stop $m"
      else
        ollama stop "$m" >/dev/null 2>&1 && ok "已卸載 $m" || warn "ollama stop $m 失敗"
      fi
    done
  fi
else
  info "沒裝 ollama，略過"
fi

# ------------------------------------------------------- 3. 殘留 llama-server
head2 "3. 收掉殘留的 llama-server 行程"
pids=$(pgrep -x "llama-server" 2>/dev/null | tr '\n' ' ')
if [ -z "$pids" ]; then
  # 程序名不是 llama-server、但執行檔是它的情況（部分版本的 ollama_llama_server）
  for p in $(pgrep -f "[l]lama-server" 2>/dev/null); do
    exe=$(readlink -f "/proc/$p/exe" 2>/dev/null)
    case "$exe" in */llama-server) pids="$pids $p" ;; esac
  done
  pids=$(echo "$pids" | tr '\n' ' ')
fi
if [ -z "$pids" ]; then
  ok "沒有殘留的 llama-server"
else
  for p in $pids; do
    info "PID $p：$(ps -p "$p" -o rss= 2>/dev/null | awk '{printf "%.1f GiB", $1/1048576}')  $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-90)"
    if [ "$DRY" = "1" ]; then
      info "[dry-run] 會執行：kill $p"
    else
      kill "$p" 2>/dev/null
      sleep 3
      if kill -0 "$p" 2>/dev/null; then
        warn "PID $p 沒回應 SIGTERM，改用 kill -9"
        kill -9 "$p" 2>/dev/null
      fi
      kill -0 "$p" 2>/dev/null || ok "PID $p 已結束"
    fi
  done
fi

# --------------------------------------------------------- 4. 指定 PID
if [ -n "$KILL_PID" ]; then
  head2 "4. 收掉指定行程 PID $KILL_PID"
  if [ -d "/proc/$KILL_PID" ]; then
    info "內容：$(tr '\0' ' ' < /proc/$KILL_PID/cmdline 2>/dev/null | cut -c1-120)"
    info "佔用：$(ps -p "$KILL_PID" -o rss= 2>/dev/null | awk '{printf "%.1f GiB", $1/1048576}')"
    if [ "$DRY" = "1" ]; then
      info "[dry-run] 會執行：kill $KILL_PID"
    else
      kill "$KILL_PID" 2>/dev/null; sleep 3
      if kill -0 "$KILL_PID" 2>/dev/null; then
        warn "沒回應，改用 kill -9"; kill -9 "$KILL_PID" 2>/dev/null
      fi
      kill -0 "$KILL_PID" 2>/dev/null || ok "PID $KILL_PID 已結束"
    fi
  else
    info "PID $KILL_PID 不存在"
  fi
fi

# --------------------------------------------------------- 5. 停用 ollama 服務
head2 "5. 停用 Ollama 服務（避免 keep_alive 又抓回 33 GB）"
if systemctl list-unit-files 2>/dev/null | grep -q "^ollama.service"; then
  if [ "$DRY" = "1" ]; then
    info "[dry-run] 會執行：sudo systemctl disable --now ollama"
  else
    if [ "$(id -u)" = "0" ]; then
      systemctl disable --now ollama >/dev/null 2>&1 && ok "已停用 ollama 服務"
    else
      sudo systemctl disable --now ollama >/dev/null 2>&1 && ok "已停用 ollama 服務" || warn "需要 sudo 權限"
    fi
  fi
else
  info "沒有 ollama.service"
fi

# --------------------------------------------------------- 6. 清 page cache
head2 "6. 清 page cache"
if [ "$DRY" = "1" ]; then
  info "[dry-run] 會執行：sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"
else
  sync
  if [ "$(id -u)" = "0" ]; then
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && ok "page cache 已清"
  else
    echo 3 2>/dev/null | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 && ok "page cache 已清" || warn "需要 sudo 權限"
  fi
fi

# --------------------------------------------------------- 7. 報告
head2 "7. 釋放後"
info "MemTotal     $(memline MemTotal) GiB"
info "MemAvailable $(memline MemAvailable) GiB"
head2 "仍佔用記憶體最多的行程（前 10）"
ps -eo pid,user,rss,comm --sort=-rss | head -11 | awk 'NR==1{printf "  %-8s %-10s %10s  %s\n", $1,$2,"RSS","CMD"; next} {printf "  %-8s %-10s %6.1f GiB  %s\n", $1, $2, $3/1048576, $4}'
head2 "GPU 行程清單"
nvidia-smi 2>/dev/null | sed -n '/Processes:/,$p' | sed 's/^/  /'

avail=$(memline MemAvailable)
echo
if awk "BEGIN{exit !($avail >= 115)}"; then
  ok "MemAvailable ${avail} GiB → 記憶體充裕，PLE 可放 RAM，prompt 快 9–18%"
elif awk "BEGIN{exit !($avail >= 90)}"; then
  ok "MemAvailable ${avail} GiB → 可安裝 IQ3_S，PLE 留在 SSD"
else
  warn "MemAvailable ${avail} GiB → 還是不到 90 GiB，IQ3_S 有風險"
  info "可考慮 MODEL=IQ2_XS（需求約 65–75 GB）"
fi
