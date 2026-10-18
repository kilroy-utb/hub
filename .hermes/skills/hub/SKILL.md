---
name: hub
description: Generate a personal index.html hub page for a GitHub-hosted knowledge base / wiki / finance notes / todo list. Hub reads a `hub.yaml` config at repo root, renders a card-grid dashboard with section links, badges (e.g. "23 comics", "5 open todos"), search, and dark/light theme toggle. Hub lives in its OWN repo (e.g. `kilroy-utb/hub`) — sections can point to other repos' GitHub Pages (e.g. k_gen's `kilroy-utb/knowledge_base`) using absolute URLs. Cross-repo badge counts are auto-fetched via shallow git clone. Use when user says "更新首頁", "rebuild hub", "新增 section 到 hub", or "幫我做個人主頁".
metadata:
  tags: hub, index, dashboard, knowledge-base, wiki, todo, personal-site, github-pages, multi-repo
  requires:
    bins: [python3, git, pyyaml]
  primaryEnv: GITHUB_TOKEN
---

# hub

把 `hub.yaml` 變成一個個人首頁 `index.html`，列出所有子 section（成語漫畫、wiki、財經、todo、雜項...）。

## 設計哲學

**Hub = 手寫設定檔 + 自動生成靜態頁面 + 跨 repo 整合**

- 你維護一個 `hub.yaml`（在 hub repo 根目錄），列出所有 section
- 跑 `hub build` → 自動生成 `index.html` → 自動 commit + push
- **每個 section 用絕對 URL**（連到各 repo 的 GitHub Pages）— 這樣 hub repo 跟 k_gen repo 互不依賴
- 跨 repo 的 badge 自動計算（shallow clone 其他 repo 來數 PNG / MD / open todo）
- Section 類型：
  - **gallery**（k_gen 風格 PNG 列表）
  - **wiki**（markdown 檔案列表 + 內容預覽）
  - **todo**（掃描 `.md` 檔案的 checkbox）
  - **external**（純外連）

## Hub repo 跟 k_gen repo 分離

| 用途 | Repo | Pages URL |
|---|---|---|
| **hub 本身** | `kilroy-utb/hub` | `kilroy-utb.github.io/hub/` |
| **k_gen 漫畫** | `kilroy-utb/knowledge_base` | `kilroy-utb.github.io/knowledge_base/` |

**為什麼分開**：
- 不同性質的東西：hub = meta / index，k_gen repo = 內容
- 不會搶 GitHub Pages root
- 各 repo 可獨立 deploy / 設定權限
- 未來加新 repo（finance / novel / 任何）只要在 hub.yaml 加一筆

## 觸發條件

- `幫我做 hub` / `更新首頁` / `rebuild hub` → 跑 `hub build`
- `新增 section X 到 hub` / `把 wiki 加到首頁` → 編輯 `hub.yaml` + 跑 build
- `列出 hub 的 section` → 顯示目前 `hub.yaml`

## CLI 用法

```bash
# 預設：讀 ./hub.yaml → 產出 ./index.html → git commit + push
python3 ~/.hermes/skills/hub/scripts/hub.py build \
    --repo kilroy-utb/knowledge_base

# 純本機（不 push）
python3 ~/.hermes/skills/hub/scripts/hub.py build \
    --no-push --output ./index.html

# 顯示目前 sections
python3 ~/.hermes/skills/hub/scripts/hub.py show

# 互動式新增 section（問你 icon / desc / path / type）
python3 ~/.hermes/skills/hub/scripts/hub.py add
```

## CLI options

| Flag | Default | Description |
|------|---------|-------------|
| `--config` | `./hub.yaml` | hub 設定檔路徑 |
| `--repo` | (從 git remote 偵測) | GitHub `USER/REPO` |
| `--branch` | `main` | push 分支 |
| `--workdir` | `~/.cache/hub/<repo-slug>` | clone 位置 |
| `--output` | `index.html` | 輸出 HTML 檔名 |
| `--no-push` | — | 跳過 git push |
| `--title` | (從 `hub.yaml` `title`) | 覆寫標題 |
| `--theme` | (從 `hub.yaml` `theme`) | 覆寫主題 (light/dark) |

## hub.yaml 結構

```yaml
title: "Kilroy's Hub"
subtitle: "個人知識、漫畫、財經、待辦的入口"
theme: "light"          # light / dark
accent: "#1976d2"       # 主色
sections:
  - title: "成語四格漫畫"
    icon: "📚"
    desc: "用四格漫畫學成語，k_gen 自動生成"
    type: gallery       # gallery | wiki | todo | external
    url: "https://kilroy-utb.github.io/knowledge_base/comics/proverb/"
    badge_source:       # 跨 repo：自動 shallow clone
      repo: "kilroy-utb/knowledge_base"
      path: "comics/proverb"
    
  - title: "財經筆記"
    icon: "💰"
    desc: "持股追蹤、研究筆記、TSLA/0050 等"
    type: wiki
    url: "https://kilroy-utb.github.io/hub/wiki/finance/"
    badge_source:       # 本 repo：直接用
      local: "wiki/finance"
    
  - title: "Todo"
    icon: "✅"
    desc: "待辦清單與進行中項目"
    type: todo
    url: "https://kilroy-utb.github.io/hub/todo/"
    badge_source:
      local: "todo"
    
  - title: "GitHub Repo"
    icon: "🔗"
    desc: "原始檔案與所有 commit"
    type: external
    url: "https://github.com/kilroy-utb/hub"
```

