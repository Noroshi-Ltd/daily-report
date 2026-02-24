#!/bin/bash
# setup-cron.sh - VPS 上で daily-report を cron 登録するセットアップスクリプト
# 使い方: bash src/setup-cron.sh
# 実行場所: VPS (haruya@160.251.199.37)
#
# !! このファイルはソースコードです。変更する場合は PR レビューを経てください !!

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT_SCRIPT="$REPO_ROOT/src/daily-report.sh"
LOG_FILE="$HOME/daily-report.log"
# 毎日 02:00 JST に実行（VPS が Asia/Tokyo 前提）
CRON_LINE="0 2 * * * $REPORT_SCRIPT >> $LOG_FILE 2>&1"

echo "=== 日報自動記録 cron セットアップ ==="
echo ""

# 1. スクリプトの存在確認
if [ ! -f "$REPORT_SCRIPT" ]; then
    echo "[ERROR] $REPORT_SCRIPT が見つかりません"
    echo "  先にリポジトリを pull してください: git -C $REPO_ROOT pull"
    exit 1
fi

# 2. 実行権限付与
chmod +x "$REPORT_SCRIPT"
echo "[OK] 実行権限を付与: $REPORT_SCRIPT"

# 3. 依存ツール確認
echo ""
echo "--- 依存ツール確認 ---"

# gh CLI
if command -v gh >/dev/null 2>&1; then
    echo "[OK] gh コマンド: $(gh --version | head -1)"
else
    echo "[ERROR] gh CLI が見つかりません。インストールしてください:"
    echo "  https://cli.github.com/"
    exit 1
fi

# gh 認証確認
if gh api user >/dev/null 2>&1; then
    GH_USER=$(gh api user --jq '.login' 2>/dev/null || echo "不明")
    echo "[OK] gh 認証済み (user: $GH_USER)"
else
    echo "[ERROR] gh CLI が認証されていません。実行してください:"
    echo "  gh auth login"
    exit 1
fi

# jq（collect_commits で gh api の出力をパイプ処理するために必要）
if command -v jq >/dev/null 2>&1; then
    echo "[OK] jq: $(jq --version)"
else
    echo "[ERROR] jq が見つかりません。インストールしてください:"
    echo "  sudo apt-get install -y jq"
    exit 1
fi

# python3
if command -v python3 >/dev/null 2>&1; then
    echo "[OK] python3: $(python3 --version)"
else
    echo "[ERROR] python3 が見つかりません"
    exit 1
fi

# curl
if command -v curl >/dev/null 2>&1; then
    echo "[OK] curl: $(curl --version | head -1 | cut -d' ' -f1-2)"
else
    echo "[ERROR] curl が見つかりません"
    exit 1
fi

# 4. Slack 設定確認
echo ""
echo "--- Slack 設定確認 ---"
ENV_FILE="$HOME/.env-openclaw"

if [ -f "$ENV_FILE" ]; then
    if grep -q "^SLACK_BOT_TOKEN=" "$ENV_FILE"; then
        echo "[OK] SLACK_BOT_TOKEN が ~/.env-openclaw に設定済み"
    else
        echo "[WARN] SLACK_BOT_TOKEN が ~/.env-openclaw に未設定"
        echo "  以下を追加してください: SLACK_BOT_TOKEN=xoxb-..."
    fi

    if grep -q "^SLACK_NOTIFY_CHANNEL=" "$ENV_FILE"; then
        CHANNEL=$(grep "^SLACK_NOTIFY_CHANNEL=" "$ENV_FILE" | head -1 | cut -d= -f2-)
        echo "[OK] SLACK_NOTIFY_CHANNEL=$CHANNEL"
    else
        echo "[WARN] SLACK_NOTIFY_CHANNEL が未設定 (デフォルト: C0AGCDY92KU を使用)"
    fi
else
    echo "[WARN] ~/.env-openclaw が存在しません"
    echo "  作成してください:"
    echo "    echo 'SLACK_BOT_TOKEN=xoxb-...' >> ~/.env-openclaw"
    echo "    echo 'SLACK_NOTIFY_CHANNEL=C0AGCDY92KU' >> ~/.env-openclaw"
fi

# 5. タイムゾーン確認
echo ""
echo "--- タイムゾーン確認 ---"
CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "不明")
echo "[INFO] 現在のタイムゾーン: $CURRENT_TZ"
if [ "$CURRENT_TZ" != "Asia/Tokyo" ]; then
    echo "[WARN] Asia/Tokyo ではありません。JST 02:00 に実行するには以下で設定してください:"
    echo "    sudo timedatectl set-timezone Asia/Tokyo"
fi

# 6. cron 登録（重複チェック付き）
echo ""
echo "--- cron 登録 ---"

if crontab -l 2>/dev/null | grep -qF "$REPORT_SCRIPT"; then
    echo "[SKIP] cron に既に登録済みです:"
    crontab -l 2>/dev/null | grep "$REPORT_SCRIPT"
else
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    echo "[OK] cron に登録しました:"
    echo "    $CRON_LINE"
fi

echo ""
echo "=== セットアップ完了 ==="
echo ""
echo "動作確認（手動実行）:"
echo "  bash $REPORT_SCRIPT"
echo ""
echo "ログ確認:"
echo "  tail -f $LOG_FILE"
echo ""
echo "cron 確認:"
echo "  crontab -l"
echo ""
echo "生成された日報の確認:"
echo "  https://github.com/Noroshi-Ltd/daily-report/tree/main/reports"
