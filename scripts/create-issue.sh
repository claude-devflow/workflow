#!/usr/bin/env bash
# Claudeが別Issueを起票するときに使う。1回の実行での起票数の上限と、似たIssueの確認を強制する。
# 使い方:
#   create-issue.sh --title "タイトル" --body-file 本文.md [--checked] [--devflow]
#   --checked  似たIssueの一覧を確認し、重複ではないと判断したとき付ける
#   --devflow  共通ワークフローのリポジトリに改善Issueを立てる（アプリ固有の情報は書かない）
set -euo pipefail

title='' body_file='' checked=false devflow=false
while [ $# -gt 0 ]; do
  case "$1" in
    --title) title=$2; shift 2 ;;
    --body-file) body_file=$2; shift 2 ;;
    --checked) checked=true; shift ;;
    --devflow) devflow=true; shift ;;
    *) echo "不明な引数: $1" >&2; exit 1 ;;
  esac
done
if [ -z "$title" ] || [ ! -f "$body_file" ]; then
  echo "--title と --body-file（存在するファイル）が必要" >&2
  exit 1
fi

repo=$GITHUB_REPOSITORY
if [ "$devflow" = true ]; then
  repo=${DEVFLOW_REPO:?DEVFLOW_REPO が必要}
  # 自分自身が共通ワークフローのリポジトリなら、アプリと同じトークンで立てる
  if [ "$repo" != "$GITHUB_REPOSITORY" ]; then
    if [ -z "${DEVFLOW_ISSUE_TOKEN:-}" ]; then
      echo "DEVFLOW_ISSUE_TOKEN が未登録のため、$repo には起票できない" >&2
      exit 1
    fi
    export GH_TOKEN=$DEVFLOW_ISSUE_TOKEN
  fi
fi

counter="${RUNNER_TEMP:-/tmp}/devflow-issue-count"
count=$(cat "$counter" 2>/dev/null || echo 0)
limit=${DEVFLOW_ISSUE_LIMIT:-3}
if [ "$count" -ge "$limit" ]; then
  echo "この実行で起票できるのは${limit}件まで。残りは計画やPRの説明に書き、承認者の判断に任せる" >&2
  exit 2
fi

if [ "$checked" = false ]; then
  similar=$(gh issue list -R "$repo" --state open --search "$title" --limit 10 --json number,title,url \
    --jq '.[] | "#\(.number) \(.title) \(.url)"')
  if [ -n "$similar" ]; then
    echo "似ているかもしれない開いたIssue:"
    echo "$similar"
    echo "重複なら起票せず、既存のIssueにコメントする。重複でなければ --checked を付けて再実行する"
    exit 3
  fi
fi

gh issue create -R "$repo" --title "$title" --body-file "$body_file"
echo $((count + 1)) > "$counter"
