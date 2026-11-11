#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectDirectory = (Join-Path $env:USERPROFILE 'codex-projects')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Backup-ExistingFile([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Copy-Item -LiteralPath $Path -Destination ($Path + '.' + [guid]::NewGuid().ToString('N') + '.bak')
    }
}

function Add-PathEntry([string]$ExistingPath, [string]$NewEntry) {
    $entries = @($ExistingPath -split ';' | Where-Object { $_.Trim() })
    foreach ($entry in $entries) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\', '/')
        if ($expanded -ieq $NewEntry.TrimEnd('\', '/')) { return $ExistingPath }
    }
    if ([string]::IsNullOrWhiteSpace($ExistingPath)) { return $NewEntry }
    return $ExistingPath.TrimEnd(';') + ';' + $NewEntry
}

try {
    if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows, not WSL.' }
    $installDir = Join-Path $env:USERPROFILE 'codex-gx10'
    $launcherPath = Join-Path $installDir 'Start-Codex-GX10.ps1'
    $configPath = Join-Path $installDir 'codex-home\config.toml'
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw 'GX10 launcher/config not found. Complete install-codex-gx10.ps1 -UseApiKey first.'
    }
    $desktop = [Environment]::GetFolderPath('DesktopDirectory')
    if (-not $desktop -or -not (Test-Path -LiteralPath $desktop -PathType Container)) {
        throw 'Windows Desktop folder is unavailable.'
    }
    $ProjectDirectory = [IO.Path]::GetFullPath($ProjectDirectory)
    $binDir = Join-Path $installDir 'bin'
    $commandPath = Join-Path $binDir 'codex-gx10.cmd'
    $shortcutPath = Join-Path $desktop 'Codex GX10.lnk'
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath)) { throw 'Windows PowerShell is unavailable.' }
    $shell = New-Object -ComObject WScript.Shell
    New-Item -ItemType Directory -Force -Path $binDir, $ProjectDirectory | Out-Null
    Backup-ExistingFile $commandPath
    Backup-ExistingFile $shortcutPath
    $command = @'
@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\codex-gx10\Start-Codex-GX10.ps1" %*
exit /b %errorlevel%
'@
    [IO.File]::WriteAllText($commandPath, ($command -replace '\r?\n', "`r`n") + "`r`n", [Text.Encoding]::ASCII)
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powershellPath
    $shortcut.Arguments = '-NoProfile -NoExit -ExecutionPolicy Bypass -File "' + $launcherPath + '"'
    $shortcut.WorkingDirectory = $ProjectDirectory
    $shortcut.Description = 'Codex connected to GX10 Strata using the existing isolated configuration'
    $shortcut.Save()
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $updatedPath = Add-PathEntry $userPath $binDir
    if ($updatedPath -cne $userPath) {
        [Environment]::SetEnvironmentVariable('Path', $updatedPath, 'User')
    }
    $env:Path = Add-PathEntry $env:Path $binDir
    Write-Host ''
    Write-Host 'Ready! Double-click Codex GX10 on your Desktop.' -ForegroundColor Green
    Write-Host "Desktop project folder: $ProjectDirectory"
    Write-Host 'Or completely close Windows Terminal / PowerShell, reopen it, then type: codex-gx10'
    Write-Host 'If an existing terminal still cannot find the command, sign out and sign in once.'
    Write-Host 'The short command keeps your current project directory.'
    Write-Host 'Your GX10 model settings and API key handling have not changed.'
    Write-Host 'No API key was read or saved. Existing matching launcher files were backed up.'
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
