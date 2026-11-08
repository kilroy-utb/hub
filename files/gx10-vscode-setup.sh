#!/usr/bin/env bash
# gx10-vscode-setup.sh — 檢查 Strata 能不能接上 VS Code，並印出可以直接貼的設定
#
#   bash gx10-vscode-setup.sh
#   bash gx10-vscode-setup.sh --url http://127.0.0.1:8080 --api-key sk-local
#   bash gx10-vscode-setup.sh --url http://192.168.1.20:8080 --model qwen3.8-flash-next-iq3_s
#
# 會做：
#   1. GET  /health            → 服務活著嗎、context 多長
#   2. GET  /v1/models         → 模型名稱
#   3. POST /v1/chat/completions（串流）    → 量首字等待
#   4. POST /v1/chat/completions（帶 tools）→ 工具呼叫能不能用（agent 能不能改檔）
#   5. 印出 Cline / Continue / VS Code 原生 Chat 的設定片段
set -uo pipefail

URL="${STRATA_URL:-http://127.0.0.1:8080}"
API_KEY="${API_KEY:-}"
MODEL=""
TIMEOUT="${TIMEOUT:-60}"
CTX_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --url)     URL="$2"; shift 2;;
    --api-key) API_KEY="$2"; shift 2;;
    --model)   MODEL="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --ctx)     CTX_OVERRIDE="$2"; shift 2;;
    -h|--help) sed -n '2,17p' "$0"; exit 0;;
    *) echo "未知選項：$1" >&2; exit 1;;
  esac
done

URL="${URL%/}"
BASE="$URL/v1"

say(){  printf '\033[36m==>\033[0m %s\n' "$*"; }
ok(){   printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m   %s\n' "$*"; }
bad(){  printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
die(){  printf '\033[31m錯誤：\033[0m %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "需要 python3"
command -v curl >/dev/null 2>&1 || die "需要 curl"

if [ -n "$API_KEY" ]; then
  API_HDR=(-H "Authorization: Bearer $API_KEY")
  export GVSU_API_KEY="$API_KEY"
else
  API_HDR=()
  export GVSU_API_KEY=""
fi

# ---------------------------------------------------------------- 1. health
say "1/5 健康檢查 $URL/health"
HEALTH_FILE="$(mktemp)"
health_code="$(curl -s -o "$HEALTH_FILE" -w '%{http_code}' -m 10 "$URL/health" 2>/dev/null)"
if [ "$health_code" != "200" ]; then
  bad "HTTP $health_code"
  head -c 400 "$HEALTH_FILE" 2>/dev/null; echo
  rm -f "$HEALTH_FILE"
  die "連不到 Strata。請確認：服務有啟動、SSH port forward 還開著、URL 對不對。"
fi
HEALTH_JSON="$(cat "$HEALTH_FILE")"
rm -f "$HEALTH_FILE"
ok "服務活著"

# ------------------------------------------------------- 2. models + context
say "2/5 模型清單 $BASE/models"
models_json="$(curl -s -m 15 "${API_HDR[@]}" "$BASE/models")"
if printf '%s' "$models_json" | grep -q 'authentication_error\|"code":401\|missing or wrong API key'; then
  bad "伺服器有設 API key，但這次請求沒帶對"
  die "請加 --api-key <你的金鑰>（或設 API_KEY 環境變數）再跑一次"
fi

# 先看 /health 回的 max_context（權威值），沒有再用 /v1/models 補
read -r H_MODEL H_CTX <<<"$(printf '%s' "$HEALTH_JSON" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
print(d.get("model") or "", d.get("max_context") or 0)
' 2>/dev/null)"

read -r M_MODEL M_CTX <<<"$(printf '%s' "$models_json" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
data=d.get("data") or []
mid=(data[0].get("id","") if data else "")
ctx=0
for m in data:
    for k in ("context_length","max_context_length","context_window","n_ctx"):
        v=m.get(k)
        if isinstance(v,int) and v>ctx: ctx=v
if not ctx:
    for m in data:
        for k in ("default_generation_settings","meta"):
            v=m.get(k)
            if isinstance(v,dict):
                for kk in ("context_length","n_ctx"):
                    if isinstance(v.get(kk),int): ctx=max(ctx,v[kk])
print(mid, ctx)
' 2>/dev/null)"

MODEL="${MODEL:-${H_MODEL:-$M_MODEL}}"
CTX="${H_CTX:-0}"; [ "${CTX:-0}" -gt 0 ] 2>/dev/null || CTX="${M_CTX:-0}"
[ -n "$CTX_OVERRIDE" ] && CTX="$CTX_OVERRIDE"
[ -n "$MODEL" ] || MODEL="local"
[ "${CTX:-0}" -gt 0 ] 2>/dev/null || CTX=262144
ok "模型：$MODEL｜context：$CTX token"

# ------------------------------------------------------------- 3. chat + TTFT
say "3/5 聊天請求（串流，量首字等待）"
ttft_json="$(python3 - "$BASE/chat/completions" "$MODEL" "$TIMEOUT" <<'PY'
import json, os, sys, time, urllib.request
url, model, timeout = sys.argv[1], sys.argv[2], float(sys.argv[3])
key = os.environ.get("GVSU_API_KEY", "")
body = json.dumps({"model": model,
                   "messages": [{"role": "user", "content": "用一句話說明什麼是遞迴。"}],
                   "max_tokens": 64, "stream": True, "reasoning_effort": "none"}).encode()
headers = {"Content-Type": "application/json"}
if key:
    headers["Authorization"] = "Bearer " + key
req = urllib.request.Request(url, data=body, headers=headers)
t0 = time.time(); first = None; text = ""
try:
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for raw in r:
            if not raw:
                continue
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                chunk = json.loads(data)
            except Exception:
                continue
            delta = (chunk.get("choices") or [{}])[0].get("delta") or {}
            piece = delta.get("content") or ""
            if piece and first is None:
                first = time.time() - t0
            text += piece
except Exception as e:
    print(json.dumps({"error": str(e)}))
    raise SystemExit
print(json.dumps({"ttft": round(first, 3) if first else None,
                  "chars": len(text), "sample": text[:80]}))
PY
)"
if printf '%s' "$ttft_json" | grep -q '"error"'; then
  err="$(printf '%s' "$ttft_json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("error"))')"
  bad "請求失敗：$err"
  case "$err" in
    *401*|*Unauthorized*) die "伺服器要求 API key，請加 --api-key <你的金鑰> 再跑一次" ;;
    *404*)              die "端點找不到：$BASE 這條路徑不對，檢查一下 Base URL" ;;
    *403*)              die "被擋下：伺服器沒設 API key 又用主機名稱連線，改用 IP 連或請管理者設定 api_key" ;;
  esac
  die "聊天端點有問題，後面的設定不會有意義。"
