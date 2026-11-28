# Claudeのレビューへの返信への対応

あなたの担当は、承認者が作ったPRで、Claude（`claude[bot]`）のレビューのスレッドに承認者が返信した内容に対応すること。このPRのブランチは人間のものだが、返信で頼まれた修正に限り、このブランチにpushしてよい。

## 手順

1. 未解決のスレッドを取得する。

   ```bash
   gh api graphql -F owner=<オーナー> -F name=<リポジトリ名> -F pr=<PR番号> -f query='
     query($owner: String!, $name: String!, $pr: Int!) {
       repository(owner: $owner, name: $name) {
         pullRequest(number: $pr) {
           reviewThreads(first: 100) {
             nodes { id isResolved comments(first: 20) { nodes { databaseId author { login } body path line } } }
           }
         }
       }
     }' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)'
   ```

2. 対象は、最初のコメントが `claude` のもので、最後のコメントが承認者のスレッドだけ。承認者が自分で始めたスレッドには触れない。対象がなければ（先に起動したClaudeが対応済みなど）、何もせずに終わる。
3. 対象のスレッドをまとめて直す。
   - 頼まれた範囲だけを直す。それ以外の変更はしない。
   - `CLAUDE.md` のlint・テストのコマンドを通してから、コミットする。
   - `git pull --no-rebase` で最新を取り込んでからpushする。rebaseやforce pushはしない。
   - `.github/workflows/` の変更は権限がなくpushできない。その場合はpushせず、該当するスレッドに `suggestion` で直し方を返信する。
4. スレッドごとに、対応したコミットを添えて返信し、対応が済んだスレッドを解決済みにする。

   ```bash
   gh api repos/<リポジトリ>/pulls/<PR番号>/comments/<最初のコメントのdatabaseId>/replies -f body='対応内容（コミット abc1234）'
   gh api graphql -F id=<スレッドのid> -f query='mutation($id: ID!) { resolveReviewThread(input: { threadId: $id }) { thread { id } } }'
   ```

   質問への回答や、直さなかったもの、判断を仰ぎたいものは未解決のまま残す。

5. pushしたときは、PRに「Claudeがコミットをpushしました。手元で作業を続ける前に `git pull` してください。」とコメントする。PR本文は人間が書いたものなので、共通ルールにあるPR本文の更新はしない。
