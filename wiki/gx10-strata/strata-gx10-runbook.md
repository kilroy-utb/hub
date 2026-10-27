# Strata LLM × ASUS Ascent GX10 — 落地 Runbook

日期：2026-10-26 ｜ 階段：**Stage 1 分支 smoke test**（先證明能跑，不追效能）

---

## 0. 已鎖定的決策

| 項目 | 決定 |
|---|---|
| 目標模型 | Qwen3.8-Flash-Next 125B |
| 量化 | **IQ3_S**（官方 `ram_gb` = 62 GB，峰值 ~78–84 GB；唯一在真實 Spark 驗證過的完整 125B 量化） |
| 常駐策略 | 只常駐 125B，27B 先放磁碟 |
| 本階段目標 | 分支能編譯 → 模型能載入 → verify 階段不崩 → 能出 token |
| 官方實測基準 | decode **58.8–66.0 tok/s**，127K prefill **1512 tok/s**（DGX Spark，同款 GB10） |

> 為什麼先 smoke test：GitHub issue **#3525** 至今未關閉（0 則回覆），GB10 上 verify 階段會 `illegal memory access was encountered`（CUDA error 77），
> 在 main v0.1.46.1 與多個社群分支、用 Q2_0 + `--mmap-experts` 都能重現。**崩潰與否跟「分支 × 量化」組合有關**，所以必須現場驗。

> ### 🚀 最快路徑：一鍵安裝腳本
>
> 本專案附 **`gx10-strata-install.sh`**，把下面 Stage A~E 全部包成 7 個步驟，可中途續跑：
>
> ```bash
> bash gx10-strata-install.sh --only 0   # 先只做環境檢查（不動任何東西）
> bash gx10-strata-install.sh             # 確認沒問題就跑完整安裝
> ```
>
> | 步驟 | 內容 | 大約時間 |
> |---|---|---|
> | 0 | 環境檢查（架構／compute_cap／driver／CUDA 13／記憶體／磁碟／CPU 指令集） | 1 分鐘 |
> | 1 | clone 程式碼並鎖定 commit `ce16205d` | 3 分鐘 |
> | 2 | apt 安裝 build-essential／cmake／ninja 等 | 5 分鐘 |
> | 3 | 編譯引擎（帶 121 + ARM NEON 三個必要參數） | 30–60 分鐘 |
> | 4 | `setup.py` 下載模型（~90 GB）並產生設定 | 數小時（看網路） |
> | 5 | 套用 `--ple-io ram` | 秒 |
> | 6 | 建立 systemd 服務並啟動 | 1 分鐘 |
> | 7 | 等服務就緒 + 送測試請求驗收 | 5–20 分鐘 |
>
> 中斷後用 `--resume` 接續；只想重跑某一步用 `--only N` 或 `--from N`。

---

## 1. 兩個候選分支（都鎖定 SHA）

| 候選 | 取得方式 | 基於 | 優勢 | 風險 |
|---|---|---|---|---|
| **A（先試這個）**<br>`ccatzin-zumwalt/Strata` | `dgx-spark-gb10-aarch64`<br>`ce16205d8b72fd489c7a2717f872133dcdbf3bd8` | v0.1.41 (`fb58e0d`) | ✅ `setup.py` **自動偵測 ARM NEON** 並傳 `GGML_CPU_ARM_ARCH`<br>✅ 有 `docs/DGX_SPARK.md` 真機數據<br>✅ IQ3_S 已在 Spark 實測過 | 較舊，缺 v0.2.x 的新功能與修復 |
| **B（第二順位）**<br>`ferstar/Strata` | `gb10-022`<br>`d891f006aaec64024513a1e55856afd992baaa94` | upstream main `011c9e6`（PR #3622 head） | ✅ 對齊最新 main<br>✅ `setup.py` 已修 aarch64 偵測（GPU arch、統一記憶體） | ⚠️ **`setup.py` 沒有 `GGML_CPU_ARM_ARCH` 自動偵測** → 必須手動編譯並帶參數 |

**已知差異（2026-10-26 核對原始碼）**

