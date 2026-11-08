# VS Code 接入指南（GX10 × Strata）

把 VS Code 接到你在 GX10 上跑的 Strata（Qwen3.8-Flash-Next 125B / IQ3_S）。

Strata 提供 **OpenAI 相容** 與 **Anthropic 相容** 兩套 API，所以 VS Code 幾乎所有
AI 擴充套件都能接；唯一接不了的是「行內自動補全」（需要 FIM 端點，Strata 沒有）。

---

## 一、先決定怎麼連

VS Code 通常跑在你的筆電，Strata 跑在 GX10（`127.0.0.1:8080`），所以要決定「怎麼讓筆電連到那台機器」。

| 方式 | 優點 | 缺點 | 建議 |
|---|---|---|---|
| **SSH port forward** | 不改伺服器設定、服務不曝露在區網 | 要留一個視窗開著 | ✅ **推薦先用這個** |
| Tailscale | 跨網段最省事、不占 port | 要裝 Tailscale | 備案 |
| `--host 0.0.0.0` | 設定一次，到處都能用 | 服務暴露在區網 | 需要防火牆 + API key |

### 1.1 SSH port forward（推薦）

在你的筆電上執行：

```bash
ssh -N -L 8080:127.0.0.1:8080 kilroy@gx10-37a8
```

- `-N` = 不開 shell，只做轉發
- 視窗要留著；按 `Ctrl+C` 結束
- 想放背景：`ssh -f -N -L 8080:127.0.0.1:8080 kilroy@gx10-37a8`
- 驗證有通：

```bash
curl -s http://127.0.0.1:8080/health
```

轉發之後，VS Code 裡的 Base URL 就寫 `http://127.0.0.1:8080/v1`，跟人在 GX10 本機用完全一樣。

> 用這種方式的時候 Host 標頭是 `127.0.0.1:8080`，Strata 的 DNS rebinding 防護會直接放行，不用額外設定。

### 1.2 直接開放給區網（不想一直開 SSH 時）

設定檔位置：`~/Strata/strata-iq3_s.json`（`STRATA_DIR` 預設 `$HOME/Strata`）

在**最外層**加兩個欄位（不是 `args` 裡面）：

```json
{
  "host": "0.0.0.0",
  "api_key": "換成你自己的金鑰"
}
```

然後重啟：

```bash
sudo systemctl restart strata
journalctl -u strata -f
```

> ⚠️ **沒有 `api_key` 就等於區網內任何人都能用你的模型**（免費幫別人跑 GPU）。
> ⚠️ `api_key` 一旦設定，請求就必須帶 `Authorization: Bearer <key>` 或 `x-api-key` 標頭。

防火牆（ufw）範例，只放行自己的網段：

```bash
sudo ufw allow from 192.168.1.0/24 to any port 8080 proto tcp
sudo ufw status
```

---

## 二、Strata 實際提供哪些端點

這一版（`ccatzin-zumwalt/Strata` 的 `dgx-spark-gb10-aarch64` 分支）實測：

| 端點 | 用途 | 誰在用 |
|---|---|---|
| `POST /v1/chat/completions` | OpenAI 相容（支援 stream / tool） | Cline、Roo Code、Continue |
| `POST /v1/messages` | Anthropic 相容 | Claude Code（要 `anthropic-version: 2023-06-01`） |
| `POST /v1/responses` | OpenAI Responses API | Codex CLI |
| `POST /v1/messages/count_tokens` | token 計數 | Anthropic SDK |
| `GET /v1/models` | 模型清單 | 檢查用 |
| `GET /health` | 健康檢查 | 檢查用 |
| `GET /props`、`/slots`、`/v1/status`、`/metrics` | 狀態與監控 | debug |

**沒有的端點（會直接影響你選哪些功能）：**

| 端點 | 影響 |
|---|---|
| ❌ `/v1/completions`（FIM） | **VS Code 的行內自動補全不能用**。Continue 的 autocomplete 也不能用。 |
| ❌ `/v1/embeddings` | 沒有向量化，codebase indexing / 語意搜尋用不了 |

---

## 三、選哪個擴充套件

| 擴充套件 | 工具呼叫（agent 改檔） | 行內補全 | 設定難度 | 備註 |
|---|---|---|---|---|
| **Cline** | ✅ | ❌ | 低 | 最推薦，agent 模式最完整 |
| **Roo Code** | ✅ | ❌ | 低 | Cline 的分支，設定幾乎一樣 |
| **Continue** | ✅ | ❌ | 中 | 設定檔是 YAML，功能多但要熟悉 |
| VS Code 原生 Chat | ✅ | — | 中 | 需裝 Copilot 擴充套件當聊天介面 |

---

## 四、Cline（推薦）

### 4.1 用介面設定

Cline 面板 → 齒輪 → API Provider → 選 **OpenAI Compatible**：

| 欄位 | 填什麼 |
|---|---|
| Base URL | `http://127.0.0.1:8080/v1` |
| API Key | 伺服器沒設 key 就留空（填任何字串也會被忽略）；有設就填對那組金鑰 |
| Model ID | `qwen3.8-flash-next-iq3_s` |
| Context Window | `262144` |
| Max Tokens | `8192` |
| Temperature | `0.2`（寫程式用） |

### 4.2 用 settings.json

`.vscode/settings.json` 或使用者設定：

```json
{
  "cline.openAiBaseUrl": "http://127.0.0.1:8080/v1",
  "cline.openAiApiKey": "",
  "cline.openAiModelId": "qwen3.8-flash-next-iq3_s",
  "cline.openAiModelInfo": {
    "contextWindow": 262144,
    "maxTokens": 8192
  }
}
```

