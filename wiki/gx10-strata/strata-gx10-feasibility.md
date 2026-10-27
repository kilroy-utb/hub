# Strata LLM × ASUS Ascent GX10 (GB10 / 128GB) — 可行性評估與落地規劃

日期：2026-10-26 ｜ 目標機器：ASUS Ascent GX10（NVIDIA GB10, sm_121, 128GB 統一記憶體, aarch64）

---

## 1. 結論

**可行，但不是「下載安裝包就能跑」。** 必須走 **aarch64 社群移植分支 + 在本機源碼編譯**。

- 官方 `main` 分支截至 2026-10-26 **仍只支援 x86-64**，ARM64 移植 PR #3622 自 10-21 起未合併。
- 已有 **3 個社群分支**可實際部署，其中一個附完整真機（DGX Spark）實測數據。
- 有 **1 個仍未關閉的 GB10 GPU 崩潰 issue**（#3525），且崩潰與否跟「分支 × 量化組合」相關，必須現場驗證。
- 真機實測效能優於 llama.cpp 同機對照，**值得做**。

---

## 2. 專案查證

| 項目 | 結論 | 依據 |
|---|---|---|
| Strata LLM | 真實存在，`Niko1221/Strata`，MIT License，C++/CUDA 自研推論引擎 | GitHub API |
| Qwen3.8-Flash-Next | 真實存在，125B 主體 + 51B n-gram + 4B MTP，Qwen3.8-Flash-Next-GSQ-RCO-GGUF | Strata `docs/MODELS.md` |
| 最新版本 | Strata v0.2.6（2026-10-25），engine 0.1.51 / dsv41 0.1.51 | GitHub Releases |
| API | OpenAI 相容 + Anthropic 相容，可用於 Claude Code / Codex CLI / OpenCode | `README.md:165` |

---

## 3. 關鍵障礙：ARM64 支援現況

### 3.1 發行產物沒有 aarch64

v0.2.6 的 Linux 產物只有 `linux-x86_64`：

- `Strata-0.2.6-linux-x86_64.AppImage`
- `strata-engine-0.1.50-linux-x86_64-cuda-cuda13.tar.gz`
- `strata-control-0.1.51-linux-x86_64.tar.gz`

`macos-arm64` 有，**Linux aarch64 沒有** → 官方安裝器在 GX10 上不可用。

### 3.2 main 分支的三處 x86 假設

| 位置 | 問題 | 修法 |
|---|---|---|
| `CMakeLists.txt:183` | 預設 `CMAKE_CUDA_ARCHITECTURES=120`（RTX 50 系）；GB10 是 **sm_121** | 顯式指定 `-DCMAKE_CUDA_ARCHITECTURES=121` |
| `setup.py:1325-1344` | CPU 特性偵測走 x86 CPUID / `/proc/cpuinfo` 的 `flags:` 行 → aarch64 誤判「無 AVX2」 | 移植補丁改讀 aarch64 flags |
| `src/kernels/cpu/*` | AVX-only kernel，aarch64 無對應實作 | 移植補丁改走 ggml-cpu NEON dot |

### 3.3 社群分支現況

| 分支 / PR | 狀態 | 內容 | 實測 |
|---|---|---|---|
| `ferstar/Strata` → `gb10-022`（= PR **#3622** head） | **open**，CI check success，但 `mergeable_state=unstable` | 對齊 upstream main，CMake + setup.py + portable.cpp NEON | GB10 上跑通 IQ3_S，55–59 tok/s |
| `ccatzin-zumwalt/Strata` → `dgx-spark-gb10-aarch64`（PR **#2419** head，closed 未合併） | 社群分支，rebased 至 v0.1.41 | 社群移植鏈 #409 → #901 → #1077 → #2419 | **完整真機數據**（見 §4） |
| `eelgaev/Strata-AC922` → `ac922` | 社群分支，8 stars，2026-10-16 更新 | 最早的 GB10 port（PR #409） | 約 60 tok/s |

移植鏈起點：`PR #409`（eelgaev）→ `PR #901`（githubhjs）→ `PR #1077`（johnlockejrr）→ `PR #2419`（ccatzin-zumwalt，最完整）。

---

## 4. 已有的真機實測數據

來源：PR #2419 的 `docs/DGX_SPARK.md`（單台 DGX Spark，2026-10-08）

### 4.1 Strata（IQ3_S）

配置：256K context、`--parallel 4`、`--kv int8`、`--mmap-experts`、**全部 24,576 個 expert 常駐 cache**

| 指標 | 數值 |
|---|---|
| Decode | **58.8 – 66.0 tok/s** |
| 短 prompt 處理 | 103 – 111 tok/s |
| 127K 長 prompt prefill | **1512 tok/s**（needle-in-haystack 正確召回） |
| 長 prompt 期間 decode | 57.4 tok/s |
| MTP 接受率 | 13/14、60/79 |
| 記憶體 | UD-Q4_K_XL 的 expert cache 全常駐時 71.7 GiB；IQ2_XS 時 33.0 GiB |

