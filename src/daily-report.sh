#!/bin/bash

# daily-report.sh - 前日の GitHub 活動を日報として記録・Slack 通知
# Mac mini launchd: 毎日 02:00 JST に自動実行
# 手動実行: bash ~/project/Noroshi-Ltd/daily-report/src/daily-report.sh
#
# 処理の流れ:
#   1. GitHub 組織全体の前日活動（コミット・PR・Issue）を収集
#   2. Markdown 形式の日報を生成し GitHub Content API で reports/ に保存
#   3. Slack へサマリー通知を送信
#
# !! このファイルはソースコードです。変更する場合は PR レビューを経てください !!

# ---------- PATH 設定（launchd は環境変数を継承しないため明示設定）----------

# Apple Silicon Mac: /opt/homebrew/bin
# Intel Mac:        /usr/local/bin
if [[ -d "/opt/homebrew/bin" ]]; then
    export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
elif [[ -d "/usr/local/bin" ]]; then
    export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
fi

# ---------- 設定 ----------

ORG="Noroshi-Ltd"
REPORT_REPO="daily-report"
REPORT_PATH_PREFIX="reports"
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

# ---------- Slack 投稿 ----------

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

urlencode() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

# ---------- リポジトリ一覧取得 ----------

get_org_repos() {
    gh api "orgs/${ORG}/repos?per_page=100&type=all" \
        --jq '.[].name' 2>/dev/null | sort
}

# ---------- コミット収集 ----------

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

collect_issues() {
    local date="$1"

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

    printf '# 日報 %s\n\n' "$date"
    printf '> 自動生成: %s JST\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s\n\n' '---'

    printf '## コミット\n\n'
    if [ -z "$commits_tsv" ]; then
        printf '前日のコミットはありませんでした。\n\n'
    else
        local authors
        authors=$(echo "$commits_tsv" | awk -F'\t' '{print $1}' | sort -u)
        while IFS= read -r author; do
            [ -z "$author" ] && continue
            local author_commits count
            author_commits=$(echo "$commits_tsv" | awk -F'\t' -v a="$author" '$1 == a')
            count=$(echo "$author_commits" | grep -c . || echo "0")
            printf '### %s (%s commits)\n\n' "$author" "$count"
            while IFS=$'\t' read -r _auth repo sha msg; do
                [ -z "$sha" ] && continue
                printf '%s\n' "- \`$sha\` [$repo] $msg"
            done <<< "$author_commits"
            printf '\n'
        done <<< "$authors"
    fi

    printf '## マージされた PR\n\n'
    if [ -z "$prs_tsv" ]; then
        printf '前日にマージされた PR はありませんでした。\n\n'
    else
        local pr_count
        pr_count=$(echo "$prs_tsv" | grep -c . || echo "0")
        printf '合計 %s 件\n\n' "$pr_count"
        while IFS=$'\t' read -r repo num title author; do
            [ -z "$num" ] && continue
            printf '%s\n' "- **[$repo#$num]** $title _(@$author)_"
        done <<< "$prs_tsv"
        printf '\n'
    fi

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
                printf '%s\n' "- **[$repo#$num]** $title _(@$author)_"
            done <<< "$opened_issues"
            printf '\n'
        fi

        if [ -n "$closed_issues" ]; then
            local closed_count
            closed_count=$(echo "$closed_issues" | grep -c . || echo "0")
            printf '### クローズ (%s 件)\n\n' "$closed_count"
            while IFS=$'\t' read -r repo num title author _ev; do
                [ -z "$num" ] && continue
                printf '%s\n' "- **[$repo#$num]** $title _(@$author)_"
            done <<< "$closed_issues"
            printf '\n'
        fi
    fi

    printf '%s\n\n' '---'
    printf '_このドキュメントは `src/daily-report.sh` により自動生成されました。_\n'
}

# ---------- GitHub Content API でファイル保存 ----------

