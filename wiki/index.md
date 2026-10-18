# Wiki 知識庫

這裡放你所有的 markdown 知識筆記。

## 子目錄

- [`wiki/finance/`](./finance/) — 財經筆記（持股、研究）
- `wiki/` — 一般知識

## 怎麼新增筆記

```bash
cd ~/hub
vim wiki/new-topic.md
git add . && git commit -m "add new-topic" && git push
python3 ~/.hermes/skills/hub/scripts/hub.py build
```

GitHub 會自動渲染 markdown，Pages 也會抓到。