### 4.2 同機對照

| 方案 | Decode |
|---|---|
| Strata IQ3_S | 58.8–66.0 tok/s |
| 社群 llama.cpp 參考（UD-IQ4_XS，llama-benchy 0.4.0） | **47 tok/s** |

→ Strata 在統一記憶體環境下**比 llama.cpp 快**。

### 4.3 對照 x86 消費級場景（Strata 官方數據）

| 硬體 | Decode |
|---|---|
| RTX 5070 12GB + Ryzen 5 7600 + 64GB RAM | **約 5 tok/s** |
| RTX 3060 12GB + 46GB RAM | 6–9 tok/s |

GX10 統一記憶體沒有 PCIe 分層瓶頸，效能高出一個數量級。

---

## 5. 記憶體與磁碟預算（128GB 統一記憶體）

### 5.1 Strata 在統一記憶體上的運作方式（DGX_SPARK.md）

- **所有 expert 進 GPU cache** → CPU 完全不參與 expert 計算（GPU 與 CPU 共用同一塊記憶體池）。
- **`--mmap-experts`**：就地讀 GGUF，避免 RAM 裡出現第二份 expert 快取。
- **關閉 KV streaming**：統一記憶體沒有獨立 VRAM 可騰挪。
- Cache 定容 = `MemAvailable − 6 GiB`（`STRATA_UMA_HEADROOM_GIB=N` 可調）。
- ⚠️ `nvidia-smi` 在 GB10 上可能顯示 `[N/A]` 或回報的可用量與實際不符，**定容與實測需在機台上確認**。

### 5.2 模型體積對照

| 模型 / 量化 | 下載量 | **全在 RAM 需求** | expert arena | 峰值估算（含 KV+MTP+OS） | 128GB 判定 |
|---|---|---|---|---|---|
| Q2_0 | 66.4 GB | 48 GB | 34.0 GB | ~70–80 GB | ✅ |
| IQ2_XS | 68.0 GB | 48 GB | 35.5 GB | ~65–75 GB | ✅ 很寬鬆（Spark 實測） |
| IQ3_XXS | 75.8 GB | 60 GB | 42.9 GB | ~80–90 GB | ✅ |
| **IQ3_S** | **83.6 GB** | **62 GB** | **50.3 GB** | **~78–84 GB**（含 `--ple-io ram` 約 ~110 GB） | ✅ **推薦** |
| **IQ1_M（Coder 版）** | **58.4 GB** | **32 GB** | **23.4 GB** | **~50–60 GB** | ✅ **最省，coding 專用** |
| UD-IQ4_XS | 93.7 GB | 48 GB | 59.5 GB | ~95–105 GB | ⚠️ 緊 |
| UD-Q4_K_XL | 111.3 GB | 48 GB | 77.0 GB | 82.2 GiB（Spark 實測，PLE 留 SSD） | ⚠️ 緊 |
| UD-Q5_K_XL / Q6_K_XL / Q8_0 | 158–188 GB | 108–136 GB | 98–128 GB | > 130 GB | ❌ 需退 SSD 分層，速度反而變慢 |

> 數據來源：Strata `setup.py` 的 `MODELS` 表（ferstar/gb10-022 @ d891f00）。`下載量` = download_gb、`全在 RAM 需求` = ram_gb、`expert arena` = arena_gb。
> 峰值估算 = ram_gb + KV cache（256K / int8 ≈ 3.5 GB）+ MTP draft（~6 GB）+ OS/驅動/page cache（~8–12 GB）+ 引擎開銷。
> ⚠️ GB10 上 `nvidia-smi` 可能回報 `[N/A]` 或可用量失真，**峰值必須在機台實測校正**，以 `STRATA_UMA_HEADROOM_GIB` 微調快取上限。

### 5.2.1 PLE n-gram 表是記憶體的關鍵變數（28.8 GB）

官方 `setup.py` 的判斷式（ccatzin 分支實測版本）：

```python
disk = rotational_disk(ple)      # 只看 sysfs queue/rotational，NVMe = 0 → None
if disk:                          # ← 只有機械式硬碟才會走這段
    if ram >= MODELS[model]["ram_gb"] + table_gb + 4:   # table_gb ≈ 28.8 GB
        args += ["--ple-io", "ram"]
```

| 情境 | PLE 位置 | 記憶體 | 代價 |
|---|---|---|---|
| **GX10 + NVMe（預設）** | **SSD**（page cache 放得下就留著） | 不佔常駐 | 隨機讀；SSD 上可接受 |
| 機械式 HDD | RAM（若記憶體夠） | 多佔 28.8 GB | prompt 快 9–18% |
| 手動設 `--ple-io ram` | RAM | 多佔 28.8 GB | prompt 快 9–18%（4K prompt 約 -18% 延遲） |

