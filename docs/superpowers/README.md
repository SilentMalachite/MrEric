# 監査 spec の進捗

2026-05-05 のセキュリティ監査から派生した hardening spec の状態です。脅威モデルは **ローカル単一ユーザーの開発ツール** です。マルチユーザー認証は対象外です。

| Spec | 内容 | 状態 | 文書 |
|------|------|------|------|
| A | 秘密情報衛生（`secret_key_base`、RAG の secret path、SecretChecker、shell env allow-list） | **Implemented**（2026-05-05, `main`） | [spec](./specs/2026-05-05-secret-hygiene-design.md) · [plan](./plans/2026-05-05-secret-hygiene.md) |
| B | Run 所有権と承認ライフサイクル（session `owner_id`、HMAC に owner 束縛、30 分 TTL、`tool_approval_expired`） | **Implemented**（2026-05-05, PR #3） | [spec](./specs/2026-05-05-run-ownership-design.md) · [plan](./plans/2026-05-05-run-ownership.md) |
| C | tool 境界（`sh -lc` 廃止、`.git`/`.ssh` の case-fold、TOCTOU 再検証） | **Implemented**（2026-08-27, `main`） | [spec](./specs/2026-08-27-tool-boundary-design.md) · [plan](./plans/2026-08-27-tool-boundary.md) |
| C-1 | コマンド引数文法（オプション結合パス、`sed -i` の位置依存回避、`git --git-dir`/`--work-tree`/`-c`、program token のパス化） | **設計済み・実装待ち**（2026-08-27） | [spec](./specs/2026-08-27-arg-grammar-design.md) · [plan](./plans/2026-08-27-arg-grammar.md) |
| D | Run 寿命と資源（`max_children`、trace / 履歴上限） | 未着手 | — |
| E | eval / RAG の正しさ（scorer early-pass、RAG キャッシュ、`rag_default_index` golden case） | 未着手 | — |
| F | 本番 HTTP（`force_ssl`、HSTS、CSP、`PHX_HOST` hard-fail） | 未着手 | — |

## 次にやる作業

**Spec C-1** が次です。Spec C 実装後の Codex レビューで見つかり、ブランチ上で実行して再現を確認した `shell_command` の迂回が 3 件あります。いずれも Spec C の regression ではなく `main` 由来の既存欠陥です。

- spec: [`specs/2026-08-27-arg-grammar-design.md`](./specs/2026-08-27-arg-grammar-design.md)
- plan: [`plans/2026-08-27-arg-grammar.md`](./plans/2026-08-27-arg-grammar.md) — 5 タスク。チェックボックスは**未実行**です。

`sh -lc` を外してもシェル文法が消えただけで、各プログラムの引数文法は残っています。`Policy` は空白区切りトークンを「パスか否か」でしか見ないため、`grep -f../outside/p`、`git --git-dir=../store`、`sed -E -i.bak`（`sed` と `-i` の間に何か挟むと deny-list を外れる）が承認まで通り、実行すると workspace 外の読み取りと workspace 内の**無承認書き込み**が成立します。

その後に **Spec D**（`RunSupervisor` の `max_children`、`MrEric.Runs.Trace` と完了 run 履歴の上限）が続きます。

Spec A から先送りされた `rag_default_index` golden case は Spec E の所有です。

## 対象外（明示的に止める）

- Phase 7 の高度 RAG（vector DB、embeddings、hybrid search、RAG UI）
- Phase 8 の実 MCP 接続（server 起動、discovery、proxy、MCP UI）
- Ecto / DB 永続化
- ログインとマルチユーザー認証
- `git commit` / `push` / `reset` / `clean`、force push、自動 rollback

実装計画のチェックボックスは履歴として残してあり、再実行しないでください。