| 項目 | A（ccatzin） | B（ferstar） |
|---|---|---|
| `setup.py` 的 `arm_cpu_arch()`（讀 `/proc/cpuinfo` 的 `Features`） | ✅ 有 | ❌ 沒有 |
| 自動傳 `-DGGML_CPU_ARM_ARCH=...` | ✅ 有 | ❌ 沒有 |
| `setup.py` 處理 GB10 統一記憶體（`nvidia-smi` 回 `[N/A]`） | ✅ | ✅ |
| `setup.py` 從 `nvidia-smi` 讀 `compute_cap` → `CMAKE_CUDA_ARCHITECTURES=121` | ✅ | ✅ |
| `CMakeLists.txt` 的 `STRATA_CPU_X86` 分流 + `portable.cpp` 頂替 AVX kernel | ✅ | ✅ |

> 為什麼 `GGML_CPU_ARM_ARCH` 重要：GB10 是 big.LITTLE（Cortex-X925 + A725），gcc 的 `-mcpu=native` 在這台機器上找不到特徵，
> 會讓 ggml-cpu **沒有 dot-product 指令**，i-quant 路徑會慢到不能用。原版文件指定 `armv8.6-a+dotprod+i8mm+fp16`。

---

## 2. Stage A — 環境盤點（不需下載模型，約 45 分鐘）

### 2.1 檢查清單

```bash
uname -m                      # 必須是 aarch64
cat /etc/os-release           # 建議 Ubuntu 24.04（官方實測 24.04）
nvidia-smi                    # driver 版本；記憶體可能顯示 [N/A]（GB10 統一記憶體，正常）
nvidia-smi --query-gpu=compute_cap,driver_version --format=csv
free -g                       # 看 MemAvailable，不是看 total
df -h /                       # 模型約需 90 GB（建議放 NVMe）
nproc                         # GB10 = 20 核
ls /usr/local/cuda*/bin/nvcc # 需要 CUDA 13 toolkit
grep -m1 Features /proc/cpuinfo   # 應含 i8mm / asimddp / asimdhp
```

### 2.2 判定標準

| 檢查 | 通過條件 | 不通過怎麼辦 |
|---|---|---|
| `uname -m` | `aarch64` | 確認沒裝到 x86 版的 Docker image |
| `compute_cap` | `12.1` | 若顯示 `12.0` → 裝錯環境，**不要**繼續 |
| driver | ≥ 580（實測 580.173.02 與 595.91.07 都可） | 升級 driver |
| CUDA toolkit | 13.x | 裝 `cuda-toolkit-13-0`（**不要**用 distro 的 12.x） |
| 磁碟 | ≥ 120 GB 可用 | 掛載/清理 |
| `Features` | 含 `i8mm`、`asimddp`、`asimdhp` | 少了就手動指定 `armv8.2-a`（會慢） |

### 2.3 取得分支並編譯

候選 A：

```bash
git clone https://github.com/ccatzin-zumwalt/Strata.git
cd Strata
git checkout ce16205d8b72fd489c7a2717f872133dcdbf3bd8
```

候選 B（**必須手動帶 ARM 參數**）：

```bash
git clone https://github.com/ferstar/Strata.git
cd Strata
git checkout d891f006aaec64024513a1e55856afd992baaa94
```

安裝相依套件：

```bash
sudo apt-get update
sudo apt-get install -y build-essential cmake ninja-build git curl python3 python3-pip
# CUDA 13：從 NVIDIA 官方 runfile 或 apt 倉庫安裝，確認 nvcc --version 是 13.x
```

編譯引擎（候選 A 與 B 通用指令，B 必須手動帶參數）：

```bash
cmake -G Ninja -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DSTRATA_ENABLE_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=121 \
  -DSTRATA_GGML_DIR=third_party/llama.cpp \
  -DGGML_CPU_ARM_ARCH=armv8.6-a+dotprod+i8mm+fp16

cmake --build build --target strata -j$(nproc)
```

**三個不可省略的參數**

