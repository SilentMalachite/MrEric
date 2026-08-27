# 監査 spec の進捗

2026-05-05 のセキュリティ監査から派生した hardening spec の状態です。脅威モデルは **ローカル単一ユーザーの開発ツール** です。マルチユーザー認証は対象外です。

| Spec | 内容 | 状態 | 文書 |
|------|------|------|------|
| A | 秘密情報衛生（`secret_key_base`、RAG の secret path、SecretChecker、shell env allow-list） | **Implemented**（2026-05-05, `main`） | [spec](./specs/2026-05-05-secret-hygiene-design.md) · [plan](./plans/2026-05-05-secret-hygiene.md) |
| B | Run 所有権と承認ライフサイクル（session `owner_id`、HMAC に owner 束縛、30 分 TTL、`tool_approval_expired`） | **Implemented**（2026-05-05, PR #3） | [spec](./specs/2026-05-05-run-ownership-design.md) · [plan](./plans/2026-05-05-run-ownership.md) |
| C | tool 境界（`sh -lc` 廃止、`.git`/`.ssh` の case-fold、TOCTOU 再検証） | **設計済み・実装待ち**（2026-08-27） | [spec](./specs/2026-08-27-tool-boundary-design.md) · [plan](./plans/2026-08-27-tool-boundary.md) |
| D | Run 寿命と資源（`max_children`、trace / 履歴上限） | 未着手 | — |
| E | eval / RAG の正しさ（scorer early-pass、RAG キャッシュ、`rag_default_index` golden case） | 未着手 | — |
| F | 本番 HTTP（`force_ssl`、HSTS、CSP、`PHX_HOST` hard-fail） | 未着手 | — |

## 次にやる作業

**Spec C** の実装が次です。設計と実装計画は書き終えており、コードはまだ入っていません。

- spec: [`specs/2026-08-27-tool-boundary-design.md`](./specs/2026-08-27-tool-boundary-design.md)
- plan: [`plans/2026-08-27-tool-boundary.md`](./plans/2026-08-27-tool-boundary.md) — 5 タスク / 32 ステップ。チェックボックスは**未実行**なので、この plan だけは実際に実行してください（Spec A / B の plan は履歴です）。

承認済み `shell_command` はまだ `System.cmd("sh", ["-lc", command])` です。argv 直実行へ替えるのが、承認ゲートの後ろに残っている実行面の穴です。

Spec A から先送りされた `rag_default_index` golden case は Spec E の所有です。

## 対象外（明示的に止める）

- Phase 7 の高度 RAG（vector DB、embeddings、hybrid search、RAG UI）
- Phase 8 の実 MCP 接続（server 起動、discovery、proxy、MCP UI）
- Ecto / DB 永続化
- ログインとマルチユーザー認証
- `git commit` / `push` / `reset` / `clean`、force push、自動 rollback

実装計画のチェックボックスは履歴として残してあり、再実行しないでください。