fi
printf '%s' "$ttft_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
tt = d.get("ttft")
print("  \033[32mOK\033[0m   回應 %d 字，首字等待 %s 秒" % (d.get("chars", 0), tt if tt is not None else "量不到"))
'
TTFT="$(printf '%s' "$ttft_json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("ttft") or 0)')"

# ---------------------------------------------------------- 4. tool calling
say "4/5 工具呼叫測試（決定 agent 能不能改檔）"
tool_json="$(python3 - "$BASE/chat/completions" "$MODEL" "$TIMEOUT" <<'PY'
import json, os, sys, urllib.request
url, model, timeout = sys.argv[1], sys.argv[2], float(sys.argv[3])
key = os.environ.get("GVSU_API_KEY", "")
payload = {"model": model,
           "messages": [{"role": "user", "content": "請用 read_file 工具讀取 hello.txt 的內容。"}],
           "tools": [{"type": "function",
                      "function": {"name": "read_file", "description": "讀取一個檔案",
                                   "parameters": {"type": "object",
                                                  "properties": {"path": {"type": "string"}},
                                                  "required": ["path"]}}}],
           "max_tokens": 256, "stream": False, "reasoning_effort": "none"}
headers = {"Content-Type": "application/json"}
if key:
    headers["Authorization"] = "Bearer " + key
req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers)
try:
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.loads(r.read().decode())
except Exception as e:
    print(json.dumps({"error": str(e)}))
    raise SystemExit
msg = (d.get("choices") or [{}])[0].get("message") or {}
calls = msg.get("tool_calls") or []
print(json.dumps({"tool_calls": len(calls),
                  "name": (calls[0].get("function") or {}).get("name") if calls else None,
                  "content": (msg.get("content") or "")[:120]}))
PY
)"
if printf '%s' "$tool_json" | grep -q '"error"'; then
  warn "工具測試請求失敗：$(printf '%s' "$tool_json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("error"))')"
  warn "工具呼叫無法驗證，agent 模式可能不能用"
else
  n="$(printf '%s' "$tool_json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("tool_calls",0))')"
  nm="$(printf '%s' "$tool_json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("name") or "")')"
  if [ "$n" -ge 1 ] 2>/dev/null; then
    ok "模型回傳了工具呼叫：$nm（agent 模式可用）"
  else
    warn "模型沒有回傳 tool_calls（$n 個）—— agent 模式可能只能用聊天"
  fi
fi

# ------------------------------------------------------------ 5. 設定片段
say "5/5 設定片段（直接複製貼上）"
KEY_PLACEHOLDER="${API_KEY:-sk-local}"

cat <<TXT

───── Cline ─────
介面：Cline 面板 → 齒輪 → API Provider → OpenAI Compatible
  Base URL       : $BASE
  API Key        : $KEY_PLACEHOLDER
  Model ID       : $MODEL
  Context Window : $CTX
  Max Tokens     : 8192

settings.json 版：
{
  "cline.openAiBaseUrl": "$BASE",
  "cline.openAiApiKey": "$KEY_PLACEHOLDER",
  "cline.openAiModelId": "$MODEL",
  "cline.openAiModelInfo": { "contextWindow": $CTX, "maxTokens": 8192 }
}

───── Continue（~/.continue/config.yaml）─────
name: Local Strata (GX10)
version: 1.0.0
schema: v1
models:
  - name: Strata $MODEL
    provider: openai
    model: $MODEL
    apiBase: $BASE
    apiKey: "$KEY_PLACEHOLDER"
    roles:
      - chat
      - edit
      - apply
    useResponsesApi: false
    defaultCompletionOptions:
      contextLength: $CTX
      maxTokens: 8192
      temperature: 0.2

───── VS Code 原生 Chat（chatLanguageModels.json）─────
[
  {
    "vendor": "customendpoint",
    "id": "strata-gx10",
    "name": "Strata GX10",
    "apiType": "chat-completions",
    "url": "$BASE/chat/completions",
    "toolCalling": true,
    "maxInputTokens": $CTX,
    "maxOutputTokens": 32768
  }
]

───── 提醒 ─────
TXT
cat <<TXT
  * Base URL 要有 /v1、不能有尾斜杠（$BASE 這樣才對）
  * VS Code 原生那個 url 要寫完整到 /chat/completions
  * 行內自動補全不能用：Strata 沒有 FIM 端點
  * 對話越長每輪越慢，context 太大時降到 65536 會快一倍以上
  * reasoning_effort 只接受 none / low / medium / high
TXT

cat <<TXT

量測結果：首字等待 ${TTFT}s、模型 $MODEL、context $CTX
TXT
