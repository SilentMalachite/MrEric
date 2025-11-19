# MrEric

Phoenix LiveView を用いた AI エージェントアプリケーションです。OpenAI API を活用し、自然言語でタスクを実行できます。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Elixir](https://img.shields.io/badge/elixir-1.17-purple.svg)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/phoenix-1.8-orange.svg)](https://www.phoenixframework.org)

## 📋 目次

- [特徴](#特徴)
- [必要要件](#必要要件)
- [セットアップ](#セットアップ)
- [使い方](#使い方)
- [OpenAI モデル設定](#openai-モデル設定)
- [開発](#開発)
- [テスト](#テスト)
- [アーキテクチャ](#アーキテクチャ)
- [デプロイ](#デプロイ)
- [トラブルシュート](#トラブルシュート)
- [ライセンス](#ライセンス)

## ✨ 特徴

- **Phoenix 1.8 + LiveView 1.1** - リアルタイム Web UI
- **OpenAI API 統合** - GPT-4o、GPT-4、GPT-3.5、O1 全モデル対応
- **ストリーミング応答** - リアルタイムでAI応答を表示
- **GUIモデル選択** - 7つのOpenAIモデルから簡単に選択
- **実行履歴管理** - タスク実行履歴を自動保存・表示
- **モダンUI** - Tailwind CSS v4 + Hero Icons
- **高速HTTPサーバ** - Bandit による高パフォーマンス
- **型安全HTTP通信** - Req ライブラリ採用

## 📦 必要要件

- **Elixir** 1.17 以上
- **Erlang/OTP** 25 以上
- **Node.js** 18 以上 (アセットビルド用)
- **OpenAI API キー** ([取得方法](https://platform.openai.com/api-keys))

## 🚀 セットアップ

### 1. リポジトリのクローン

```bash
git clone https://github.com/SilentMalachite/MrEric.git
cd MrEric
```

### 2. 環境変数の設定

OpenAI API キーを環境変数に設定します：

```bash
export OPENAI_API_KEY="sk-your-api-key-here"
```

または `.env` ファイルを作成：

```bash
# .env
OPENAI_API_KEY=sk-your-api-key-here
```

### 3. 依存関係のインストールと起動

```bash
mix setup
mix phx.server
```

ブラウザで [http://localhost:4000](http://localhost:4000) を開きます。

## 💡 使い方

### Web UI

1. ブラウザで `http://localhost:4000` にアクセス
2. **OpenAI Model** ドロップダウンからモデルを選択
3. **Task Description** にタスクを入力（例: "Create a simple Phoenix controller"）
4. **Execute Task** ボタンをクリック
5. ストリーミングでAIの応答を確認
6. 実行履歴が自動的に保存されます

### プログラムからの利用

```elixir
# タスクの実行
{:ok, result} = MrEric.execute_task("Create a simple Phoenix controller")

# 実行履歴の取得
history = MrEric.get_task_history()

# 最新のタスクを取得
latest = MrEric.get_latest_task()

# OpenAI API の直接呼び出し
response = MrEric.OpenAIClient.chat_completion("Hello, AI!", model: "gpt-4")

# ストリーミング応答
MrEric.OpenAIClient.stream_completion("Tell me a story", self(), model: "gpt-4o")
receive do
  {:chunk, text} -> IO.write(text)
  {:complete, :ok} -> IO.puts("\nDone!")
end
```

## 🤖 OpenAI モデル設定

### デフォルトモデルの変更

`config/config.exs` でデフォルトモデルを設定できます：

```elixir
config :mr_eric,
  openai_model: "gpt-4o"  # デフォルト
```

### 利用可能なモデル

| モデル | ID | 推奨用途 |
|--------|---|----------|
| GPT-4o | `gpt-4o` | 最新・高性能（推奨） |
| GPT-4o Mini | `gpt-4o-mini` | 高速・コスト効率 |
| GPT-4 Turbo | `gpt-4-turbo` | 高性能・長文対応 |
| GPT-4 | `gpt-4` | 高精度タスク |
| GPT-3.5 Turbo | `gpt-3.5-turbo` | 高速・低コスト |
| O1 Preview | `o1-preview` | 推論特化 |
| O1 Mini | `o1-mini` | 推論・高速 |

### コードでモデルを指定

```elixir
# 特定のモデルで実行
MrEric.OpenAIClient.chat_completion("Hello", model: "gpt-3.5-turbo")

# ストリーミングでも指定可能
MrEric.OpenAIClient.stream_completion("Story", self(), model: "gpt-4-turbo")
```

## 🛠️ 開発

### よく使うコマンド

| 作業 | コマンド |
|------|----------|
| サーバ起動 | `mix phx.server` |
| テスト実行 | `mix test` |
| 失敗したテストのみ再実行 | `mix test --failed` |
| コード品質チェック | `mix precommit` |
| 依存関係の取得 | `mix deps.get` |
| アセットビルド（開発） | `mix assets.build` |
| アセットビルド（本番） | `mix assets.deploy` |
| 対話型シェル | `iex -S mix phx.server` |

### コーディングガイドライン

詳細は [AGENTS.md](./AGENTS.md) を参照してください。

**重要なポイント：**

- 変更完了時は必ず `mix precommit` を実行
- LiveView テンプレートは `<Layouts.app flash={@flash}>` で開始
- フォームは `to_form/2` を使用し、テンプレートで `@form` を参照
- HTTP リクエストは必ず `:req` ライブラリを使用
- アイコンは `<.icon name="hero-..."/>` コンポーネントを使用

## 🧪 テスト

### テストの実行

```bash
# 全テストを実行
mix test

# 特定のファイルのテスト
mix test test/mr_eric/openai_client_test.exs

# 失敗したテストのみ再実行
mix test --failed

# カバレッジ付きで実行
mix test --cover
```

### テストの種類

- **Unit Tests** - `test/mr_eric/`
  - OpenAI クライアントのテスト
  - Agent ロジックのテスト
  
- **Integration Tests** - `test/mr_eric_web/`
  - LiveView の統合テスト
  - コントローラーのテスト

- **Mocking** - Mox を使用
  - OpenAI API 呼び出しをモック
  - `test/support/openai_mock.ex` 参照

## 🏗️ アーキテクチャ

### ディレクトリ構成

```
MrEric/
├── lib/
│   ├── mr_eric/              # ビジネスロジック
│   │   ├── agent.ex          # タスク実行エージェント
│   │   └── openai_client.ex  # OpenAI API クライアント
│   └── mr_eric_web/          # Web インターフェース
│       ├── live/
│       │   └── agent_live.ex # メイン LiveView
│       ├── components/        # UI コンポーネント
│       ├── controllers/       # コントローラー
│       └── endpoint.ex        # Phoenix エンドポイント
├── assets/                    # フロントエンド資産
│   ├── css/
│   │   └── app.css           # Tailwind CSS v4
│   └── js/
│       └── app.js            # JavaScript
├── test/                      # テストコード
├── config/                    # 設定ファイル
└── priv/                      # 静的リソース
```

### 主要モジュール

#### `MrEric.Agent`
- タスクの実行管理
- 履歴の保存・取得
- ETS を使用したインメモリストレージ

#### `MrEric.OpenAIClient`
- OpenAI API との通信
- ストリーミング応答のサポート
- 全モデル対応

#### `MrEricWeb.AgentLive`
- メイン LiveView
- リアルタイム UI
- モデル選択と履歴表示

## 🚢 デプロイ

### 本番環境のビルド

```bash
# 環境変数の設定
export SECRET_KEY_BASE=$(mix phx.gen.secret)
export OPENAI_API_KEY="your-api-key"
export PHX_HOST="your-domain.com"

# アセットとリリースのビルド
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release

# リリースの起動
_build/prod/rel/mr_eric/bin/mr_eric start
```

### 必要な環境変数

| 変数 | 説明 | 必須 |
|------|------|------|
| `OPENAI_API_KEY` | OpenAI API キー | ✅ |
| `SECRET_KEY_BASE` | Phoenix シークレットキー | ✅ |
| `PHX_HOST` | ホスト名 | ✅ |
| `PORT` | ポート番号 | ❌ (デフォルト: 4000) |
| `DATABASE_URL` | データベースURL | ❌ (未使用) |

### Docker でのデプロイ

```dockerfile
FROM elixir:1.17-alpine AS build

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY . .
RUN mix assets.deploy && \
    MIX_ENV=prod mix release

FROM alpine:3.19
RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app
COPY --from=build /app/_build/prod/rel/mr_eric ./

ENV PHX_SERVER=true
EXPOSE 4000

CMD ["bin/mr_eric", "start"]
```

## 🔧 トラブルシュート

### よくある問題

#### OpenAI API エラー

```
Error: {:error, %{status: 401}}
```

**解決方法:**
- `OPENAI_API_KEY` が正しく設定されているか確認
- API キーの有効性を OpenAI ダッシュボードで確認

#### アセットがビルドされない

```
Error: esbuild not found
```

**解決方法:**
```bash
mix assets.setup
```

#### ポートが既に使用中

```
Error: address already in use
```

**解決方法:**
```bash
# ポート番号を変更
PORT=4001 mix phx.server
```

#### テストが失敗する

**解決方法:**
```bash
# 依存関係を再取得
mix deps.clean --all
mix deps.get
mix test
```

### ログの確認

```bash
# 開発環境
mix phx.server

# 本番環境
_build/prod/rel/mr_eric/bin/mr_eric remote
```

## 📝 ライセンス

本プロジェクトは MIT License で公開されています。詳細は [LICENSE](./LICENSE) を参照してください。

## 🔗 リンク

- **GitHub**: https://github.com/SilentMalachite/MrEric
- **Phoenix Framework**: https://www.phoenixframework.org/
- **OpenAI API**: https://platform.openai.com/docs
- **Elixir**: https://elixir-lang.org/

## 📮 サポート

- Issues: [GitHub Issues](https://github.com/SilentMalachite/MrEric/issues)
- Phoenix Forum: https://elixirforum.com/c/phoenix-forum

---

**最終更新**: 2025-11-19  
**バージョン**: 0.1.0
