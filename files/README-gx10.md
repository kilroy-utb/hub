# GX10 × Strata 工具組

ASUS Ascent GX10（GB10 / 128GB 統一記憶體 / aarch64）跑 Qwen3.8-Flash-Next 125B 的操作腳本。

## 檔案

| 檔案 | 用途 |
|---|---|
| `sync_github_files.sh` | 把本 repo 的 `files/` 目錄同步到本機（新增／更新／刪除都處理） |
| `gx10-verify.sh` | 只做驗收：error 77、experts 常駐、CPU 忙碌度、server 端計時、記憶體、設定檔 |
| `gx10-bench.py` | 真實 prompt benchmark：8 個測試案例，量 TTFT／prefill／decode／CPU／記憶體，並檢查答案品質 |
| `gx10-strata-smoke.sh` | 原本那支（已修正：記憶體門檻分階段、磁碟 fallback、關 thinking、log 自動偵測） |
| `smoke-fixes.patch` | 相對於原版 smoke.sh 的 unified diff |

## 同步工作流程

```
我改腳本  →  你 commit 到 kilroy-utb/hub 的 files/  →  在 GX10 跑一次 sync_github_files.sh
```

```bash
bash sync_github_files.sh              # 同步到腳本所在目錄
bash sync_github_files.sh --flatten    # 檔案直接放目標目錄根層（方便直接執行）
bash sync_github_files.sh --dir ~/gx10-scripts
bash sync_github_files.sh --dry-run    # 只看會做什麼
bash sync_github_files.sh --list       # 只列遠端清單
bash sync_github_files.sh --prefix files --prefix wiki/gx10-strata
bash sync_github_files.sh --exclude 'README.md' --exclude 'index.html'   # 不抓這些
```

### 刪除是怎麼處理的

1. 只刪「上次同步清單裡有、遠端現在沒有」的檔案 → 你的其他檔案不會被碰到
2. 覆寫與刪除前都先備份到 `.sync_backup/<時間戳>/`（預設保留最近 5 份）
3. 用 git blob sha 比對，本機沒改就不重下
4. 下載先寫 `.part` 再 `mv`，落地後驗 sha 通過才取代
5. `--prune` 才會碰「不在遠端、也不在清單裡」的同類孤兒檔，而且會先問你

同步清單在 `.github-files.manifest`，記錄「遠端路徑 / 本機路徑 / blob sha」。

### 首次部署

`sync_github_files.sh` 自己也在 `files/` 裡，但第一次要手動先放一份：

```bash
curl -O https://kilroy-utb.github.io/hub/files/sync_github_files.sh
chmod +x sync_github_files.sh
bash sync_github_files.sh
```

之後它就能連同其他腳本一起更新自己。

## 驗收流程

```bash
bash gx10-verify.sh          # 一次跑完所有門檻檢查
```

門檻可用環境變數覆寫：`MIN_DECODE=45 MIN_PREFILL=800 MIN_MEM=10 MAX_CPU=20 PORT=8080`

## Benchmark（真實 prompt 測試）

`gx10-verify.sh` 只確認「服務活著且達標」，`gx10-bench.py` 才會真的送一輪 prompt，
量出這台機器實際跑起來多快，以及答案品質對不對。

```bash
python3 gx10-bench.py                      # 完整 8 個案例
python3 gx10-bench.py --quick              # 快測（跳過長上下文，約 2 分鐘）
python3 gx10-bench.py --repeat 3           # 每個案例重跑 3 次取中位數
python3 gx10-bench.py --out report.json    # 存報告
python3 gx10-bench.py --compare old.json   # 跟舊報告比（看改了設定有沒有比較快）
python3 gx10-bench.py --only code,zh       # 只跑指定案例
```

### 測哪些東西

