# daily-report

Noroshi 組織の GitHub 活動を毎日自動記録する日報リポジトリ。

---

## リポジトリ構成

```
daily-report/
├── src/                    ← ソースコード（変更は PR レビュー必須）
│   ├── daily-report.sh     ← 日報生成メインスクリプト
│   └── setup-cron.sh       ← VPS cron 登録スクリプト
└── reports/                ← 日報記録（cron により自動追加）
    └── YYYY-MM-DD.md
```

### src/ について

スクリプトファイルが格納されています。**直接編集・main への push は禁止です。**
変更が必要な場合は必ずブランチを作成し、PR レビューを経てください。

### reports/ について

cron が毎日自動生成する日報が格納されます。**手動編集は行わないでください。**
ファイル名は `YYYY-MM-DD.md` 形式（例: `2026-02-23.md`）。

---

## 動作フロー

```
[cron] 毎日 02:00 JST (VPS: ConoHa Ubuntu 22.04)
  ↓
src/daily-report.sh
  ├─ Noroshi-Ltd 全リポジトリのコミット（著者別）収集
  ├─ マージ済み PR 収集
  └─ 新規・クローズ Issue 収集
  ↓
  ├─ GitHub Content API → reports/YYYY-MM-DD.md に自動保存
  └─ Slack chat.postMessage → #general へサマリー通知
```

---

## 初回セットアップ（VPS で実行）

```bash
# 1. リポジトリをクローン
cd ~/project/Noroshi-Ltd
git clone https://github.com/Noroshi-Ltd/daily-report.git

# 2. cron 登録（依存ツール確認 + crontab 設定を自動実行）
bash ~/project/Noroshi-Ltd/daily-report/src/setup-cron.sh

# 3. 動作確認（手動実行）
bash ~/project/Noroshi-Ltd/daily-report/src/daily-report.sh

# 4. ログ確認
tail -f ~/daily-report.log
```

---

## 運用方法

| 操作 | コマンド |
|------|---------|
| ログ確認 | `tail -f ~/daily-report.log` |
| cron 確認 | `crontab -l` |
| 手動実行 | `bash ~/project/Noroshi-Ltd/daily-report/src/daily-report.sh` |
| 日報一覧 | [reports/ を見る](./reports/) |

---

## 関連リポジトリ

| リポジトリ | 役割 |
|-----------|------|
| [Noroshi-Ltd/ai-ops-design](https://github.com/Noroshi-Ltd/ai-ops-design) | 設計ドキュメント（`projects/日報/`） |
