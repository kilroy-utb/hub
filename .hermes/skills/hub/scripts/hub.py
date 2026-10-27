#!/usr/bin/env python3
"""
hub — 個人首頁 builder

讀 hub.yaml → 計算 section badges → 產出 index.html → git commit + push

Usage:
  python3 hub.py build [--config hub.yaml] [--repo USER/REPO] [--no-push]
  python3 hub.py show
  python3 hub.py add   (互動式新增 section)
  python3 hub.py validate
"""

import argparse
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print("ERROR: pyyaml not installed. Run: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


# ---- Config loading ----

def load_config(path: str) -> dict:
    p = Path(path)
    if not p.exists():
        print(f"ERROR: config not found: {path}", file=sys.stderr)
        sys.exit(1)
    with open(p, encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}
    return _validate_config(cfg, p)


def _validate_config(cfg: dict, src: Path) -> dict:
    """基本 schema 驗證 + 補預設值"""
    cfg.setdefault("title", "My Hub")
    cfg.setdefault("subtitle", "")
    cfg.setdefault("theme", "light")
    cfg.setdefault("accent", "#1976d2")
    cfg.setdefault("sections", [])

    if not isinstance(cfg["sections"], list):
        raise ValueError(f"{src}: 'sections' must be a list")

    for i, sec in enumerate(cfg["sections"]):
        if "title" not in sec:
            raise ValueError(f"{src}: section #{i} missing 'title'")
        sec.setdefault("icon", "📄")
        sec.setdefault("desc", "")
        sec.setdefault("type", "wiki")
        if sec["type"] not in ("gallery", "wiki", "todo", "file", "external"):
            raise ValueError(f"{src}: section '{sec['title']}' has invalid type '{sec['type']}'")
        # url 必填（gallery/wiki/todo/file/external 都要有，連到 Pages 絕對 URL）
        sec.setdefault("url", "#")

    return cfg


# ---- Badge calculation ----

CACHE_BASE = Path("~/.cache/hub").expanduser()


def get_repo_workdir(repo: str) -> Path:
    return CACHE_BASE / repo.replace("/", "-")


def ensure_repo_cloned(repo: str, branch: str) -> Path | None:
    """從 GitHub clone（給 badge 計算用，shallow）。失敗回傳 None。"""
    wd = get_repo_workdir(repo)
    if not wd.exists():
        wd.parent.mkdir(parents=True, exist_ok=True)
        print(f"[hub] cloning {repo} for badge → {wd}")
        r = subprocess.run(
            ["git", "clone", "--depth=1", "--branch", branch,
             f"https://github.com/{repo}.git", str(wd)],
            capture_output=True, text=True
        )
        if r.returncode != 0:
            print(f"  WARN: clone {repo} failed: {r.stderr.strip()[:200]}", file=sys.stderr)
            return None
    return wd


def _local_count_pngs(workdir: Path, path: str) -> int:
    d = workdir / path
    return sum(1 for _ in d.glob("*.png")) if d.exists() else 0


def _local_count_mds(workdir: Path, path: str) -> int:
    d = workdir / path
    return sum(1 for _ in d.glob("*.md")) if d.exists() else 0


def _local_count_open_todos(workdir: Path, path: str) -> int:
    d = workdir / path
    if not d.exists():
        return 0
    n = 0
    for md in d.glob("*.md"):
        try:
            content = md.read_text(encoding="utf-8")
            n += len(re.findall(r"^\s*-\s*\[\s\]\s", content, re.MULTILINE))
        except Exception:
            pass
    return n


def _local_count_files(workdir: Path, path: str) -> int:
    """算 path 下所有「非 .md 非 index.html」檔案"""
    d = workdir / path
    if not d.exists():
        return 0
    n = 0
    for f in d.iterdir():
        if f.is_file() and f.suffix.lower() not in (".md", ".html"):
            n += 1
    return n


def compute_badges(sections: list, primary_workdir: Path, primary_repo: str) -> list:
    """
    badge_source 支援三種:
      - 字串 (legacy): 視為 primary repo 內的 path
      - {"local": "path"}: primary repo 內
      - {"repo": "USER/REPO", "path": "..."}: 跨 repo（會自動 clone）
    """
    for sec in sections:
        if sec["type"] == "external":
            sec["badge"] = None
            continue

        src = sec.get("badge_source")
        if isinstance(src, str):
            wd, path = primary_workdir, src
        elif isinstance(src, dict):
            if "local" in src:
                wd, path = primary_workdir, src["local"]
            elif "repo" in src and "path" in src:
                ext_wd = ensure_repo_cloned(src["repo"], "main")
                if ext_wd is None:
                    sec["badge"] = None
                    continue
                wd, path = ext_wd, src["path"]
            else:
                sec["badge"] = None
                continue
        else:
            sec["badge"] = None
            continue

        if sec["type"] == "gallery":
            sec["badge"] = _local_count_pngs(wd, path)
        elif sec["type"] == "wiki":
            sec["badge"] = _local_count_mds(wd, path)
        elif sec["type"] == "todo":
            sec["badge"] = _local_count_open_todos(wd, path)
        elif sec["type"] == "file":
            sec["badge"] = _local_count_files(wd, path)
        else:
            sec["badge"] = None

    return sections


# ---- HTML rendering ----

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-Hant" data-theme="{theme}">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{title}</title>
  <style>
    :root {{
      --bg: #ffffff;
      --fg: #1a1a1a;
      --card-bg: #f5f5f5;
      --card-fg: #1a1a1a;
      --border: #e0e0e0;
      --muted: #666;
      --accent: {accent};
    }}
    [data-theme="dark"] {{
      --bg: #121212;
      --fg: #e0e0e0;
      --card-bg: #1e1e1e;
      --card-fg: #e0e0e0;
      --border: #2a2a2a;
      --muted: #999;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans TC", sans-serif;
      background: var(--bg);
      color: var(--fg);
      margin: 0;
      padding: 0;
      line-height: 1.5;
    }}
    .container {{ max-width: 1100px; margin: 0 auto; padding: 32px 20px 80px; }}
    header {{ text-align: center; margin-bottom: 40px; }}
    h1 {{ font-size: 32px; margin: 0 0 8px 0; }}
    .subtitle {{ color: var(--muted); font-size: 14px; margin: 0; }}
    .controls {{
      display: flex;
      gap: 12px;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 24px;
      flex-wrap: wrap;
    }}
    .search {{
      flex: 1;
      min-width: 200px;
      padding: 10px 14px;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--card-bg);
      color: var(--card-fg);
      font-size: 14px;
    }}
    .theme-toggle {{
      padding: 8px 16px;
      background: var(--card-bg);
      color: var(--card-fg);
      border: 1px solid var(--border);
      border-radius: 8px;
      cursor: pointer;
      font-size: 13px;
    }}
    .theme-toggle:hover {{ background: var(--accent); color: white; border-color: var(--accent); }}
    .grid {{
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
      gap: 16px;
    }}
    .card {{
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 20px;
      text-decoration: none;
      color: var(--card-fg);
      transition: transform 0.15s, box-shadow 0.15s, border-color 0.15s;
      display: flex;
      flex-direction: column;
      gap: 8px;
      position: relative;
    }}
    .card:hover {{
      transform: translateY(-2px);
      box-shadow: 0 4px 12px rgba(0,0,0,0.1);
      border-color: var(--accent);
    }}
    .card-header {{ display: flex; align-items: center; gap: 10px; }}
    .icon {{ font-size: 28px; }}
    .card-title {{ font-size: 17px; font-weight: 600; flex: 1; margin: 0; }}
    .badge {{
      background: var(--accent);
      color: white;
      padding: 3px 10px;
      border-radius: 12px;
      font-size: 12px;
      font-weight: 600;
      white-space: nowrap;
    }}
    .desc {{ color: var(--muted); font-size: 13px; margin: 0; }}
    .empty {{
      text-align: center;
      padding: 60px 20px;
      color: var(--muted);
      grid-column: 1 / -1;
    }}
    footer {{
      text-align: center;
      margin-top: 60px;
      color: var(--muted);
      font-size: 12px;
    }}
    footer a {{ color: var(--accent); text-decoration: none; }}
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>{title}</h1>
      {subtitle_html}
    </header>

    <div class="controls">
      <input type="text" class="search" id="search" placeholder="搜尋 section…">
      <button class="theme-toggle" id="theme-toggle">🌙 切換主題</button>
    </div>

    <div class="grid" id="grid">
      {cards_html}
    </div>

    <footer>
      Last build: {build_time}<br>
      <a href="https://github.com/{repo}" target="_blank" rel="noopener">GitHub repo</a>
    </footer>
  </div>

  <script>
    // theme
    const root = document.documentElement;
    const saved = localStorage.getItem('hub-theme');
    if (saved) root.setAttribute('data-theme', saved);
    document.getElementById('theme-toggle').addEventListener('click', () => {{
      const cur = root.getAttribute('data-theme') || 'light';
      const next = cur === 'light' ? 'dark' : 'light';
      root.setAttribute('data-theme', next);
      localStorage.setItem('hub-theme', next);
    }});

    // search
    const search = document.getElementById('search');
    const cards = Array.from(document.querySelectorAll('.card'));
    search.addEventListener('input', (e) => {{
      const q = e.target.value.toLowerCase();
      let visible = 0;
      cards.forEach(c => {{
        const text = c.textContent.toLowerCase();
        const match = !q || text.includes(q);
        c.style.display = match ? '' : 'none';
        if (match) visible++;
      }});
      document.getElementById('empty')?.remove();
      if (visible === 0) {{
        const empty = document.createElement('div');
        empty.id = 'empty';
        empty.className = 'empty';
        empty.textContent = '沒有符合的 section。';
        document.getElementById('grid').appendChild(empty);
      }}
    }});
  </script>
