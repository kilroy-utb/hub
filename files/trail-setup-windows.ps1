#Requires -Version 5.1
<#
.SYNOPSIS
  Windows 上安裝 Trail（舊名 Graft）+ 接到 Codex CLI / GitHub Copilot。

.DESCRIPTION
  全自動偵測，不需要你自己填任何東西：
    1. 檢查 Node（Trail 需要 ^20.16.0 || >=22.3.0）
    2. npm 安裝 @trailhq/trail-code（遇到權限問題自動改用 LOCALAPPDATA）
    3. 從 Windows 的 Tailscale 找出 GX10 的 IP（不用手動輸入）
    4. 先備份 %USERPROFILE%\.codex\config.toml 與 hooks.json
    5. 在指定專案執行 trail init --agents agents copilot
    6. 選用 -Deep：改用 GX10 的 Strata 做深度摘要（省 API 額度）

.EXAMPLE
  pwsh -File trail-setup-windows.ps1 -Repo C:\code\myproject

.EXAMPLE
  pwsh -File trail-setup-windows.ps1 -Repo C:\code\myproject -Deep
#>
[CmdletBinding()]
param(
  [string]$Repo = "",
  [string]$Gx10Host = "",
  [string]$ApiKey = "",
  [string]$Model = "qwen3.8-flash-next-iq3_s",
  [int]$Port = 8080,
  [switch]$Deep,
  [switch]$Check
)

$ErrorActionPreference = "Continue"
$script:Fails = 0

function Write-Ok   { param($m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "  [XX] $m" -ForegroundColor Red; $script:Fails++ }
function Write-Info { param($m) Write-Host "  -- $m" -ForegroundColor DarkCyan }
function Write-Step { param($m) Write-Host ""; Write-Host "== $m ==" -ForegroundColor Cyan }

# ── 安全護欄：絕不寫進 Codex session 目錄 ────────────────────────────
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "$env:USERPROFILE\.codex" }
if ($codexHome -like "*.codex-home*") {
    Write-Host "[XX] CODEX_HOME 指向 Codex session 目錄，為安全起見中止。" -ForegroundColor Red
    Write-Host "     $codexHome" -ForegroundColor Red
    Write-Host "     請在一般 Windows 帳號下執行，不要設 CODEX_HOME。" -ForegroundColor Red
    exit 1
}

# ── npm / node 指令（Windows 上是 .cmd） ──────────────────────────────
function Get-NpmCmd {
    $c = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $c = Get-Command npm -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return ""
}

# ── 從 Windows 的 Tailscale 找出 GX10 的 IP ──────────────────────────
function Get-Gx10Address {
    param([string]$Preferred = "")

    if ($Preferred) {
        if ($Preferred -match '^\d+\.\d+\.\d+\.\d+$') { Write-Ok "使用指定的 GX10 IP：$Preferred" }
        else { Write-Ok "使用指定的 GX10 主機名：$Preferred" }
        return $Preferred
    }

    $ts = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $ts) {
        Write-Warn "找不到 tailscale 指令（Windows 沒裝 Tailscale？）"
        return "gx10-37a8"
    }

    try {
        $raw = (& tailscale status --json 2>$null | Out-String)
        if (-not $raw.Trim()) { Write-Warn "tailscale status 沒有輸出"; return "gx10-37a8" }
        $data = $raw | ConvertFrom-Json
    } catch {
        Write-Warn "解析 tailscale status 失敗：$($_.Exception.Message)"
        return "gx10-37a8"
    }

    $peers = @()
    if ($data.PSObject.Properties.Name -contains "Peer" -and $data.Peer) {
        $peers = @($data.Peer.PSObject.Properties | ForEach-Object { $_.Value })
    }
    if (-not $peers) { Write-Warn "Tailscale 沒有任何 peer"; return "gx10-37a8" }

    $picked = @($peers | Where-Object { ($_.HostName -match "gx10") -or ($_.DNSName -match "gx10") })
    if (-not $picked) {
        Write-Warn "Tailscale 清單裡沒有名字含 gx10 的機器，改用第一台在線的 peer"
        $picked = @($peers | Where-Object { $_.Online })
    }

    foreach ($peer in $picked) {
        $ips = @($peer.TailscaleIPs)
        foreach ($ip in ($ips | Where-Object { $_ -like "100.*" })) {
            Write-Ok "偵測到 GX10：$($peer.HostName) → $ip"
            return $ip
        }
        foreach ($ip in ($ips | Where-Object { $_ -notlike "*:*" -and $_ -notlike "100.*" })) {
            Write-Ok "偵測到 GX10：$($peer.HostName) → $ip"
            return $ip
        }
    }

    Write-Warn "在 Tailscale 清單裡找不到可用的位址，改用主機名 gx10-37a8"
    return "gx10-37a8"
}

