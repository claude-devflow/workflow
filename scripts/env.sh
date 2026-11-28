#!/usr/bin/env bash
# 工程ごとの claude_args と共通の環境変数を GITHUB_ENV に書き出す。
# 入力: CFG（route.sh が出力した設定のJSON）
set -euo pipefail

: "${CFG:?CFG が必要}"
dir="$RUNNER_TEMP/devflow"
tools='Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,TodoWrite,Task'

# auto のときに判定がなければ使うモデル
fallback() { case $1 in plan) echo best ;; *) echo sonnet ;; esac; }

{
  for stage in plan implement review light; do
    model=$(jq -r ".models.$stage" <<<"$CFG")
    if [ "$model" = auto ]; then model=$(fallback "$stage"); fi
    turns=$(jq -r ".max_turns.$stage" <<<"$CFG")
    base="--max-turns $turns --append-system-prompt-file $dir/rules/common.md --allowedTools $tools"
    # ARGS_*_BASE はモデルを判定で決める工程用（--model を付けずに渡す）
    echo "ARGS_${stage^^}_BASE=$base"
    echo "ARGS_${stage^^}=--model $model $base"
  done
  # 判定はIssueの本文だけで行う。ファイルを読みにいかないようにツールを外す
  echo "ARGS_TRIAGE=--model $(jq -r .models.triage <<<"$CFG") --max-turns 3 --disallowedTools $tools"
  echo "DEVFLOW_DIR=$dir"
  echo "DEFAULT_BRANCH=$(jq -r .default_branch <<<"$CFG")"
  echo "DEVFLOW_ISSUE_LIMIT=$(jq -r .issue_limit <<<"$CFG")"
} >> "$GITHUB_ENV"

# 共通ワークフローのファイルがアプリにコミットされないようにする
echo '.devflow-src/' >> .git/info/exclude
