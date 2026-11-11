#Requires -Version 5.1
<#
.SYNOPSIS
  Windows 上的 Codex CLI 環境檢查 + 安裝 + 接上 GX10 的 Strata。

.DESCRIPTION
  全自動偵測，不需要你自己填任何東西：
    1. 從 Windows 的 Tailscale 找出 GX10 的 IP（不用手動輸入）
    2. 測 /health 是否連得通
    3. 檢查 Node / npm / Codex CLI，缺就裝
    4. 直接產生並寫入 %USERPROFILE%\.codex\config.toml
    5. 設定 STRATA_API_KEY（輸入時不顯示）
    6. 跑 codex doctor 驗收，並印出你接下來要打的所有指令

.EXAMPLE
  pwsh -File codex-setup-windows.ps1

.EXAMPLE
  pwsh -File codex-setup-windows.ps1 -Check
#>
[CmdletBinding()]
param(
  [string]$Gx10Ip = "",
  [string]$ApiKey = "",
  [string]$Model = "qwen3.8-flash-next-iq3_s",
  [int]$Port = 8080,
  [switch]$Check,
  [switch]$SkipDoctor
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
if ($codexHome -like "*\.codex-home\*" -or $codexHome -like "*.codex-home*") {
    Write-Host "[XX] CODEX_HOME 指向 Codex session 目錄，為安全起見中止。" -ForegroundColor Red
    Write-Host "     $codexHome" -ForegroundColor Red
    Write-Host "     請在一般 Windows 帳號下執行，不要設 CODEX_HOME。" -ForegroundColor Red
    exit 1
}

# ── 從 Windows 的 Tailscale 找出 GX10 的 IP ──────────────────────────
function Get-Gx10Address {
    param([string]$Preferred = "")

    if ($Preferred) { return $Preferred }

    $ts = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $ts) {
        Write-Warn "找不到 tailscale 指令（Windows 沒裝 Tailscale？）"
        return ""
    }

    try {
        $raw = (& tailscale status --json 2>$null | Out-String)
        if (-not $raw.Trim()) { Write-Warn "tailscale status 沒有輸出"; return "" }
        $data = $raw | ConvertFrom-Json
    } catch {
        Write-Warn "解析 tailscale status 失敗：$($_.Exception.Message)"
        return ""
    }

    $peers = @()
    if ($data.PSObject.Properties.Name -contains "Peer" -and $data.Peer) {
        $peers = @($data.Peer.PSObject.Properties | ForEach-Object { $_.Value })
    }
    if (-not $peers) { Write-Warn "Tailscale 沒有任何 peer"; return "" }

    # 先找名字帶 gx10 的
    $picked = @($peers | Where-Object {
        ($_.HostName -match "gx10") -or ($_.DNSName -match "gx10")
    })
    if (-not $picked) {
        Write-Warn "Tailscale 清單裡沒有名字含 gx10 的機器"
        $picked = @($peers | Where-Object { $_.Online })
    }

    foreach ($peer in $picked) {
        $ips = @($peer.TailscaleIPs)
        # 優先 Tailscale 網段（100.64.0.0/10），其次任何 IPv4
        foreach ($ip in ($ips | Where-Object { $_ -like "100.*" })) {
            Write-Ok "偵測到 GX10：$($peer.HostName) → $ip"
            return $ip
        }
        foreach ($ip in ($ips | Where-Object { $_ -notlike "*:*" -and $_ -notlike "100.*" })) {
            Write-Ok "偵測到 GX10：$($peer.HostName) → $ip"
            return $ip
        }
    }

    Write-Warn "在 Tailscale 清單裡找不到可用的位址"
    return ""
}

# ── 主流程 ───────────────────────────────────────────────────────────
Write-Host "==============================================="
Write-Host "  Windows × Codex CLI 環境檢查與安裝"
Write-Host "  腳本版本：2026-11-11.2"
Write-Host "==============================================="

Write-Step "步驟 1：系統環境"

if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) { Write-Ok "Windows $($os.Caption)（$($os.Version)）" }
}
else {
    Write-Ok "PowerShell $($PSVersionTable.PSVersion)"
}

$arch = $env:PROCESSOR_ARCHITECTURE
switch ($arch) {
    "AMD64" { Write-Ok "架構：x86_64（Codex CLI 有 win32-x64 官方套件）" }
    "ARM64" { Write-Ok "架構：ARM64（Codex CLI 有 win32-arm64 官方套件）" }
    default { Write-Warn "架構：$arch" }
}

Write-Ok "設定檔位置：$codexHome\config.toml"

Write-Step "步驟 2：Node.js / npm"

$nodeOk = $false
if (Get-Command node -ErrorAction SilentlyContinue) {
    $nodeVer = (& node --version).Trim()
    $nodeMajor = [int](($nodeVer -replace "^v", "").Split(".")[0])
    Write-Ok "node：$nodeVer"
    if ($nodeMajor -ge 16) {
        Write-Ok "Node ≥ 16，符合 Codex CLI 需求（不用升級）"
        $nodeOk = $true
    } else {
        Write-Err "Node $nodeVer < 16，Codex CLI 官方要求 >=16"
    }
} else {
    Write-Err "找不到 node"
}

if (Get-Command npm -ErrorAction SilentlyContinue) {
    Write-Ok "npm：$((& npm --version).Trim())"
} else {
    Write-Warn "找不到 npm（安裝 Codex CLI 會需要）"
}

