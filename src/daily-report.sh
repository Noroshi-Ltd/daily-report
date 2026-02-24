#!/bin/bash

# daily-report.sh - 前日の GitHub 活動を日報として記録・Slack 通知
# VPS cron: 0 2 * * * /home/haruya/project/Noroshi-Ltd/daily-report/src/daily-report.sh >> ~/daily-report.log 2>&1
#
# 処理の流れ:
#   1. GitHub 組織全体の前日活動（コミット・PR・Issue）を収集
#   2. Markdown 形式の日報を生成し GitHub Content API で reports/ に保存
#   3. Slack へサマリー通知を送信
#
# !! このファイルはソースコードです。変更する場合は PR レビューを経てください !!

# ---------- 初期化 ----------

ORG="Noroshi-Ltd"
REPORT_REPO="daily-report"      # 日報を保存するリポジトリ
REPORT_PATH_PREFIX="reports"    # リポジトリ内の保存先ディレクトリ
ENV_FILE="$HOME/.env-openclaw"

# ---------- 環境変数読み込み ----------

load_env() {
    if [ -f "$ENV_FILE" ]; then
        SLACK_BOT_TOKEN=$(grep "^SLACK_BOT_TOKEN=" "$ENV_FILE" | head -1 | cut -d= -f2-)
        SLACK_NOTIFY_CHANNEL=$(grep "^SLACK_NOTIFY_CHANNEL=" "$ENV_FILE" | head -1 | cut -d= -f2-)
    fi
    SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
    SLACK_NOTIFY_CHANNEL="${SLACK_NOTIFY_CHANNEL:-C0AGCDY92KU}"
}

# ---------- Slack 投稿（ohayou-notify.sh と同パターン）----------

post_to_slack() {
    local text="$1"
    local token="${SLACK_BOT_TOKEN}"
    local channel="${SLACK_NOTIFY_CHANNEL}"

    if [ -z "$token" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] SLACK_BOT_TOKEN が未設定 (~/.env-openclaw を確認)" >&2
        return 1
    fi

    local payload
    payload=$(python3 -c "
import json, sys
text = sys.stdin.read()
channel = sys.argv[1]
print(json.dumps({'channel': channel, 'text': text, 'mrkdwn': True}))
" "$channel" <<< "$text")

    local resp
    resp=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if echo "$resp" | grep -q '"ok":true'; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] Slack 投稿完了 (channel: $channel)"
    else
        local err
        err=$(echo "$resp" | grep -o '"error":"[^"]*"' | sed 's/"error":"//;s/"//')
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Slack 投稿失敗: ${err:-$resp}" >&2
        return 1
    fi
}

# ---------- URL エンコード ----------

# +09:00 の + がクエリパラメータ中でスペース解釈されるのを防ぐ
urlencode() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

# ---------- リポジトリ一覧取得 ----------

get_org_repos() {
    gh api "orgs/${ORG}/repos?per_page=100&type=all" \
        --jq '.[].name' 2>/dev/null | sort
}

# ---------- コミット収集 ----------

# 出力: "author_name TAB repo TAB sha7 TAB message" の TSV（全リポジトリ分）
collect_commits() {
    local since="$1"
    local until="$2"

    local since_enc until_enc
    since_enc=$(urlencode "$since")
    until_enc=$(urlencode "$until")

    local repos
    repos=$(get_org_repos)

    while IFS= read -r repo; do
        [ -z "$repo" ] && continue
        # gh api の --jq は jq の --arg をサポートしないため jq にパイプする
        gh api \
            "repos/${ORG}/${repo}/commits?since=${since_enc}&until=${until_enc}&per_page=100" \
            2>/dev/null \
        | jq -r --arg repo "$repo" \
            '.[] | [
                (.author.login // .commit.author.name // "unknown"),
                $repo,
                .sha[:7],
                (.commit.message | split("\n")[0] | .[0:100])
            ] | @tsv' \
            2>/dev/null || true
    done <<< "$repos"
}

# ---------- マージ済み PR 収集 ----------

# 出力: "repo TAB number TAB title TAB author" の TSV
collect_merged_prs() {
    local date="$1"
    gh api \
        "search/issues?q=org:${ORG}+is:pr+is:merged+merged:${date}&per_page=100" \
        --jq '.items[] | [
            (.repository_url | split("/")[-1]),
            (.number | tostring),
            (.title | .[0:100]),
            .user.login
        ] | @tsv' \
        2>/dev/null || true
}

# ---------- Issue 収集 ----------

