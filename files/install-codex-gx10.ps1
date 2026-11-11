#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Gx10Host,
    [ValidateRange(1, 65535)][int]$Port = 8080,
    [string]$Model,
    [switch]$UseApiKey,
    [switch]$CheckOnly,
    [switch]$TestResponse
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Update-ProcessPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
        [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + $env:Path
}

function ConvertTo-TomlString([string]$Value) {
    if ($Value -match '[\x00-\x1f\x7f]') { throw 'Invalid control character in setting.' }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

try {
    if ($env:OS -ne 'Windows_NT') { throw 'Run this script in Windows PowerShell, not WSL.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not $Gx10Host) {
        $tailscale = Get-Command tailscale.exe -ErrorAction SilentlyContinue
        $tailscalePath = if ($tailscale) { $tailscale.Source } else { $null }
        if (-not $tailscale) {
            $candidate = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
            if (Test-Path $candidate) { $tailscalePath = $candidate }
        }
        if ($tailscalePath) {
            try {
                $statusText = & $tailscalePath status --json 2>$null
                if ($LASTEXITCODE -ne 0) { throw 'Tailscale is not ready.' }
                $status = ($statusText | Out-String) | ConvertFrom-Json
                $peers = @($status.Peer.PSObject.Properties.Value | Where-Object {
                    $_.HostName -match 'gx10' -or $_.DNSName -match 'gx10'
                })
                if ($peers.Count -eq 1) {
                    $Gx10Host = @($peers[0].TailscaleIPs | Where-Object { $_ -notmatch ':' })[0]
                    Write-Host "Detected GX10: $Gx10Host"
                }
            } catch { Write-Warning 'Automatic discovery failed; enter the address manually.' }
        }
        if (-not $Gx10Host) { $Gx10Host = Read-Host 'GX10 Tailscale IPv4 address or hostname (no http://)' }
    }
    if ($Gx10Host -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.\-]*$') {
        throw 'Enter only an IPv4 address or DNS hostname, without a port or URL.'
    }
    $baseUrl = "http://${Gx10Host}:$Port/v1"
    Write-Host "Testing $baseUrl/models"
    Write-Host 'Use this HTTP endpoint only over your trusted Tailscale network.'
    $headers = @{}
    if ($UseApiKey) {
        $secureKey = Read-Host 'Strata API key (not saved)' -AsSecureString
        $credential = New-Object System.Net.NetworkCredential('', $secureKey)
        $headers.Authorization = 'Bearer ' + $credential.Password
        $credential = $null
        $secureKey.Dispose()
    }
    try {
        $catalog = Invoke-RestMethod -Uri "$baseUrl/models" -Headers $headers -TimeoutSec 30
        $modelIds = @($catalog.data | ForEach-Object { $_.id } | Where-Object { $_ })
        if ($modelIds.Count -eq 0) { throw 'The server returned no model IDs.' }
        if (-not $Model) {
            if ($modelIds.Count -eq 1) { $Model = $modelIds[0] }
            else {
                Write-Host ('Available models: ' + ($modelIds -join ', '))
                $Model = Read-Host 'Enter the exact model ID'
            }
        }
        if ($modelIds -cnotcontains $Model) { throw 'The selected model is not in /v1/models.' }
        Write-Host "Model: $Model"
        if ($TestResponse) {
            $body = @{ model = $Model; input = 'Reply only OK.'; stream = $false; max_output_tokens = 128 } | ConvertTo-Json
            $response = Invoke-RestMethod -Uri "$baseUrl/responses" -Method Post -Headers $headers `
                -ContentType 'application/json' -Body $body -TimeoutSec 180
            if (-not $response.PSObject.Properties['output'] -or @($response.output).Count -eq 0) {
                throw 'The Responses endpoint returned no output. Check Strata compatibility.'
            }
            Write-Host 'Responses endpoint returned output. Tool calling still requires a Codex test.'
        }
    } finally { $headers.Clear() }

    if ($CheckOnly) {
        Write-Host 'Connection check passed. No software or configuration was changed.'
        return
    }

    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    $needNode = -not $node
    if ($node) {
        $nodeVersion = & node.exe --version
        if ($LASTEXITCODE -ne 0) { throw 'Cannot read Node.js version.' }
        $needNode = [int](($nodeVersion -replace '^v', '').Split('.')[0]) -lt 22
    }
    if ($needNode) {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            throw 'Install Node.js LTS from nodejs.org, reopen PowerShell, then rerun this script.'
        }
        Write-Host 'Installing Node.js LTS using winget. Windows may request administrator approval.'
        & winget.exe install --id OpenJS.NodeJS.LTS --exact --source winget `
            --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw 'Node.js installation failed. Install LTS manually and rerun.' }
        Update-ProcessPath
    }
    if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
        throw 'npm.cmd is unavailable. Reopen PowerShell after installing Node.js LTS.'
    }
    Write-Host 'Installing the current Codex CLI from npm...'
    & npm.cmd install -g '@openai/codex@latest'
    if ($LASTEXITCODE -ne 0) { throw 'Codex installation failed.' }
    Update-ProcessPath
    $npmPrefix = (& npm.cmd prefix -g | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot locate the npm installation directory.' }
    $codexPath = Join-Path $npmPrefix 'codex.cmd'
    if (-not (Test-Path $codexPath)) { throw 'codex.cmd was not found after installation.' }
    & $codexPath --version
    if ($LASTEXITCODE -ne 0) { throw 'Codex cannot start.' }

    $installDir = Join-Path $env:USERPROFILE 'codex-gx10'
    $codexHome = Join-Path $installDir 'codex-home'
    New-Item -ItemType Directory -Force $codexHome | Out-Null
    $modelLiteral = ConvertTo-TomlString $Model
    $urlLiteral = ConvertTo-TomlString $baseUrl
    $keySetting = if ($UseApiKey) { 'env_key = "STRATA_API_KEY"' } else { '' }
    $config = @"
model = $modelLiteral
model_provider = "strata"

[model_providers.strata]
name = "GX10 Strata"
base_url = $urlLiteral
wire_api = "responses"
requires_openai_auth = false
$keySetting
"@
    $launcher = @'
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$previousHome = $env:CODEX_HOME
$previousKey = $env:STRATA_API_KEY
$exitCode = 0
try {
    $env:CODEX_HOME = Join-Path $PSScriptRoot 'codex-home'
    if (__USE_KEY__ -and -not $env:STRATA_API_KEY) {
        $secureKey = Read-Host 'Strata API key (not saved)' -AsSecureString
        $credential = New-Object System.Net.NetworkCredential('', $secureKey)
        $env:STRATA_API_KEY = $credential.Password
        $credential = $null
        $secureKey.Dispose()
    }
    & '__CODEX_PATH__' @args
    $exitCode = $LASTEXITCODE
} finally {
    $env:CODEX_HOME = $previousHome
    $env:STRATA_API_KEY = $previousKey
}
exit $exitCode
'@
    $keyLiteral = if ($UseApiKey) { '$true' } else { '$false' }
    $launcher = $launcher.Replace('__USE_KEY__', $keyLiteral).Replace('__CODEX_PATH__', $codexPath.Replace("'", "''"))
    $configPath = Join-Path $codexHome 'config.toml'
    $launcherPath = Join-Path $installDir 'Start-Codex-GX10.ps1'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($target in @($configPath, $launcherPath)) {
        if (Test-Path $target) { Copy-Item -LiteralPath $target -Destination ($target + '.' + [guid]::NewGuid().ToString('N') + '.bak') }
    }
    [IO.File]::WriteAllText($configPath, $config, $utf8)
    [IO.File]::WriteAllText($launcherPath, $launcher, $utf8)
    Write-Host ''
    Write-Host 'Installation complete. Your existing .codex settings were not changed.' -ForegroundColor Green
    Write-Host 'From your project directory, run:'
    Write-Host ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $launcherPath + '"')
    Write-Host 'First ask for a text reply, then test creating a disposable file.'
    Write-Host 'This installer does not change GX10, firewall rules, or persistent execution policy.'
} catch {
    Write-Error $_ -ErrorAction Continue
    Write-Host 'Check Tailscale connectivity, the Strata port/bind address, and API authorization.'
    exit 1
}