→ **修正先前判斷**：GX10 出廠是 NVMe（非機械碟），`rotational_disk()` 回 `None`，
**setup 不會自動加 `--ple-io ram`**，PLE 表留在 SSD。官方 Spark 實測（UD-Q4_K_XL）明確寫
「the 28.8 GB PLE table stays on the SSD」。所以 IQ3_S 的記憶體峰值是 **~78–84 GB**，不是 85–90 GB。

→ **建議：主動加上 `--ple-io ram`**。IQ3_S（62 + 28.8 + KV 3.5 + MTP 6 + OS 10 ≈ 110 GB）在 128 GB 內還有餘裕，
換取 prompt 快 9–18%。若後續要塞 27B 常駐，再把它改回 SSD。

### 5.3 磁碟

下載合計（IQ3_S）：pack 54.8 GB + PLE n-gram 表 28.8 GB + MTP draft ~6 GB ≈ **90 GB**（官方 `download_gb` 記為 83.6 GB）。GX10 出廠 4TB NVMe，充裕。
若要再放 27B（Q4_K_M ~17 GB），磁碟共需 ~110 GB，仍有大量餘裕。

### 5.4 GX10 該用哪個版本（決策）

篩選條件依序為：**① 有沒有在真實 Spark 上跑過** → ② 速度 → ③ 品質 → ④ 記憶體餘裕。

| 量化 | 真機驗證 | decode | 品質 | 常駐 RAM | expert arena | 下載 | 判定 |
|---|---|---|---|---|---|---|---|
| **IQ3_S** | ✅ **已驗證**（2026-10-08，256K ctx／`--parallel 4`／`--kv int8`） | **58.8–66.0** | **最高**（top-token 87.69%，setup 註「matches the full model」） | 62 GB | 50.3 GB | 83.6 GB | 🥇 **本專案採用** |
| IQ2_XS | ✅ 已驗證（完整 benchmark 表，128K ctx） | 55.7–63.7 | 次之 | 48 GB | 33.0 GiB | 68.0 GB | 🥈 備援（省記憶體時） |
| UD-IQ4_XS | ❌ 未在 Spark 跑過 | 估 38–45 | 高（93.09%） | 48 GB | 59.5 GB | 93.7 GB | 🥉 有餘裕可再試 |
| UD-Q4_K_XL | ✅ 已驗證（262K ctx） | 38.4–41.5 | 高（近 4-bit） | 48 GB | 71.7 GiB | 111.3 GB | ⚠️ 慢 3–4 成，且 PLE 在 SSD |
| IQ3_XXS | ❌ 未驗證 | 估 45–55 | 中 | 60 GB | 42.9 GB | 75.8 GB | ⚠️ 品質不如 IQ3_S |
| IQ1_M（Coder 專用） | ❌ 未驗證 | 估 45–55 | 無公開 benchmark | 32 GB | 23.4 GB | 58.4 GB | ⚠️ 最省但要另外驗證品質 |
| Q2_0 | ⚠️ pack 為 x86-only | 最快 | 低（80.60%） | 48 GB | 34.0 GB | 66.4 GB | ❌ 品質跌幅太大 |
| UD-Q5/Q6_K_XL、Q8_0 | ❌ | — | 最高 | 108–136 GB | 98–128 GB | 158–188 GB | ❌ **記憶體不夠** |

**結論：選 IQ3_S。**

1. **它是唯一被真機完整驗證過「完整 125B」的量化**，而 IQ3_S 正是 setup.py 唯一標註
   「matches the full model on the published benchmarks」的一級。
2. **速度最快**：58.8–66.0 tok/s，且在 256K context、4 併發下量測（IQ2_XS 的數字是 128K／單請求）。
3. **記憶體夠**：62 GB 常駐 + 50.3 GB arena，峰值 ~78–84 GB，128 GB 還剩 40+ GB 可留給 PLE、KV 與其他程式。
4. **品質最高**：相較 UD-Q4_K_XL（38–41 tok/s）快 1.5 倍，品質差距只在 87.69% vs 93.09% 這個量級。

**避坑重點（來源：DGX_SPARK.md 的 CPU fallback 實測）**

> 當 expert cache 塞不下全部 24,576 個 experts，CPU 就會接手計算。
> 實測：2,048 slots（每層約 22/29 個 expert 由 CPU 算）→ **19.7 tok/s**；
> 全部留在 GPU → **82.9 tok/s**。**差 4.2 倍。**