# 出力: "repo TAB number TAB title TAB author TAB event" の TSV
collect_issues() {
    local date="$1"

    # 新規オープン
    gh api \
        "search/issues?q=org:${ORG}+is:issue+created:${date}&per_page=100" \
        --jq '.items[] | [
            (.repository_url | split("/")[-1]),
            (.number | tostring),
            (.title | .[0:100]),
            .user.login,
            "opened"
        ] | @tsv' \
        2>/dev/null || true

    # クローズ済み
    gh api \
        "search/issues?q=org:${ORG}+is:issue+is:closed+closed:${date}&per_page=100" \
        --jq '.items[] | [
            (.repository_url | split("/")[-1]),
            (.number | tostring),
            (.title | .[0:100]),
            .user.login,
            "closed"
        ] | @tsv' \
        2>/dev/null || true
}

# ---------- Markdown 日報生成 ----------

generate_report() {
    local date="$1"
    local commits_tsv="$2"
    local prs_tsv="$3"
    local issues_tsv="$4"

    local generated_at
    generated_at=$(date '+%Y-%m-%d %H:%M:%S')

    printf '# 日報 %s\n\n' "$date"
    printf '> 自動生成: %s JST\n\n' "$generated_at"
    printf '---\n\n'

    # ── コミットセクション ──
    printf '## コミット\n\n'

    if [ -z "$commits_tsv" ]; then
        printf '前日のコミットはありませんでした。\n\n'
    else
        local authors
        authors=$(echo "$commits_tsv" | awk -F'\t' '{print $1}' | sort -u)

        while IFS= read -r author; do
            [ -z "$author" ] && continue
            local author_commits
            author_commits=$(echo "$commits_tsv" | awk -F'\t' -v a="$author" '$1 == a')
            local count
            count=$(echo "$author_commits" | grep -c . || echo "0")

            printf '### %s (%s commits)\n\n' "$author" "$count"
            while IFS=$'\t' read -r _auth repo sha msg; do
                [ -z "$sha" ] && continue
                printf '- `%s` [%s] %s\n' "$sha" "$repo" "$msg"
            done <<< "$author_commits"
            printf '\n'
        done <<< "$authors"
    fi

    # ── マージ済み PR セクション ──
    printf '## マージされた PR\n\n'

    if [ -z "$prs_tsv" ]; then
        printf '前日にマージされた PR はありませんでした。\n\n'
    else
        local pr_count
        pr_count=$(echo "$prs_tsv" | grep -c . || echo "0")
        printf '合計 %s 件\n\n' "$pr_count"

        while IFS=$'\t' read -r repo num title author; do
            [ -z "$num" ] && continue
            printf '- **[%s#%s]** %s _(@%s)_\n' "$repo" "$num" "$title" "$author"
        done <<< "$prs_tsv"
        printf '\n'
    fi

    # ── Issue セクション ──
    printf '## Issue の動き\n\n'

    if [ -z "$issues_tsv" ]; then
        printf '前日の Issue の動きはありませんでした。\n\n'
    else
        local opened_issues closed_issues

        opened_issues=$(echo "$issues_tsv" | awk -F'\t' '$5 == "opened"')
        closed_issues=$(echo "$issues_tsv" | awk -F'\t' '$5 == "closed"')

        if [ -n "$opened_issues" ]; then
            local opened_count
            opened_count=$(echo "$opened_issues" | grep -c . || echo "0")
            printf '### 新規オープン (%s 件)\n\n' "$opened_count"
            while IFS=$'\t' read -r repo num title author _ev; do
                [ -z "$num" ] && continue
                printf '- **[%s#%s]** %s _(@%s)_\n' "$repo" "$num" "$title" "$author"
            done <<< "$opened_issues"
            printf '\n'
        fi

        if [ -n "$closed_issues" ]; then
            local closed_count
            closed_count=$(echo "$closed_issues" | grep -c . || echo "0")
            printf '### クローズ (%s 件)\n\n' "$closed_count"
            while IFS=$'\t' read -r repo num title author _ev; do
                [ -z "$num" ] && continue
                printf '- **[%s#%s]** %s _(@%s)_\n' "$repo" "$num" "$title" "$author"
            done <<< "$closed_issues"
            printf '\n'
        fi
    fi

    printf '---\n\n'
    printf '_このドキュメントは `src/daily-report.sh` により自動生成されました。_\n'
}

# ---------- GitHub Content API でファイル保存 ----------

