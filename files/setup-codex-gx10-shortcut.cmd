@echo off
setlocal
set "GX10_SETUP=%TEMP%\codex-gx10-shortcut-%RANDOM%-%RANDOM%.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; try { Invoke-WebRequest -UseBasicParsing -Uri 'https://kilroy-utb.github.io/hub/files/setup-codex-gx10-shortcut.ps1' -OutFile $env:GX10_SETUP; if ((Get-FileHash -LiteralPath $env:GX10_SETUP -Algorithm SHA256).Hash -ne '0fa2fec04f208ef487b800dc18e396c5133c6088f06144b52d1b1ce4891ebf88') { throw 'Download verification failed. Download the latest setup CMD from the hub and retry.' }; & $env:GX10_SETUP; if (-not $?) { exit 1 } } catch { Write-Error $_; exit 1 }"
if errorlevel 1 (
  echo Setup failed. Read the message above.
  pause
  exit /b 1
)
echo.
echo Setup finished. You may close this window.
pause
exit /b 0
