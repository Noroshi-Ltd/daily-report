# daily-report

Noroshi 組織の GitHub 活動を毎日自動記録する日報リポジトリ。

---

## リポジトリ構成

```
daily-report/
├── src/                    ← ソースコード（変更は PR レビュー必須）
│   ├── daily-report.sh     ← 日報生成メインスクリプト
│   └── setup-launchd.sh    ← Mac mini launchd 登録スクリプト
└── reports/                ← 日報記録（launchd により自動追加）
    └── YYYY-MM-DD.md
```

### src/ について

**直接編集・main への push は禁止です。** 変更は PR レビューを経てください。

### reports/ について

launchd が毎日自動生成する日報が格納されます。**手動編集は行わないでください。**

---

## 動作フロー

```
Mac mini launchd（毎日 02:00 JST）
  ↓
src/daily-report.sh
  ├─ gh CLI → Noroshi-Ltd 全リポジトリのコミット（著者別）収集
  ├─ gh CLI → マージ済み PR 収集
  └─ gh CLI → 新規・クローズ Issue 収集
  ↓
  ├─ GitHub Content API → reports/YYYY-MM-DD.md に自動保存
  └─ Slack chat.postMessage → サマリー通知
```

---

## 実行環境

| 項目 | 内容 |
|------|------|
| 実行マシン | Mac mini（macOS, 24h 稼働） |
| スケジューラ | launchd（`~/Library/LaunchAgents/com.noroshi.daily-report.plist`） |
| 実行時刻 | 毎日 02:00 JST |
| GitHub 認証 | `gh auth login` 済みのトークン |
| Slack 認証 | `~/.env-openclaw` の `SLACK_BOT_TOKEN` |

---

## 初回セットアップ（Mac mini で実行）

```bash
# 1. リポジトリをクローン
cd ~/project/Noroshi-Ltd
git clone https://github.com/Noroshi-Ltd/daily-report.git

# 2. launchd 登録（依存ツール確認 + plist 自動生成 + 登録）
bash ~/project/Noroshi-Ltd/daily-report/src/setup-launchd.sh

# 3. 動作確認（手動実行）
bash ~/project/Noroshi-Ltd/daily-report/src/daily-report.sh

# 4. ログ確認
tail -f ~/daily-report.log
```

**前提条件（Homebrew でインストール）:**

```bash
brew install gh jq
gh auth login
```

---

## 運用コマンド

| 操作 | コマンド |
|------|---------|
| ログ確認 | `tail -f ~/daily-report.log` |
| launchd 状態確認 | `launchctl list \| grep noroshi` |
| 手動実行 | `bash ~/project/Noroshi-Ltd/daily-report/src/daily-report.sh` |
| launchd 停止 | `launchctl unload ~/Library/LaunchAgents/com.noroshi.daily-report.plist` |
| launchd 再起動 | `launchctl unload ... && launchctl load ...` |

---

## 関連リポジトリ

| リポジトリ | 役割 |
|-----------|------|
| [Noroshi-Ltd/ai-ops-design](https://github.com/Noroshi-Ltd/ai-ops-design) | 設計ドキュメント（`projects/日報/`） |