→ GX10 上 IQ3_S 的 arena 只要 50.3 GB，遠小於 128 GB，**理論上必然放得下**；
但啟動後必須確認日誌顯示 24,576 個 experts 全部 GPU 常駐，若不是，`--expert-cache auto` 的定容就有問題
（`MemAvailable − 6 GiB` 在 UMA 上要靠 `STRATA_UMA_HEADROOM_GIB` 校正）。

---

## 6. 已知風險

| # | 風險 | 等級 | 說明 / 緩解 |
|---|---|---|---|
| R1 | **GB10 GPU 崩潰**：issue #3525（仍 open，0 回覆）verify 階段 `illegal memory access`（CUDA error 77），main v0.1.46.1 與社群分支皆可重現（Q2_0 + `--mmap-experts`） | **高** | 但 PR #2419 用 IQ3_S 跑通 → 疑似與特定分支/量化組合相關。**步驟一必須先做 smoke test** |
| R2 | **官方不支援**：ARM64 PR #3622 未合併，`mergeable_state=unstable` | 中 | 走社群分支；記錄 commit SHA 以便回滾 |
| R3 | **上游迭代快**：v0.2.6 已到，社群分支 rebase 成本高（#2419 已 rebase 過一次 v0.1.41） | 中 | 鎖定 commit；不追上游 |
| R4 | **記憶體定容不準**：GB10 的 `cudaMemGetInfo` 只報 free RAM、不含 page cache | 中 | 依 `MemAvailable` 定容並保留 6 GiB headroom；必要時 `STRATA_UMA_HEADROOM_GIB` 調整 |
| R5 | 依賴環境：CUDA 13 toolkit + driver 580+ + Ubuntu 24.04 + aarch64 原生編譯 | 中 | 走 Docker（`nvidia/cuda:13.0.0-devel-ubuntu24.04` 有 arm64 版）可隔離 |
| R6 | Strata 的分層賣点在 GX10 上**退化**（無獨立 VRAM） | 低 | 反而是優勢：全常駐、零 PCIe 傳輸 |
| R7 | **expert cache 放不下 → CPU 接手算 expert → 慢 4.2 倍**（82.9 → 19.7 tok/s，官方實測） | **高** | 啟動後確認日誌顯示 **24,576 個 experts 全部 GPU 常駐**；不足時調 `STRATA_UMA_HEADROOM_GIB` 讓 cache 更大 |
| R8 | 燒腦思考延遲：125B 開 xhigh 思考，首 token 中位數 38 秒、長推理可達 21 分鐘 | 中 | 日常把 `reasoning_effort` 設 low/off；預留「回答前先想」的使用習慣 |

---

## 7. 落地步驟（分支選定後鎖定）

> 可直接執行的腳本：`gx10-strata-smoke.sh`（一鍵 env→build→setup→serve→verify）與
> `gx10-patch-ple.py`（把 `--ple-io ram` 寫進設定檔）。步驟細節見 `strata-gx10-runbook.md`。

1. **環境盤點**（機台）：OS 版本、`nvidia-smi`（driver/GB10 記憶體回報）、`free -g`、NVMe 可用空間、CUDA 版本、網路（模型下載）。
2. **取得程式碼**：clone 選定分支（鎖定 SHA），記錄 base commit。
3. **編譯 engine**：`CMAKE_CUDA_ARCHITECTURES=121`、`GGML_CPU_ARM_ARCH=armv8.6-a+dotprod+i8mm+fp16`、`STRATA_ENABLE_CUDA=ON`、CUDA 13。
4. **下載模型**：IQ3_S pack（54.8GB）+ PLE shard 2（29.6GB）+ MTP draft（~6GB）。
5. **Smoke test（關鍵閘門）**：以 `--expert-cache auto --mmap-experts --no-pool --max-context 4096` 起服務，送一個 20-token 請求 → **確認不再出現 error 77**。若崩潰，立即切換分支或改用 IQ2_XS 重試（記錄是哪個組合）。
6. **常駐確認（第二道閘門）**：確認日誌顯示 **24,576 個 experts 全部在 GPU cache**、CPU 閒置（不是 2,048 slots 的 fallback 模式），否則速度會直接掉到 20 tok/s 上下。
7. **效能驗證**：IQ3_S，256K context、`--kv int8`、`--parallel 4`、`--ple-io ram`，量 decode / prefill / MTP 接受率，對照 §4.1 的 58.8–66 tok/s。
8. **長上下文驗證**：127K needle-in-haystack（官方實測 1512 tok/s prefill）。
9. **API 層驗證**：OpenAI 相容 `/v1/chat/completions` + Anthropic 相容端點，接 Claude Code / Codex CLI 實測。
10. **常駐化**：systemd 或 Docker（`--restart unless-stopped`、`--ulimit memlock=-1`）。

---

## 8. 驗收標準