</body>
</html>
"""

CARD_TEMPLATE = """      <a class="card" href="{href}"{external}>
        <div class="card-header">
          <span class="icon">{icon}</span>
          <h2 class="card-title">{title}</h2>
          {badge_html}
        </div>
        <p class="desc">{desc}</p>
      </a>"""


def render_hub_html(cfg: dict, repo: str) -> str:
    sections = cfg["sections"]
    cards = []

    for sec in sections:
        href = sec.get("url", "#")
        external = ' target="_blank" rel="noopener"' if sec["type"] == "external" else ""

        if sec.get("badge") is not None:
            badge_label = f"{sec['badge']}"
            if sec["type"] == "todo":
                badge_label = f"{sec['badge']} open"
            elif sec["type"] == "gallery":
                badge_label = f"{sec['badge']} pics"
            elif sec["type"] == "wiki":
                badge_label = f"{sec['badge']} files"
            elif sec["type"] == "file":
                badge_label = f"{sec['badge']} files"
            badge_html = f'<span class="badge">{badge_label}</span>'
        else:
            badge_html = ""

        cards.append(CARD_TEMPLATE.format(
            href=href,
            external=external,
            icon=sec.get("icon", "📄"),
            title=sec["title"],
            badge_html=badge_html,
            desc=sec.get("desc", ""),
        ))

    cards_html = "\n".join(cards) if cards else '<div class="empty">沒有任何 section。在 hub.yaml 加一個再跑 build。</div>'

    subtitle_html = f'<p class="subtitle">{cfg["subtitle"]}</p>' if cfg.get("subtitle") else ""

    build_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S") + " (GMT+8)"

    return HTML_TEMPLATE.format(
        title=cfg["title"],
        subtitle_html=subtitle_html,
        theme=cfg.get("theme", "light"),
        accent=cfg.get("accent", "#1976d2"),
        cards_html=cards_html,
        build_time=build_time,
        repo=repo or "your/repo",
    )


# ---- Section landing page (wiki/todo/notes) ----

SECTION_INDEX_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-Hant" data-theme="{theme}">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{title} — {hub_title}</title>
  <style>
    :root {{
      --bg: #ffffff;
      --fg: #1a1a1a;
      --card-bg: #f5f5f5;
      --card-fg: #1a1a1a;
      --border: #e0e0e0;
      --muted: #666;
      --accent: {accent};
    }}
    [data-theme="dark"] {{
      --bg: #121212;
      --fg: #e0e0e0;
      --card-bg: #1e1e1e;
      --card-fg: #e0e0e0;
      --border: #2a2a2a;
      --muted: #999;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans TC", sans-serif;
      background: var(--bg);
      color: var(--fg);
      margin: 0;
      padding: 0;
      line-height: 1.5;
    }}
    .container {{ max-width: 900px; margin: 0 auto; padding: 32px 20px 80px; }}
    nav.breadcrumb {{
      font-size: 13px;
      color: var(--muted);
      margin-bottom: 20px;
    }}
    nav.breadcrumb a {{ color: var(--accent); text-decoration: none; }}
    header {{ margin-bottom: 32px; }}
    h1 {{ font-size: 28px; margin: 0 0 8px 0; display: flex; align-items: center; gap: 10px; }}
    h1 .icon {{ font-size: 32px; }}
    .desc {{ color: var(--muted); margin: 0 0 12px 0; }}
    .actions {{ display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }}
    .actions a {{
      padding: 6px 14px;
      border: 1px solid var(--border);
      border-radius: 6px;
      color: var(--card-fg);
      text-decoration: none;
      font-size: 13px;
      background: var(--card-bg);
    }}
    .actions a:hover {{ background: var(--accent); color: white; border-color: var(--accent); }}
    .search {{
      width: 100%;
      padding: 10px 14px;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--card-bg);
      color: var(--card-fg);
      font-size: 14px;
      margin-bottom: 16px;
    }}
    .file-list {{ display: flex; flex-direction: column; gap: 8px; }}
    .file-item {{
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 12px 16px;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      transition: border-color 0.15s;
    }}
    .file-item:hover {{ border-color: var(--accent); }}
    .file-icon {{ font-size: 20px; }}
    .file-name {{ flex: 1; font-weight: 500; }}
    .file-meta {{ font-size: 12px; color: var(--muted); }}
    .file-link {{
      font-size: 12px;
      color: var(--accent);
      text-decoration: none;
    }}
    .empty {{
      text-align: center;
      padding: 40px 20px;
      color: var(--muted);
      background: var(--card-bg);
      border: 1px dashed var(--border);
      border-radius: 8px;
    }}
    .theme-toggle {{
      position: fixed;
      top: 20px;
      right: 20px;
      padding: 8px 12px;
      background: var(--card-bg);
      color: var(--card-fg);
      border: 1px solid var(--border);
      border-radius: 6px;
      cursor: pointer;
      font-size: 12px;
    }}
  </style>
</head>
<body>
  <button class="theme-toggle" id="theme-toggle">🌙</button>
  <div class="container">
    <nav class="breadcrumb">
      <a href="{hub_url}">← {hub_title}</a> / <span>{title}</span>
    </nav>

    <header>
      <h1><span class="icon">{icon}</span> {title}</h1>
      {desc_html}
      <div class="actions">
        {new_button}
        <a href="{edit_folder_url}" target="_blank" rel="noopener">📁 資料夾</a>
        {back_button}
      </div>
    </header>

    <input type="text" class="search" id="search" placeholder="搜尋…">

    <div class="file-list" id="file-list">
      {items_html}
    </div>
  </div>

  <script>
    const root = document.documentElement;
    const saved = localStorage.getItem('hub-theme');
    if (saved) root.setAttribute('data-theme', saved);
    document.getElementById('theme-toggle').addEventListener('click', () => {{
      const cur = root.getAttribute('data-theme') || 'light';
      const next = cur === 'light' ? 'dark' : 'light';
      root.setAttribute('data-theme', next);
      localStorage.setItem('hub-theme', next);
    }});

    const search = document.getElementById('search');
    const items = Array.from(document.querySelectorAll('.file-item'));
    search.addEventListener('input', (e) => {{
      const q = e.target.value.toLowerCase();
      let visible = 0;
      items.forEach(it => {{
        const match = !q || it.textContent.toLowerCase().includes(q);
        it.style.display = match ? '' : 'none';
        if (match) visible++;
      }});
      document.getElementById('empty-msg')?.remove();
      if (visible === 0) {{
        const empty = document.createElement('div');
        empty.id = 'empty-msg';
        empty.className = 'empty';
        empty.textContent = '沒有符合的檔案。';
        document.getElementById('file-list').appendChild(empty);
      }}
    }});
  </script>
</body>
</html>
"""


