# MrEric

Phoenix LiveView を用いた AI エージェントアプリケーションです。OpenAI/Grok/OpenRouter、さらにローカル LLM（Ollama/LM Studio）の OpenAI 互換 API を活用し、自然言語でタスクを実行できます。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Elixir](https://img.shields.io/badge/elixir-1.17-purple.svg)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/phoenix-1.8-orange.svg)](https://www.phoenixframework.org)

## 📋 目次

- [✨ 特徴](#-特徴)
- [📦 必要要件](#-必要要件)
- [🚀 セットアップ](#-セットアップ)
- [🔁 AIプロバイダの切替](#-aiプロバイダの切替)
- [💡 使い方](#-使い方)
- [🤖 OpenAI モデル設定](#-openai-モデル設定)
- [🛠️ 開発](#️-開発)
- [🧪 テスト](#-テスト)
- [🏗️ アーキテクチャ](#️-アーキテクチャ)
- [🚢 デプロイ](#-デプロイ)
- [🔧 トラブルシュート](#-トラブルシュート)
- [📝 ライセンス](#-ライセンス)

## ✨ 特徴

- **Phoenix 1.8 + LiveView 1.1** - リアルタイム Web UI
- **OpenAI API 統合** - GPT-4o、GPT-4、GPT-3.5、O1 全モデル対応
- **ストリーミング応答** - リアルタイムでAI応答を表示
- **Phase 4 リアルタイム実行UI** - Planner、Draft Agents、Reviewer、Synthesizer の進捗を段階表示
- **実行キャンセル** - 実行中 Run をUIから停止し、以降のchunkを無視
- **GUIモデル選択** - 7つのOpenAIモデルから簡単に選択
- **実行履歴管理** - タスク実行履歴を自動保存・表示
- **モダンUI** - Tailwind CSS v4 + Hero Icons
- **高速HTTPサーバ** - Bandit による高パフォーマンス
- **型安全HTTP通信** - Req ライブラリ採用

## 📦 必要要件

- **Elixir** 1.17 以上
- **Erlang/OTP** 25 以上
- **Node.js** 18 以上 (アセットビルド用)
- 以下のいずれかの API キー（利用するプロバイダに応じて）
  - OpenAI: OPENAI_API_KEY（[取得方法](https://platform.openai.com/api-keys)）
  - Grok(xAI): GROK_API_KEY または XAI_API_KEY
  - OpenRouter: OPENROUTER_API_KEY（[OpenRouter](https://openrouter.ai/)）
  - ローカル LLM（Ollama/LM Studio）はキー不要

## 🚀 セットアップ

### 1. リポジトリのクローン

```bash
git clone https://github.com/SilentMalachite/MrEric.git
cd MrEric
```

### 2. 環境変数の設定

利用する AI プロバイダに応じて環境変数を設定します（未設定時は `openai` が既定）。

例）OpenAI を利用する場合：

```bash
export AI_PROVIDER=openai
export OPENAI_API_KEY="sk-your-api-key-here"
```

例）Grok(xAI) を利用する場合：

```bash
export AI_PROVIDER=grok   # または xai
export GROK_API_KEY="your-grok-key"   # または XAI_API_KEY
```

例）OpenRouter を利用する場合：

```bash
export AI_PROVIDER=openrouter
export OPENROUTER_API_KEY="your-openrouter-key"
# 任意（推奨）: OpenRouter のポリシーに基づくヘッダ
export OPENROUTER_SITE_URL="https://your.app"   # または SITE_URL
export OPENROUTER_APP_NAME="MrEric"
```

例）ローカル LLM（Ollama / LM Studio）を利用する場合：

```bash
# Ollama
export AI_PROVIDER=ollama
# 任意: ベースURLの上書き
export OLLAMA_BASE_URL="http://localhost:11434/v1"

# LM Studio（LLStudio）
export AI_PROVIDER=lmstudio   # または llstudio
# 任意: ベースURLの上書き
export LMSTUDIO_BASE_URL="http://localhost:1234/v1"
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
2. **Provider** と **Model** ドロップダウンから利用するAIを選択
3. **Task Description** にタスクを入力（例: "Create a simple Phoenix controller"）
4. **Execute Task** ボタンをクリック
5. Run ID、全体ステータス、roleごとの進捗パネルを確認
6. 必要に応じて **Cancel** ボタンで実行中 Run を停止
7. 完了した実行は履歴へ保存されます

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

# プロバイダをリクエスト単位で指定
response = MrEric.OpenAIClient.chat_completion("Hello", provider: :ollama, model: "llama3")

# OpenAI 互換 /v1/models の取得
{:ok, models} = MrEric.OpenAIClient.list_models(:openai, [])

# ストリーミング応答
MrEric.OpenAIClient.stream_completion("Tell me a story", self(), model: "gpt-4o")
receive do
  {:chunk, text} -> IO.write(text)
  {:complete, :ok} -> IO.puts("\nDone!")
end

# Phase 4 Run の開始・購読・キャンセル
{:ok, run} = MrEric.Runs.start_run("Build a feature", provider: :ollama, model: "llama3.1")
MrEric.Runs.subscribe(run.id)
MrEric.Runs.cancel_run(run.id)
```

## 🧭 Phase 4 リアルタイム実行UI

Phase 4 では、1つのタスク実行を **Run** として扱います。Run は `MrEric.Runs.RunWorker` が所有し、Planner、Local Drafter、Cloud Drafter、Critic、Reviewer、Synthesizer の stage 状態を GenServer state として保持します。

このプロジェクトは現在 `ecto_repos: []` でDB永続化を使っていないため、Run の進行中状態はDBではなく `RunWorker` のメモリ上に保持します。完了した Run は既存の `MrEric.Agent` 履歴へコピーされ、LiveView の履歴に表示されます。

### PubSub stage event

RunWorker は Phoenix PubSub の topic `"runs:#{run_id}"` に統一形式のイベントを配信します。

- `{:run_started, %{run_id: run_id, task: task}}`
- `{:stage_started, %{run_id: run_id, role: :planner}}`
- `{:stage_chunk, %{run_id: run_id, role: :planner, chunk: text}}`
- `{:stage_completed, %{run_id: run_id, role: :planner, content: content}}`
- `{:stage_failed, %{run_id: run_id, role: :cloud_drafter, error: message}}`
- `{:run_completed, %{run_id: run_id, final: final}}`
- `{:run_failed, %{run_id: run_id, error: message}}`
- `{:run_cancelled, %{run_id: run_id}}`

LiveView は現在の Run topic を subscribe し、`handle_info/2` で受信したイベントを `MrEric.Runs.Run` に反映して画面を更新します。APIキーや認証ヘッダはイベントにも画面にも出しません。

### RunWorker / RunSupervisor

- `MrEric.Runs.start_run/2` は1 Runにつき1つの `RunWorker` を `DynamicSupervisor` 配下で起動します。
- `RunWorker` は `MrEric.Orchestrator.stream/3` を別Taskで実行し、stage eventを受け取って状態更新とPubSub配信を行います。
- `Orchestrator.stream/3` は draft/review 系を `Task.async_stream/3` で並列化し、一部roleが失敗しても他の出力と失敗情報を Synthesizer に渡します。

### キャンセル仕様

UIの **Cancel** は `MrEric.Runs.cancel_run(run_id)` を呼びます。RunWorker は orchestration task を停止し、Run status を `:cancelled` に更新して `{:run_cancelled, ...}` を配信します。すでに外部HTTPリクエストがプロバイダ側へ到達している場合、プロバイダ側の処理完了までは保証できませんが、キャンセル後に届いたchunkや完了通知はRunWorker側で無視され、UIへ流れません。

## 🔁 AIプロバイダの切替

MrEric は OpenAI 互換の `/v1/chat/completions` を提供する複数プロバイダに対応しています。プロバイダの選択は環境変数または `config` で行えます。

- 環境変数: `AI_PROVIDER` に `openai | grok | xai | openrouter | ollama | lmstudio | llstudio`
- 設定ファイル: `config :mr_eric, :ai_provider, "openai"`

プロバイダ別の要点:

- OpenAI: `OPENAI_API_KEY` 必須（本番では未設定時に起動失敗）
- Grok(xAI): `GROK_API_KEY` または `XAI_API_KEY` のいずれか必須
- OpenRouter: `OPENROUTER_API_KEY` 必須。任意ヘッダ `OPENROUTER_SITE_URL`（または `SITE_URL`）、`OPENROUTER_APP_NAME`
- Ollama: APIキー不要。デフォルト `http://localhost:11434/v1`（`OLLAMA_BASE_URL` で上書き可）
- LM Studio: APIキー不要。デフォルト `http://localhost:1234/v1`（`LMSTUDIO_BASE_URL` で上書き可）

備考: 本番環境では `config/runtime.exs` にて、選択したプロバイダに応じた必須変数が未設定の場合は起動が失敗するようガードしています。

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

- **Mocking** - Req plug と FakeProvider を使用
  - OpenAI互換API呼び出しは `test/support/openai_mock.ex` でモック
  - Orchestrator/Run テストは `test/support/llm_fake_provider.ex` で外部通信なしに検証

## 🏗️ アーキテクチャ

### ディレクトリ構成

```
MrEric/
├── lib/
│   ├── mr_eric/              # ビジネスロジック
│   │   ├── agent.ex          # タスク実行エージェント
│   │   ├── runs.ex           # Run開始・購読・キャンセルAPI
│   │   ├── runs/             # Run状態、Worker、Supervisor、PubSub events
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
- GenServer state を使用したインメモリ履歴

#### `MrEric.Runs`
- Phase 4 の Run コンテキスト
- `start_run/2`、`get_run/1`、`cancel_run/1`、`subscribe/1` を提供
- 実行中状態は `RunWorker` の GenServer state に保持
- 完了Runは既存 `MrEric.Agent` 履歴へコピー

#### `MrEric.Runs.RunWorker` / `MrEric.Runs.RunSupervisor`
- `DynamicSupervisor` 配下で1 Runにつき1 Workerを起動
- `MrEric.Orchestrator.stream/3` からの stage event を受信
- Phoenix PubSub topic `"runs:#{run_id}"` へ進捗を配信
- キャンセル後のchunkや完了通知を無視

#### `MrEric.OpenAIClient`
- OpenAI 互換 API との通信（OpenAI/Grok/OpenRouter/Ollama/LM Studio）
- `MrEric.LLM.OpenAICompat` への後方互換ラッパー
- ストリーミング応答のサポート
- `/v1/models` 取得用の `list_models/2`
- 全モデル対応（プロバイダ側のモデル名で指定）

#### `MrEric.LLM.Provider` / `MrEric.LLM.OpenAICompat`
- LLM プロバイダ共通 behaviour と OpenAI 互換実装
- `provider:` / `model:` opts によるリクエスト単位の切替
- HTTP クライアントは `Req` を使用

#### `MrEricWeb.AgentLive`
- メイン LiveView
- Provider / Model 選択
- Run ID、全体ステータス、roleごとの進捗パネル
- PubSub event を `handle_info/2` で受信して表示更新
- 実行キャンセルと履歴表示

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

必須変数は選択したプロバイダにより異なります。

- 共通:
  - `SECRET_KEY_BASE`（必須）
  - `PHX_HOST`（必須）
  - `PORT`（任意・デフォルト: 4000）

- プロバイダ別（`AI_PROVIDER` 未指定時は `openai` 扱い）:
  - `openai`: `OPENAI_API_KEY`（必須）
  - `grok`/`xai`: `GROK_API_KEY` または `XAI_API_KEY`（いずれか必須）
  - `openrouter`: `OPENROUTER_API_KEY`（必須）
    - 任意: `OPENROUTER_SITE_URL`（または `SITE_URL`）、`OPENROUTER_APP_NAME`
  - `ollama`: なし（任意で `OLLAMA_BASE_URL`）
  - `lmstudio`/`llstudio`: なし（任意で `LMSTUDIO_BASE_URL`）

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

#### APIキー未設定

```
The selected provider is missing its API key.
```

**解決方法:**
- OpenAI/Grok/OpenRouter を使う場合は該当するAPIキーを環境変数へ設定
- ローカルで試す場合は Provider を `ollama` または `lmstudio` に変更
- APIキーはサーバ側環境変数にだけ設定し、ブラウザやテンプレートへ出さない

#### ローカル LLM が起動していない

```
The selected LLM provider is unavailable.
```

**解決方法:**
- Ollama: `ollama serve` が起動しているか確認
- LM Studio: Local Server が起動し、OpenAI-compatible endpoint が有効か確認
- `OLLAMA_BASE_URL` / `LMSTUDIO_BASE_URL` を変更している場合はURLとポートを確認
- UIは壊れず該当stageを `failed` として表示し、他roleが継続可能ならRunを続行

#### モデル未ロード・モデル名不一致

```
The selected model or endpoint was not found.
```

**解決方法:**
- Ollama では `ollama list` でモデル名を確認し、必要なら `ollama pull llama3.1`
- LM Studio ではモデルをロードしてから再実行
- OpenRouter/OpenAIでは指定モデルIDが利用可能か確認

#### Run をキャンセルしても外部側の処理がすぐ止まらない

**仕様:**
- MrEric は RunWorker の orchestration task を停止し、以降のchunkをUIへ配信しません
- すでにプロバイダへ届いたHTTPリクエストのサーバ側処理停止までは保証しません
- キャンセル後は同じ画面から別タスクを実行できます

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