| 項目 | 門檻 |
|---|---|
| 模型載入 | IQ3_S 載入成功，無 verify 崩潰（error 77） |
| Expert 常駐 | 日誌顯示 **24,576 / 24,576 experts 在 GPU**，CPU 不計算 expert |
| Decode（單請求） | ≥ 45 tok/s（官方實測 58.8–66 的下限折讓） |
| Prefill | ≥ 800 tok/s（127K 長 prompt） |
| 記憶體峰值 | ≤ 115 GB（含 `--ple-io ram` 時）；不含則 ≤ 90 GB |
| 長跑 | 連續 1 小時 mixed workload 無 OOM / 無引擎重啟 |
| API | OpenAI 相容 + Anthropic 相容端點皆可用 |

---

## 9. 開始前需確認

1. 是否能 SSH 進入 GX10？OS 版本為何？（文件建議 Ubuntu 24.04，官方實測為 24.04）
2. GPU driver 版本 ≥ 580？CUDA toolkit 是否已裝？（官方實測 driver 580.173.02 / CUDA 13.0）
3. 網路能否直連 HuggingFace 下載約 90 GB 模型檔？
4. NVMe 磁碟可用空間？
5. 目標只有本機自用，還是要開放給其他機器呼叫？

---

## 10. 替代方案（誠實評估）

Strata 在 GX10 上**不佔優於成熟方案**的唯一領域，是「離散 GPU + 分層」這類消費級場景。統一記憶體環境下：

- **llama.cpp**：DGX Spark 官方支援最好，Qwen3.8-Flash-Next GGUF 齊全（含 MTP + ngram 推測解碼）。同機參考值 47 tok/s（UD-IQ4_XS）—— **低於 Strata 的 58.8–66 tok/s**，但支援成熟度、升級路徑、穩定性都更好。
- **vLLM**：支援 sm_121 / Blackwell，但 Qwen3.8-Flash-Next 這種新架構的支援度需另行驗證。

**建議：把 llama.cpp 當作 baseline 一起跑，做 A/B 對照。** Strata 的增量價值在統一記憶體下主要體現在 MTP 接受率、prefill 速度與 API 層，而非峰值 decode。

---

## 11. 能力對照：125B Flash-Next vs 27B vs 30B Coder

### 11.1 規格差異（決定速度與記憶體）

| 項目 | Qwen3.8-Flash-Next 125B | Qwen3.8-27B | Qwen3-Coder-30B-A3B |
|---|---|---|---|
| 架構 | MoE + n-gram(Engram) + MTP | Dense（GDN/QSA 混合注意力） | MoE 8-of-128 experts |
| 總量 / 啟用量 | 125B / **6B active** | 27B / **27B active** | 30.5B / **3.3B active** |
| 上下文 | 256K | **1M** | 262K |
| 視覺 | 有 | 有 | 無 |
| 思考模式 | 有 | off / low / medium / xhigh | **僅非思考** |
| 授權 | qwen-community-1.0 | Apache 2.0 | Apache 2.0 |
| 狀態 | Qwen4 架構預覽版（非 GA） | GA | **2026-10-01 已棄用** |

### 11.2 程式能力：同一把尺（Artificial Analysis v4.1.1 官方測）

| 指標 | Flash-Next 125B | 27B | 30B Coder |
|---|---|---|---|
| AA Coding Index | **73.1** | 68.1 | 13.3 |
| AA Intelligence Index | **39.8** | 34（xhigh）/ 28（medium）/ 26（low）/ 20（off） | 9.6 |
| AA Agentic Index | **53.6** | 42.9 | — |
| GPQA Diamond（研究所級理） | **92.3%** | 89.2%（廠商） | 51.6% |
| HLE（人類最後考試） | **38.0%** | 30.8%（廠商） | 3.8% |
| SciCode（科學寫碼） | **50.6%** | — | 27.8% |
| AA-LCR（長文推論） | **79.7%** | — | 32.7% |
| AA-Omniscience 準確率 | — | — | 16.4% |
| Terminal-Bench 2.1 / 4.0 | **86.1% / 25.3%** | — | Hard 15.2% |
| SWE-bench | Pro 62.5 | Pro 61.7 | Verified 51.6 |
| LiveCodeBench | 91.9（v6） | 90.3（v6） | 40.3 |

#### ⚠️ 但這個比較有一個不對稱，必須說清楚

| | Flash-Next 125B | 30B Coder |
|---|---|---|
| 思考模式 | **開**，預設 `reasoning_effort` = **xhigh** | **僅非思考**（沒有 thinking block） |
| 隱私 | — | — |

上面那份表的本質是「**允許長思考的模型**」對上「**完全不會思考的模型**」。30B Coder 不是比較弱，
而是**被拿掉思考能力**。同一個問題，125B 會先寫 2,000～22,000 個 token 的推理草稿再給答案，
30B Coder 直接給答案 —— 所以差距被機制放大，不全是參數量差距。

**代價（這是實際使用上最該注意的）：**

