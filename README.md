# claude-devflow/workflow

Claude駆動開発フローの共通ワークフロー。人間はIssueを書き、PRをレビューしてマージするだけで、計画・実装・テスト・CI修正・セルフレビューはClaudeが担う。仕様は [docs/spec.md](docs/spec.md)。

## 使い方

アプリは [claude-devflow/template](https://github.com/claude-devflow/template) から作り、`setup.sh` でシークレットを登録する。

```bash
gh repo create <名前> --private --template claude-devflow/template --clone
curl -fsSL https://raw.githubusercontent.com/claude-devflow/workflow/main/setup.sh | bash -s -- install <owner>/<名前>
```

| コマンド | 内容 |
| --- | --- |
| `setup.sh install <owner/repo> [--ref <ref>]` | シークレットの登録（登録済みならそのまま）、マージコミットの有効化、呼び出し用ファイルの同期（差分があればPR） |
| `setup.sh rotate-token [<owner> ...]` | `CLAUDE_CODE_OAUTH_TOKEN` を、フローを導入済みの全リポジトリで差し替える |

## イベントと工程

`scripts/route.sh` がイベントを判定し、次のジョブに振り分ける。

| イベント | 条件 | 工程（モデル） |
| --- | --- | --- |
| Issueの作成 | 承認者かClaudeが起票。依存Issueが開いていない | 計画（`best`）→ 承認者のIssueか簡単なものは実装（`sonnet`） |
| Issueへのコメント | 承認者の新規コメント。`[MEMO]` は無視 | `[LGTM]` なら実装、それ以外は計画のやり直し・返信 |
| PRへのコメント | 承認者、`claude/` のブランチ。`[LGTM]`・`[MEMO]`・`[REVIEW REQUEST]` は無視 | コメント対応（`sonnet`） |
| PRへのコメント（人間のPR） | 承認者、`claude/` 以外のブランチ、`@claude` のメンションあり | 返信（`sonnet`）。修正は `suggestion` で示すだけで、pushはしない |
| PRへの `[REVIEW REQUEST]` | 承認者。ブランチは問わない（人間のPRにも、ClaudeのPRにも使える） | レビュー（`opus`）。インラインコメントで返し、狭い修正は `suggestion` で提案する。pushはしない |
| レビューの送信 | 承認者、`claude/` のブランチ | レビュー対応（`sonnet`）。スレッドごとに返信し、対応済みだけ解決 |
| CIの完了（失敗） | `claude/` のブランチ | 1回目は失敗したジョブを再実行（flaky判定）。また落ちたら要約（`haiku`）→ 修正（`sonnet`）。承認者が最後に発言してから3回まで |
| CIの完了（成功） | Draft PR | セルフレビュー前ならセルフレビュー（`opus`）、指摘があれば修正（`sonnet`）。セルフレビュー済みならReady化してレビュアーを指定 |
| CIの再実行での成功 | | flaky testの分析（`haiku`）と起票・発生回数の追記 |
| デフォルトブランチへのpush | | 閉じたIssueを待っていたサブIssueの計画、コンフリクトしたPRの解消（`sonnet`） |
| いずれかの工程の失敗 | | 承認者をメンションして、Re-run failed jobs を案内 |

## 目印

状態はラベルではなく、コメントの目印とブランチ名で持つ。

| 目印 | 意味 |
| --- | --- |
| ブランチ `claude/issue-<N>-...` | Issue #N の作業ブランチ。PRとIssueの対応づけに使う |
| `<!-- devflow:plan -->` | 計画のコメント |
| `<!-- devflow:self-review -->` | セルフレビュー済み（1回だけ行う） |
| `<!-- devflow:ci-fix -->` | CIの自動修正の回数 |
| `<!-- devflow:ci-limit -->` | 自動修正の上限に達した通知 |
| `<!-- devflow:after #N -->` | サブIssueの本文に書く。#N が閉じてから計画を始める |
| `<!-- devflow:flaky-occurrence -->` | flaky testの再発の記録 |

## 改善の配り方

1. このリポジトリで、同じフローでClaudeに改善させる（mainはRulesetでPR必須）
2. claude-devflow/sandbox は `main` を呼ぶので、マージ後にそこで動作を確かめる
3. 問題なければ `v1` タグを動かして全アプリに配る

   ```bash
   git tag -f v1 origin/main && git push -f origin v1
   ```

呼び出し用ファイルの変更を伴う場合は、テンプレートを更新したあと、各アプリで `setup.sh install` を再実行する。
