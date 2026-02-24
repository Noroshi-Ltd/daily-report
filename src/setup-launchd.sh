#!/bin/bash
# setup-launchd.sh - Mac mini 上で daily-report を launchd に登録するセットアップスクリプト
# 使い方: bash src/setup-launchd.sh
# 実行場所: Mac mini (macOS)
#
# !! このファイルはソースコードです。変更する場合は PR レビューを経てください !!

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT_SCRIPT="$REPO_ROOT/src/daily-report.sh"
PLIST_LABEL="com.noroshi.daily-report"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG_FILE="$HOME/daily-report.log"

echo "=== 日報自動記録 launchd セットアップ ==="
echo ""

# 1. macOS 確認
if [[ "$(uname)" != "Darwin" ]]; then
    echo "[ERROR] このスクリプトは macOS 専用です"
    exit 1
fi

# 2. スクリプトの存在確認
if [ ! -f "$REPORT_SCRIPT" ]; then
    echo "[ERROR] $REPORT_SCRIPT が見つかりません"
    echo "  先にリポジトリを pull してください: git -C $REPO_ROOT pull"
    exit 1
fi

# 3. 実行権限付与
chmod +x "$REPORT_SCRIPT"
echo "[OK] 実行権限を付与: $REPORT_SCRIPT"

# 4. 依存ツール確認
echo ""
echo "--- 依存ツール確認 ---"

# Homebrew PATH 設定（Apple Silicon / Intel 両対応）
if [[ -d "/opt/homebrew/bin" ]]; then
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
elif [[ -d "/usr/local/bin" ]]; then
    export PATH="/usr/local/bin:$PATH"
fi

# gh CLI
if command -v gh >/dev/null 2>&1; then
    echo "[OK] gh コマンド: $(gh --version | head -1)"
else
    echo "[ERROR] gh CLI が見つかりません。インストールしてください:"
    echo "  brew install gh && gh auth login"
    exit 1
fi

# gh 認証確認
if gh api user >/dev/null 2>&1; then
    GH_USER=$(gh api user --jq '.login' 2>/dev/null || echo "不明")
    echo "[OK] gh 認証済み (user: $GH_USER)"
else
    echo "[ERROR] gh CLI が認証されていません:"
    echo "  gh auth login"
    exit 1
fi

# jq
if command -v jq >/dev/null 2>&1; then
    echo "[OK] jq: $(jq --version)"
else
    echo "[ERROR] jq が見つかりません:"
    echo "  brew install jq"
    exit 1
fi

# python3
if command -v python3 >/dev/null 2>&1; then
    echo "[OK] python3: $(python3 --version)"
else
    echo "[ERROR] python3 が見つかりません:"
    echo "  brew install python3"
    exit 1
fi

# curl（macOS 標準搭載）
if command -v curl >/dev/null 2>&1; then
    echo "[OK] curl: $(curl --version | head -1 | cut -d' ' -f1-2)"
fi

# 5. Slack 設定確認
echo ""
echo "--- Slack 設定確認 ---"
ENV_FILE="$HOME/.env-openclaw"

if [ -f "$ENV_FILE" ]; then
    if grep -q "^SLACK_BOT_TOKEN=" "$ENV_FILE"; then
        echo "[OK] SLACK_BOT_TOKEN が ~/.env-openclaw に設定済み"
    else
        echo "[WARN] SLACK_BOT_TOKEN が未設定"
        echo "  以下を追加してください: echo 'SLACK_BOT_TOKEN=xoxb-...' >> ~/.env-openclaw"
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
    echo "    chmod 600 ~/.env-openclaw"
fi

# 6. タイムゾーン確認
echo ""
echo "--- タイムゾーン確認 ---"
CURRENT_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || echo "不明")
echo "[INFO] 現在のタイムゾーン: $CURRENT_TZ"
if [ "$CURRENT_TZ" != "Asia/Tokyo" ]; then
    echo "[WARN] Asia/Tokyo ではありません。以下で設定してください:"
    echo "  sudo systemsetup -settimezone Asia/Tokyo"
fi

# 7. Homebrew パスを確認して plist に書き込む
BREW_PREFIX=""
if [[ -d "/opt/homebrew/bin" ]]; then
    BREW_PREFIX="/opt/homebrew/bin"
elif [[ -d "/usr/local/bin" ]]; then
    BREW_PREFIX="/usr/local/bin"
fi

# 8. LaunchAgents ディレクトリ作成
mkdir -p "$HOME/Library/LaunchAgents"

# 9. plist 生成（既存があれば先に unload）
echo ""
echo "--- launchd 登録 ---"

if launchctl list | grep -q "$PLIST_LABEL" 2>/dev/null; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    echo "[INFO] 既存の launchd ジョブをアンロードしました"
fi

cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${REPORT_SCRIPT}</string>
    </array>

    <!-- PATH を明示設定（launchd は環境変数を継承しないため必須）-->
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${BREW_PREFIX}:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>

    <!-- 毎日 02:00 に実行 -->
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>2</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>

    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>

    <!-- 起動時に即実行しない -->
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST

echo "[OK] plist を生成しました: $PLIST_PATH"

# 10. launchd に登録
launchctl load "$PLIST_PATH"
echo "[OK] launchd に登録しました (毎日 02:00 JST に実行)"

echo ""
echo "=== セットアップ完了 ==="
echo ""
echo "動作確認（手動実行）:"
echo "  bash $REPORT_SCRIPT"
echo ""
echo "ログ確認:"
echo "  tail -f $LOG_FILE"
echo ""
echo "launchd 状態確認:"
echo "  launchctl list | grep noroshi"
echo ""
echo "launchd 停止・削除:"
echo "  launchctl unload $PLIST_PATH"
echo ""
echo "生成された日報:"
echo "  https://github.com/Noroshi-Ltd/daily-report/tree/main/reports"
