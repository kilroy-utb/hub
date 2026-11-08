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