# ── 主流程 ───────────────────────────────────────────────────────────
Write-Host "==============================================="
Write-Host "  Windows × Trail（code context graph）安裝"
Write-Host "  腳本版本：2026-11-11.1"
Write-Host "==============================================="

Write-Step "步驟 1：系統環境"
if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) { Write-Ok "Windows $($os.Caption)（$($os.Version)）" }
} else {
    Write-Ok "PowerShell $($PSVersionTable.PSVersion)"
}
switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { Write-Ok "架構：x86_64" }
    "ARM64" { Write-Ok "架構：ARM64" }
    default { Write-Warn "架構：$($env:PROCESSOR_ARCHITECTURE)" }
}
Write-Ok "Codex 設定檔位置：$codexHome\config.toml"
# Codex 讀的是 CODEX_HOME（沒設就是 %USERPROFILE%\.codex），
# Trail 寫的是 %USERPROFILE%\.codex。兩者不一致的話 Codex 會讀不到。
$defaultCodexHome = "$env:USERPROFILE\.codex"
if ($env:CODEX_HOME -and ($codexHome -ne $defaultCodexHome)) {
    Write-Warn "你設了 CODEX_HOME=$codexHome，但 Trail 寫入的位置是 $defaultCodexHome"
    Write-Info "兩者不一致，Codex 可能讀不到 MCP/hooks。建議：Remove-Item Env:\CODEX_HOME"
}

Write-Step "步驟 2：Node.js 與 npm"

$npmCmd = Get-NpmCmd
if (-not $npmCmd) {
    Write-Err "找不到 npm"
    Write-Host ""
    Write-Host "== 總結 =="
    Write-Err "npm 缺失，無法繼續"
    exit 1
}
Write-Ok "npm：$npmCmd"

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Err "找不到 node —— Trail 需要 Node ^20.16.0 或 >=22.3.0"
    Write-Host ""
    Write-Host "== 總結 =="
    Write-Err "Node 缺失，無法繼續"
    exit 1
}

$nodeVer = (& node --version).Trim()
$nodeNum = $nodeVer -replace '^v', ''
$parts = $nodeNum.Split('.')
$nodeMajor = [int]$parts[0]
$nodeMinor = [int]$parts[1]
$nodeOk = ($nodeMajor -gt 22) -or
          ($nodeMajor -eq 22 -and $nodeMinor -ge 3) -or
          ($nodeMajor -eq 20 -and $nodeMinor -ge 16)
if ($nodeOk) {
    Write-Ok "Node $nodeVer（Trail 要求 ^20.16.0 || >=22.3.0）"
} else {
    Write-Err "Node $nodeVer 太舊，Trail 要求 ^20.16.0 || >=22.3.0"
    Write-Info "升級到 Node 22 LTS：https://nodejs.org/ 下載 22.x 的 Windows Installer (.msi)"
}

Write-Step "步驟 3：安裝 Trail"