| 參數 | 原因 |
|---|---|
| `-DCMAKE_CUDA_ARCHITECTURES=121` | 專案預設是 `120`（RTX 50 系）。GB10 是 **sm_121**，用 120 會編出跑不了的 cubin |
| `-DGGML_CPU_ARM_ARCH=armv8.6-a+dotprod+i8mm+fp16` | `-mcpu=native` 在 big.LITTLE 上失效 → ggml 沒有 dot-product 指令 |
| `-DSTRATA_GGML_DIR=third_party/llama.cpp` | 指定 ggml 來源位置（上游會抓 pinned commit，但本機已有較快） |

> ❌ **不要**用 `-DCMAKE_CUDA_ARCHITECTURES="120;121"`：issue #3525 明確記錄 multi-arch 一樣會崩。

編譯完成後確認版本：

```bash
./build/strata --version
```

### 2.4 讓 setup 檢查這台機器

```bash
python3 setup.py --check
```

重點看它報出來的：
- GPU arch 應為 **121**
- **不應**出現「CPU 沒有 AVX2」之類的 x86 誤判（那是未打 ARM 補丁的訊號）
- RAM 預估應在 120 GB 上下

---

## 3. Stage B — 下載模型（約 90 GB，耗時依網路）

```bash
python3 setup.py \
  --model IQ3_S \
  --context 262144 \
  --kv int8 \
  --parallel 4 \
  --mtp on \
  --cuda 13 \
  --build \
  --data-dir /data/strata \
  --yes
```

| 項目 | 值 | 說明 |
|---|---|---|
| 下載量 | ~84–90 GB | pack 54.8 + PLE n-gram 表 28.8 + MTP ~6 |
| 產出的 config | `Strata-data/.../run-iq3_s.sh` | 之後都用它啟動 |
| `--kv int8` | 256K context 的 KV ≈ 3.5 GB | 官方實測用的設定 |
| `--parallel 4` | 官方實測用的設定 | |
| `--ple-io ram` | **不會自動加上（要手動加）** | GX10 是 NVMe（非機械碟），`rotational_disk()` 回 None → setup 不自動加。手動加可讓 prompt 快 9–18%，記憶體峰值 ~110 GB |

手動加 `--ple-io ram`：**參數在設定檔 JSON 裡，不在 `run-iq3_s.sh`**。
`run-iq3_s.sh` 只是呼叫 `serve/server.py --config strata-iq3_s.json`。所以要改的是 `strata-iq3_s.json` 的 `args` 陣列：

```bash
# 在 Strata 目錄下執行（備份會自動產生 .bak）
python3 /path/to/gx10-patch-ple.py strata-iq3_s.json
```

> 若之後要讓 27B 同時常駐（記憶體會逼近 128 GB 上限），把它移除即可，改回讀 NVMe。

### 3.1 一鍵煙霧測試腳本

本專案附一支可直接在 GX10 上跑的腳本（已做語法檢查）：

```bash
# 放到 GX10 後
chmod +x gx10-strata-smoke.sh gx10-patch-ple.py
bash gx10-strata-smoke.sh env      # 只做環境盤點，不下載
bash gx10-strata-smoke.sh all      # 盤點 → 編譯 → 下載 → 啟動 → 驗證
```

| 參數 | 作用 |
|---|---|
| `env` | 檢查 aarch64 / compute_cap 12.1 / driver / CUDA 13 / 記憶體 / 磁碟 / CPU 指令集 |
| `build` | 用 121 + ARM NEON 三個必要參數編譯引擎 |
| `setup` | 下載 IQ3_S（~90 GB）並自動加上 `--ple-io ram` |
| `serve` | 背景啟動服務，同時盯 error 77 |
| `verify` | 查 error 77、查 experts 常駐、送真實請求量 tok/s、取樣記憶體 |

> `verify` 會量**請求期間的 CPU 忙碌度**：全部 experts 在 GPU 時應接近 0%；
> 若明顯偏高，代表 cache 塞不下、CPU 接手算，速度會掉到 20 tok/s 上下（官方實測 82.9 → 19.7）。

如果 `setup.py` 在 ARM 上有問題（候選 B 已知可能），改用 Docker：