FILE_ITEM_TEMPLATE = """      <div class="file-item">
        <span class="file-icon">{icon}</span>
        <span class="file-name">{name}</span>
        <span class="file-meta">{meta}</span>
        <a class="file-link" href="{href}" target="_blank" rel="noopener">{action_label}</a>
      </div>"""


def _icon_for_ext(ext: str) -> str:
    return {
        ".md": "📝",
        ".png": "🖼️", ".jpg": "🖼️", ".jpeg": "🖼️", ".gif": "🖼️", ".webp": "🖼️", ".svg": "🖼️",
        ".pdf": "📕",
        ".csv": "📊", ".xlsx": "📊", ".xls": "📊",
        ".docx": "📄", ".doc": "📄",
        ".txt": "📃",
        ".mp3": "🎵", ".wav": "🎵",
        ".mp4": "🎬", ".mov": "🎬",
        ".zip": "📦", ".tar": "📦", ".gz": "📦",
    }.get(ext.lower(), "📄")


def render_section_index_html(sec: dict, cfg: dict, hub_url: str, files: list, file_type: str) -> str:
    """
    產生 section landing page (e.g. wiki/index.html, todo/index.html)
    files: list of (filename, ext, size_bytes)
    file_type: 'md' (markdown) or 'file' (other)
    """
    # 從 section url 推導資料夾在 repo 內的路徑
    # e.g. https://kilroy-utb.github.io/hub/wiki/ → wiki/
    url = sec.get("url", "")
    if "/hub/" in url:
        path = url.split("/hub/", 1)[1].rstrip("/") + "/"
    else:
        path = sec.get("badge_source", {}).get("local", "unknown") if isinstance(sec.get("badge_source"), dict) else "unknown"

    # 顯示每個檔案
    items = []
    for fname, ext, size in files:
        icon = _icon_for_ext(ext)
        meta = f"{ext[1:].upper()} · {size:,} bytes" if ext else f"{size:,} bytes"
        if file_type == "md":
            href = f"./{fname}"
            action_label = "閱讀"
        else:
            href = f"./{fname}"
            action_label = "下載"
        items.append(FILE_ITEM_TEMPLATE.format(
            icon=icon,
            name=fname,
            meta=meta,
            href=href,
            action_label=action_label,
        ))

    items_html = "\n".join(items) if items else '<div class="empty">這個資料夾還是空的。從 GitHub 編輯加第一個檔案吧 👇</div>'

    desc_html = f'<p class="desc">{sec["desc"]}</p>' if sec.get("desc") else ""

    # 「新增檔案」按鈕：直連 GitHub web editor
    repo_name = "kilroy-utb/hub"
    if isinstance(sec.get("badge_source"), dict) and "repo" in sec["badge_source"]:
        repo_name = sec["badge_source"]["repo"]
    new_button = f'<a href="https://github.com/{repo_name}/new/main/{path.rstrip("/")}?filename={path}new-file.md" target="_blank" rel="noopener">+ 新增檔案</a>'

    edit_folder_url = f"https://github.com/kilroy-utb/hub/tree/main/{path.rstrip('/')}"

    # 「返回 hub」按鈕
    back_button = f'<a href="{hub_url}">← 回首頁</a>'

    build_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S") + " (GMT+8)"

    return SECTION_INDEX_TEMPLATE.format(
        title=sec["title"],
        hub_title=cfg["title"],
        hub_url=hub_url,
        icon=sec.get("icon", "📄"),
        desc_html=desc_html,
        new_button=new_button,
        edit_folder_url=edit_folder_url,
        back_button=back_button,
        items_html=items_html,
        theme=cfg.get("theme", "light"),
        accent=cfg.get("accent", "#1976d2"),
    )


