# Codex GX10 快速啟動

先完成原本的 `install-codex-gx10.ps1` 安裝，確認專用啟動器能正常連上 GX10。

下載 `setup-codex-gx10-shortcut.cmd` 後雙擊執行。它會下載並驗證同版 PowerShell 設定腳本，再建立：

- 桌面 `Codex GX10` 捷徑：預設在 `%USERPROFILE%\codex-projects` 工作。
- `codex-gx10` 指令：在目前的專案資料夾啟動。

指令要在完全關閉並重新開啟 Windows Terminal／PowerShell 後使用；若新視窗仍找不到，可登出 Windows 後重新登入。桌面捷徑可以立即使用。

不會更動模型位址、不會讀取或儲存金鑰、不會取代原本的 `codex` 指令。若原啟動器要求 Strata 金鑰，仍會照常詢問。設定只加入使用者 PATH，不需要管理員，也不永久變更執行原則。

同名指令檔或捷徑會先備份，重跑不重複加入 PATH。啟動設定本身仍由 `%USERPROFILE%\codex-gx10\Start-Codex-GX10.ps1` 管理。

如要指定桌面捷徑的工作資料夾，可下載 `.ps1` 後執行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup-codex-gx10-shortcut.ps1 -ProjectDirectory "D:\MyProject"
```

請先檢視腳本再執行；若組織禁止腳本，請聯絡管理員，不要繞過政策。下載器不會停用安全防護。如果 SHA256 驗證失敗，重新下載最新版 `.cmd`，不要移除驗證。

腳本已進行語法及 PATH 處理測試；桌面捷徑、Windows 登錄檔與 GX10 的實際連線仍須在使用者電腦驗證。
