# Kilroy's Hub

個人首頁 / 知識 / 漫畫 / 財經 / 待辦 入口

👉 **網頁**：https://kilroy-utb.github.io/hub/

## 這個 repo 是什麼

這是 [hub skill](https://github.com/kilroy-utb/hub) 的內容儲存：
- `hub.yaml` — section 設定（編輯這個加新卡片）
- `wiki/` — markdown 知識庫
- `todo/` — 待辦事項
- `notes/` — 雜項筆記

## 怎麼更新首頁

```bash
# 編輯 hub.yaml 或加新 markdown

# 重建 index.html
python3 ~/.hermes/skills/hub/scripts/hub.py build --repo kilroy-utb/hub
```

## Sections

請看 [hub.yaml](./hub.yaml)。

| Section | 來源 | Badge |
|---|---|---|
| 📚 成語四格漫畫 | `kilroy-utb/knowledge_base` | PNG 數 |
| 🧬 生物四格漫畫 | `kilroy-utb/knowledge_base` | PNG 數 |
| 📖 Wiki | `./wiki/` | MD 數 |
| 💰 財經筆記 | `./wiki/finance/` | MD 數 |
| ✅ Todo | `./todo/` | open checkbox 數 |
| 📝 雜項筆記 | `./notes/` | MD 數 |