def collect_section_files(workdir: Path, path: str, sec_type: str) -> tuple[list, str]:
    """
    掃描 section 資料夾，回傳 (files, file_type)
    files = [(filename, ext, size_bytes), ...]
    file_type = 'md' 或 'file'
    """
    d = workdir / path
    if not d.exists():
        return [], "md"

    if sec_type in ("wiki", "todo"):
        # 只列 .md，跳過 index.md
        files = []
        for f in sorted(d.glob("*.md")):
            if f.name == "index.md":
                continue
            files.append((f.name, ".md", f.stat().st_size))
        return files, "md"
    elif sec_type == "file":
        # 列所有非 .md / .html 檔
        files = []
        for f in sorted(d.iterdir()):
            if not f.is_file():
                continue
            ext = f.suffix
            if ext.lower() in (".md", ".html"):
                continue
            files.append((f.name, ext, f.stat().st_size))
        return files, "file"
    else:
        return [], "md"


# ---- Git ops ----

def get_git_remote(workdir: Path) -> str | None:
    try:
        out = subprocess.check_output(
            ["git", "remote", "get-url", "origin"],
            cwd=workdir, stderr=subprocess.DEVNULL
        ).decode().strip()
        m = re.search(r"github\.com[:/](.+?)(?:\.git)?$", out)
        return m.group(1) if m else None
    except Exception:
        return None


