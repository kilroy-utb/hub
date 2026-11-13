# codex-setup-linux.sh — 一般 Linux 安裝 Codex CLI

## 透過 Tailscale 連接 GX10 Strata（2026-11-13.4）

參考同倉庫的 `codex-setup-windows.ps1` 與 `codex-setup-wsl.sh`。
此流程不需要 `codex login`，也不使用 OpenAI 服務的金鑰。

```bash
curl -fLO https://kilroy-utb.github.io/hub/files/codex-setup-linux.sh
bash codex-setup-linux.sh --strata
export PATH="$HOME/.local/bin:$PATH"
read -rsp "Strata API Key: " STRATA_API_KEY; echo; export STRATA_API_KEY
codex
```

`--strata` 會從 `tailscale status --json` 找出名稱含 GX10 的唯一主機，使用其 Tailscale IPv4。
找不到、離線或有多台時會停止，不會任選其他在線電腦。此時可手動指定：

```bash
bash codex-setup-linux.sh --strata --gx10-ip 100.80.1.2 --gx10-port 8080 --model your-model
```

請將範例 IP、port 與模型替換為自己的設定。預設沿用參考腳本的 port `8080`、
模型 `qwen3.8-flash-next-iq3_s`；這不是對目前 GX10 已載入模型的自動確認。

- 固定安裝到 `~/.local`，不修改 npm 全域 prefix；補上 `.bashrc`、`.profile` 及實際 Bash 登入檔的 PATH。
- 設定位置尊重 `CODEX_HOME`，未設定時使用 `~/.codex/config.toml`。
- 原設定先備份為 `config.toml.bak.*`，再替換成 Strata 設定；原本其他自訂設定需自行從備份合併。
- provider 為 `strata`，base URL 為 `http://<Tailscale-IP>:<port>/v1`，`wire_api = "responses"`。
- 金鑰僅透過 `STRATA_API_KEY` 提供；安裝腳本不讀取金鑰、不寫入 log 或 shell 啟動檔。
- 上述 `read -rsp` 在使用者自己的終端機隱藏輸入金鑰，僅對目前 shell 有效；新終端機需重新設定。
- 無認證的 Strata 服務，請移除設定中的 `env_key` 行，不要填假的官方金鑰。
- 健康檢查使用 `/health`；401/403 僅代表服務回應但需授權。HTTP 失敗會停止並保留原設定。
- `/health` 成功不等於推論成功；必須由使用者執行 Codex，驗證 Strata 的 `/v1/responses`、金鑰與模型。
- 已通過本機模擬安裝、PATH、偵測、設定備份與 HTTP 失敗測試；未連線到使用者的私人 Tailscale/GX10。

## 2026-11-13.3 修正

- NodeSource 設定腳本先下載，再以 sudo 執行；root 則直接執行。
- 設定、安裝 nodejs、檢查實際 Node 版本與 npm 都成功，才顯示安裝成功。
- 舊 Node 升級失敗會嘗試使用者層級安裝；最終仍不符合需求則以非零狀態結束，不繼續安裝 Codex CLI。
- Node 版本不足但已成功修復，不再計入最終失敗數。
- 使用模擬指令驗證 sudo/root、下載與安裝失敗、假成功、npm 故障及後備流程；未在各 Linux 發行版實機測試。

一鍵完成四件事：**確認環境 → 偵測缺套件 → 補裝套件 → 安裝 Codex CLI**，全程寫 log。

## 快速開始

```bash
curl -O https://kilroy-utb.github.io/hub/files/codex-setup-linux.sh
bash codex-setup-linux.sh
```

裝完之後（同一個終端機）：

```bash
export PATH="$HOME/.local/bin:$PATH"
codex login
codex "用繁體中文回一句話，確認連線正常"
```

## 參數