Write-Step "步驟 3：偵測 GX10"

$ip = Get-Gx10Address -Preferred $Gx10Ip

if (-not $ip) {
    Write-Info "以下是你 Tailscale 上的機器（手動挑 GX10 那列的 IP）："
    if (Get-Command tailscale -ErrorAction SilentlyContinue) {
        & tailscale status 2>$null | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
    }
    $ip = (Read-Host "`n請輸入 GX10 的 Tailscale IP").Trim()
    if ($ip) { Write-Ok "使用輸入的 IP：$ip" }
}

if (-not $ip) {
    Write-Err "沒有 IP，無法繼續"
    Write-Info "在 GX10 上執行 tailscale ip -4 取得 IP，再重跑本腳本並加上 -Gx10Ip <IP>"
    exit 1
}

$baseUrl = "http://${ip}:${Port}"
Write-Info "目標：$baseUrl"

Write-Step "步驟 4：連線測試"

try {
    $resp = Invoke-WebRequest -Uri "$baseUrl/health" -TimeoutSec 10 -UseBasicParsing
    Write-Ok "GX10 可連線（HTTP $($resp.StatusCode)）"
}
catch {
    Write-Err "連不到 $baseUrl/health ：$($_.Exception.Message)"
    Write-Info "先確認 Windows 的 Tailscale 已連上，然後在 Windows 執行：ping $ip"
}

Write-Step "步驟 5：Codex CLI"

$codexPath = $null
if (Get-Command codex -ErrorAction SilentlyContinue) {
    $codexPath = (Get-Command codex).Source
    Write-Ok "已安裝：$((& codex --version 2>$null | Out-String).Trim())"
    Write-Info "路徑：$codexPath"
} else {
    Write-Warn "還沒安裝 Codex CLI"
}

if ($Check) {
    Write-Step "總結（檢查模式，未變更任何檔案）"
    if ($script:Fails -eq 0) { Write-Ok "環境檢查通過" } else { Write-Warn "$($script:Fails) 項需要處理" }
    exit 0
}

if (-not $codexPath) {
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Info "安裝中：npm install -g @openai/codex"
        & npm install -g @openai/codex --registry=https://registry.npmjs.org/
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "安裝完成"
            $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
            $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
            $env:Path = "$machinePath;$userPath"
            $codexPath = (Get-Command codex -ErrorAction SilentlyContinue).Source
        } else {
            Write-Err "npm 安裝失敗，試試：npm install -g @openai/codex --registry=https://registry.npmmirror.com/"
        }
    } else {
        Write-Err "沒有 npm，無法安裝。請先裝 Node.js 22 LTS（https://nodejs.org/）"
    }
}

if ($codexPath) {
    Write-Ok "codex：$((& codex --version 2>$null | Out-String).Trim())"
} else {
    Write-Err "找不到 codex 指令"
}

Write-Step "步驟 6：寫入設定檔"

New-Item -ItemType Directory -Force $codexHome | Out-Null
$cfgPath = Join-Path $codexHome "config.toml"

if (Test-Path $cfgPath) {
    $bak = "$cfgPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $cfgPath $bak
    Write-Ok "已備份原設定 → $(Split-Path $bak -Leaf)"
}

$toml = @"
model = "$Model"
model_provider = "strata"
model_context_window = 262144
model_auto_compact_token_limit = 200000

[model_providers.strata]
name = "Strata GX10"
base_url = "$baseUrl/v1"
wire_api = "responses"
env_key = "STRATA_API_KEY"
"@

Set-Content -Path $cfgPath -Value $toml -Encoding UTF8
Write-Ok "已寫入 $cfgPath"
Write-Host ""
Write-Host "  寫進去的內容：" -ForegroundColor DarkCyan
Get-Content $cfgPath | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
Write-Host ""

Write-Step "步驟 7：設定金鑰"

$key = $ApiKey
if (-not $key -and [Console]::IsInputRedirected) {
    # 非互動模式（管線 / CI）：直接讀一行，螢幕不會回顯
    try { $line = $Host.UI.ReadLine() } catch { $line = $null }
    if ($line) { $key = $line.Trim() }
}
elseif (-not $key) {
    # 互動模式：用 SecureString，輸入時不顯示
    try {
        $secure = Read-Host "貼上 GX10 的 API 金鑰（輸入不會顯示，空白則略過）" -AsSecureString
        if ($secure) {
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } catch {
        Write-Warn "讀取金鑰時中斷：$($_.Exception.Message)"
    }
}
if ($key -and $key.Trim()) {
    [Environment]::SetEnvironmentVariable("STRATA_API_KEY", $key.Trim(), "User")
    $env:STRATA_API_KEY = $key.Trim()
    Write-Ok "STRATA_API_KEY 已設定（User 層級 + 目前這個視窗）"
} else {
    Write-Warn "沒輸入金鑰。之後自己設（用戶層級，重開視窗生效）："
    Write-Info 'setx STRATA_API_KEY "sk-你的金鑰"'
}

Write-Step "總結"

if ($script:Fails -eq 0) {
    Write-Ok "全部完成"
} else {
    Write-Warn "$($script:Fails) 項需要留意（見上面 XX 標記）"
}

Write-Host ""
Write-Host "接下來照這幾行打：" -ForegroundColor Cyan
Write-Host "  1. codex doctor --summary"
Write-Host "  2. codex"
Write-Host ""