def clone_or_pull(repo: str, workdir: Path, branch: str) -> Path:
    workdir.parent.mkdir(parents=True, exist_ok=True)
    if workdir.exists() and (workdir / ".git").exists():
        print(f"[hub] reusing clone: {workdir}")
        subprocess.run(["git", "fetch", "origin"], cwd=workdir, check=False, capture_output=True)
        subprocess.run(["git", "checkout", branch], cwd=workdir, check=False, capture_output=True)
        subprocess.run(["git", "pull", "--rebase", "origin", branch], cwd=workdir, check=False, capture_output=True)
    else:
        if workdir.exists():
            subprocess.run(["rm", "-rf", str(workdir)], check=False)
        print(f"[hub] cloning {repo} → {workdir}")
        url = f"https://github.com/{repo}.git"
        result = subprocess.run(
            ["git", "clone", "--depth=50", "--branch", branch, url, str(workdir)],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"ERROR cloning {repo}:\n{result.stderr}", file=sys.stderr)
            sys.exit(1)
    return workdir


def commit_and_push(workdir: Path, branch: str, message: str) -> bool:
    try:
        subprocess.run(["git", "add", "-A"], cwd=workdir, check=True, capture_output=True)

        # 檢查有沒有改動
        diff = subprocess.run(
            ["git", "diff", "--cached", "--stat"],
            cwd=workdir, capture_output=True, text=True
        ).stdout.strip()
        if not diff:
            print("[hub] no changes to commit")
            return True

        subprocess.run(["git", "commit", "-m", message], cwd=workdir, check=True, capture_output=True)
        result = subprocess.run(
            ["git", "push", "origin", branch],
            cwd=workdir, capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"ERROR push failed:\n{result.stderr}", file=sys.stderr)
            return False
        print(f"[hub] pushed: {message}")
        return True
    except subprocess.CalledProcessError as e:
        print(f"ERROR git: {e}", file=sys.stderr)
        return False