| 案例 | 類別 | 在量什麼 |
|---|---|---|
| `ttft` | 核心 | 首字等待（agent 每輪都會感受到） |
| `decode` | 核心 | 長輸出解碼速度 |
| `code` | 品質 | 生成程式碼，檢查有沒有真的寫出函式 |
| `zh` | 品質 | 繁體中文，中文字元數是否足夠 |
| `reasoning` | 品質 | 邏輯推理，檢查有沒有列出步驟 |
| `instruction` | 品質 | 指令遵循，檢查有沒有只回要的部分 |
| `longctx` | 壓力 | 長 prompt 的 prefill 速度 |
| `cache` | 壓力 | 同一 prompt 送兩次，看快取有沒有命中 |

### 測試條件（實際送出的 prompt）

所有案例都用 `reasoning_effort: none`（關閉思考模式），streaming 送出。

| 案例 | 實際 prompt | max_tokens | 檢查代碼 |
|---|---|---|---|
| `ttft` | 用一句話說明什麼是遞迴。 | 64 | `nonempty` |
| `decode` | 詳細說明 Python 的 GIL 是什麼，以及它對多執行緒程的影響。 | 512 | `nonempty` |
| `code` | 用 Python 寫一個函式 `def is_palindrome(s: str) -> bool`，判斷字串是否為回文（忽略大小寫與非字母數字字元）。只回程式碼，不要解釋。 | 512 | `code` |
| `zh` | 請用繁體中文寫一段 150 字左右，說明台灣的四季氣候特色。 | 512 | `chinese` |
| `reasoning` | 一隻烏鴉把一隻 5 升的桶裝滿了水，桶上有一個 3 升的桶。請問要怎麼量出恰好 4 升的水？請只列出步驟，不要多作解釋。 | 256 | `steps` |
| `instruction` | 請只輸出三個以逗號分隔的英文單字，代表顏色，不要任何其他文字。 | 32 | `short` |
| `longctx` | 同一段內部技術文件重複 40 段（約 4K token）+「請用三個要點總結這份文件的核心內容，並說明 expert 常駐的重要性。」 | 256 | `nonempty` |
| `cache` | 同一段文件 +「另外請列出三個關於 PLE n-gram 表的技術重點。」 | 256 | `nonempty` |

`cache` 會把**同一個 prompt 送兩次**：第一次是冷啟動，第二次看快取有沒有命中。
報告裡會多出 `cache_cold_prefill`、`cache_cold_ttft`、`cache_hit_ratio` 三個欄位。

### 品質檢查規則

| 代碼 | 檢查方式 | 通過條件 |
|---|---|---|
| `nonempty` | 回應有內容 | 去空白後 ≥ 8 字元 |
| `code` | 有真的寫出函式 | 正則找到 `def is_palindrome` |
| `chinese` | 中文字數足夠 | 中文字元 ≥ 40 個 |
| `steps` | 有列出步驟 | 步驟標記（數字／①-⑩／一-五／`1.`）≥ 2 個 |
| `short` | 指令遵循 | 長度 ≤ 200 字元，且有逗號 |

### 執行流程

1. **健康檢查** — 打 `GET /health`，不通就直接結束（exit 2）
2. **暖機** — 先送一個 `你好`（8 token）的請求，這次的 TTFT 記為「冷啟動 TTFT」，
   後面的數字才彼此可比
3. **Prefill 校準** — 3 種長度（64 / 1K / 4K token）× 2 輪，每輪開頭塞隨機標記，
   避免命中前一次的前綴快取
4. **測試案例** — 依序跑，每個案例記錄 TTFT、prefill、decode、CPU 忙碌度、
   MemAvailable 最低值
5. **報告** — 表格 + 總結；`--out` 可存成 JSON 供日後比較

### 完整 CLI 旗標

| 旗標 | 說明 |
|---|---|
| `--url` | 服務位置（預設 `http://127.0.0.1:8080`） |
| `--api-key` | API key（有設就帶 `Authorization` header） |
| `--model` | 模型名稱（不給會自動查 `/v1/models`） |
| `--repeat N` | 每個案例重跑 N 次取中位數（預設 1） |
| `--quick` | 跳過 `longctx` 與 `cache` |
| `--only a,b` | 只跑指定案例（逗號分隔） |
| `--no-stream` | 不用串流（量不到真實 TTFT） |
| `--no-warmup` | 跳過暖機 |
| `--no-calibrate` | 跳過 prefill 校準（退回固定門檻判定） |
| `--timeout` | 單次請求逾時秒數（預設 900） |
| `--out` | 存 JSON 報告 |
| `--compare` | 跟舊報告比較（看改了設定有沒有變快） |
| `--ttft` `--prefill` `--decode` `--max-cpu` `--min-mem` | 覆寫各項門檻 |

