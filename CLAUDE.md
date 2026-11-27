# CLAUDE.md

Claude駆動開発フローの共通ワークフロー。全アプリがこのリポジトリのワークフロー・スクリプト・プロンプトを実行時に使う。仕様は `docs/spec.md`。

## 技術スタック

- GitHub Actions（`workflow_call` の再利用可能ワークフロー）
- bash、jq、yq、gh（GitHub Actions の ubuntu-latest に入っているもの）
- anthropics/claude-code-action@v1

## コマンド

- lint：`actionlint` と `shellcheck setup.sh scripts/*.sh`（CIで実行する）

## 構成

| パス | 役割 |
| --- | --- |
| `.github/workflows/devflow.yml` | 共通ワークフローの本体 |
| `scripts/route.sh` | イベントの判定。Claudeを起動しない処理もここで行う |
| `scripts/env.sh`、`scripts/prompt.sh` | 工程ごとの引数とプロンプトの組み立て |
| `scripts/create-issue.sh`、`scripts/flaky-issue.sh` | 起票（上限と重複の確認） |
| `rules/common.md` | 全アプリのClaudeに `--append-system-prompt-file` で渡す共通ルール |
| `prompts/` | 工程ごとのプロンプト |
| `setup.sh` | アプリへの導入とトークンの一括差し替え |
| `.github/workflows/claude.yml` | このリポジトリ自身の呼び出し用ファイル（main を呼ぶ） |

## 規約

- 公開リポジトリなので、アプリ固有の情報（コード、エラーの内容、アプリ名）を書かない。
- 全アプリに影響する。後方互換を保ち、呼び出し用ファイルの変更が必要な変更は避ける。必要なら `docs/spec.md` とテンプレートの更新もIssueに切り出す。
- 変更は claude-devflow/sandbox（main を呼ぶ）で動作を確かめてから、`v1` タグを動かして配る。タグの更新は人間が行う。
- 仕様を変える変更では `docs/spec.md` も更新する。