- AA 評測平均要吃 **2 億個 output token**（中位數 1.1 億），AA 直接標記 125B「very verbose」。
- **首 token 延遲中位數 38 秒**；實際案例曾出現 **21 分鐘、22,000 個 reasoning token** 的推理。
- 換算到 GX10：60 tok/s 跑完 22,000 token 思考 ≈ **6 分鐘等待**。
- 因此日常用要自己把 `reasoning_effort` 降到 low/off。27B 從 xhigh 34 掉到 off 20（**−41%**）；
  125B 同理會掉一大截，代表**「開思考的 125B」跟「日常的 125B」是兩種東西**。

#### 量化後的有效分數（把 §11.4 疊進來）

125B 在 GX10 上只能跑 IQ3_S（top-token 一致率 **87.69%**、KL 0.144），等效於把分數再打折：

| | 全精度 AA | IQ3_S 實際估算 |
|---|---|---|
| Coding Index | 73.1 | **~66** |
| Intelligence Index | 39.8 | **~36** |

→ 拿「66 / 36」去對 30B Coder 的「13.3 / 9.6」，差距仍然很大；但要拿去對 27B 的「68.1 / 34」，
就變成同一量級（甚至思考模式一開就反超）。

### 11.3 Agent / Repo 級能力（官方 model card，廠商自測）

| 指標 | Flash-Next 125B | 27B | 差距 |
|---|---|---|---|
| DeepSWE 1.1 | **58.7** | 42.2 | +16.5 |
| SWE-bench Pro | **62.5** | 61.7 | +0.8 |
| SWE-bench Multilingual | **81.0** | 73.8 | +7.2 |
| NL2Repo-Bench | **48.1** | 42.3 | +5.8 |
| JobBench | **55.7** | 33.4 | +22.3 |
| Toolathlon | **73.5** | 67.1 | +6.4 |
| AndroidWorld | **84.5** | 71.0 | +13.5 |
| Agents' Last Exam | **24.3** | 20.4 | +3.9 |

> 官方自測數字，可能偏樂觀；但 27B 與 125B 用同一套 harness，對「誰比較強」的相對比較有效。

### 11.4 量化失真對能力的影響（關鍵）

AA 的 73.0 / 68.1 是**全精度**成績。GX10 上實際能跑的量化會打折：

| 量化 | 記憶體 | 與 Q8_0 的一致率 | 平均 KL |
|---|---|---|---|
| UD-IQ4_XS | 93.7 GB | 93.09% | 0.056 |
| **IQ3_S（125B 甜蜜點）** | **54.8 GB** | **87.69%** | **0.144** |
| Q2_0 | 37.6 GB | 80.60% | 0.315 |
| 27B Q4_K_M | ~17 GB | ~98%（近似全精度） | 極低 |

→ 125B 跑 IQ3_S 時，AA Coding Index 大約會從 73 掉到 **66 上下**，與 27B 的 68.1 變成同一個量級。**這是「選 125B 還是 27B」真正的分水嶺，不是 3 GB/s 的速度差。**

### 11.5 GX10 上的實際速度（全部為 GB10 實測）

| 模型 / 量化 | active | 每 token 位元組 | 理論上限 | **實測 decode** | 32K context |
|---|---|---|---|---|---|
| **Qwen3.8-Flash-Next 125B** IQ3_S（Strata） | 6B | ~3.0 GB | ~90 tok/s | **58.8–66.0 tok/s** | — |
| Qwen3.8-Flash-Next 125B IQ2_XS（Strata） | 6B | ~2.0 GB | ~135 tok/s | 55.7–63.7 tok/s | 56.2–56.4（64K ctx）|
| Qwen3.8-Flash-Next 125B Q4_K_M（llama.cpp） | 6B | ~3.6 GB | ~75 tok/s | 31.8 tok/s | 23.2 |
| **Qwen3-Coder-30B-A3B** Q8_0（llama.cpp） | 3.3B | ~3.7 GB | ~74 tok/s | **60.0–61.0 tok/s** | 27–44 |
| Qwen3-Coder-30B-A3B Q4_K_M（llama.cpp） | 3.3B | ~2.0 GB | ~135 tok/s | ~107 tok/s（估算） | 58.9 |
| Qwen3-Coder-Next 80B-A3B Q4_K_M（llama.cpp） | 3B | ~2.0 GB | ~135 tok/s | 47.5 tok/s | 26.2 |
| **Qwen3.8-27B** dense Q4_K_M（llama.cpp） | 27B | ~15.5 GB | ~17 tok/s | **7–11 tok/s** | — |
| Qwen3.8-27B dense（llama.cpp + DFlash 推測解碼） | 27B | ~15.5 GB | — | 24–40 tok/s | — |
| Qwen3.8-27B dense（vLLM + MTP） | 27B | ~15.5 GB | — | ~30 tok/s | — |

