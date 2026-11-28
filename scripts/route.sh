#!/usr/bin/env bash
# イベントを判定し、後続ジョブで行う作業を GITHUB_OUTPUT に書き出す。
# Claudeを起動しない処理（flaky判定の再実行、上限の通知、Ready化）はここで済ませる。
set -euo pipefail

REPO="$GITHUB_REPOSITORY"
EVENT="$GITHUB_EVENT_PATH"
BOT='claude[bot]'
ACTIONS_BOT='github-actions[bot]'
M_SELF_REVIEW='<!-- devflow:self-review -->'
M_CI_FIX='<!-- devflow:ci-fix -->'
M_CI_LIMIT='<!-- devflow:ci-limit -->'

issue_action='' issues='[]' pr_action='' prs='[]'
flaky_run='' run_id='' comment_id='' review_id=''

ev() { jq -r "$1 // empty" "$EVENT"; }
log() { echo "[route] $*" >&2; }
to_json() { if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -cs 'unique'; fi; }

emit() {
  {
    echo "config=$CONFIG"
    echo "mention=$MENTION"
    echo "reviewers=$REVIEWERS"
    echo "issue_action=$issue_action"
    echo "issues=$issues"
    echo "pr_action=$pr_action"
    echo "prs=$prs"
    echo "flaky_run=$flaky_run"
    echo "run_id=$run_id"
    echo "comment_id=$comment_id"
    echo "review_id=$review_id"
  } >> "$GITHUB_OUTPUT"
  log "issue_action=$issue_action issues=$issues pr_action=$pr_action prs=$prs flaky_run=$flaky_run"
}