save_to_github() {
    local file_path="$1"
    local content="$2"

    # base64 エンコード（Linux: -w 0 でラップなし。printf で余分な末尾改行を避ける）
    local encoded
    encoded=$(printf '%s' "$content" | base64 -w 0)

    # 既存ファイルの SHA 取得（更新時に必須。新規の場合は空文字）
    local sha
    sha=$(gh api "repos/${ORG}/${REPORT_REPO}/contents/${file_path}" \
        --jq '.sha' 2>/dev/null || echo "")

    # PUT ペイロードを Python3 で構築（JSON の安全な組み立て）
    local filename="${file_path##*/}"
    local payload
    payload=$(python3 -c "
import json, sys
sha = sys.argv[1]
encoded = sys.argv[2]
filename = sys.argv[3]
action = 'update' if sha else 'add'
d = {
    'message': f'chore: {action} daily report {filename} [skip ci]',
    'content': encoded,
}
if sha:
    d['sha'] = sha
print(json.dumps(d))
" "$sha" "$encoded" "$filename")

    local resp
    resp=$(gh api \
        --method PUT \
        "repos/${ORG}/${REPORT_REPO}/contents/${file_path}" \
        --input - <<< "$payload" 2>&1)

    if echo "$resp" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print('ok' if d.get('content') else 'fail')
except:
    print('fail')
" 2>/dev/null | grep -q "^ok$"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] GitHub に保存: $file_path"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] GitHub 保存失敗: $resp" >&2
        return 1
    fi
}

# ---------- Slack サマリーメッセージ生成 ----------

build_slack_summary() {
    local date="$1"
    local commits_tsv="$2"
    local prs_tsv="$3"
    local issues_tsv="$4"
    local report_url="$5"

    local commit_count=0 pr_count=0 opened_count=0 closed_count=0

    [ -n "$commits_tsv" ] && commit_count=$(echo "$commits_tsv" | grep -c . || echo "0")
    [ -n "$prs_tsv" ]     && pr_count=$(echo "$prs_tsv" | grep -c . || echo "0")
    if [ -n "$issues_tsv" ]; then
        opened_count=$(echo "$issues_tsv" | awk -F'\t' '$5=="opened"' | grep -c . || echo "0")
        closed_count=$(echo "$issues_tsv" | awk -F'\t' '$5=="closed"' | grep -c . || echo "0")
    fi

    printf '*📊 %s の活動サマリー*\n' "$date"
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
    printf '• 💻 コミット: *%s 件*\n' "$commit_count"
    printf '• 🔀 マージ PR: *%s 件*\n' "$pr_count"
    printf '• 🆕 新規 Issue: *%s 件*\n' "$opened_count"
    printf '• ✅ クローズ Issue: *%s 件*\n' "$closed_count"

    if [ -n "$commits_tsv" ]; then
        printf '\n*アクティブメンバー:*\n'
        echo "$commits_tsv" | awk -F'\t' '{print $1}' | sort | uniq -c | sort -rn | \
            while read -r cnt name; do
                printf '  • %s (%s commits)\n' "$name" "$cnt"
            done
    else
        printf '\n活動なし\n'
    fi

    printf '\n<'
    printf '%s' "$report_url"
    printf '|詳細レポートを見る>\n'
}

# ---------- メイン ----------

main() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') === 日報生成開始 ==="

    load_env

    # GitHub 認証チェック
    if ! gh api user >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] GitHub CLI が認証されていません (gh auth login を実行)" >&2
        exit 1
    fi

    # 日付計算（GNU date: Asia/Tokyo 前提。VPS は Asia/Tokyo に設定済み）
    local yesterday
    yesterday=$(date -d "yesterday" '+%Y-%m-%d')

    local since="${yesterday}T00:00:00+09:00"
    local until="${yesterday}T23:59:59+09:00"

    echo "$(date '+%Y-%m-%d %H:%M:%S') 対象日: $yesterday"

    # データ収集
    echo "$(date '+%Y-%m-%d %H:%M:%S') コミット収集中..."
    local commits_tsv
    commits_tsv=$(collect_commits "$since" "$until")

    echo "$(date '+%Y-%m-%d %H:%M:%S') PR 収集中..."
    local prs_tsv
    prs_tsv=$(collect_merged_prs "$yesterday")

    echo "$(date '+%Y-%m-%d %H:%M:%S') Issue 収集中..."
    local issues_tsv
    issues_tsv=$(collect_issues "$yesterday")

    # Markdown 日報生成
    echo "$(date '+%Y-%m-%d %H:%M:%S') Markdown 生成中..."
    local report_content
    report_content=$(generate_report "$yesterday" "$commits_tsv" "$prs_tsv" "$issues_tsv")

    # GitHub に保存（Noroshi-Ltd/daily-report の reports/ 以下）
    local file_path="${REPORT_PATH_PREFIX}/${yesterday}.md"
    echo "$(date '+%Y-%m-%d %H:%M:%S') GitHub に保存中: $file_path"
    save_to_github "$file_path" "$report_content"

    # Slack 通知
    local report_url="https://github.com/${ORG}/${REPORT_REPO}/blob/main/${file_path}"
    local slack_msg
    slack_msg=$(build_slack_summary "$yesterday" "$commits_tsv" "$prs_tsv" "$issues_tsv" "$report_url")

    echo "$(date '+%Y-%m-%d %H:%M:%S') Slack 通知送信中..."
    post_to_slack "$slack_msg"

    echo "$(date '+%Y-%m-%d %H:%M:%S') === 日報生成完了 ==="
}

main "$@"
