# codex-setup-linux.sh — 一般 Linux 安裝 Codex CLI

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
| `--provider <名稱>` | 搭配 `--with-config`，自訂 model provider |

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
前綴落在 `/usr/lib` 等系統目錄時全域安裝會 EACCES，腳本會自動改成 `~/.local`
並把 `export PATH="$HOME/.local/bin:$PATH"` 寫到 `~/.bashrc` 最末尾
（避免被後面的 nvm / asdf / mise 蓋掉）。

**步驟 7 — 安裝 Codex CLI**
`npm install -g @openai/codex`；官方 registry 失敗時自動改用 npmmirror。
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
| 連不上 npm registry | 腳本已內建 npmmirror fallback |

上游專案：https://github.com/openai/codex
