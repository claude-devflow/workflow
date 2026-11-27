#!/usr/bin/env bash
# flaky testのIssueを起票する。同じテストのIssueが開いていれば、発生回数を追記する。
# Claudeが原因を分析したあとに実行する。Claude App のトークンで立てるので、Claudeが起票したIssueになる。
# 使い方: flaky-issue.sh "<テスト名>" <分析を書いたファイル>
# 入力: RUN_ID（1回目に失敗したCIの実行ID）
set -euo pipefail

test_name=${1:?テスト名が必要}
analysis=$(cat "${2:?分析のファイルが必要}")
title="flaky test: $test_name"
run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$RUN_ID"
marker='<!-- devflow:flaky-occurrence -->'

existing=$(gh issue list --state open --search "\"$title\" in:title" --limit 20 --json number,title \
  --jq ".[] | select(.title == $(jq -Rn --arg t "$title" '$t')) | .number" | head -n1)

if [ -n "$existing" ]; then
  # 起票時の1回 + 追記した回数
  n=$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$existing/comments" --jq ".[] | select(.body | contains(\"$marker\")) | .id" | wc -l)
  gh issue comment "$existing" --body "再発しました（通算$((n + 2))回目）。[実行]($run_url)

$marker"
  exit 0
fi

gh issue create --title "$title" --body "CIが1回失敗し、再実行で通りました。flaky testとみなして起票します。

- テスト: \`$test_name\`
- 実行: $run_url
- 発生回数: 1回目（再発したらコメントで追記します）

## 原因の分析（Haiku）

$analysis"
