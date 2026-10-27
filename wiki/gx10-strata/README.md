# GX10 × Strata LLM 部署工具組

在 **ASUS Ascent GX10**（NVIDIA GB10、128GB 統一記憶體、aarch64）上，用開源推論引擎 **Strata LLM** 跑 **Qwen3.8-Flash-Next 125B**（量化 IQ3_S）。

這頁是三支程式的操作手冊：怎麼下載、怎麼執行、每個參數是什麼、怎麼判斷成功或失敗。

---

## 三支程式各做什麼

| 程式 | 角色 | 什麼時候跑 |
|---|---|---|
| [`gx10-strata-install.sh`](#一gx10-strata-installsh安裝) | **安裝**：環境檢查 → 取得程式碼 → 編譯引擎 → 下載模型 → 產生設定 → 開 systemd → 驗收 | 一開始跑一次 |
| [`gx10-strata-smoke.sh`](#二gx10-strata-smokesh測試) | **測試**：檢查崩潰、查 experts 常駐、量 tok/s、量 CPU 忙碌度、取樣記憶體 | 想確認效能或懷疑退化時跑 |
| [`gx10-patch-ple.py`](#三gx10-patch-plepy設定調整) | **小幫手**：把 `--ple-io ram` 寫進設定檔（安裝腳本第 5 步會自動呼叫） | 通常不用手動執行 |

> 這三支都是**純腳本**，不取代 Strata 官方的 `setup.py`。安裝本身仍是 `git clone` + `cmake` + `setup.py`，腳本只是把參數填好、把錯誤判斷寫清楚。

---

## 快速開始（最短路徑）

在 GX10 上：

```bash
# 1. 下載三支程式
curl -O https://kilroy-utb.github.io/hub/files/gx10-strata-install.sh
curl -O https://kilroy-utb.github.io/hub/files/gx10-strata-smoke.sh
curl -O https://kilroy-utb.github.io/hub/files/gx10-patch-ple.py
chmod +x gx10-strata-*.sh gx10-patch-ple.py

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

### 7 個步驟

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

### 參數

```bash
bash gx10-strata-install.sh                # 全部 7 步
bash gx10-strata-install.sh --only 0       # 只跑某一步
bash gx10-strata-install.sh --from 3       # 從第 3 步開始
bash gx10-strata-install.sh --skip 6,7     # 跳過指定步驟（逗號分隔）
bash gx10-strata-install.sh --resume       # 自動跳過已完成的步驟
bash gx10-strata-install.sh --no-systemd   # 不建立 systemd（手動啟動用）
bash gx10-strata-install.sh --diag         # 只做記憶體診斷：誰占掉了記憶體
```

`--resume` 靠 `$STRATA_DIR/.install-state/stepN.done` 標記檔判斷中斷在哪。

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

## 驗收標準

| 項目 | 門檻 |
|---|---|
| 模型載入 | IQ3_S 載入成功，無 verify 崩潰 |
| Expert 常駐 | 24,576 / 24,576 在 GPU，CPU 不計算 expert |
| Decode（單請求） | ≥ 45 tok/s |
| Prefill（127K prompt） | ≥ 800 tok/s |
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