$pkg = "@trailhq/trail-code"
if ($Check) {
    Write-Info "check 模式，略過安裝"
} else {
    Write-Info "安裝 $pkg …"
    $out = & $npmCmd install -g $pkg --registry=https://registry.npmjs.org/ 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "npm 安裝失敗，改用 LOCALAPPDATA 前綴重試"
        $fallback = "$env:LOCALAPPDATA\npm-global"
        New-Item -ItemType Directory -Force -Path $fallback | Out-Null
        $out2 = & $npmCmd install -g $pkg --prefix $fallback --registry=https://registry.npmjs.org/ 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Err "npm 安裝失敗"
            Write-Info "請手動執行：$npmCmd install -g $pkg"
            Write-Info ($out2.Trim() -split "`n" | Select-Object -Last 4 | Out-String)
        } else {
            Write-Ok "安裝完成（前綴 $fallback）"
            $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
            if ($userPath -notlike "*$fallback*") {
                [Environment]::SetEnvironmentVariable("Path", "$userPath;$fallback", "User")
                Write-Ok "已把 $fallback 加到使用者 PATH（重開終端機生效）"
            }
        }
    } else {
        Write-Ok "安裝完成"
    }
}

$trailCmd = Get-Command trail.cmd -ErrorAction SilentlyContinue
if (-not $trailCmd) { $trailCmd = Get-Command trail -ErrorAction SilentlyContinue }
if ($trailCmd) {
    Write-Ok "trail：$($trailCmd.Source)"
    Write-Ok ("版本：" + ((& trail --version 2>&1 | Out-String).Trim()))
} else {
    Write-Err "找不到 trail 指令"
    Write-Info "重開終端機讓 PATH 生效後再試：trail --version"
}

Write-Step "步驟 4：Codex CLI"
$codexCmd = Get-Command codex -ErrorAction SilentlyContinue
if ($codexCmd) {
    Write-Ok "codex：$((& codex --version 2>&1 | Select-Object -First 1))"
} else {
    Write-Warn "這台機器沒裝 Codex CLI —— Trail 的 MCP/hook 接不上去"
    Write-Info "先跑 codex-setup-windows.ps1 裝好 Codex"
}
if (Test-Path $codexHome) { Write-Ok "Codex 設定目錄：$codexHome" }
else { Write-Warn "$codexHome 不存在，Trail 會略過 Codex 的 MCP 與 hook 接線" }

Write-Step "步驟 5：備份 Codex 設定"
New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
foreach ($f in @("config.toml", "hooks.json")) {
    $src = Join-Path $codexHome $f
    if (Test-Path $src) {
        Copy-Item $src "$src.bak-$ts" -Force
        Write-Ok "已備份 $f → $f.bak-$ts"
    } else {
        Write-Info "$f 不存在，無需備份"
    }
}
Write-Info "Trail 只會「附加」區段，不會重寫整份 config.toml，你的 Strata provider 設定會保留"

Write-Step "步驟 6：在專案啟用 Trail"

$target = ""
if ($Repo) {
    if (Test-Path $Repo) { $target = (Resolve-Path $Repo).Path }
    else { Write-Err "指定的 -Repo 目錄不存在：$Repo" }
} elseif (Test-Path (Join-Path (Get-Location) ".git")) {
    $target = (Get-Location).Path
    Write-Info "未指定 -Repo，使用目前目錄：$target"
} else {
    Write-Info "未指定 -Repo，且目前目錄不是 git 專案"
    Write-Info "啟用指令（換成你的專案路徑）："
    Write-Info "  cd C:\code\myproject; trail init --agents agents copilot"
}