# ---- Commands ----

def cmd_build(args):
    cfg = load_config(args.config)

    if args.no_push:
        # 本機模式：--repo 可省略（badge 仍算）。先從 cwd 的 git remote 偵測 repo，
        # 這樣 CI 的 --no-push 建置產生的頁面，連結才會指向真正的 GitHub Pages
        # （沒有就退回 dummy，footer 與面包屑才不會指向 local.github.io/local）
        repo = args.repo or get_git_remote(Path.cwd()) or "local/local"
    elif args.repo:
        repo = args.repo
    else:
        # 試著從 cwd git remote 偵測
        detected = get_git_remote(Path.cwd())
        if detected:
            repo = detected
            print(f"[hub] detected repo from cwd: {repo}")
        else:
            print("ERROR: --repo not given and no git remote in cwd", file=sys.stderr)
            sys.exit(1)

    branch = args.branch
    workdir = Path(args.workdir).expanduser() if args.workdir else Path(f"~/.cache/hub/{repo.replace('/', '-')}").expanduser()

    if not args.no_push:
        workdir = clone_or_pull(repo, workdir, branch)
        workdir_for_badges = workdir
    else:
        # 本機模式：從 cwd 算 badges
        workdir_for_badges = Path.cwd()

    cfg["sections"] = compute_badges(cfg["sections"], workdir_for_badges, repo)

    # 顯示 badge 摘要
    print("[hub] sections:")
    for sec in cfg["sections"]:
        badge_str = f" [{sec.get('badge')}]" if sec.get("badge") is not None else ""
        print(f"  - {sec.get('icon', '📄')} {sec['title']}{badge_str} ({sec['type']})")

    html = render_hub_html(cfg, repo)

    if args.no_push:
        out = Path(args.output or "index.html")
        out.write_text(html, encoding="utf-8")
        print(f"[hub] wrote: {out}")

        # 本機模式也生成 section index.html（不 push）
        hub_url = f"https://{repo.split('/')[0]}.github.io/{repo.split('/')[1]}/"
        for sec in cfg["sections"]:
            if sec["type"] not in ("wiki", "todo", "file"):
                continue
            bs = sec.get("badge_source", {})
            if isinstance(bs, dict) and "local" in bs:
                path = bs["local"]
            elif isinstance(bs, str):
                path = bs
            else:
                url = sec.get("url", "")
                path = url.split(f"/{repo.split('/')[1]}/", 1)[-1].rstrip("/") if f"/{repo.split('/')[1]}/" in url else ""
            if not path:
                continue
            files, file_type = collect_section_files(Path.cwd(), path, sec["type"])
            sec_html = render_section_index_html(sec, cfg, hub_url, files, file_type)
            sec_index_path = Path.cwd() / path / "index.html"
            sec_index_path.parent.mkdir(parents=True, exist_ok=True)
            sec_index_path.write_text(sec_html, encoding="utf-8")
            print(f"  wrote: {path.rstrip('/')}/index.html  ({len(files)} files)")
    else:
        out_path = workdir / (args.output or "index.html")
        out_path.write_text(html, encoding="utf-8")

        # 給每個 wiki/todo/file section 生成 landing page
        hub_url = f"https://{repo.split('/')[0]}.github.io/{repo.split('/')[1]}/"
        for sec in cfg["sections"]:
            if sec["type"] not in ("wiki", "todo", "file"):
                continue

            # 決定資料夾路徑（在 repo 內）
            bs = sec.get("badge_source", {})
            if isinstance(bs, dict) and "local" in bs:
                path = bs["local"]
            elif isinstance(bs, str):
                path = bs
            else:
                # 從 url 推導
                url = sec.get("url", "")
                path = url.split(f"/{repo.split('/')[1]}/", 1)[-1].rstrip("/") if f"/{repo.split('/')[1]}/" in url else ""
            if not path:
                print(f"  skip landing: {sec['title']} (no path)")
                continue

            files, file_type = collect_section_files(workdir, path, sec["type"])
            sec_html = render_section_index_html(sec, cfg, hub_url, files, file_type)
            sec_index_path = workdir / path / "index.html"
            sec_index_path.parent.mkdir(parents=True, exist_ok=True)
            sec_index_path.write_text(sec_html, encoding="utf-8")
            print(f"  wrote: {path.rstrip('/')}/index.html  ({len(files)} files)")

        ok = commit_and_push(workdir, branch, "hub: regenerate index.html")
        if not ok:
            print("[hub] WARNING: commit/push failed, but HTML is in repo", file=sys.stderr)


