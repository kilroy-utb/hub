#!/usr/bin/env bash
set -uo pipefail
if ! command -v python3 >/dev/null 2>&1; then
  printf 'ERROR：需要 python3；未修改任何設定。\n'
  exit 1
fi
python3 - <<'PY'
import os
import pathlib
import platform
import re
import shutil

print('=== Codex WSL 唯讀診斷 v1 ===')
print('不顯示金鑰、不讀取 .env/auth.json、不啟動 Codex、不連線服務。')
print('本報告只代表執行此腳本的終端機，不代表其他已開啟的程式。')
home = pathlib.Path.home()
problems = []

def label(path):
    text = str(path)
    if text == str(home):
        return '~'
    if text.startswith(str(home) + '/'):
        text = '~/' + text[len(str(home)) + 1:]
    return ascii(text)

print('\n[1] 環境與路徑')
print('系統:', platform.system(), platform.machine())
print('WSL:', '是' if 'microsoft' in platform.release().lower() else '未偵測到')
print('登入 shell 名稱:', ascii(pathlib.Path(os.environ.get('SHELL', '')).name))
expected_bin = home / '.local/bin'
path_entries = os.environ.get('PATH', '').split(os.pathsep)
print('PATH 包含 ~/.local/bin:', str(expected_bin) in path_entries)
resolved = shutil.which('codex')
expected = expected_bin / 'codex'
print('PATH 找到 codex:', label(resolved) if resolved else '找不到')
print('~/.local/bin/codex 可執行:', expected.is_file() and os.access(expected, os.X_OK))
if not resolved:
    problems.append('目前 PATH 找不到 codex。')
elif expected.exists() and pathlib.Path(resolved).resolve() != expected.resolve():
    problems.append('PATH 找到的 Codex 與 ~/.local/bin/codex 不同。')
print('注意：腳本無法看到父 shell 的 alias、function 或命令快取。')

print('\n[2] 子行程收到的金鑰狀態（不輸出值）')
present = 'STRATA_API_KEY' in os.environ
nonempty = bool(os.environ.get('STRATA_API_KEY'))
print('STRATA_API_KEY 已傳給子行程:', present)
print('STRATA_API_KEY 非空:', nonempty)
if not nonempty:
    problems.append('此終端機未將非空 STRATA_API_KEY 匯出給子行程。')

print('\n[3] 設定來源')
default_home = home / '.codex'
configured_home = os.environ.get('CODEX_HOME')
effective_home = pathlib.Path(configured_home) if configured_home else default_home
print('CODEX_HOME 已設定:', configured_home is not None)
print('使用預設 ~/.codex:', effective_home.resolve() == default_home.resolve())
print('設定目錄:', label(effective_home))
if configured_home and not effective_home.is_absolute():
    problems.append('CODEX_HOME 是相對路徑，需檢查啟動位置。')

try:
    import tomllib
except ImportError:
    tomllib = None
    print('WARN：Python 缺少 tomllib，略過 TOML 解析；不自動安裝套件。')

def inspect_config(path, role):
    print('\n設定檔:', role, label(path))
    print('存在:', path.is_file())
    if not path.is_file() or tomllib is None:
        return
    try:
        with path.open('rb') as source:
            config = tomllib.load(source)
    except Exception as error:
        print('無法解析:', type(error).__name__, '（隱藏原始錯誤，避免洩漏設定值）')
        problems.append(role + ' 設定無法解析。')
        return
    provider = config.get('model_provider')
    print('model_provider:', 'strata' if provider == 'strata' else '未設定或其他值（隱藏）')
    print('頂層 profile 已指定:', 'profile' in config)
    providers = config.get('model_providers', {})
    strata = providers.get('strata', {}) if isinstance(providers, dict) else {}
    if not isinstance(strata, dict):
        print('WARN：strata 區塊不是表格')
        return
    env_key = strata.get('env_key')
    print('strata.env_key 存在:', env_key is not None)
    print('strata.env_key 完全等於 STRATA_API_KEY:', env_key == 'STRATA_API_KEY')
    if isinstance(env_key, str):
        print('env_key 包含額外引號:', any(mark in env_key for mark in ('"', "'", '“', '”', '‘', '’')))
        print('env_key 包含空白:', any(char.isspace() for char in env_key))
        valid = bool(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', env_key))
        print('env_key 是標準變數名稱:', valid)
        if env_key != 'STRATA_API_KEY':
            problems.append(role + ' 的 strata.env_key 不是 STRATA_API_KEY。')
    print('設定含 profiles:', bool(config.get('profiles')))
    print('注意：不輸出模型、網址、headers 或 profiles 的內容。')

inspect_config(effective_home / 'config.toml', '使用者設定')
if effective_home.resolve() != default_home.resolve():
    inspect_config(default_home / 'config.toml', '預設目錄設定（可能不是目前使用的）')
for index, directory in enumerate([pathlib.Path.cwd(), *pathlib.Path.cwd().parents]):
    candidate = directory / '.codex/config.toml'
    if candidate.is_file() and candidate.resolve() != (effective_home / 'config.toml').resolve():
        inspect_config(candidate, '專案/上層候選設定 ' + str(index))
        print('注意：存在不代表已載入，仍取決於信任與設定載入規則。')

print('\n[4] 結論')
if problems:
    for problem in problems:
        print('CHECK:', problem)
else:
    print('未在上述檢查發現直接原因；不代表 API 金鑰有效或服務可連線。')
print('若仍報缺少變數：需比對實際啟動方式、CLI -c/--profile 參數及已開啟程式的舊環境。')
print('本工具未讀取或執行 .bashrc，也不會測試 API 認證。')
print('=== 報告結束；可貼回此報告，勿貼金鑰或完整 env ===')
PY