**兩個關鍵結論：**

1. **125B vs 27B dense：125B 確定快得多。** 27B dense 每 token 要讀全部 27B 權重，GB10 上實測只有 **7–11 tok/s**（加推測解碼 24–40）。125B 是 59–66 tok/s → **快 1.5–6 倍**。這是 MoE 在頻寬受限裝置上的結構性優勢，沒有例外。

2. **125B vs Qwen3-Coder-30B-A3B：打平，不是「快很多」。**
   - 30B Coder Q8_0（llama.cpp 官方 DGX Spark bench）：**61 tok/s**
   - 125B IQ3_S（Strata 真機）：**58.8–66.0 tok/s**
   - → **同一個量級。** 先前「30B Coder 最快」的說法來自頻寬算式（3.3B active 理論上該更快），
     但實測顯示 llama.cpp 對這個模型的效率高達頻寬上限的 ~81%，抵銷了 active 參數的差距。
   - ⚠️ 但 **30B Coder 是 Q8_0（近乎無損），125B 是 IQ3_S 3.5-bit（top-token 一致率 87.7%）**。
     同等速度下，30B Coder 的**品質保真度遠高於** 125B。真正贏 125B 的是**能力**（AA Coding Index 73.1 vs 13.3），不是速度。

3. **Strata 的長 context 與併發優勢**：
   - 30B Coder 在 32K context 掉到 **27–44 tok/s**；Strata IQ2_XS 在 64K context 仍有 **56.2–56.4 tok/s**
     （差異部分來自量化，方向明確）
   - llama-batched-bench（llama.cpp 維護者，2026-02）：30B Coder Q8_0 在 1/2/4/8/16/32 併發下
     每請求 **53.5 / 31.4 / 20.9 / 15.0 / 10.3 / 6.8 tok/s**；Strata 支援 `--parallel 4`。

### 11.6 結論

1. **純 coding 強度：125B > 27B >> 30B Coder**。30B Coder 在 AA Coding Index 只有 13.3、Intelligence Index 9.6，
   且**只會非思考**、2026-10-01 已棄用，作為主力 agent 應退場。
2. **在 GX10 上，125B 同時更快**，125B 是唯一「又快又強」的選項。
3. **但三個要扣分的點**：量化失真（IQ3_S 掉 ~7 分）、授權較嚴、125B 是非 GA 預覽版。
4. **務實組合**：125B 當主力 coding agent，27B 留著當長文件（1M ctx）、視覺與穩定後備。**但兩者不可同時常駐** —— 125B IQ3_S 執行時已佔 ~78–84 GB（加 `--ple-io ram` 約 ~110 GB），再加 27B Q4_K_M（~18 GB + KV）會超過 128GB。實務上採「磁碟各存一份 + 開機選常駐哪一個」，或靠 SSD 分層輪替（會慢）。

### 11.7 Strata 內建的 Coder 版：IQ1_M（256/512 experts）

Strata 的 `setup.py` 除了主模型，還提供 **Coder 版**（對應 `ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF`）：

| 項目 | IQ1_M（Coder） | IQ3_S（完整 125B） |
|---|---|---|
| 保留的 experts | **256 / 512**（保留 code、tools、vision 會用到的那半） | 全部 24,576 |
| 儲存格式 | 與 IQ3_S 同（3.5-bit） | 3.5-bit i-quant |
| 下載量 | **58.4 GB** | 83.6 GB |
| 全在 RAM 需求 | **32 GB** | 62 GB |
| 峰值估算 | **~50–60 GB** | ~78–84 GB |

→ 若最終用途以 coding 為主，這個版本用**一半不到的記憶體**就能跑，且專門保留程式相關的 experts。
但官方沒有公布 IQ1_M 的獨立 benchmark 分數（它的量化等同 IQ3_S，差在「少了那半 experts」），
**品質需實測**才能跟 27B／125B 比較。

---

## 12. Strata 對 GX10 到底值不值（2026-10-27 誠實評估）

### 12.1 關鍵前提：你的 GX10 就是 DGX Spark

公開實測明言：**「DGX Spark 與其他 GB10 機器（ASUS Ascent GX10、Dell Pro Max GB10、MSI EdgeXpert、Gigabyte AI TOP Atom、Lenovo ThinkStation PGX）的公開結果沒有可察覺的 LLM 速度差異。」**

→ 所有 DGX Spark 的實測數字可直接套用到你的 GX10。

### 12.2 瓶頸是 273 GB/s 頻寬，不是引擎

GB10 的 LPDDR5X 只有 273 GB/s。125B 是 6B active 的 MoE，每個 token 只讀約 3 GB 權重 → 理論上限約 90 tok/s。

