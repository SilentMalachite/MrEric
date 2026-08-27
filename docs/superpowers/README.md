# 監査 spec の進捗

2026-05-05 のセキュリティ監査から派生した hardening spec の状態です。脅威モデルは **ローカル単一ユーザーの開発ツール** です。マルチユーザー認証は対象外です。

| Spec | 内容 | 状態 | 文書 |
|------|------|------|------|
| A | 秘密情報衛生（`secret_key_base`、RAG の secret path、SecretChecker、shell env allow-list） | **Implemented**（2026-05-05, `main`） | [spec](./specs/2026-05-05-secret-hygiene-design.md) · [plan](./plans/2026-05-05-secret-hygiene.md) |
| B | Run 所有権と承認ライフサイクル（session `owner_id`、HMAC に owner 束縛、30 分 TTL、`tool_approval_expired`） | **Implemented**（2026-05-05, PR #3） | [spec](./specs/2026-05-05-run-ownership-design.md) · [plan](./plans/2026-05-05-run-ownership.md) |
| C | tool 境界（`sh -lc` 廃止、`.git`/`.ssh` の case-fold、TOCTOU 再検証） | **Implemented**（2026-08-27, `main`） | [spec](./specs/2026-08-27-tool-boundary-design.md) · [plan](./plans/2026-08-27-tool-boundary.md) |
| C-1 | コマンド引数文法（プログラム別 grammar allow-list、bundled 短オプション、値種別、`--`、`sed` 削除） | **Implemented**（2026-08-27, rev 2） | [spec](./specs/2026-08-27-arg-grammar-design.md) · [plan](./plans/2026-08-27-arg-grammar.md) |
| D | Run 寿命と資源（`max_children`、worker の回収と絶対期限、trace / 履歴上限） | **Implemented**（2026-08-27, `main`） | [spec](./specs/2026-08-27-run-lifetime-design.md) · [plan](./plans/2026-08-27-run-lifetime.md) |
| E | eval / RAG の正しさ（scorer early-pass、RAG キャッシュ、`rag_default_index` golden case） | 未着手 | — |
| F | 本番 HTTP（`force_ssl`、HSTS、CSP、`PHX_HOST` hard-fail） | 未着手 | — |

## 次にやる作業

**Spec E** が次です。Spec D で run の同時実行数・worker 寿命・trace / 履歴の上限が閉じたので、
承認ゲートの後ろに残る運用面の穴はありません。残りは eval / RAG の正しさ（scorer の early-pass、
RAG キャッシュ、`rag_default_index` golden case）です。

Spec A から先送りされた `rag_default_index` golden case は Spec E の所有です。

## 対象外（明示的に止める）

- Phase 7 の高度 RAG（vector DB、embeddings、hybrid search、RAG UI）
- Phase 8 の実 MCP 接続（server 起動、discovery、proxy、MCP UI）
- Ecto / DB 永続化
- ログインとマルチユーザー認証
- `git commit` / `push` / `reset` / `clean`、force push、自動 rollback

実装計画のチェックボックスは履歴として残してあり、再実行しないでください。
