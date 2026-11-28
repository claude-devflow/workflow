#!/usr/bin/env bash
# 実行コンテキストとプロンプト本文を結合し、ステップ出力 text に書き出す。
# 使い方: prompt.sh <prompts/ 以下のファイル名（拡張子なし）>
set -euo pipefail

name=$1
file="$DEVFLOW_DIR/prompts/$name.md"
delim="EOF_$(openssl rand -hex 8)"

# PRの作業ではブランチ名からIssue番号を求める
issue=${ISSUE:-}
if [ -z "$issue" ] && [ -n "${PR:-}" ]; then
  head=$(gh pr view "$PR" --json headRefName -q .headRefName)
  if [[ $head =~ ^claude/issue-([0-9]+)- ]]; then issue=${BASH_REMATCH[1]}; fi
fi

line() { if [ -n "$2" ]; then echo "- $1: $2"; fi; }

{
  echo "text<<$delim"
  echo "# 実行コンテキスト"
  echo
  line "リポジトリ" "$GITHUB_REPOSITORY"
  line "デフォルトブランチ" "$DEFAULT_BRANCH"
  line "承認者へのメンション" "${MENTION:-}"
  line "Issue" "${issue:+#$issue}"
  if [ -n "$issue" ]; then
    author=$(gh issue view "$issue" --json author -q .author.login)
    case "$author" in
      *claude*) line "Issueの起票元" "Claude" ;;
      *) line "Issueの起票元" "承認者（$author）" ;;
    esac
  fi
  line "PR" "${PR:+#$PR}"
  line "きっかけのコメントID" "${COMMENT_ID:-}"
  line "きっかけのレビューID" "${REVIEW_ID:-}"
  line "失敗したCIの実行ID" "${RUN_ID:-}"
  line "CIの失敗ログ" "${CI_LOG:-}"
  line "共通ワークフローのディレクトリ" "$DEVFLOW_DIR"
  line "共通ワークフローのリポジトリ" "${DEVFLOW_REPO:-}"
  line "この実行で起票できるIssueの上限" "${DEVFLOW_ISSUE_LIMIT:-}"
  line "計画のモデル" "${PLAN_MODEL:-}"
  if [ -n "${ISSUE_DUMP:-}" ] && [ -s "$ISSUE_DUMP" ]; then
    echo
    echo "## Issueの本文とコメント"
    echo
    cat "$ISSUE_DUMP"
  fi
  if [ -n "${CI_SUMMARY_FILE:-}" ] && [ -s "$CI_SUMMARY_FILE" ]; then
    echo
    echo "## CIの失敗の要約（Haiku）"
    echo
    cat "$CI_SUMMARY_FILE"
  fi
  echo
  cat "$file"
  echo "$delim"
} >> "$GITHUB_OUTPUT"