def cmd_show(args):
    cfg = load_config(args.config)
    print(f"Title: {cfg['title']}")
    print(f"Subtitle: {cfg.get('subtitle', '')}")
    print(f"Theme: {cfg.get('theme', 'light')}")
    print(f"\nSections ({len(cfg['sections'])}):")
    for sec in cfg["sections"]:
        url = sec.get("url", "")
        url_short = url if len(url) < 60 else url[:57] + "..."
        print(f"  {sec.get('icon', '📄')} {sec['title']} → {url_short} ({sec['type']})")


def cmd_validate(args):
    try:
        load_config(args.config)
        print(f"✓ {args.config} is valid")
    except (ValueError, yaml.YAMLError) as e:
        print(f"✗ {e}", file=sys.stderr)
        sys.exit(1)


def cmd_add(args):
    """互動式新增 section（寫到 hub.yaml）"""
    print("=== 新增 section 到 hub.yaml ===\n")

    title = input("Title: ").strip()
    icon = input("Icon (emoji, 預設 📄): ").strip() or "📄"
    desc = input("Description: ").strip()
    print("\nType: gallery / wiki / todo / external")
    sec_type = input("Type: ").strip()
    while sec_type not in ("gallery", "wiki", "todo", "external"):
        sec_type = input("Type (gallery/wiki/todo/external): ").strip()

    if sec_type == "external":
        path_or_url = input("URL: ").strip()
    else:
        path_or_url = input("Path (e.g. comics/proverb/): ").strip()
        if path_or_url and not path_or_url.endswith("/"):
            path_or_url += "/"

    badge_src = ""
    if sec_type in ("gallery", "wiki", "todo"):
        ans = input(f"Badge source path (留空用 path 本身): ").strip()
        badge_src = ans or path_or_url

    cfg_path = Path(args.config)
    if cfg_path.exists():
        with open(cfg_path, encoding="utf-8") as f:
            cfg = yaml.safe_load(f) or {}
    else:
        cfg = {"title": "My Hub", "sections": []}

    new_sec = {
        "title": title,
        "icon": icon,
        "desc": desc,
        "type": sec_type,
    }
    if sec_type == "external":
        new_sec["url"] = path_or_url
    else:
        new_sec["path"] = path_or_url
        if badge_src:
            new_sec["badge_source"] = badge_src

    cfg.setdefault("sections", []).append(new_sec)

    with open(cfg_path, "w", encoding="utf-8") as f:
        yaml.dump(cfg, f, allow_unicode=True, sort_keys=False, default_flow_style=False)

    print(f"\n✓ 新增完成: {title}")
    print(f"  跑 `python3 hub.py build --repo USER/REPO` 重建 index.html")


