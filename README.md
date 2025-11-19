# MrEric

Phoenix LiveView を用いた Web アプリケーションです。高速な開発体験とリアルタイム UI を重視しています。

## 特徴 / Features
- Phoenix 1.8 + LiveView 1.1 採用
- Bandit による HTTP サーバ
- Req による HTTP クライアント（`:httpoison`, `:tesla`, `:httpc` は不使用）
- Tailwind CSS v4（`app.css` の新しい `@import` / `@source` 構文）
- Precommit チェック (`mix precommit`) による品質担保

## 開発環境セットアップ
```
mix setup
mix phx.server
```
ブラウザで http://localhost:4000 を開いて確認してください。

### よく使うコマンド
| 作業 | コマンド |
|------|----------|
| 依存取得 | `mix deps.get` |
| サーバ起動 | `mix phx.server` |
| テスト | `mix test` |
| 失敗テストのみ再実行 | `mix test --failed` |
| Precommit (警告をエラー扱い) | `mix precommit` |
| アセット開発ビルド | `mix assets.build` |
| アセット本番ビルド | `mix assets.deploy` |

## コーディング / 実装ガイド
詳細な社内ガイドは [AGENTS.md](./AGENTS.md) を参照してください。以下は特に重要な抜粋です。

### LiveView テンプレート
- すべて `<Layouts.app flash={@flash} ...>` で開始すること
- フォームは LiveView 側で `assign(socket, :form, to_form(changeset))` し、テンプレートでは `<.form for={@form}>` + `<.input field={@form[:field]}>`
- コレクションはメモリ効率のため Stream API を利用 (`stream/3`)

### HTTP リクエスト
```elixir
# Req の最小例
{:ok, resp} = Req.get("https://example.com/api")
body = resp.body
```

### Ecto / セキュリティ
- 外部から与えない値（user_id 等）は `cast` しないで直接セット
- テンプレートで関連を使う場合は必ず preload 済みクエリを取得

## ディレクトリ概要
| ディレクトリ | 説明 |
|--------------|------|
| `lib/` | アプリケーションコード (Contexts, LiveViews, Components) |
| `assets/` | JS / CSS (Tailwind v4, app.js, app.css) |
| `priv/` | 静的リソース・gettext 等 |
| `test/` | テストコード |

## 品質とスタイル
- 変更完了時は必ず `mix precommit` を実行し format / 未使用依存 / 警告 を解消
- UI は Tailwind 素のユーティリティクラスで構築（`@apply` 不使用）
- アイコンは必ず `<.icon name="hero-..."/>` を使用（Heroicons モジュールを直接呼ばない）

## デプロイ準備
- 本番ビルド: `MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release`
- Bandit 利用のため標準の Cowboy 設定は不要
- `SECRET_KEY_BASE` 等の必須環境変数を設定

## トラブルシュート
| 症状 | 対処 |
|------|------|
| LiveView で `current_scope` エラー | ルータの `live_session` と `<Layouts.app current_scope={@current_scope}>` を確認 |
| フォーム入力が描画されない | `@changeset` を直接使っていないか確認し `@form` に統一 |
| クラス構文エラー | HEEx の `class={[...]}` リスト構文になっているか確認 |

## ライセンス
本プロジェクトは MIT License で公開されています。詳細は [LICENSE](./LICENSE) を参照してください。

## Phoenix 公式情報
- Website: https://www.phoenixframework.org/
- Guides: https://hexdocs.pm/phoenix/overview.html
- Docs: https://hexdocs.pm/phoenix
- Forum: https://elixirforum.com/c/phoenix-forum
- Source: https://github.com/phoenixframework/phoenix

## 参考
Phoenix デプロイガイド: https://hexdocs.pm/phoenix/deployment.html

---
最終更新: 2025-11-19