### 報告 JSON 欄位

```jsonc
{
  "when": "2026-11-08 15:04:11",
  "model": "qwen3.8-flash-next-iq3_s",
  "cold_start_ttft": 0.274,          // 暖機那次的 TTFT
  "calibration": {
    "rate": 1145,                    // 實測 prefill 速率（tok/s）
    "overhead": 0.28,                // 固定延遲（秒）
    "points": [[163, 0.42], [2683, 2.61]]   // (token 數, TTFT)
  },
  "thresholds": { "ttft": 3, "prefill": 800, "decode": 45, "max_cpu": 20, "min_mem": 10 },
  "results": [{
    "id": "cache", "name": "提示快取命中", "group": "壓力",
    "ttft": 0.28, "prefill_tps": 14209.1, "decode_tps": 57.1,
    "decode_best": 57.1,
    "prompt_tokens": 3961, "completion_tokens": 240,
    "total_s": 12.8, "cpu_busy": 10.5, "mem_min": 39.6,
    "check": "nonempty", "check_passed": true, "check_note": "有內容",
    "cache_cold_prefill": 1059.2,    // 同一 prompt 冷跑
    "cache_hit_ratio": 13.41,        // 快取命中後快幾倍
    "sample": "……"                    // 回應前 300 字
  }]
}
```

### 判定門檻

預設跟 `gx10-verify.sh` 對齊，可用 CLI 覆寫：

```bash
python3 gx10-bench.py --ttft 3 --prefill 800 --decode 45 --max-cpu 20 --min-mem 10
```

結束碼：`0` 全部通過、`1` 有項目未達門檻、`2` 服務沒起來。

### 為什麼要先做「Prefill 校準」

短 prompt 的 `tokens ÷ TTFT` 量到的是**固定延遲**（HTTP、排程、CUDA graph），
不是 prefill 速率 —— 20 個 token 的 prompt 花 0.34 秒，會顯示成 59 tok/s，
但那 0.34 秒幾乎跟讀 prompt 沒關係。

而長 prompt 的 TTFT 本來就會隨長度成長，也不能用固定秒數去卡。

所以跑 benchmark 前會先用 3 種長度（64 / 1K / 4K token）的 prompt 配一條線：

```
TTFT ≈ 固定延遲 + prompt_tokens / prefill_rate
```

兩個參數一起求出來，然後：

- prefill 門檻用**校準出來的速率**判斷，不看單一 case 的推算值
- TTFT 上限 = `max(固定門檻, 固定延遲 + prompt_tokens / 速率 × 1.5)`
- decode 門檻只在輸出 ≥ 64 token 時才判（輸出太短速率不準）

```bash
python3 gx10-bench.py --no-calibrate   # 跳過校準（退回固定門檻判定）
```

會長這樣：

```
== Prefill 校準 ==
  固定延遲（HTTP + 排程 + CUDA graph）：0.321 秒
  實際 prefill 速率：1199 tok/s（門檻 ≥ 800）
  樣本：(163 tok, 0.46s) (2683 tok, 2.56s) (10747 tok, 9.28s)
```

### 環境變數

`PORT`（預設 8080）、`API_KEY`（有設就帶 Authorization header）、`MODEL`、
`BENCH_TIMEOUT`（預設 900 秒）。

### 怎麼比較兩次結果

```bash
python3 gx10-bench.py --quick --out before.json
# 改設定（例如套 gx10-patch-ttft.py）並重啟服務
python3 gx10-bench.py --quick --out after.json --compare before.json
```

會列出每個案例的 prefill／decode 增減量，正數代表變快。