```bash
docker build -t strata .
docker run --rm --gpus all -p 8080:8080 --ulimit memlock=-1 \
  -v strata-data:/data -e MODEL=IQ3_S -e CONTEXT=262144 strata
```

> Docker 版**必須在 GX10 上 build**（x86 build 出來的 image 沒有 GB10 cubin）。build 時不要設 `CUDA_ARCHITECTURES`。

---

## 4. Stage C — 關鍵驗證：verify 階段不能崩

啟動：

```bash
./run-iq3_s.sh
```

### 4.1 判讀 log

**✅ 通過（Smoke test 成功）**

```
strata verify: window up to 2 tokens, 32.2 MiB of device buffers (100% VRAM resident: zero-doorbell graph)
strata verify: captured the 2-token window (upload no error, sync no error)
strata serve: ... generated in ... s (... tok/s)
```

**❌ 踩到 issue #3525**

```
strata verify: captured the 2-token window (upload no error, sync no error)
strata serve: verify: an illegal memory access was encountered
[strata] the engine reported an error: verify: an illegal memory access was encountered
[strata] done: 0 tokens in 0 s (0.0 tok/s) (error, cancel=False)
```

出現這段 = 該分支 × 該量化組合有問題，**引擎會對每個請求重啟並重複同樣錯誤**。這時不要重試，先走 §5 排查。

### 4.1.1 第二道閘門：experts 有沒有全部留在 GPU

即使沒崩潰，也要確認常駐狀態。官方實測：**cache 塞不下全部 24,576 個 experts 時，
CPU 會接手計算，速度從 82.9 tok/s 掉到 19.7 tok/s（慢 4.2 倍）**。

```bash
# 看日誌裡的 expert / cache 行
grep -iE "expert|cache|resident|slot" run-iq3_s.log | head -20
```

判斷方式（由強到弱）：

1. 日誌明寫 **24,576 / 24,576 experts 在 GPU cache** → 通過。
2. 沒有明寫 → 用 **CPU 忙碌度**判斷：發一個請求，同時量 CPU 使用率。
   - 接近 **0%** → experts 全在 GPU，通過。
   - 明顯偏高（> 20%）→ CPU 正在算 expert，需調 `STRATA_UMA_HEADROOM_GIB`（預設 6，可設 8–12）。

```bash
top -b -n 1 | head -15   # 另一個終端機，送請求時看 %Cpu(s)
```

### 4.2 記憶體實測校正（重要）

GB10 上 `nvidia-smi` 可能顯示 `[N/A]` 或回報量與實際不符，所以峰值要自己量：

```bash
# 另一個終端機，跑模型期間每 2 秒記錄
while true; do
  echo "$(date +%T) avail=$(grep MemAvailable /proc/meminfo | awk '{print $2/1024/1024}') GiB" >> /tmp/mem.log
  sleep 2
done
```

| 項目 | 預期 | 不符時的處置 |
|---|---|---|
| 最低 MemAvailable | ≥ 10 GiB | 調 `STRATA_UMA_HEADROOM_GIB=8`（預設 6）留更多給 OS |
| 最低 MemAvailable | < 5 GiB | 從 config 移除 `--ple-io ram`（省 28.8 GB，但 prompt 會慢） |

---

## 5. 若崩潰：#3525 排查矩陣

### 4.3 記憶體被占滿時怎麼查（GB10 專用）

GB10 是統一記憶體，`nvidia-smi` 的 memory.used 顯示 `[N/A]`，但**行程清單還是看得到**，
而且每個行程後面有真實的佔用量 —— 這是查「誰吃掉記憶體」最快的入口：

```bash
nvidia-smi          # 看最下面那欄 GPU Memory
```

實測案例（MemAvailable 只有 68.7 / 128 GiB）：

| 程序 | 佔用 | 處置 |
|---|---|---|
| `ollama/llama-server` | 33,244 MiB | `ollama stop <模型>` 或 `sudo systemctl stop ollama` |
| `python`（另起的推論服務） | 6,977 MiB | 先 `ps -p <PID> -o cmd` 確認是什麼再決定 |
| Xorg / gnome-shell / firefox | 474 MiB | 桌面，可忽略 |