def main():
    parser = argparse.ArgumentParser(description="hub — 個人首頁 builder")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_build = sub.add_parser("build", help="build index.html")
    p_build.add_argument("--config", default="hub.yaml")
    p_build.add_argument("--repo", help="USER/REPO (e.g. kilroy-utb/knowledge_base)")
    p_build.add_argument("--branch", default="main")
    p_build.add_argument("--workdir", help="clone 位置")
    p_build.add_argument("--output", help="output 檔名 (default index.html)")
    p_build.add_argument("--no-push", action="store_true", help="純本機，不 push")
    p_build.add_argument("--title", help="覆寫 title")
    p_build.add_argument("--theme", choices=["light", "dark"], help="覆寫 theme")
    p_build.set_defaults(func=cmd_build)

    p_show = sub.add_parser("show", help="顯示 sections")
    p_show.add_argument("--config", default="hub.yaml")
    p_show.set_defaults(func=cmd_show)

    p_val = sub.add_parser("validate", help="只驗證 hub.yaml")
    p_val.add_argument("--config", default="hub.yaml")
    p_val.set_defaults(func=cmd_validate)

    p_add = sub.add_parser("add", help="互動式新增 section")
    p_add.add_argument("--config", default="hub.yaml")
    p_add.set_defaults(func=cmd_add)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