if ($target) {
    if (-not (Test-Path (Join-Path $target ".git"))) {
        Write-Warn "$target 沒有 .git（不是 git 專案），仍可建立地圖，但 teammates 拿不到"
    }
    if ($Check) {
        Write-Info "check 模式，實際會寫入的檔案："
        Push-Location $target
        try { & trail init --agents agents copilot --dry-run 2>&1 | ForEach-Object { Write-Host "    $_" } }
        catch { Write-Warn $_ }
        Pop-Location
    } else {
        Push-Location $target
        try {
            & trail init --agents agents copilot 2>&1 | Select-Object -Last 12 | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -eq 0) { Write-Ok "trail init 完成" }
            else { Write-Err "trail init 失敗（退出碼 $LASTEXITCODE）" }
        } catch { Write-Err "trail init 失敗：$_" }
        Pop-Location
        Write-Info "產生的東西："
        Write-Info "  $target\AGENTS.md                         （Codex 會讀）"
        Write-Info "  $target\.github\copilot-instructions.md  （VS Code Copilot 會讀）"
        Write-Info "  $target\.trail\                          （地圖 + 學習紀錄）"
        Write-Info "  $codexHome\config.toml                   （新增 [mcp_servers.trail]）"
        Write-Info "  $codexHome\hooks.json                    （自動更新地圖的 hooks）"
    }
}

Write-Step "步驟 7：驗收"

$trailPath = $null
if ($trailCmd) { $trailPath = $trailCmd.Source }

if ($trailPath) {
    # 真實握手一次，確認 MCP server 真的起得來（用 Job + timeout 避免卡住）
    $job = Start-Job -ScriptBlock {
        param($bin)
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1.0"}}}' | & $bin mcp 2>$null
    } -ArgumentList $trailPath
    $probeOut = ""
    if (Wait-Job $job -Timeout 30) {
        $probeOut = (Receive-Job $job | Out-String)
    } else {
        Stop-Job $job -ErrorAction SilentlyContinue
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ($probeOut -match 'serverInfo') {
        Write-Ok "MCP server 握手成功"
    } else {
        Write-Err "MCP server 握手失敗 —— Codex 的地圖查詢工具會不能用"
        Write-Info "手動測試："
        Write-Info "  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"p","version":"1"}}}' | trail mcp"
    }
}

$codexCmd2 = Get-Command codex -ErrorAction SilentlyContinue
if ($codexCmd2) {
    Write-Info "Codex 已註冊的 MCP server："
    $oldHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $codexHome
        & codex mcp list 2>&1 | ForEach-Object { Write-Host "      $_" }
    } finally {
        if ($null -eq $oldHome) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue }
        else { $env:CODEX_HOME = $oldHome }
    }
}

$cfgPath = Join-Path $codexHome "config.toml"
if ((Test-Path $cfgPath) -and (Select-String -Path $cfgPath -Pattern "mcp_servers" -Quiet)) {
    Write-Ok "config.toml 已含 [mcp_servers.trail]"
    Write-Info "你的 Strata provider 區段原封不動（附加式寫入，非覆蓋）"
} else {
    Write-Warn "config.toml 沒有 [mcp_servers.trail] —— 重新執行本腳本並帶 -Repo"
}

if ($target -and (Test-Path (Join-Path $target "AGENTS.md"))) {
    Write-Ok "AGENTS.md 已寫入（Codex 每次開 session 都會讀）"
}

if (Test-Path (Join-Path $codexHome "hooks.json")) {
    Write-Warn "Codex 預設不執行別人寫的 hook —— 必須手動信任一次"
    Write-Info "開 Codex 後輸入：/hooks  →  找到 graft-hooks.cjs  → 信任"
    Write-Info "沒信任的話，hook 不會自動更新地圖（其他功能照常可用）"
}

Write-Step "步驟 8：深度摘要（-Deep）"

