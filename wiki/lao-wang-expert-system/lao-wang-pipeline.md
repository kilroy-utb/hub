# 資料管線（step0–step10）與重現指令

原始 repo（未公開）：`~/codex/lao_wang_channel`。下面每一階都對應一個可重跑的腳本，輸出都是 CSV/JSON，沒有手工步驟（除標注外）。

## 管線表

| # | 腳本 | 輸入 | 輸出 | 實測成本 | 狀態 |
|---|---|---|---|---|---|
| 0 目錄 | `step0_metadata.py` | 頻道 id | `catalog.csv/.json`（2,639 支：id、標題、類型、長度、觀看、播放清單、標題日期）、`availability.tsv` | 數秒 | 完成 |
| 1 抓音訊 | `step1_fetch_audio.py` | id 清單 | `audio/<id>.m4a`＋`fetch_manifest.jsonl` | 單集 45–47MB、約 5 秒；全系列 892 集 ≈40GB | 完成 |
| 2 ASR | `step2_asr.py`（faster-whisper `small` int8，CPU 6 執行緒） | m4a | `transcripts/<id>.txt/.json` | RTF 0.128 → 單集 49 分鐘音訊 6.3 分鐘；全系列 ≈70 CPU 小時 | 進行中（685/892） |
| 2b 名稱修復 | `step2b_name_repair.py` | txt＋`ticker_map.json` | `<id>.fixed.txt`＋repair log | 秒級 | 完成（ASR 把「力積電／南亞科／友達／富喬」整批漏識） |
| 3 摘要 | `step3_digest.py` | transcripts | `digests/<id>.digest.txt`＋signals.json | 單集壓到 ≈1.7k 字 | 完成（單集驗證） |
| 4 台帳（舊） | `step4_strategy_ledger.py` | digests | `ledger_3min.csv` | — | 方向判定不可靠，`score()` 引用不存在的欄位 → 已停用，僅供歷史 |
| 5 規則引擎＋回測 | `step5_rule_engine.py`（`fetch`/`backtest`/`sweep`） | RULES_SPEC 參數＋Yahoo 復權 | `data/BACKTEST_REPORT.md`、`ablation_*.csv`、`sweep_*.csv`、`data/px/*.csv` | 24 檔抓價 ≈1 分鐘；回測秒級；36 組掃描 ≈1 分鐘 | 完成 |
| 6 字幕抓取 | `step6_captions.py` | 頻道 id | `captions/<頻道>/<vid>.txt`、`.info.json`、`.desc.txt`、`index.csv` | 有字幕的頻道抽取近零成本（三家各 150–250 支 ≈ 數分鐘） | 完成（三家） |
| 7 跨家台帳 | `step7_ledger_captions.py` | captions | `ledger_captions.csv`（含 `expert`/`program`/`when`） | 秒級 | 完成，但方向精確度 ≈36% |
| 8 用語指紋 | `step8_fingerprint.py` | transcripts＋captions | `data/style_fingerprint.csv`＋立場相關、重疊一致性 | ≈2 分鐘 | 完成 |
| 9 規則飽和度 | `step9_rule_saturation.py` | 全部逐字稿 | `data/rule_saturation.csv`＋報告 txt | ≈20 秒 | 完成 |
| 10 喊單評核 | `step10_evaluate_calls.py` | 任一 ledger＋價格 | `data/call_eval.csv`、`call_quality.csv`＋P&L 相關矩陣 | 首次抓 200+ 檔價格 ≈20 分鐘，之後快取 | 完成 |

## 重現指令

```bash
cd ~/codex/lao_wang_channel

# 規則引擎
python3 pipeline/step5_rule_engine.py fetch      # 抓復權價格到 data/px/
python3 pipeline/step5_rule_engine.py backtest   # 主結果＋消融
python3 pipeline/step5_rule_engine.py sweep      # 36 組參數掃描

# 字幕頻道（抽取近零成本）
python3 pipeline/step6_captions.py --channel <channel_id> --name <頻道名> --limit 250
python3 pipeline/step7_ledger_captions.py         # → ledger_captions.csv
python3 pipeline/step8_fingerprint.py             # → data/style_fingerprint.csv
python3 pipeline/step9_rule_saturation.py --folds 8
python3 pipeline/step10_evaluate_calls.py --ledger ledger_captions.csv --horizon 10

# 頻道篩檢用的 yt-dlp 查詢
~/.local/bin/yt-dlp "ytsearch20:台股 技術分析 均線 策略" --flat-playlist \
  --print "%(channel_id)s | %(channel)s | %(view_count)s | %(title).55s"
~/.local/bin/yt-dlp --skip-download --write-subs --sub-langs zh-TW,zh-Hant "https://www.youtube.com/watch?v=<id>"
```

## 踩過的坑（每一條都花過時間）

1. **Yahoo 對上櫃（TPEx）股票要用 `.TWO`**，主板用 `.TW`。一律用 `.TW` 會讓 78 檔出現「No data found, symbol may be delisted」，看起來像退市，其實是後綴錯。現在 `step10` 會先 `.TW` 再 `.TWO`，並把真的查無資料的檔寫進 `data/px_failed.txt`（避免每次重跑都重試）。**丟掉抓不到價格的樣本會製造倖存者偏差，所以失敗清單必須留著看。**
2. **Yahoo chart API 的 `indicators.adjclose` 有時是 list、有時是 dict**，兩邊都要處理。
3. **必須用復權序列**（adjclose 比例套到 O/H/L），否則除息會製造假缺口與假跌破 —— 她的缺口與均線出場規則會直接被污染。
4. **`-J`（dump JSON）在 simulate 模式下不會列播放清單**；字幕抓取改用 `--skip-download --write-subs --write-info-json`。
5. **股票名字串匹配會製造幽靈股票**：「爆大量」→ 大量科技、「海力士」→ 力士、「世界」→ 世界先進。解法是兩層閘門：常見詞只有在 4 碼代號鄰近或出現在標題時才算；黑名單（`STOP`）要确实接到過濾函數上（曾經定義了卻沒使用，導致「大量」變成 107 筆喊單）。
6. **最長名稱優先＋字元 consumption**，否則「南亞科」會同時被記成「南亞」。
7. **ASR 的專有名詞不可靠**：`small` 層級把「力積電／南亞科／友達／富喬」整個漏識，需要 2b 名稱修復；字幕頻道則沒有這個問題（人工字幕有標點、專有名詞正確）。→ 有字幕的頻道邊際價值高於繼續 ASR。
8. **逐句抽取會把規則切爛**：「就不是我們會進場追高的地方」這種反向語意、以及「昨天不要追」這種指稱前文的片段，都要在 ±150 字視窗＋距離衰減下判讀；即便如此仍只有 ≈36% 精確度。
9. **沙盒裡的背景行程會被回收**：長時間的 ASR／抓取要用前台 exec ＋ 輪詢，不能 `nohup &`。
10. **`pkill -f step6` 會自我匹配到沙盒 wrapper**，要用 `pkill -f '[s]tep6'`。
11. **cluster bootstrap 要按日期（或 股票×月份）分群**：同一天的喊單共用同一個市場結果，按筆數 bootstrap 會讓信賴區間假狹窄。

## 名義與合規

- 逐字稿是別人內容的轉錄，僅供個人研究；本知識庫只發布彙總統計與少量引用句，不發布逐字稿、音訊與逐筆台帳。
- 頻道篩檢時刻意記錄行銷漏斗偏差（會員制、學員限定影片、投顧推股），因為它直接決定「公開言論的樣本是否有選擇偏差」。