### 4.3 `/v1` 的坑（最容易錯的地方）

Cline 會自己補 `/chat/completions`，所以 **Base URL 一定要有 `/v1`、而且不能有尾斜杠**：

| 寫法 | 實際打出去 | 結果 |
|---|---|---|
| `http://127.0.0.1:8080/v1` | `/v1/chat/completions` | ✅ |
| `http://127.0.0.1:8080` | `/chat/completions` | ❌ 404 |
| `http://127.0.0.1:8080/v1/` | `/v1//chat/completions` | ❌ 404 |

---

## 五、Continue

`~/.continue/config.yaml`：

```yaml
name: Local Strata (GX10)
version: 1.0.0
schema: v1
models:
  - name: Qwen3.8 Flash Next IQ3_S
    provider: openai
    model: qwen3.8-flash-next-iq3_s
    apiBase: http://127.0.0.1:8080/v1
    apiKey: ""
    roles:
      - chat
      - edit
      - apply
    useResponsesApi: false
    defaultCompletionOptions:
      contextLength: 262144
      maxTokens: 8192
      temperature: 0.2
```

三個注意：

- `apiBase` **要帶 `/v1`**（跟 Cline 一樣）
- `useResponsesApi: false` → 固定走 `/v1/chat/completions`，不要走 `/v1/responses`
- **不要**加 `useLegacyCompletionsEndpoint: true` → 那是打 `/v1/completions`，Strata 沒這個端點，會 404

Continue 的 `autocomplete` role 需要 FIM，Strata 不支援 → **不要把模型掛到 `autocomplete` role**。
VS Code 內建的行內補全建議另外用 Copilot / Codeium，只把「agent 對話 + 改檔」交給本地模型。

---

## 六、VS Code 原生 Chat（`chat.languageModels`）

VS Code 1.104+ 支援自訂聊天模型。

1. 命令面板 → `Chat: Manage Language Models` → `Add Models...` → `Custom Endpoint`
2. VS Code 會寫進 `chatLanguageModels.json`（在你的使用者資料目錄）

內容長這樣：

```json
[
  {
    "vendor": "customendpoint",
    "id": "strata-gx10",
    "name": "Strata GX10",
    "apiType": "chat-completions",
    "url": "http://127.0.0.1:8080/v1/chat/completions",
    "toolCalling": true,
    "maxInputTokens": 262144,
    "maxOutputTokens": 32768,
    "apiKey": "${input:strata-api-key}"
  }
]
```

注意：

- `url` 是**完整端點**，要自己寫到 `/chat/completions`（跟 Cline 的 Base URL 規則不同，這裡沒有 `/v1` 補上的問題）
- `toolCalling: true` **一定要開**，否則 agent 模式不會改檔案，只能聊天
- `maxInputTokens` 要跟伺服器的 `--context` 一致（256K = `262144`）
- `apiKey` 用 `${input:strata-api-key}` 會跳出輸入提示，值存在 VS Code 的 secret storage，不會留在檔案裡

---

## 七、一定要知道的四個限制

### 7.1 context 大小直接決定每輪等待多久

- 伺服器 `--context 262144`（256K）
- coding agent 每輪都要重送整段對話歷史 → 對話越長，首字等待越久
- 社群實測：64K 約 40 秒／輪、256K 約 86 秒／輪
- **日常把 context 降到 65536（64K）會快一倍以上**，需要讀大文件時再切回來

要改的話是設定檔裡 `--context` 的值，改完重啟服務。

### 7.2 行內自動補全不會有反應

Strata 沒有 FIM 端點。VS Code 的 Suggest 會沒反應或報錯。
解法：補全交給別的工具，agent 對話才用本地模型。

### 7.3 `reasoning_effort` 只接受 4 個值

`none` / `low` / `medium` / `high`。
其他值（例如 `xhigh`）會被伺服器拒掉，回 HTTP 400。

### 7.4 剛重啟後第一個請求會慢一點

模型剛進記憶體時第一個字會慢，之後就正常了。

---

## 八、自我檢查腳本

`gx10-vscode-setup.sh` 會幫你把整條路徑測一遍，並印出可以直接貼的設定：

```bash
bash gx10-vscode-setup.sh                                  # 預設 http://127.0.0.1:8080
bash gx10-vscode-setup.sh --url http://192.168.1.20:8080 \
                          --api-key sk-local
```

它會做：

1. 打 `/health` 看服務活著嗎
2. 打 `/v1/models` 看模型名稱
3. 送一個普通 chat，量首字等待
4. 送一個**帶 tools** 的請求，確認工具呼叫能不能用（這決定 agent 能不能改檔）
5. 印出 Cline / Continue / VS Code 原生 Chat 三種設定片段

---

## 九、常見問題

| 症狀 | 原因 | 解法 |
|---|---|---|
| 404 | Base URL 少 `/v1` 或有尾斜杠 | 對照 §4.3 檢查 |
| 401 | 伺服器設了 api key，客戶端沒帶 | 客戶端填同一組 key |
| 403 + 「not allowed (DNS rebinding protection)」 | 用主機名稱連、伺服器又沒設 api key | 改用 IP 連，或在伺服器設 `api_key` |
| 連不上 | SSH port forward 沒開 | 確認那個視窗還開著 |
| 每輪等很久 | context 太大 | 降到 65536 |
| agent 不會改檔 | tool calling 沒開 | `toolCalling: true` |
| 行內補全沒反應 | 沒有 FIM 端點 | 改用其他補全工具 |
| 回傳 `reasoning_effort` 400 | 送了不支援的值 | 改成 `none`/`low`/`medium`/`high` |
