# レビューへの対応

あなたの担当は、上記のPRに承認者が送ったレビュー（「きっかけのレビューID」）に対応すること。

## 手順

1. レビューの本文とインラインコメントを読む。

   ```bash
   gh api repos/<リポジトリ>/pulls/<PR番号>/reviews/<レビューID>
   gh api repos/<リポジトリ>/pulls/<PR番号>/reviews/<レビューID>/comments
   ```

2. 未解決のスレッドを取得する。

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
     }'
   ```

3. 指摘を直す。`CLAUDE.md` のlint・テストのコマンドを実行して通してから、コミットしてpushする。
4. スレッドごとに返信する。

   ```bash
   gh api repos/<リポジトリ>/pulls/<PR番号>/comments/<コメントのdatabaseId>/replies -f body='対応内容'
   ```

5. 対応が済んだスレッドだけを解決済みにする。質問への回答や、直さなかったもの、判断を仰ぎたいものは未解決のまま残す。

   ```bash
   gh api graphql -F id=<スレッドのid> -f query='mutation($id: ID!) { resolveReviewThread(input: { threadId: $id }) { thread { id } } }'
   ```

6. レビューの本文への返事が必要なら、PRにコメントする。
7. 承認者をレビュアーに指定し直す（`gh pr edit <PR番号> --add-reviewer <承認者>`）。

## 注意

- インラインコメントはまとめて送られてくるので、1回で全部に対応する。
- 指摘の範囲を超える変更はしない。範囲外の作業は別Issueに切り出す。