if (-not $Deep) {
    Write-Info "未加 -Deep，略過（地圖本身不需要 LLM，照樣能用）"
} else {
    if (-not $target) {
        Write-Warn "-Deep 需要 -Repo 指定專案"
    } else {
        $host_ = Get-Gx10Address -Preferred $Gx10Host
        $base = "http://${host_}:$Port"
        Write-Info "測試 GX10：$base/health"
        try {
            $r = Invoke-WebRequest -Uri "$base/health" -TimeoutSec 8 -UseBasicParsing
            if ($r.StatusCode -eq 200) { Write-Ok "GX10 Strata 可連線" }
            else { Write-Warn "GX10 回 HTTP $($r.StatusCode)" }
        } catch {
            Write-Warn "連不上 $base/health —— 請確認 GX10 正在跑、且已 --expose"
            Write-Info "PowerShell 測試：Invoke-WebRequest $base/health -UseBasicParsing"
            Write-Info "若 MagicDNS 抓不到，改用 Tailscale IP：-Gx10Host 100.x.y.z"
        }

        # 找金鑰：參數 → 環境變數 → 使用者層級環境變數 → 互動輸入
        $key = $ApiKey
        if (-not $key) { $key = $env:STRATA_API_KEY }
        if (-not $key) { $key = [Environment]::GetEnvironmentVariable("STRATA_API_KEY", "User") }
        if (-not $key -and -not [Console]::IsInputRedirected) {
            try {
                $sec = Read-Host "請輸入 Strata api_key（輸入時不顯示）" -AsSecureString
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
                $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            } catch { $key = "" }
        }
        if (-not $key) {
            Write-Warn "沒有 api_key，略過 -Deep"
            Write-Info "設定方式：[Environment]::SetEnvironmentVariable('STRATA_API_KEY','你的金鑰','User')"
        } else {
            Write-Ok "已取得 api_key（不會顯示內容）"
            Write-Info "測試模型端點（$base/v1）"
            $body = @{ model = $Model; messages = @(@{ role = "user"; content = "hi" }); max_tokens = 1 } | ConvertTo-Json -Depth 5
            try {
                $resp = Invoke-RestMethod -Uri "$base/v1/chat/completions" -Method Post -ContentType "application/json" `
                    -Headers @{ Authorization = "Bearer $key" } -Body $body -TimeoutSec 30
                Write-Ok "模型端點可呼叫"
                Write-Info "開始深度摘要（會跑一陣子，視專案大小）"
                Push-Location $target
                try {
                    $env:GRAFT_PROVIDER = "openai"
                    $env:GRAFT_BASE_URL = "$base/v1"
                    $env:GRAFT_API_KEY = $key
                    $env:GRAFT_MODEL = $Model
                    & trail build --deep 2>&1 | Select-Object -Last 15 | ForEach-Object { Write-Host $_ }
                } finally { Pop-Location }
                Write-Ok "深度摘要完成"
            } catch {
                Write-Warn "模型端點呼叫失敗：$($_.Exception.Message)"
                Write-Info "先測試：Invoke-RestMethod $base/v1/models -Headers @{Authorization='Bearer <key>'}"
            }
        }
    }
}

Write-Host ""
Write-Host "== 總結 =="
if ($script:Fails -eq 0) { Write-Ok "全部完成" }
else { Write-Warn "有 $($script:Fails) 項需要留意（見上面 XX 標記）" }

Write-Host @"

下一步：
  1. 重開終端機（讓 PATH 生效），確認：
       trail --version
       codex --version
  2. 進你的專案，開 Codex：
       cd C:\code\myproject
       codex
  3. 開 codex 後輸入 /hooks，把 graft-hooks.cjs 的項目信任掉
     （不信任的話，hook 不會自動更新地圖）
  4. 讓 agent 用地圖的方式（AGENTS.md 已寫好，也可以直接說）：
       「先跑 trail map，再 trail ask "<你的問題>" --source」
  5. VS Code Copilot 也會讀 .github\copilot-instructions.md，重新開一個
     Copilot Chat 視窗即可。
  6. 建議把這些檔案 commit 進 repo：
       git add AGENTS.md .github .trail
       git commit -m "chore: add trail context graph"
"@