| 參數 | 說明 |
|------|------|
| （無） | 完整流程：檢查 → 補套件 → 裝 Codex CLI |
| `--check` | 只檢查，不動系統任何東西 |
| `--dry-run` | 顯示「會做什麼」，但不真的執行 |
| `--upgrade` | 強制把 Codex CLI 升級到最新版 |
| `--log-file <路徑>` | 指定 log 檔位置（預設 `~/codex-setup-linux.log`） |
| `--with-config` | 順便寫 `~/.codex/config.toml` |
| `--provider <名稱>` | 搭配 `--with-config`，支援 openai 或 strata |
| `--strata` | 安裝並自動偵測 Tailscale GX10、寫入 Strata 設定 |
| `--gx10-ip <IP>` | 明確指定 GX10 的 Tailscale IPv4，同時啟用 Strata 設定 |
| `--gx10-port <port>` | Strata 連接埠，預設 8080 |
| `--model <名稱>` | Strata 已載入的模型名稱 |

## 流程拆解

**步驟 1 — 環境盤點**
作業系統 / 核心 / CPU 架構（x86_64 ↔ linux-x64、aarch64 ↔ linux-arm64）、記憶體、磁碟、
身分（root / sudo / 一般使用者）。偵測到 WSL 會提醒改用 `codex-setup-wsl.sh`。

**步驟 2 — 套件管理器**
自動偵測 `apt-get` / `dnf` / `yum` / `apk` / `zypper` / `pacman`。

**步驟 3 — 缺套件偵測**
檢查 `curl`、`tar`、`gzip`、`ca-certificates`（必要）與 `git`、`xz`（選用），
列出完整缺少清單。

**步驟 4 — 補裝系統套件**
用對應的套件管理器一次裝齊缺的那些。

**步驟 5 — Node.js / npm**
- 已有 Node ≥ 16 → 直接沿用（低於 18 會額外提示）
- 缺 Node → 先試套件管理器，再試 NodeSource，最後退回 **nodejs.org 官方 tarball**
  裝到 `~/.local/lib/nodejs/`（**不需要 root**）

**步驟 6 — npm 全域前綴**
明確傳入 `--prefix "$HOME/.local"`，不修改 npm 的全域設定。
在 Bash 互動與登入啟動檔追加 PATH，不刪除原有設定；目前終端機需自行執行 export。

**步驟 7 — 安裝 Codex CLI**
`npm install -g --prefix "$HOME/.local" @openai/codex`；官方 registry 失敗時停止，不自動切換來源。
已有安裝時會比對 registry 最新版並提示可升級。

**步驟 8 — 驗證**
確認 `codex --version` 與 PATH 可用性。特別提醒：腳本內的 `export` 只對自己的
行程有效，離開腳本後要自己貼一次 `export PATH="$HOME/.local/bin:$PATH"`。

## Log

所有訊息、每個外部指令、每段輸出都會寫進 log 檔（不含 ANSI 色碼）：

```
~/codex-setup-linux.log
```

每次執行會在檔頭 append 一段會話標頭，方便回頭查。

## 對照表

| 環境 | 用哪一支 |
|------|----------|
| 一般 Linux（Ubuntu/Debian/Rocky/Alma/Fedora/Arch/openSUSE/Alpine） | `codex-setup-linux.sh` |
| WSL（要接 GX10 Strata） | `codex-setup-wsl.sh` |
| Windows PowerShell（要接 GX10 Strata） | `codex-setup-windows.ps1` |

## 疑難排解

| 症狀 | 解法 |
|------|------|
| `codex: command not found` | `export PATH="$HOME/.local/bin:$PATH"`，並重開終端機 |
| `npm ERR! code EACCES` | 腳本步驟 6 會自動處理；手動的話 `npm config set prefix ~/.local` |
| Node 版本太舊 | `bash codex-setup-linux.sh --upgrade` 不含 Node 升級，請自行用 nvm 或 NodeSource |
| 連不上 npm registry | 檢查網路與代理設定，腳本不自動切換套件來源 |

上游專案：https://github.com/openai/codex
