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

# ---------- 進捗バー ----------

progress_bar() {
    local done="$1"
    local total="$2"
    local width=10
    [ "$total" -eq 0 ] && { printf '[░░░░░░░░░░]'; return; }
    local filled=$(( done * width / total ))
    local empty=$(( width - filled ))
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar="${bar}█"; done
    for (( i=0; i<empty; i++ )); do bar="${bar}░"; done
    printf '[%s]' "$bar"
}

# ---------- due date（Slack 向け）----------

format_due_date_plain() {
    local due_iso="$1"
    [ -z "$due_iso" ] && return
    local due_date="${due_iso%%T*}"
    local date_info
    date_info=$(python3 -c "
from datetime import date
import sys
due = date.fromisoformat(sys.argv[1])
today = date.today()
diff = (due - today).days
print(str(diff) + '\t' + str(due.month) + '/' + str(due.day))
" "$due_date" 2>/dev/null) || return
    local diff_days short_date
    diff_days=$(echo "$date_info" | cut -f1)
    short_date=$(echo "$date_info" | cut -f2)
    if [ "$diff_days" -lt 0 ]; then
        printf '⚠ %s日超過 (%s〆)' "$(( -diff_days ))" "$short_date"
    elif [ "$diff_days" -eq 0 ]; then
        printf '⚠ 今日〆'
    else
        printf '〆 %s (残り%s日)' "$short_date" "$diff_days"
    fi
}

# ---------- メンバー別 Issue 進捗（マイルストーン単位・今日の進捗ハイライト）----------

build_member_issue_progress() {
    local member="$1"
    local closed_today_text="$2"  # format: "#NUM title (repo)" 1行1件

    local repos_with_issues
    repos_with_issues=$(gh search issues --assignee "$member" --owner "$ORG" \
        --json repository \
        --template '{{range .}}{{.repository.name}}{{"\n"}}{{end}}' 2>/dev/null | sort -u)

    if [ -z "$repos_with_issues" ]; then
        printf '  割り当てられた Issue はありません\n'
        return
    fi

    local found=false
    while IFS= read -r repo; do
        [ -z "$repo" ] && continue

        local issues_tsv
        issues_tsv=$(gh issue list --repo "$ORG/$repo" --state all --assignee "$member" --limit 100 \
            --json number,title,state,milestone \
            --template '{{range .}}{{.number}}	{{.title}}	{{.state}}	{{if .milestone}}{{.milestone.title}}{{else}}(なし){{end}}	{{if .milestone}}{{.milestone.dueOn}}{{end}}{{"\n"}}{{end}}' 2>/dev/null)
        [ -z "$issues_tsv" ] && continue

        # 今日このリポジトリでクローズされた Issue 番号を抽出
        local today_nums_for_repo=""
        [ -n "$closed_today_text" ] && \
            today_nums_for_repo=$(printf '%s\n' "$closed_today_text" | \
                grep "(${repo})" | grep -oE '#[0-9]+' | tr -d '#')

        found=true
        printf '  *%s*\n' "$repo"

        local milestones
        milestones=$(printf '%s' "$issues_tsv" | awk -F'\t' '{print $4}' | awk '!seen[$0]++' | sort | \
            awk '/^\(なし\)$/{last=$0; next} {print} END{if(last) print last}')

        while IFS= read -r milestone; do
            [ -z "$milestone" ] && continue

            local ms_issues
            ms_issues=$(printf '%s' "$issues_tsv" | awk -F'\t' -v ms="$milestone" '$4 == ms')

            local open_count closed_count total
            open_count=$(printf '%s' "$ms_issues"  | awk -F'\t' 'BEGIN{c=0} $3=="OPEN"   {c++} END{print c}')
            closed_count=$(printf '%s' "$ms_issues" | awk -F'\t' 'BEGIN{c=0} $3=="CLOSED" {c++} END{print c}')
            total=$((open_count + closed_count))

            local bar
            bar=$(progress_bar "$closed_count" "$total")

            local due_on due_str=""
            due_on=$(printf '%s' "$ms_issues" | head -1 | awk -F'\t' '{print $5}')
            [ -n "$due_on" ] && due_str=" $(format_due_date_plain "$due_on")"

            if [ "$open_count" -eq 0 ]; then
                # 完了済みマイルストーン: 折りたたみ
                printf '    %s %s/%s *%s* ✅\n' "$bar" "$closed_count" "$total" "$milestone"
            else
                # 進行中マイルストーン: Issue 一覧展開、今日クローズ分を ★ でハイライト
                printf '    %s %s/%s *%s*%s\n' "$bar" "$closed_count" "$total" "$milestone" "$due_str"
                printf '%s' "$ms_issues" | sort -t$'\t' -k3,3 -k1,1n | while IFS=$'\t' read -r num title state ms_col due_col; do
                    [ -z "$num" ] && continue
                    if [ "$state" = "CLOSED" ]; then
                        if printf '%s\n' "$today_nums_for_repo" | grep -qx "$num"; then
                            printf '      ★  #%s %s\n' "$num" "$title"
                        else
                            printf '      ~✅ #%s %s~\n' "$num" "$title"
                        fi
                    else
                        printf '      ○  #%s %s\n' "$num" "$title"
                    fi
                done
            fi
        done <<< "$milestones"

        printf '\n'
    done <<< "$repos_with_issues"

    [ "$found" = false ] && printf '  割り当てられた Issue はありません\n'
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

# Claude API でメンバー活動の自然言語サマリーを生成
summarize_member_activity() {
    local name="$1"
    local date="$2"
    local commits_text="$3"
    local closed_text="${4:-なし}"
    local prs_text="${5:-なし}"

    [ -z "${ANTHROPIC_API_KEY:-}" ] && return 1

    python3 -c "
import json, urllib.request, os, sys

name, date, commits_text, closed_text, prs_text = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
api_key = os.environ.get('ANTHROPIC_API_KEY', '')
if not api_key:
    sys.exit(1)

prompt = (
    f'以下は {name} の {date} のGitHub活動データです。\n'
    '経営者・マネージャー向けに、下記の4項目をそれぞれ1〜2文の日本語で評価してください。\n'
    '技術用語は使わず、わかりやすい言葉で表現してください。\n'
    '指定のラベルを正確に使い、他の文言・前置き・説明は一切出力しないでください。\n\n'
    '作業量: （本日の活動ボリューム全体を平易な言葉で評価する）\n'
    '作業内容: （どのような性質・種類の仕事をしたかを具体的に説明する）\n'
    '難易度: （★1〜5で表し、その根拠を1文で補足する）\n'
    '成果: （今日の活動でチームや事業に何をもたらしたかを述べる）\n\n'
    f'【コミット内容】\n{commits_text}\n\n'
    f'【クローズしたIssue】\n{closed_text}\n\n'
    f'【マージしたPR】\n{prs_text}'
)

payload = json.dumps({
    'model': 'claude-haiku-4-5-20251001',
    'max_tokens': 200,
    'messages': [{'role': 'user', 'content': prompt}]
}).encode()

req = urllib.request.Request(
    'https://api.anthropic.com/v1/messages',
    data=payload,
    headers={
        'x-api-key': api_key,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json'
    }
)
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        data = json.load(r)
        print(data['content'][0]['text'].strip())
except Exception:
    pass
" "$name" "$date" "$commits_text" "$closed_text" "$prs_text" 2>/dev/null
}

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
    printf '• 💻 コミット: *%s 件*  •  🔀 PR マージ: *%s 件*\n' "$commit_count" "$pr_count"
    printf '• 🆕 新規 Issue: *%s 件*  •  ✅ クローズ Issue: *%s 件*\n' "$opened_count" "$closed_count"

    if [ -n "$commits_tsv" ]; then
        printf '\n*メンバー別活動*\n'
        local members
        members=$(echo "$commits_tsv" | awk -F'\t' '{print $1}' | sort | uniq -c | sort -rn)

        echo "$members" | while read -r cnt name; do
            [ -z "$name" ] && continue
            printf '\n👤 *%s*  (%s commits)\n' "$name" "$cnt"

            # AI サマリー用データ収集
            local commits_text prs_text closed_text
            commits_text=$(echo "$commits_tsv" | awk -F'\t' -v m="$name" '$1==m {print $2": "$4}')
            prs_text=$(echo "$prs_tsv" | awk -F'\t' -v m="$name" '$4==m {print "#"$2" "$3" ("$1")"}')
            closed_text=$(echo "$issues_tsv" | awk -F'\t' -v m="$name" '$5=="closed" && $4==m {print "#"$2" "$3" ("$1")"}')

            # AI 生成サマリー（箇条書きフォーマット）
            local summary
            summary=$(summarize_member_activity "$name" "$date" "$commits_text" "$closed_text" "$prs_text")
            if [ -n "$summary" ]; then
                echo "$summary" | while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    case "$line" in
                        作業量:*|作業内容:*|難易度:*|成果:*)
                            printf '%s\n' "• ${line}" ;;
                        *)
                            printf '%s\n' "  ${line}" ;;
                    esac
                done
            fi

            # Issue 進捗（マイルストーン別・今日の進捗ハイライト）
            printf '*Issue進捗*\n'
            build_member_issue_progress "$name" "$closed_text"

            printf '\n'
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