```bash
# 卸載後清 page cache，把可回收的部分還給系統
sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches

# ⚠️ Ollama 的 keep_alive 預設 5 分鐘，模型會自動載回來吃掉那 33 GB。
#    裝 Strata 前要收掉：sudo systemctl disable --now ollama
#    或 export OLLAMA_KEEP_ALIVE=0
```

> 記憶體不足不一定會報錯。最陰險的狀況是 **cache 失駐**：記憶體有壓力時 kernel 會把
> mmap 的 GGUF 頁面踢出來，CPU 就開始接手算 expert，速度從 82.9 掉到 19.7 tok/s。
> 所以啟動後一定要用 `top` 確認 CPU 忙碌度接近 0%。

依序嘗試，每次只動一個變因：

| 順序 | 動作 | 預期 |
|---|---|---|
| 1 | 換候選分支 A ↔ B（重編譯，模型不用重下） | 崩潰與分支相關，換邊可能就過 |
| 2 | 換量化 IQ3_S → **IQ2_XS**（Spark 也有實測數據） | 記憶體更低、且是另一條 pack 路徑 |
| 3 | 換 driver（580.173.02 ↔ 595.91.07 兩版都有人跑通） | — |
| 4 | 拿掉 `--mmap-experts`（改用 RAM arena，記憶體多佔但路徑不同） | 官方文件指出 CPU 算 expert 時全走 ggml NEON |
| 5 | 只編 sm_121（不要 multi-arch） | 已列為必要條件，通常不會變 |
| 6 | 換 llama.cpp 同機當 baseline | 至少確認「模型本身沒壞」 |

> 補充：#3525 提到 PyTorch 的 CUDA 測試在同機正常 → **問題在 Strata 自己的 kernel**，不是 GB10 或 driver 本身。
> 若六步都試完仍崩 → 這條路先擱置，改用 llama.cpp（同 GGUF，DGX Spark 參考值 47 tok/s）。

---

## 6. Stage E — 基準驗證（smoke test 通過後）

用官方同一套工具，數字才可比：

```bash
# llama-benchy 0.4.0
pip install llama-benchy
llama-benchy --model <gguf-path> --ctx 131072 --no-cache -n 128
```

| 指標 | 官方 Spark 實測 | 本機驗收門檻 |
|---|---|---|
| decode（短 prompt） | 58.8–66.0 tok/s | **≥ 45 tok/s** |
| decode（128K context） | 57.4 tok/s | ≥ 45 tok/s |
| prefill（127K prompt） | 1512 tok/s | ≥ 800 tok/s |
| MTP 接受率 | 60/79、13/14 | > 50% |
| 記憶體峰值 | — | ≤ 115 GB |
| 長跑 | — | 連續 1 小時 mixed workload 無 OOM |
| API | OpenAI + Anthropic 相容 | 兩種端點皆可用 |

### 6.1 API 驗證

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"local","messages":[{"role":"user","content":"寫一個 Python 快速排序"}]}'
```

Anthropic 相容端點（供 Claude Code 用）：

```bash
curl http://127.0.0.1:8080/v1/messages \
  -H 'Content-Type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"local","max_tokens":64,"messages":[{"role":"user","content":"hello"}]}'
```

---

## 7. 常駐化（驗收後再做）

```ini
# /etc/systemd/system/strata.service
[Unit]
Description=Strata LLM (Qwen3.8-Flash-Next IQ3_S)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/Strata/Strata-data
Environment=STRATA_UMA_HEADROOM_GIB=8
ExecStart=/opt/Strata/Strata-data/run-iq3_s.sh
Restart=unless-stopped
RestartSec=10
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now strata
```

> 若要開放給其他機器呼叫，`--host 0.0.0.0` 同時務必加 `--api-key`，或用防火牆只開放內網。

---

## 8. 下一步決策點

Stage A 完成後回報這三項，即可決定要不要往下走：

1. `setup.py --check` 的完整輸出
2. `cmake --build` 是否成功、`strata --version` 的結果
3. 從 `ferstar` 或 `ccatzin` 哪個分支開始
