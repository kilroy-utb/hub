# Windows Codex → Tailscale → GX10 Strata

在 Windows PowerShell 5.1 或 PowerShell 7 執行。GX10 必須已啟動 Strata；本腳本不會安裝或更動 GX10 的模型服務。

## 下載與安裝

```powershell
curl.exe -fL "https://kilroy-utb.github.io/hub/files/install-codex-gx10.ps1" -o install-codex-gx10.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-codex-gx10.ps1
```

先檢視下載內容再執行。腳本自動尋找名稱包含 gx10 的 Tailscale 裝置，找不到或有多台就詢問位址。預設連接埠 8080，並不保證等於你的設定。請使用 Tailscale IP 或名稱，勿用公開網路的明文 HTTP。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-codex-gx10.ps1 -Gx10Host 100.101.102.103 -Port 8081 -TestResponse
```

範例 IP 請替換。需要授權時加 `-UseApiKey`，會以隱藏輸入詢問金鑰，不寫入設定或登錄檔；每次啟動 Codex 會再詢問。無金鑰保護的服務應限於可信任的 Tailscale 成員可存取。

## 行為

- 先測試 `/v1/models`，使用服務實際回傳的模型 ID；多模型時詢問，亦可用 `-Model` 指定。
- 加 `-CheckOnly` 僅測連線，不安裝軟體、不寫設定；加 `-TestResponse` 額外執行一次短推論以測 `/v1/responses`，最長等候 180 秒。
- 缺少 Node.js 或版本低於 22 時，透過 winget 安裝 LTS，可能要求 Windows 管理員同意。沒有 winget 時提示自行安裝 Node.js LTS。
- 使用 npm 全域安裝／更新 `@openai/codex@latest`，會影響目前 npm 全域位置內既有的 Codex 版本。
- 獨立設定與會話放在 `%USERPROFILE%\codex-gx10\codex-home`，不更動既有 `.codex` 或 `.codex-home`。
- 重跑前備份此安裝目錄的設定及啟動腳本。啟動器只在執行期間切換 `CODEX_HOME`。
- 不修改防火牆、不關閉 Codex 安全限制、不永久變更 PowerShell 執行原則。

## 啟動

先切換至希望 Codex 操作的專案資料夾，再執行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\codex-gx10\Start-Codex-GX10.ps1"
```

不要直接執行裸的 `codex`，它不會套用此獨立 GX10 設定。第一次依 Codex 畫面完成 Windows 沙箱設定；不要選擇停用安全限制。

先要求純文字回覆，再測試建立可丟棄的檔案。`/v1/models` 通過不代表 Responses 或工具呼叫一定相容；即使 `-TestResponse` 成功，仍須實測 Codex 工具呼叫。

## 排錯

- 連線失敗：確認雙方已登入 Tailscale、ACL 允許、連接埠正確，且 Strata 不是只監聽 `127.0.0.1`。
- HTTP 401/403：確認服務授權，使用 `-UseApiKey`；不要貼出金鑰。
- `/v1/responses` 回傳 404：需使用支援 Responses 的 Strata 版本，不能僅憑支援 chat/completions 判定相容。
- 公司執行原則禁止腳本：請管理員協助，不要繞過組織政策。

本腳本的自動檢查不能代替你的 Windows、GX10 與實際模型的端到端測試。