save_to_github() {
    local file_path="$1"
    local content="$2"

    # macOS: base64 は改行あり出力のため tr -d '\n' で除去
    # Linux の場合は base64 -w 0 を使用
    local encoded
    encoded=$(printf '%s' "$content" | base64 | tr -d '\n')

    local sha
    sha=$(gh api "repos/${ORG}/${REPORT_REPO}/contents/${file_path}" \
        --jq '.sha' 2>/dev/null || echo "")

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

# ---------- Slack サマリー生成 ----------

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
        local members
        members=$(echo "$commits_tsv" | awk -F'\t' '{print $1}' | sort | uniq -c | sort -rn)
        echo "$members" | while read -r cnt name; do
            [ -z "$name" ] && continue
            printf '  • *%s* (%s commits)\n' "$name" "$cnt"

            # リポジトリ別にコミットメッセージを表示
            local member_repos
            member_repos=$(echo "$commits_tsv" | awk -F'\t' -v m="$name" '$1==m {print $2}' | sort -u)
            echo "$member_repos" | while IFS= read -r repo; do
                [ -z "$repo" ] && continue
                local rcnt
                rcnt=$(echo "$commits_tsv" | awk -F'\t' -v m="$name" -v r="$repo" '$1==m && $2==r' | wc -l | tr -d ' ')
                printf '    💻 *%s* (%s commits)\n' "$repo" "$rcnt"
                echo "$commits_tsv" | awk -F'\t' -v m="$name" -v r="$repo" '$1==m && $2==r {print $3, $4}' | \
                    while read -r sha msg; do
                        [ -z "$sha" ] && continue
                        printf '%s\n' "      · \`$sha\` $msg"
                    done
            done

            # クローズしたイシュー
            local closed
            closed=$(echo "$issues_tsv" | awk -F'\t' -v m="$name" '$5=="closed" && $4==m')
            if [ -n "$closed" ]; then
                printf '    ✅ *クローズした Issue:*\n'
                echo "$closed" | while IFS=$'\t' read -r repo num title author ev; do
                    [ -z "$num" ] && continue
                    printf '%s\n' "      · #$num $title  _($repo)_"
                done
            fi
        done
    else
        printf '\n活動なし\n'
    fi

    printf '\n<%s|詳細レポートを見る>\n' "$report_url"
}

# ---------- メイン ----------

main() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') === 日報生成開始 ==="

    load_env

    if ! gh api user >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] GitHub CLI が認証されていません (gh auth login を実行)" >&2
        exit 1
    fi

    # 日付計算（macOS BSD date: -v-1d で前日）
    local yesterday
    yesterday=$(date -v-1d '+%Y-%m-%d')

    local since="${yesterday}T00:00:00+09:00"
    local until="${yesterday}T23:59:59+09:00"

    echo "$(date '+%Y-%m-%d %H:%M:%S') 対象日: $yesterday"

    echo "$(date '+%Y-%m-%d %H:%M:%S') コミット収集中..."
    local commits_tsv
    commits_tsv=$(collect_commits "$since" "$until")

    echo "$(date '+%Y-%m-%d %H:%M:%S') PR 収集中..."
    local prs_tsv
    prs_tsv=$(collect_merged_prs "$yesterday")

    echo "$(date '+%Y-%m-%d %H:%M:%S') Issue 収集中..."
    local issues_tsv
    issues_tsv=$(collect_issues "$yesterday")

    echo "$(date '+%Y-%m-%d %H:%M:%S') Markdown 生成中..."
    local report_content
    report_content=$(generate_report "$yesterday" "$commits_tsv" "$prs_tsv" "$issues_tsv")

    local file_path="${REPORT_PATH_PREFIX}/${yesterday}.md"
    echo "$(date '+%Y-%m-%d %H:%M:%S') GitHub に保存中: $file_path"
    save_to_github "$file_path" "$report_content"

    local report_url="https://github.com/${ORG}/${REPORT_REPO}/blob/main/${file_path}"
    local slack_msg
    slack_msg=$(build_slack_summary "$yesterday" "$commits_tsv" "$prs_tsv" "$issues_tsv" "$report_url")

    echo "$(date '+%Y-%m-%d %H:%M:%S') Slack 通知送信中..."
    post_to_slack "$slack_msg"

    echo "$(date '+%Y-%m-%d %H:%M:%S') === 日報生成完了 ==="
}

main "$@"