# 設定はデフォルトブランチの .github/devflow.yml から読む（PRのブランチでは書き換えられない）
load_config() {
  local raw user='{}'
  raw=$(gh api "repos/$REPO/contents/.github/devflow.yml" -H 'Accept: application/vnd.github.raw' 2>/dev/null || true)
  if [ -n "$raw" ]; then user=$(printf '%s\n' "$raw" | yq -o=json -I=0 '. // {}'); fi
  CONFIG=$(jq -cn --argjson u "$user" --arg branch "$(ev .repository.default_branch)" '
    {
      default_branch: $branch,
      approvers: [],
      models: {triage: "opus", plan: "auto", implement: "auto", review: "opus", light: "haiku"},
      max_turns: {plan: 30, implement: 100, review: 30, light: 10},
      ci_fix_limit: 3,
      issue_limit: 3
    } * $u')

  APPROVERS=$(jq -c '.approvers // []' <<<"$CONFIG")
  # 指定がなければリポジトリのオーナー（個人アカウントのとき）
  if [ "$APPROVERS" = '[]' ] && [ "$(ev .repository.owner.type)" = User ]; then
    APPROVERS=$(jq -cn --arg o "$(ev .repository.owner.login)" '[$o]')
  fi
  CONFIG=$(jq -c --argjson a "$APPROVERS" '.approvers = $a' <<<"$CONFIG")
  MENTION=$(jq -r 'map("@" + .) | join(" ")' <<<"$APPROVERS")
  REVIEWERS=$(jq -r 'join(",")' <<<"$APPROVERS")
}

is_approver() { jq -e --arg u "$1" 'any(.[]; . == $u)' <<<"$APPROVERS" >/dev/null; }

# 先頭の空白・改行を除いた本文の種類（lgtm / memo / review / normal）
comment_kind() {
  jq -r "$1"' // "" | sub("^[[:space:]]+"; "") |
    if startswith("[LGTM]") then "lgtm" elif startswith("[MEMO]") then "memo"
    elif startswith("[REVIEW REQUEST]") then "review" else "normal" end' "$EVENT"
}

# 本文に @claude のメンションがあるか
mentions_claude() {
  jq -e "$1"' // "" | test("(^|[^A-Za-z0-9_/-])@claude($|[^A-Za-z0-9_-])"; "i")' "$EVENT" >/dev/null
}

# Issueに対応する、開いている・マージ済みのClaudeのPR
active_pr_for_issue() {
  gh pr list -R "$REPO" --state all --limit 100 --json number,headRefName,state \
    --jq ".[] | select(.state != \"CLOSED\" and (.headRefName | startswith(\"claude/issue-$1-\"))) | .number" | head -n1
}

# 本文の <!-- devflow:after #N --> のうち、まだ開いているIssue
open_deps() {
  local n
  for n in $(grep -oE '<!-- devflow:after #[0-9]+ -->' <<<"$1" | grep -oE '[0-9]+' || true); do
    if [ "$(gh issue view "$n" -R "$REPO" --json state -q .state)" = OPEN ]; then echo "$n"; fi
  done
}

pr_comments() {
  gh api --paginate "repos/$REPO/issues/$1/comments" --jq '.[] | {user: .user.login, body, at: .created_at}' | jq -cs .
}

# 承認者の最後のコメント・レビューの日時（CIの修正回数はここから数え直す）
last_approver_activity() {
  {
    pr_comments "$1" | jq -r --argjson a "$APPROVERS" '.[] | select(.user as $u | any($a[]; . == $u)) | .at'
    gh api --paginate "repos/$REPO/pulls/$1/reviews" --jq '.[] | {user: .user.login, at: .submitted_at}' |
      jq -r --argjson a "$APPROVERS" 'select(.user as $u | any($a[]; . == $u)) | .at'
  } | sort | tail -n1
}

# botが書いた、指定の目印を含むコメントの数（since より後のもの）
count_markers() {
  pr_comments "$1" | jq --arg m "$2" --arg since "${3:-}" --arg bot "$BOT" --arg ab "$ACTIONS_BOT" \
    '[.[] | select((.user == $bot or .user == $ab) and (.body | contains($m)) and .at > $since)] | length'
}

mark_ready() {
  log "PR #$1 をレビュー可能にする"
  gh pr ready "$1" -R "$REPO"
  if [ -n "$REVIEWERS" ]; then gh pr edit "$1" -R "$REPO" --add-reviewer "$REVIEWERS"; fi
}

on_issue_opened() {
  local n author
  n=$(ev .issue.number)
  author=$(ev .issue.user.login)
  if [ "$author" != "$BOT" ] && ! is_approver "$author"; then log "対象外の起票者: $author"; return; fi
  if [ -n "$(open_deps "$(ev .issue.body)")" ]; then log "#$n は依存Issueのマージ待ち"; return; fi
  issue_action=plan
  issues=$(to_json "$n")
}

on_issue_comment() {
  local n commenter kind head
  n=$(ev .issue.number)
  commenter=$(ev .comment.user.login)
  if ! is_approver "$commenter"; then log "対象外のコメント: $commenter"; return; fi
  if [ "$(ev .issue.state)" != open ]; then return; fi
  kind=$(comment_kind .comment.body)
  if [ "$kind" = memo ]; then return; fi
  comment_id=$(ev .comment.id)

  if [ -n "$(ev .issue.pull_request.url)" ]; then
    # PR上の [LGTM] は承認として扱わない
    if [ "$kind" = lgtm ]; then return; fi
    if [ "$kind" = review ]; then
      # [REVIEW REQUEST] はどのブランチのPRでもレビューする（pushはしない）
      pr_action=review_request
    else
      head=$(gh pr view "$n" -R "$REPO" --json headRefName -q .headRefName)
      if [[ $head == claude/* ]]; then
        pr_action=pr_comment
      elif mentions_claude .comment.body; then
        # 人間のPRは、@claude と話しかけられたときだけ返信する（pushはしない）
        pr_action=pr_reply
      else
        return
      fi
    fi
    prs=$(to_json "$n")
    return
  fi

  # Issue上の [REVIEW REQUEST] は対象外
  if [ "$kind" = review ]; then return; fi
  if [ "$kind" = lgtm ]; then
    if [ -n "$(active_pr_for_issue "$n")" ]; then log "#$n はPRがあるため [LGTM] を無視"; return; fi
    issue_action=implement
  else
    issue_action=plan
  fi
  issues=$(to_json "$n")
}

on_review() {
  local n reviewer head kind count
  n=$(ev .pull_request.number)
  reviewer=$(ev .review.user.login)
  head=$(ev .pull_request.head.ref)
  if ! is_approver "$reviewer" || [[ $head != claude/* ]] || [ "$(ev .pull_request.state)" != open ]; then return; fi
  kind=$(comment_kind .review.body)
  if [ "$kind" = memo ]; then return; fi
  review_id=$(ev .review.id)
  # 本文もインラインコメントもない承認には何もしない
  if [ "$(ev .review.state)" = approved ] && [ -z "$(ev .review.body)" ]; then
    count=$(gh api "repos/$REPO/pulls/$n/reviews/$review_id/comments" --jq length)
    if [ "$count" = 0 ]; then return; fi
  fi
  pr_action=review_fix
  prs=$(to_json "$n")
}

attempt_failed() {
  case "$(gh api "repos/$REPO/actions/runs/$1/attempts/$2" --jq .conclusion)" in
    failure | timed_out) return 0 ;;
    *) return 1 ;;
  esac
}

# 失敗したジョブを1回だけ再実行し、通ったら0を返す
rerun_passes() {
  local state attempt status conclusion
  log "flaky判定のため、実行 $1 の失敗したジョブを再実行する"
  gh run rerun "$1" -R "$REPO" --failed
  for _ in $(seq 120); do
    sleep 30
    state=$(gh api "repos/$REPO/actions/runs/$1" --jq '"\(.run_attempt) \(.status) \(.conclusion)"')
    read -r attempt status conclusion <<<"$state"
    if [ "$attempt" -ge 2 ] && [ "$status" = completed ]; then
      [ "$conclusion" = success ]
      return
    fi
  done
  return 1
}

on_ci_success() {
  if [ "$PR_DRAFT" != true ]; then return; fi
  if [ "$(count_markers "$PR_NUM" "$M_SELF_REVIEW")" -gt 0 ]; then
    mark_ready "$PR_NUM"
  else
    pr_action=self_review
    prs=$(to_json "$PR_NUM")
  fi
}

on_ci_failure() {
  local since count limit url
  since=$(last_approver_activity "$PR_NUM")
  count=$(count_markers "$PR_NUM" "$M_CI_FIX" "$since")
  limit=$(jq -r .ci_fix_limit <<<"$CONFIG")
  url=$(ev .workflow_run.html_url)
  if [ "$count" -ge "$limit" ]; then
    if [ "$(count_markers "$PR_NUM" "$M_CI_LIMIT" "$since")" -eq 0 ]; then
      gh pr comment "$PR_NUM" -R "$REPO" --body "$MENTION CIの自動修正が上限（${limit}回）に達したため止めました。[失敗した実行]($url) を確認してください。方針をコメントすると、そこから再開します。

$M_CI_LIMIT"
    fi
    return
  fi
  gh pr comment "$PR_NUM" -R "$REPO" --body "CIが失敗したため自動修正します（$((count + 1))/${limit}回目）。[失敗した実行]($url)

$M_CI_FIX"
  pr_action=ci_fix
  prs=$(to_json "$PR_NUM")
}

on_workflow_run() {
  local branch attempt conclusion pr_json
  branch=$(ev .workflow_run.head_branch)
  if [[ $branch != claude/* ]]; then return; fi
  # routeが行った再実行の結果は、再実行したrouteがその場で扱う
  if [ "$(ev .workflow_run.triggering_actor.login)" = "$ACTIONS_BOT" ]; then return; fi
  pr_json=$(gh pr list -R "$REPO" --head "$branch" --state open --json number,isDraft --jq '.[0] // empty')
  if [ -z "$pr_json" ]; then log "$branch のPRがない"; return; fi
  PR_NUM=$(jq -r .number <<<"$pr_json")
  PR_DRAFT=$(jq -r .isDraft <<<"$pr_json")
  run_id=$(ev .workflow_run.id)
  attempt=$(ev .workflow_run.run_attempt)
  conclusion=$(ev .workflow_run.conclusion)

  case "$conclusion" in
    success)
      if [ "$attempt" -gt 1 ] && attempt_failed "$run_id" $((attempt - 1)); then flaky_run=$run_id; fi
      on_ci_success
      ;;
    failure | timed_out)
      if [ "$attempt" -eq 1 ] && rerun_passes "$run_id"; then
        flaky_run=$run_id
        on_ci_success
      else
        on_ci_failure
      fi
      ;;
    *) log "CIの結果 $conclusion は扱わない" ;;
  esac
}

on_push() {
  local sha p c num body64 body m
  local closed=() targets=() conflicts=()
  if [ "$(ev .ref)" != "refs/heads/$(jq -r .default_branch <<<"$CONFIG")" ]; then return; fi
  sha=$(ev .after)

  # マージされたPRが閉じたIssueを待っていたサブIssueを起動する
  for p in $(gh api "repos/$REPO/commits/$sha/pulls" --jq '.[] | select(.merged_at != null) | .number'); do
    for c in $(gh pr view "$p" -R "$REPO" --json closingIssuesReferences --jq '.closingIssuesReferences[].number'); do
      closed+=("$c")
    done
  done
  if [ ${#closed[@]} -gt 0 ]; then
    while IFS=$'\t' read -r num body64; do
      body=$(base64 -d <<<"$body64")
      for c in "${closed[@]}"; do
        if grep -qF "<!-- devflow:after #$c -->" <<<"$body" && [ -z "$(open_deps "$body")" ]; then
          targets+=("$num")
          break
        fi
      done
    done < <(gh issue list -R "$REPO" --state open --limit 200 --json number,body,author \
      --jq '.[] | select((.author.login | test("claude")) and (.body | contains("devflow:after"))) | [.number, (.body | @base64)] | @tsv')
  fi
  if [ ${#targets[@]} -gt 0 ]; then
    issue_action=plan
    issues=$(to_json "${targets[@]}")
  fi

  # コンフリクトしたClaudeのPRを直す
  for p in $(gh pr list -R "$REPO" --state open --limit 100 --json number,headRefName \
    --jq '.[] | select(.headRefName | startswith("claude/")) | .number'); do
    for _ in 1 2 3 4 5 6; do
      m=$(gh pr view "$p" -R "$REPO" --json mergeable -q .mergeable)
      if [ "$m" != UNKNOWN ]; then break; fi
      sleep 10
    done
    if [ "$m" = CONFLICTING ]; then conflicts+=("$p"); fi
  done
  if [ ${#conflicts[@]} -gt 0 ]; then
    pr_action=conflict
    prs=$(to_json "${conflicts[@]}")
  fi
}

# きっかけの対象に 👀 を付けて、受け付けたことを知らせる（失敗しても続ける）
react() {
  gh api -X POST "repos/$REPO/$1/reactions" -f content=eyes --silent >/dev/null || log "リアクションに失敗: $1"
}

# Claudeのジョブを起動すると決めたとき、きっかけのIssue・コメントに付ける（push・workflow_run は対象外）
acknowledge() {
  if [ -z "$issue_action" ] && [ -z "$pr_action" ]; then return; fi
  case "$GITHUB_EVENT_NAME" in
    issues) react "issues/$(ev .issue.number)" ;;
    issue_comment) react "issues/comments/$comment_id" ;;
    pull_request_review)
      if [ -n "$(ev .review.body)" ]; then
        # 本文のあるレビューは、レビュー本体にGraphQLで付ける（RESTでは付けられない）
        # shellcheck disable=SC2016
        gh api graphql -f query='mutation($id: ID!) { addReaction(input: {subjectId: $id, content: EYES}) { clientMutationId } }' \
          -f id="$(ev .review.node_id)" --silent >/dev/null || log "レビューへのリアクションに失敗"
      else
        # 本文のないレビューは、全部のインラインコメントに付ける（PR本文には付けない）
        local cid
        for cid in $(gh api --paginate "repos/$REPO/pulls/$(ev .pull_request.number)/reviews/$(ev .review.id)/comments" --jq '.[].id' 2>/dev/null); do
          react "pulls/comments/$cid"
        done
      fi
      ;;
  esac
}

load_config
if [ "$APPROVERS" = '[]' ]; then
  log "承認者が決まらない。organizationのリポジトリでは .github/devflow.yml の approvers を指定する"
  emit
  exit 0
fi

action=$(ev .action)
case "$GITHUB_EVENT_NAME" in
  issues) if [ "$action" = opened ]; then on_issue_opened; fi ;;
  issue_comment) if [ "$action" = created ]; then on_issue_comment; fi ;;
  pull_request_review) if [ "$action" = submitted ]; then on_review; fi ;;
  workflow_run) if [ "$action" = completed ]; then on_workflow_run; fi ;;
  push) on_push ;;
  *) log "対象外のイベント: $GITHUB_EVENT_NAME" ;;
esac
acknowledge
emit
