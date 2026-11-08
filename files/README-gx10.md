# GX10 × Strata 工具組

ASUS Ascent GX10（GB10 / 128GB 統一記憶體 / aarch64）跑 Qwen3.8-Flash-Next 125B 的操作腳本。

## 檔案

| 檔案 | 用途 |
|---|---|
| `sync_github_files.sh` | 把本 repo 的 `files/` 目錄同步到本機（新增／更新／刪除都處理） |
| `gx10-verify.sh` | 只做驗收：error 77、experts 常駐、CPU 忙碌度、server 端計時、記憶體、設定檔 |
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