## Badge 計算

- `gallery` badge = 該 path 下 `*.png` 數量
- `wiki` badge = 該 path 下 `*.md` 數量
- `todo` badge = 該 path 下 `*.md` 中 `- [ ]` 數量（未完成）
- `external` 不算

### `badge_source` 三種格式

1. **字串**（legacy）：`badge_source: "comics/proverb"` — 視為 primary repo 內的 path
2. **dict + local**：`{local: "wiki/finance"}` — primary repo 內
3. **dict + repo+path**：`{repo: "USER/REPO", path: "..."}` — 跨 repo，自動 shallow clone 到 `~/.cache/hub/<repo>/`

## 設計細節

- **響應式卡片牆** — desktop 3 欄、tablet 2 欄、手機 1 欄
- **深色模式切換** — localStorage 記住偏好
- **搜尋框** — 即時過濾 section 名稱 + 描述
- **每個 section 點擊 → 連到該 path**（gallery 自動開 k_gen 風格 index）
- **頂部 footer** — 顯示 last build time + GitHub repo 連結
- **小細節** — icon emoji 為主（避免 icon font dependency）

## 工作流程

1. 讀 `hub.yaml`（驗證 schema）
2. clone repo（如不在 cache）
3. 對每個 section 計算 badge（`gallery`/`wiki`/`todo` 各自算）
4. 用 `render_hub_html()` 模板生成 `index.html`
5. git commit + push

## 跟 k_gen 的關係

- `k_gen` 跑在 `kilroy-utb/knowledge_base` repo
- `hub` 跑在 `kilroy-utb/hub` repo
- 兩個 skill **互不依賴** — k_gen 跑完不會自動觸發 hub
- 兩個 skill 共享資訊是透過 hub.yaml 的 `badge_source.repo` 設定（hub 自動去 clone k_gen repo 算 PNG 數）
- 兩個 skill 各自的 gallery / index 完全獨立
- 互相不搶 GitHub Pages root

## 跟其他 skill 的可能整合（未來）

- **`obsidian`** — wiki section 可以接 Obsidian vault 路徑（symlink 或 cp）
- **`webnovel-writer`** — 加一個 `novel` section type
- **`finance` skill (待建)** — 加個 `portfolio` section type，顯示持股損益
- **`kanban-orchestrator`** — todo section 可以從 kanban 抓 open issues

## Pitfalls / 已知坑

1. **hub.yaml 編輯錯誤** — YAML 縮排敏感，space 不可 tab。`--validate` flag 可只驗證不 build。
2. **badge 計算** — 第一次 build 沒 cache 會慢（要列整個目錄）；之後 `~/.cache/hub/<repo>/` 已經有檔案
3. **GitHub Pages cache** — push 後不會立刻反映，等 1-5 分鐘
4. **Section path 不存在** — 警告但不 fail build（方便你先建好設定、之後再放內容）
5. **Empty section** — badge 顯示 0，但卡片還是會出（不隱藏）
6. **Theme 切換** — 預設跟系統 `prefers-color-scheme`，使用者可手動切換並 localStorage 記住
7. **First run 慢** — clone 大 repo 要時間。第二次 reuse clone 就快
8. **GitHub token** — 透過 `~/.git-credentials` 自動偵測。沒 token → push 失敗但 HTML 仍在本機
9. **Markdown frontmatter** — wiki section badge 只算檔案數，不解析 frontmatter

## Prerequisites

- Python 3.8+
- `pyyaml` (`pip install pyyaml`)
- GitHub credentials at `~/.git-credentials`
- 已建立 `kilroy-utb/knowledge_base` repo（或自訂 repo）

## 範例

第一次設定 hub：

```bash
# 1. 複製範例 hub.yaml 到你的 repo
cp ~/.hermes/skills/hub/examples/hub.yaml ~/my-repo/hub.yaml

# 2. 編輯 hub.yaml（改 title / sections）

# 3. 跑 build
python3 ~/.hermes/skills/hub/scripts/hub.py build \
    --repo YOUR_USER/YOUR_REPO

# 4. 開瀏覽器看 https://YOUR_USER.github.io/YOUR_REPO/
```

新增 section：

```bash
# 互動式
python3 ~/.hermes/skills/hub/scripts/hub.py add

# 或直接編輯 hub.yaml 加一段
```

## 設計簡化歷史

- 2026-10-18：初版。YAML 設定 + 卡片牆 + badge + dark mode + search。
- ❌ 不做：自動去各 section 抓真實內容渲染（太重，靜態 badge + 連外就夠）
- ❌ 不做：自己寫 wiki 編輯器（GitHub 網頁編輯就夠用）
- ❌ 不做：dashboard 模式（要 JS fetch 外部 API）— 未來再說
- ✅ 做：純靜態、手寫設定、badge 自動化
