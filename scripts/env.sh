#!/usr/bin/env bash
# 工程ごとの claude_args と共通の環境変数を GITHUB_ENV に書き出す。
# 入力: CFG（route.sh が出力した設定のJSON）
set -euo pipefail

: "${CFG:?CFG が必要}"
dir="$RUNNER_TEMP/devflow"
tools='Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,TodoWrite,Task'

{
  for stage in plan implement review light; do
    model=$(jq -r ".models.$stage" <<<"$CFG")
    turns=$(jq -r ".max_turns.$stage" <<<"$CFG")
    echo "ARGS_${stage^^}=--model $model --max-turns $turns --append-system-prompt-file $dir/rules/common.md --allowedTools $tools"
  done
  echo "DEVFLOW_DIR=$dir"
  echo "DEFAULT_BRANCH=$(jq -r .default_branch <<<"$CFG")"
  echo "DEVFLOW_ISSUE_LIMIT=$(jq -r .issue_limit <<<"$CFG")"
} >> "$GITHUB_ENV"

# 共通ワークフローのファイルがアプリにコミットされないようにする
echo '.devflow-src/' >> .git/info/exclude
