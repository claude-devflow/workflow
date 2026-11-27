#!/usr/bin/env bash
# Claude駆動開発フローをアプリのリポジトリに導入する。何度実行しても同じ結果になる。
#
# 使い方:
#   setup.sh install <owner/repo> [--ref <タグまたはブランチ>]
#     シークレットを登録し（登録済みならそのまま）、呼び出し用ファイルをテンプレートの最新に合わせる。
#     呼び出し用ファイルに差分があれば、ブランチ devflow-setup でPRを出す。
#     --ref は呼び出す共通ワークフローのバージョン（既定 v1。sandbox では main）
#   setup.sh rotate-token [<owner> ...]
#     CLAUDE_CODE_OAUTH_TOKEN だけを、フローを導入済みの全リポジトリで差し替える。
#     owner の既定は、ログイン中のアカウントと claude-devflow
#
# トークンは環境変数 CLAUDE_CODE_OAUTH_TOKEN / DEVFLOW_ISSUE_TOKEN で渡すか、実行中に入力する。
# 必要なもの: gh（workflow スコープ付きでログイン済み）、git
set -euo pipefail

DEVFLOW_ORG=claude-devflow
TEMPLATE_REPO=$DEVFLOW_ORG/template
WORKFLOW_REPO=$DEVFLOW_ORG/workflow
CALLER=.github/workflows/claude.yml
BRANCH=devflow-setup

log() { echo "[setup] $*" >&2; }
die() { log "$*"; exit 1; }

# 環境変数になければ端末から読む（curl | bash でも入力できるよう /dev/tty から）
ask_secret() {
  local name=$1 value=${!1:-}
  if [ -z "$value" ]; then
    read -rsp "$name を入力してください: " value </dev/tty
    echo >&2
  fi
  [ -n "$value" ] || die "$name が空です"
  printf -v "$name" '%s' "$value"
  export "${name?}"
}

has_secret() { gh secret list -R "$1" --json name --jq '.[].name' | grep -qx "$2"; }

set_secret() {
  local repo=$1 name=$2
  if has_secret "$repo" "$name" && [ -z "${!name:-}" ]; then
    log "$repo: $name は登録済み"
    return
  fi
  ask_secret "$name"
  gh secret set "$name" -R "$repo" --body "${!name}"
  log "$repo: $name を登録しました"
}

caller_content() {
  local ref=$1
  gh api "repos/$TEMPLATE_REPO/contents/$CALLER" -H 'Accept: application/vnd.github.raw' |
    sed -e "s|devflow.yml@v1|devflow.yml@$ref|" -e "s|devflow_ref: v1|devflow_ref: $ref|"
}

install() {
  local repo=$1 ref=$2 tmp default
  gh repo view "$repo" >/dev/null || die "$repo が見つかりません"

  set_secret "$repo" CLAUDE_CODE_OAUTH_TOKEN
  if [ "$repo" != "$WORKFLOW_REPO" ]; then set_secret "$repo" DEVFLOW_ISSUE_TOKEN; fi

  # 通常のマージ（マージコミット）を使えるようにする
  gh repo edit "$repo" --enable-merge-commit >/dev/null

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  gh repo clone "$repo" "$tmp/repo" -- --quiet
  default=$(git -C "$tmp/repo" symbolic-ref --short HEAD)
  mkdir -p "$tmp/repo/.github/workflows"
  caller_content "$ref" > "$tmp/repo/$CALLER"

  if [ -z "$(git -C "$tmp/repo" status --porcelain)" ]; then
    log "$repo: 呼び出し用ファイルは最新です"
    return
  fi
  git -C "$tmp/repo" switch --quiet -C "$BRANCH"
  git -C "$tmp/repo" add "$CALLER"
  git -C "$tmp/repo" commit --quiet -m "Claude駆動開発フローの呼び出し用ファイルを更新"
  git -C "$tmp/repo" push --quiet --force origin "$BRANCH"
  if [ -z "$(gh pr list -R "$repo" --head "$BRANCH" --state open --json number --jq '.[].number')" ]; then
    gh pr create -R "$repo" --base "$default" --head "$BRANCH" \
      --title "Claude駆動開発フローの呼び出し用ファイルを更新" \
      --body "setup.sh が、呼び出し用ファイル（\`$CALLER\`）をテンプレートの最新（共通ワークフロー \`$ref\`）に合わせました。"
  else
    log "$repo: 既存のPRを更新しました"
  fi
}

rotate_token() {
  local owners=("$@") owner repo
  if [ ${#owners[@]} -eq 0 ]; then owners=("$(gh api user --jq .login)" "$DEVFLOW_ORG"); fi
  ask_secret CLAUDE_CODE_OAUTH_TOKEN
  for owner in "${owners[@]}"; do
    for repo in $(gh repo list "$owner" --limit 1000 --no-archived --json nameWithOwner --jq '.[].nameWithOwner'); do
      if gh api "repos/$repo/contents/$CALLER" -H 'Accept: application/vnd.github.raw' 2>/dev/null |
        grep -q "$WORKFLOW_REPO/.github/workflows/devflow.yml"; then
        gh secret set CLAUDE_CODE_OAUTH_TOKEN -R "$repo" --body "$CLAUDE_CODE_OAUTH_TOKEN"
        log "$repo: 差し替えました"
      fi
    done
  done
}

cmd=${1:-}
shift || true
case "$cmd" in
  install)
    repo=${1:-}
    [ -n "$repo" ] || die "使い方: setup.sh install <owner/repo> [--ref <ref>]"
    shift
    ref=v1
    if [ "${1:-}" = --ref ]; then ref=${2:?--ref の値が必要}; fi
    install "$repo" "$ref"
    ;;
  rotate-token) rotate_token "$@" ;;
  *) sed -n '2,14p' "$0" 2>/dev/null || true; die "サブコマンドを指定してください（install / rotate-token）" ;;
esac