| 引擎 / 量化（同一台 GB10） | decode | 佔理論上限 |
|---|---|---|
| Strata IQ3_S（社群 port 真機） | **58.8–66.0 tok/s** | 65–73% |
| Strata IQ2_XS | 55.7–63.7 tok/s | 62–71% |
| Strata UD-Q4_K_XL | 38.4–41.5 tok/s | 43–46% |
| llama.cpp stock b2276（APEX MIDDLE） | 31.1 tok/s | 35% |
| llama.cpp UD-IQ1_S（176.94B） | 34.5 tok/s | 38% |
| llama.cpp Q4_K_M（willitrunai） | 31.8 tok/s | 35% |
| llama.cpp UD-IQ4_XS（同 Strata 文件） | 47 tok/s | 52% |
| llama.cpp fork IQ4_XS + MTP | 45.97 tok/s（code） | 51% |
| SGLang fork（+ FR-Spec hot-token map） | **60.0 tok/s（code）** | 67% |

**結論：引擎效率確實有 1.3–2× 的空間，Strata 在這裡是真的有增量**，不是玄學。
但要注意 **Strata 的 IQ3_S 是 3.5-bit i-quant，llama.cpp 讀不了 Strata 的 `experts.bin`**（兩邊是不同的檔案格式），
要做真正 apples-to-apples 必須兩套都下載（各 ~90 GB）。

### 12.3 這個增量在你的工作負載上有用嗎？

| 工作負載 | 差距 | 有意義？ |
|---|---|---|
| 單次問答、讀一段回覆 | 31 → 60 tok/s | ❌ 英文閱讀速度約 5–7 tok/s，31 tok/s 早就過剩 |
| **Agentic coding**（實測平均 4,429 output tokens / task） | 每 task 從 ~2.4 分鐘 → ~1.2 分鐘 | ✅ **有意義**，長 session 累積明顯 |
| 長 prompt prefill（32K） | llama.cpp 600–2,333 tok/s vs Strata 1,512 tok/s | ❌ 沒有優勢，llama.cpp 可能更快 |
| 多人並行 / 服務化 | llama.cpp 受限於 `--parallel 1`（見 §12.5） | ✅ Strata 支援 `--parallel 4` |
| 長 context（256K+）、視覺 | SGLang fork 支援 524K + vision | ❌ Strata IQ3_S 只有 256K |

### 12.4 Strata 的真實成本

| 成本 | 細節 |
|---|---|
| 必須自己編譯 | 官方無 linux-aarch64 產物；PR #3622 自 2026-10-21 未合併 |
| 分支要挑 | 3 個候選，ARM 處理程度不一（見 runbook §1） |
| 未關閉的崩潰 issue | #3525 `illegal memory access`，0 回覆，main v0.1.46.1 也能重現 |
| 單人專案 | `Niko1221/Strata`，MIT，社群規模小，API 層與工具相容要自己測 |
| 模型檔綁定 | 只能用 Strata 自己的 pack 格式，不能與 llama.cpp 共用 GGUF |

### 12.5 別忘了 llama.cpp 也有坑

公平起見，llama.cpp 在這個架構上也有明確的坑：

- **只能用 f16 KV**：`q8_0` KV 在此架構會 crash 或輸出亂碼（APEX GGUF README）
- **`--parallel 1`**：QSA sparse-attention indexer 有自己的 KV cache，多 slot 會 desync → `GGML_ASSERT` abort
- **採樣參數必須照廠商**：`temp 1.0 / top_k 20 / top_p 0.95 / min_p 0`
- **`reasoning_effort` 不接受 `high`**：會拋例外回 HTTP 500。**預設用 high 的 agent harness 會 100% 失敗**
- 128K 以上的長 context 仍需未合併 PR

### 12.6 結論與建議順序

**「讓 125B 在 GX10 上跑起來」→ Strata 沒有意義。**
NVIDIA 官方有 llama.cpp playbook（`build.nvidia.com/spark`，`-DCMAKE_CUDA_ARCHITECTURES=121a-real`），30 分鐘能跑，
且已有實測：**agentic coding 9/9 tasks、154/154 tests 全過**（stock llama.cpp）。

**「讓 125B 在 GX10 上跑最快」→ Strata 有意義（decode 1.3–2×），但要接受移植成本。**

建議順序：

1. **先跑 llama.cpp**（NVIDIA 官方路徑）→ 當 baseline，同時把 27B 與 125B 都架起來，確認日常真的夠快
2. **量測你的真實負載**：如果 agentic coding session 的等待時間有感，再往下走
3. **要快就走 SGLang fork**（實測 code 60 tok/s、524K ctx、vision 開著），成本比移植 Strata 低
4. **Strata 留到最後**：當作「已經確認需要那 1.3–2×」時的執行方案
5. **vLLM / TRT-LLM 是第四條路**：NVIDIA 官方支援，CES 2026 宣布 NVFP4 + speculative decoding 有 2.6× 加速
