# GX10 × Strata LLM 部署工具組

在 **ASUS Ascent GX10**（NVIDIA GB10、128GB 統一記憶體、aarch64）上，用開源推論引擎 **Strata LLM** 跑 **Qwen3.8-Flash-Next 125B**（量化 IQ3_S）。

這頁是這些程式的操作手冊：怎麼下載、怎麼執行、每個參數是什麼、怎麼判斷成功或失敗。

---

## 各支程式各做什麼

| 程式 | 角色 | 什麼時候跑 |
|---|---|---|
| [`gx10-strata-install.sh`](#一gx10-strata-installsh安裝) | **安裝**：環境檢查 → 取得程式碼 → 編譯引擎 → 下載模型 → 產生設定 → 開 systemd → 驗收 | 一開始跑一次 |
| [`gx10-strata-smoke.sh`](#二gx10-strata-smokesh測試) | **測試**：檢查崩潰、查 experts 常駐、量 tok/s、量 CPU 忙碌度、取樣記憶體 | 想確認效能或懷疑退化時跑 |
| [`gx10-patch-ple.py`](#三gx10-patch-plepy設定調整) | **小幫手**：把 `--ple-io ram` 寫進設定檔（安裝腳本第 5 步會自動呼叫） | 通常不用手動執行 |
| [`gx10-patch-ttft.py`](#五gx10-patch-ttftpy降低首字等待) | **小幫手**：開啟對話快取等參數，讓 agent 續接時不用重讀整段歷史（會先驗證引擎支援） | 裝完後建議跑一次 |
| `gx10-patch-bind.py` | **小幫手**：改監聽位址與 API 金鑰（安裝腳本第 8 步會自動呼叫） | 要讓別台機器連進來時 |
| [`gx10-free-mem.sh`](#四gx10-free-memsh記憶體釋放) | **釋放記憶體**：卸載 Ollama 模型、收掉殘留推論行程、清 page cache | 安裝前記憶體不夠時跑 |
| [`gx10-bench.py`](#六gx10-benchpy真實-prompt-benchmark) | **Benchmark**：送 8 輪真實 prompt，量 TTFT／prefill／decode／CPU 忙碌度，並檢查答案品質 | 想確認這台機器到底跑多快時跑 |
| [`gx10-vscode-setup.sh`](#七gx10-vscode-setupsh接-vs-code) | **接入測試**：一次測完能不能接上 VS Code，並印出 Cline／Continue／原生 Chat 的設定片段 | 想在 VS Code 裡用這台機器時跑 |

> 這些都是**純腳本**，不取代 Strata 官方的 `setup.py`。安裝本身仍是 `git clone` + `cmake` + `setup.py`，腳本只是把參數填好、把錯誤判斷寫清楚。

---

## 快速開始（最短路徑）

在 GX10 上：

```bash
# 1. 下載五支程式
curl -O https://kilroy-utb.github.io/hub/files/gx10-strata-install.sh
curl -O https://kilroy-utb.github.io/hub/files/gx10-strata-smoke.sh
curl -O https://kilroy-utb.github.io/hub/files/gx10-patch-ple.py
curl -O https://kilroy-utb.github.io/hub/files/gx10-patch-ttft.py
curl -O https://kilroy-utb.github.io/hub/files/gx10-free-mem.sh
curl -O https://kilroy-utb.github.io/hub/files/gx10-bench.py
chmod +x gx10-strata-*.sh gx10-patch-ple.py gx10-patch-ttft.py gx10-bench.py

# 2. 先只做環境檢查（不動任何東西）
bash gx10-strata-install.sh --only 0

# 3. 檢查通過就跑完整安裝
bash gx10-strata-install.sh
```

安裝完成後，服務在 `http://127.0.0.1:8080` ：

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"local","messages":[{"role":"user","content":"你好"}]}'
```

---

## 一、`gx10-strata-install.sh`（安裝）

### 8 個步驟

| 步驟 | 做什麼 | 預估時間 | 失敗代表什麼 |
|---|---|---|---|
| 0 | 環境檢查：aarch64／compute_cap 12.1／driver／CUDA 13／記憶體／磁碟／CPU 指令集 | 1 分鐘 | 環境不對，**別硬跑**，先照訊息修 |
| 1 | `git clone` 並鎖定 commit `ce16205d`（ARM64 社群分支） | 3 分鐘 | 網路或 GitHub 連線問題 |
| 2 | apt 安裝 build-essential／cmake／ninja 等 | 5 分鐘 | 沒有 sudo 權限，或沒裝 CUDA 13 |
| 3 | 編譯引擎（帶 `121` + ARM NEON 三個必要參數） | 30–60 分鐘 | CUDA toolkit 版本不符 |
| 4 | `setup.py` 下載模型（~90 GB）並產生設定 | 數小時 | 磁碟空間不足或 HuggingFace 連不上 |
| 5 | 套用 `--ple-io ram` | 秒 | 找不到 helper 腳本（不影響主流程） |
| 6 | 建立 systemd 服務並啟動 | 1 分鐘 | 沒有 root 權限 |
| 7 | 等服務就緒 + 送測試請求驗收 | 5–20 分鐘 | 看到 `illegal memory access` 就是 issue #3525 |
| 8 | **對外服務設定**：綁 0.0.0.0 + 金鑰 + 防火牆 + 重啟（**要明確指定才會跑**） | 2–5 分鐘 | 綁外部位址失敗 |

### 參數

```bash
bash gx10-strata-install.sh                # 全部 7 步
bash gx10-strata-install.sh --only 0       # 只跑某一步
bash gx10-strata-install.sh --from 3       # 從第 3 步開始
bash gx10-strata-install.sh --skip 6,7     # 跳過指定步驟（逗號分隔）
bash gx10-strata-install.sh --resume       # 自動跳過已完成的步驟
bash gx10-strata-install.sh --no-systemd   # 不建立 systemd（手動啟動用）
bash gx10-strata-install.sh --diag         # 只做記憶體診斷：誰占掉了記憶體
bash gx10-strata-install.sh --expose       # 步驟 8：改成對外可連（0.0.0.0 + 金鑰 + 防火牆）
bash gx10-strata-install.sh --only 8       # 同上，只做步驟 8
bash gx10-strata-install.sh --unexpose     # 步驟 8：收回成只給本機用
```

`--resume` 靠 `$STRATA_DIR/.install-state/stepN.done` 標記檔判斷中斷在哪。

### 步驟 8：讓別台機器連進來（VS Code / Cline / Continue）

安裝完之後，Strata 預設只監聽 `127.0.0.1`，所以從筆電連 `http://gx10-37a8:8080` 會得到
`ERR_CONNECTION_REFUSED`。一條指令就能改成對外可連：

```bash
bash gx10-strata-install.sh --expose
```

它會依序做：

1. 備份 `run-iq3_s.sh` 與 `strata-iq3_s.json`
2. 呼叫 `gx10-patch-bind.py` 把 **run 腳本**（`--host` 是 CLI 參數，優先於設定檔）
   與 **JSON**（`host` / `api_key`）一起改成對外模式
3. 自動產生一組 API 金鑰（已存在 `~/Strata/gx10-api-key.txt` 就沿用；要換用 `--new-key`）
4. 開防火牆：有 `tailscale0` 就只放行 Tailscale 介面，否則放行整個埠
5. 重啟 systemd 並驗證監聽位址與 `/health`
6. 印出 VS Code 的 `chatLanguageModels.json` 設定片段

```bash
bash gx10-strata-install.sh --expose --new-key      # 換一組新金鑰
bash gx10-strata-install.sh --expose --firewall any # 放行所有來源（不只 Tailscale）
bash gx10-strata-install.sh --expose --bind 100.x.x.x # 只綁單一 IP
bash gx10-strata-install.sh --unexpose              # 收回成只給本機用（會拿掉金鑰）
```

金鑰存在 `~/Strata/gx10-api-key.txt`（權限 600），**不要貼到公開 repo**。

也可以單獨用 helper（不改其他設定）：

```bash
python3 gx10-patch-bind.py --run ~/Strata/run-iq3_s.sh --cfg ~/Strata/strata-iq3_s.json --bind 0.0.0.0 --api-key sk-xxxx
python3 gx10-patch-bind.py --run ~/Strata/run-iq3_s.sh --cfg ~/Strata/strata-iq3_s.json --bind 127.0.0.1 --clear-api-key
```

### 可覆寫的環境變數

| 變數 | 預設值 | 說明 |
|---|---|---|
| `STRATA_DIR` | `$HOME/Strata` | 程式碼位置 |
| `DATA_DIR` | `/data/strata` | 模型資料夾 |
| `MODEL` | `IQ3_S` | 量化版本 |
| `CTX` | `262144` | context 長度（256K） |
| `PORT` | `8080` | API 埠號 |
| `API_HOST` | `127.0.0.1` | 監聽位址；要給別台機器接就設 `0.0.0.0` |
| `API_KEY` | 空 | API 金鑰；對外開放時**務必**設定 |
| `BRANCH_REPO` | ccatzin-zumwalt/Strata | 程式碼來源 |
| `BRANCH_SHA` | `ce16205d…` | 鎖定的 commit |
| `UMA_HEADROOM_GIB` | `8` | 統一記憶體留給 OS 的餘裕 |

### 記憶體門檻說明

GX10 是 128 GB，但引擎實際能用的是 **MemAvailable**（可立即動用的記憶體），不是 MemTotal。
`setup.py` 用 MemTotal（128 GiB）做判斷，引擎則用 **MemAvailable − 6 GiB** 決定 expert cache 要多大——
兩者落差太大時，記憶體不夠會讓 cache 塞不下，**CPU 接手算 expert，速度直接掉 4.2 倍**。

| MemAvailable | 判定 | 動作 |
|---|---|---|
| ≥ 115 GiB | 充裕 | 全套，含 `--ple-io ram`（prompt 快 9–18%） |
| 90–115 GiB | 堪用 | 照裝，但 **PLE 留在 SSD**，prompt 慢 9–18% |
| < 90 GiB | 不安全 | 先釋放記憶體，否則可能 OOM 或掉進 CPU fallback |

```bash
# 看是誰占掉記憶體
bash gx10-strata-install.sh --diag
```

常見吃貨：還在跑的 Ollama / llama-server（你原本的 30B coder、27B）、Docker 容器、
NVIDIA 驅動對統一記憶體的保留。釋放方法依序是：停掉模型服務 → 清 page cache → 重開機。

範例：開給區網用並加金鑰

```bash
API_HOST=0.0.0.0 API_KEY=your-secret bash gx10-strata-install.sh
```

### 為什麼用這個分支

Strata 官方 **main 分支只有 x86-64**，ARM64 的 PR #3622 至今未合併（`mergeable_state: unstable`）。
`ccatzin-zumwalt/Strata` 的 `dgx-spark-gb10-aarch64` 分支會自動偵測 ARM NEON 指令集並傳給 ggml，
而且附了 `docs/DGX_SPARK.md` 真機實測資料。另一個候選是 `ferstar/Strata` 的 `gb10-022` 分支，
但它不會自動帶 ARM 參數，要自己加。

---

## 二、`gx10-strata-smoke.sh`（測試）

安裝完成後、或想確認效能有沒有退化時跑。

### 5 個階段

| 階段 | 做什麼 |
|---|---|
| `env` | 環境盤點（不動任何東西） |
| `build` | 編譯引擎 |
| `setup` | 下載模型 + 套用 `--ple-io ram` |
| `serve` | 背景啟動服務，一邊等就緒一邊盯 error 77 |
| `verify` | **驗收**：抓 error 77、查 experts 常駐、送真實請求量 tok/s、量 CPU 忙碌度、記憶體取樣 |

### 參數

```bash
bash gx10-strata-smoke.sh env      # 只盤點
bash gx10-strata-smoke.sh all      # 盤點 → 編譯 → 下載 → 啟動 → 驗證
bash gx10-strata-smoke.sh verify   # 只跑驗收（服務已在跑時用這個）
```

### `verify` 會量什麼、怎麼判讀

| 指標 | 正常值 | 不正常時的意思 |
|---|---|---|
| `illegal memory access` | 不出現 | 出現 = GitHub issue **#3525**，換分支或換量化 |
| experts 常駐 | **24,576 / 24,576 在 GPU** | 沒塞滿 → CPU 接手算，**速度掉 4.2 倍**（82.9 → 19.7 tok/s） |
| CPU 忙碌度 | 接近 **0%** | 明顯偏高 = experts 沒全在 GPU |
| decode 速度 | **≥ 45 tok/s**（官方實測 58.8–66.0） | 低於 45 要檢查常駐狀態與量化 |
| MemAvailable 最低點 | **≥ 10 GiB** | 低於 5 GiB → 把 `--ple-io ram` 拿掉 |

```bash
# 量 CPU 忙碌度也可以這樣看
top -b -n 1 | head -15
```

---

## 三、`gx10-patch-ple.py`（設定調整）

只做一件事：把 `--ple-io ram` 加進 `strata-iq3_s.json` 的 `args` 陣列。

**為什麼需要手動加？** Strata 的 `setup.py` 只在**機械式硬碟**時才會自動加 `--ple-io ram`，
而 GX10 是 NVMe（非機械碟），`rotational_disk()` 會回 `None`，所以不會自動加。

| 放哪 | 記憶體 | prompt 速度 |
|---|---|---|
| RAM（`--ple-io ram`） | 多佔 28.8 GB，峰值約 110 GB | **快 9–18%** |
| SSD（預設） | 省下 28.8 GB，峰值約 78–84 GB | 慢 9–18% |

```bash
# 單獨執行
python3 gx10-patch-ple.py strata-iq3_s.json

# 手動移除
python3 - <<'PY'
import json
p = "strata-iq3_s.json"
cfg = json.load(open(p))
if "--ple-io" in cfg["args"]:
    i = cfg["args"].index("--ple-io")
    del cfg["args"][i:i+2]
    json.dump(cfg, open(p, "w"), indent=2)
    print("已移除 --ple-io")
PY
```

> ⚠️ **參數在設定檔 JSON 裡，不在 `run-iq3_s.sh`。** `run-iq3_s.sh` 只是呼叫
> `serve/server.py --config strata-iq3_s.json`。

---

## 四、`gx10-free-mem.sh`（記憶體釋放）

安裝前記憶體被占滿時跑這支。它依序做四件事，最後報告釋放了多少：

1. 卸載 Ollama 的模型（`ollama stop <模型>`）
2. 收掉殘留的 `llama-server` 行程（先 SIGTERM，不行才 SIGKILL）
3. 停用 ollama 服務（避免 `keep_alive` 又抓回 33 GB）
4. 清 page cache（`drop_caches`）

```bash
# 先看它要做什麼，不實際執行
bash gx10-free-mem.sh --dry-run

# 實際執行
bash gx10-free-mem.sh

# 順便收掉某個指定的行程（例如那個吃 6.8 GB 的 python）
bash gx10-free-mem.sh --kill-pid 31775
```

**安全設計**：只會收掉 `llama-server` 與你明確指定的 PID，其他行程只列出、不動作。

**GB10 專用排查法**：`nvidia-smi` 雖然把記憶體顯示成 `[N/A]`，但行程清單看得到真實佔用量，
是查「誰吃掉記憶體」最快的入口：

```bash
nvidia-smi | sed -n '/Processes:/,$p'
```

實測案例（MemAvailable 只有 68.7 / 128 GiB）：`ollama/llama-server` 佔 33,244 MiB、
某個 python 推論服務佔 6,977 MiB，兩者合計就是那 59 GiB 的落差來源。

---

## 五、`gx10-patch-ttft.py`（降低首字等待）

安裝完建議跑一次。它把「讓 agent 續接對話時只讀增量」的引擎參數寫進設定檔。

**為什麼需要**：coding agent 每輪都要重送整段對話歷史。沒有對話快取時，
官方社群實測會「重讀約 90% 的 prompt」；128K context 冷啟動時，
第一個字要等 **80–90 秒**。

```bash
# 設定檔路徑依你的機型調整
python3 gx10-patch-ttft.py /home/kilroy/Strata/strata-iq3_s.json

# 套用後重新啟動服務
systemctl restart strata   # 或 cd /home/kilroy/Strata && ./run-iq3_s.sh
```

| 參數 | 作用 | 記憶體 |
|---|---|---|
| `--prefill auto:32768` | 長 prompt 分塊讀取，社群實測快 21–35%（RAM ≥ 96 GB，GX10 有 128 GB） | 借用 expert cache |
| `--prompt-cache-spread` | checkpoint 分散保存，agent 改寫舊 history 仍能命中 | 同一份預算 |
| `--conversation-cache-mib 8192` | 保留每個 client 的對話 | 主機 RAM 8 GiB |
| `--conversation-cache-slots 4` | 最多 4 個對話同時保留 | — |
| `STRATA_CACHE_MESSAGE_BOUNDARY=1` | 改寫最後一段訊息時保留上一輪邊界 | — |

**安全設計**：

- 先跑一次引擎的 `--help`，確認這個版本真的支援該參數才加入，不支援的會略過
- 改之前自動備份成 `strata-iq3_s.json.bak-ttft`
- 引擎若回報不認得某個選項，`cp` 備份回來即可

⚠ **手動加的引擎參數，之後重跑 `setup.py` 會被清掉**，重跑後要再套一次。

---

---

## 六、`gx10-bench.py`（真實 prompt benchmark）

`gx10-strata-smoke.sh` 的 verify 階段只確認「服務活著、沒有 CUDA error 77、速度達標」，
這個 benchmark 才會**真的送一輪 prompt**，量出這台機器實際跑起來多快，以及答案品質對不對。

適合拿來做兩件事：

1. 驗收：交機之前跑一次，確認效能與品質都過門檻
2. 比較：改完設定（例如套用 `gx10-patch-ttft.py`）再跑一次，看有沒有變快

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

環境變數：`PORT`（預設 8080）、`API_KEY`、`MODEL`、`BENCH_TIMEOUT`（預設 900 秒）。

結束碼：`0` 全部通過、`1` 有項目未達門檻、`2` 服務沒起來。

### 為什麼要先做「Prefill 校準」

短 prompt 的 `tokens ÷ TTFT` 量到的是**固定延遲**（HTTP、排程、CUDA graph）而不是
prefill 速率 —— 20 個 token 的 prompt 花 0.34 秒會顯示成 59 tok/s，但那 0.34 秒
幾乎跟讀 prompt 沒關係。長 prompt 的 TTFT 又本來就會隨長度成長，不能用固定秒數去卡。

所以 benchmark 會先用 3 種長度（64 / 1K / 4K token）配一條線，把兩者拆開：

```
TTFT ≈ 固定延遲 + prompt_tokens / prefill_rate
```

- prefill 門檻用**校準出來的速率**判斷
- TTFT 上限 = `max(固定門檻, 固定延遲 + prompt_tokens / 速率 × 1.5)`
- decode 門檻只在輸出 ≥ 64 token 時才判（輸出太短速率不準）

```bash
python3 gx10-bench.py --no-calibrate   # 跳過校準（退回固定門檻判定）
```

```
== Prefill 校準 ==
  固定延遲（HTTP + 排程 + CUDA graph）：0.321 秒
  實際 prefill 速率：1199 tok/s（門檻 ≥ 800）
  樣本：(163 tok, 0.46s) (2683 tok, 2.56s) (10747 tok, 9.28s)
```

### 怎麼比較兩次結果

```bash
python3 gx10-bench.py --quick --out before.json
# 改設定（例如套 gx10-patch-ttft.py）並重啟服務
python3 gx10-bench.py --quick --out after.json --compare before.json
```

會列出每個案例的 prefill／decode 增減量，正數代表變快。

---

## 七、`gx10-vscode-setup.sh`（接 VS Code）

完整說明在 `files/README-vscode.md`。這支腳本在你的**筆電**上跑，不是 GX10 上。

```bash
# 筆電上先開轉發（視窗留著）
ssh -N -L 8080:127.0.0.1:8080 kilroy@gx10-37a8

# 測一次
bash gx10-vscode-setup.sh --url http://127.0.0.1:8080
bash gx10-vscode-setup.sh --url http://192.168.1.20:8080 --api-key sk-local
```

| 旗標 | 說明 |
|---|---|
| `--url` | 服務位置（預設 `http://127.0.0.1:8080`） |
| `--api-key` | 有設金鑰時要帶 |
| `--model` | 指定模型名稱（不給會自動抓） |
| `--ctx` | 覆寫 context 長度 |
| `--timeout` | 單次請求逾時秒數（預設 60） |

它依序做五件事：

1. `GET /health` —— 服務活著嗎、context 多長
2. `GET /v1/models` —— 模型名稱
3. 送一個串流 chat —— 量首字等待
4. 送一個**帶 tools** 的請求 —— 確認工具呼叫能不能用（決定 agent 能不能改檔）
5. 印出 Cline／Continue／VS Code 原生 Chat 三種設定片段

### Strata 實際支援的端點

| 端點 | 誰在用 |
|---|---|
| `POST /v1/chat/completions` | Cline、Roo Code、Continue |
| `POST /v1/messages` | Claude Code |
| `POST /v1/responses` | Codex CLI |
| `POST /v1/messages/count_tokens` | Anthropic SDK |
| `GET /v1/models`、`/health`、`/props`、`/slots`、`/v1/status`、`/metrics` | 檢查與監控 |

**沒有** `/v1/completions`（FIM）→ VS Code 的行內自動補全不能用。
**沒有** `/v1/embeddings` → codebase indexing 用不了。

### 接上去之前要知道的

| 事項 | 說明 |
|---|---|
| Base URL 要有 `/v1` | Cline／Continue 都會自己補 `/chat/completions`，`http://ip:8080` 會 404，尾斜杠也不行 |
| VS Code 原生的 `url` 要寫完整 | 寫到 `/v1/chat/completions`，且 `toolCalling: true` 否則不會改檔 |
| context 越大每輪越慢 | coding agent 每輪重送整段歷史；日常把 `--context` 降到 `65536` |
| `reasoning_effort` 只收 4 個值 | `none` / `low` / `medium` / `high`，其他值回 HTTP 400 |
| 沒設金鑰時別用主機名稱連 | Strata 的 DNS rebinding 防護會回 403；用 IP 連，或在設定檔加 `api_key` |

---

## 八、`repo-map` skill（讓 agent 每個 session 先讀地圖）

大海撈針的解法不是讓模型更聰明，而是**先給它一張地圖**。

```bash
curl -O https://kilroy-utb.github.io/hub/files/repo-map-install.sh
bash repo-map-install.sh /path/to/your/repo
```

它會做四件事：

1. 裝 `repo-map` skill 到 `~/.hermes/skills`、`~/.codex/skills`、`/workspace/.codex/skills`
2. 在目標 repo 寫 `.github/instructions/repo-map.instructions.md`（`applyTo: "**"`）
   → **VS Code Copilot Chat 每個 session 自動先讀地圖**
3. 在 `AGENTS.md` / `.clinerules` / `.roorules` 追加同一段（不覆蓋既有內容）
4. 產生第一次地圖

地圖分兩層：

| 層 | 內容 | 產生方式 | 成本 |
|---|---|---|---|
| 骨架層 | 目錄樹、行數、符號索引、入口點、TODO、import | 純腳本 | 幾秒、零失真 |
| 語意層 | 每個頂層目錄的「用途 / 關鍵檔案 / 資料流 / 常見問題」 | 呼叫 Strata | 每個目錄一次 |

```bash
python3 ~/.hermes/skills/repo-map/scripts/repo-map.py --init --dir <repo>
python3 ~/.hermes/skills/repo-map/scripts/repo-map.py --refresh --dir <repo>
python3 ~/.hermes/skills/repo-map/scripts/repo-map.py --stats --dir <repo>
```

| 環境變數 | 預設 |
|---|---|
| `REPO_MAP_URL` | `http://gx10-37a8:8080/v1` |
| `REPO_MAP_API_KEY` | 讀 `~/Strata/gx10-api-key.txt` |
| `REPO_MAP_MODEL` | `qwen3.8-flash-next-iq3_s` |

沒有金鑰也能跑：**只有骨架層時，符號索引 + grep 已經能解決大部分「大海撈針」**。

---

## 驗收標準

| 項目 | 門檻 |
|---|---|
| 模型載入 | IQ3_S 載入成功，無 verify 崩潰 |
| Expert 常駐 | 24,576 / 24,576 在 GPU，CPU 不計算 expert |
| Decode（單請求） | ≥ 45 tok/s |
| Prefill（127K prompt） | ≥ 800 tok/s |
| Prefill（8K prompt + 64K 既有 ctx） | ≥ 1,200 tok/s（官方 1,548） |
| **TTFT（2K prompt、無既有 ctx）** | ≤ 3 s（官方 2.18 s） |
| **TTFT（8K prompt + 64K 既有 ctx）** | ≤ 60 s（官方 47.8 s） |
| 記憶體峰值 | ≤ 115 GB（含 `--ple-io ram` 時） |
| 長跑 | 連續 1 小時 mixed workload 無 OOM、無引擎重啟 |
| API | OpenAI 相容 + Anthropic 相容端點皆可用 |

---

## 疑難排解

| 症狀 | 原因 | 處置 |
|---|---|---|
| `illegal memory access was encountered`（CUDA error 77） | issue #3525，特定分支×量化組合 | 換 `IQ2_XS` 重試；仍崩就改用 llama.cpp |
| 速度只有 20 tok/s 上下 | experts 沒全在 GPU，CPU 接手算 | 調 `STRATA_UMA_HEADROOM_GIB`（8→12）讓 cache 更大 |
| `compute_cap` 不是 12.1 | 裝到 x86 版環境 | 確認沒用 x86 的 Docker image |
| 編譯出的引擎跑不起來 | CUDA arch 用錯 | 必須 `-DCMAKE_CUDA_ARCHITECTURES=121`（專案預設是 120） |
| prompt 卡住數十秒 | n-gram 表在機械式磁碟隨機讀 | 加 `--ple-io ram` |
| API 回應慢到不能忍 | 125B 開 xhigh 思考，首 token 中位數 38 秒 | 日常把 `reasoning_effort` 降到 low/off |
| VS Code 端 404 | Base URL 少 `/v1` 或有尾斜杠 | 改成 `http://<主機>:8080/v1` |
| VS Code 端 403 | 伺服器沒設金鑰，又用主機名稱連線 | 改用 IP，或在 `strata-iq3_s.json` 加 `api_key` |
| VS Code 行內補全沒反應 | Strata 沒有 FIM 端點 | 補全改用其他工具，agent 對話才用本地模型 |

---

## 選模型時要一起看的三個維度

| 維度 | 看什麼 | 125B IQ3_S（Strata） | 30B Coder（Ollama） | 27B dense |
|---|---|---|---|---|
| 能力 | Coding 指數 | **73.1**（量化後約 66） | 13.3 | 較低 |
| 每輪等待 | 續接命中後 TTFT | 約 1–2 秒 | 約 1–2 秒 | 約 1–2 秒 |
| 記憶體 | 128K ctx 的 KV cache | **約 0.9 GB（int8）** | 約 6–13 GB | 約 12–17 GB |

→ cache 開好之後，TTFT 這個維度被拉平，差距回到能力與記憶體效率，
**125B 是「能力最高、記憶體最省」的選項**。完整分析見可行性報告 §11.8。

---

## 延伸文件

- [可行性評估報告](./strata-gx10-feasibility.md) —— 記憶體預算、版本比較、能力對照、已知風險
- [落地 Runbook](./strata-gx10-runbook.md) —— 每一階段的完整指令與排查矩陣

---

## 參考資料

Strata：<https://github.com/Niko1221/Strata>

ARM64 PR #3622：<https://github.com/Niko1221/Strata/pull/3622>

GB10 崩潰 issue #3525：<https://github.com/Niko1221/Strata/issues/3525>

真機實測文件（DGX Spark）：<https://github.com/ccatzin-zumwalt/Strata/blob/dgx-spark-gb10-aarch64/docs/DGX_SPARK.md>

NVIDIA Spark 官方支援：<https://build.nvidia.com/spark>
