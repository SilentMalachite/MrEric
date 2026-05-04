# MrEric

Phoenix LiveView を用いた AI エージェントアプリケーションです。OpenAI/Grok/OpenRouter と、Ollama/LM Studio などのローカル LLM を OpenAI 互換 API として扱い、Planner、Draft Agents、Reviewer、Synthesizer によるタスク実行をリアルタイムに表示します。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Elixir](https://img.shields.io/badge/elixir-1.17-purple.svg)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/phoenix-1.8-orange.svg)](https://www.phoenixframework.org)

## 目次

- [特徴](#特徴)
- [必要要件](#必要要件)
- [クイックスタート](#クイックスタート)
- [AI プロバイダ](#ai-プロバイダ)
- [使い方](#使い方)
- [安全なツール実行](#安全なツール実行)
- [Deterministic Evals](#deterministic-evals)
- [開発とテスト](#開発とテスト)
- [アーキテクチャ](#アーキテクチャ)
- [デプロイ](#デプロイ)
- [トラブルシュート](#トラブルシュート)
- [ライセンス](#ライセンス)

## 特徴

- **リアルタイム Run UI**: Planner、Local Drafter、Cloud Drafter、Critic、Reviewer、Synthesizer の進捗を LiveView で段階表示
- **OpenAI 互換 provider 対応**: OpenAI、Grok/xAI、OpenRouter、Ollama、LM Studio を同じ LLM 層で利用
- **安全な tool / patch flow**: workspace 境界、secret file 保護、承認必須 tool、承認後だけの `apply_patch`
- **軽量 RAG / MCP extension point**: workspace 内テキスト検索と MCP adapter interface。外部 MCP 接続は未実装
- **Deterministic eval harness**: Fake LLM provider、golden eval cases、Run trace、error classification、secret leak check
- **実行キャンセルと履歴**: 実行中 Run を停止し、完了 Run を履歴へ保存
- **Phoenix 1.8 + LiveView 1.1**: Tailwind CSS v4、daisyUI、Bandit、Req を利用

## 必要要件

- Elixir 1.17 以上
- Erlang/OTP 25 以上
- Node.js 18 以上
- 利用する外部 provider に応じた API key

ローカル LLM provider の Ollama / LM Studio は API key なしで利用できます。

## クイックスタート

```bash
git clone https://github.com/SilentMalachite/MrEric.git
cd MrEric
```

利用する provider を選び、必要な環境変数を設定します。

```bash
# OpenAI
export AI_PROVIDER=openai
export OPENAI_API_KEY="sk-your-api-key"

# ローカル LLM: Ollama
export AI_PROVIDER=ollama
export OLLAMA_BASE_URL="http://localhost:11434/v1"
```

依存関係を入れてサーバを起動します。

```bash
mix setup
mix phx.server
```

ブラウザで [http://localhost:4000](http://localhost:4000) を開きます。

## AI プロバイダ

MrEric は `MrEric.LLM.OpenAICompat` を通じて、OpenAI 互換の `/v1/chat/completions` と `/v1/models` を呼び出します。`MrEric.OpenAIClient` は後方互換 wrapper です。

| Provider | `AI_PROVIDER` | 必須環境変数 | 既定 base URL |
|----------|---------------|--------------|---------------|
| OpenAI | `openai` | `OPENAI_API_KEY` | `https://api.openai.com/v1` |
| Grok / xAI | `grok` / `xai` | `GROK_API_KEY` または `XAI_API_KEY` | `https://api.x.ai/v1` |
| OpenRouter | `openrouter` | `OPENROUTER_API_KEY` | `https://openrouter.ai/api/v1` |
| Ollama | `ollama` | なし | `http://localhost:11434/v1` |
| LM Studio | `lmstudio` / `llstudio` | なし | `http://localhost:1234/v1` |

OpenRouter では任意で `OPENROUTER_SITE_URL` または `SITE_URL`、`OPENROUTER_APP_NAME` を設定できます。本番環境では `config/runtime.exs` が provider ごとの必須環境変数を検証します。

リクエスト単位でも provider と model を指定できます。

```elixir
MrEric.OpenAIClient.chat_completion("Hello", provider: :ollama, model: "llama3.1")
MrEric.OpenAIClient.list_models(:openai, [])
```

## 使い方

### Web UI

1. `http://localhost:4000` を開く
2. Provider と Model を選ぶ
3. Task Description にタスクを入力する
4. Execute Task を押す
5. Run ID、全体ステータス、role ごとの進捗、tool approval、patch approval を確認する
6. 必要なら Cancel で実行中 Run を停止する

### Elixir API

```elixir
# タスク実行
{:ok, result} = MrEric.execute_task("Create a simple Phoenix controller")

# 履歴
history = MrEric.get_task_history()
latest = MrEric.get_latest_task()

# Run 開始、購読、キャンセル
{:ok, run} = MrEric.Runs.start_run("Build a feature", provider: :ollama, model: "llama3.1")
MrEric.Runs.subscribe(run.id)
MrEric.Runs.cancel_run(run.id)

# Streaming completion
MrEric.OpenAIClient.stream_completion("Tell me a story", self(), model: "gpt-4o")

receive do
  {:chunk, text} -> IO.write(text)
  {:complete, :ok} -> IO.puts("\nDone!")
end
```

## 安全なツール実行

すべての tool 実行は `MrEric.Tools.Executor` から `Registry` と `Policy` を通ります。ファイルパスは workspace 内に限定され、`.env*`、秘密鍵、credential/token/secret を含むパス、`.git`、`.ssh` は保護されます。

| Tool | 説明 | 承認 |
|------|------|------|
| `file_read` | workspace 内ファイルを読み取り | 不要 |
| `file_write_proposal` | 書き込み提案と diff を返す。実ファイルは変更しない | 不要 |
| `apply_patch` | 承認済み patch を workspace 内ファイルへ適用し、git diff を返す | 必須 |
| `shell_command` | read-oriented allowlist の shell command を実行 | 必須 |
| `git_status` | `git status --short` を実行 | 不要 |
| `git_diff` | `git diff` を実行 | 不要 |

`shell_command` は shell 展開、リダイレクト、破壊的コマンド、mutating git subcommand を拒否します。`git commit`、`git push`、`git reset`、`git clean`、force push は実装していません。

### Orchestrator tool loop

`MrEric.Orchestrator.stream/3` では Planner / Critic / Reviewer が tool request を出せます。RunWorker が唯一の broker として `Executor.request_tool/4` を呼び、承認が必要な場合は Run status を `:waiting_for_approval` にします。

対応する tool call は次の 2 形式です。

- OpenAI 互換 `choices[0].message.tool_calls`
- ローカル LLM 向けの本文全体 JSON:

```json
{
  "tool": "file_read",
  "input": {"path": "lib/mr_eric/orchestrator.ex"},
  "reason": "Need to inspect the orchestrator"
}
```

任意の文章から JSON を抜き出して実行することはありません。tool loop には `max_tool_calls_per_run`、`max_tool_calls_per_role`、`max_total_runtime_ms`、`max_context_chars`、`max_tool_output_chars` の上限があります。

### Patch proposal / apply

実ファイルへの書き込みは `apply_patch` だけが行い、必ず承認後に実行されます。validation は承認前と適用直前の 2 回走ります。

```elixir
{:approval_required, request} =
  MrEric.Tools.Executor.execute(:apply_patch, %{
    changes: [
      %{path: "README.md", before: "old text\n", after: "new text\n"}
    ]
  })

MrEric.Tools.Executor.execute_approved(request)
```

`apply_patch` は unified diff 形式も受け付けます。削除 patch、binary patch、workspace 外、secret path、stale `before`、サイズ超過、許可されていない新規拡張子は拒否されます。rollback は手動で、表示された `git diff` を確認して Codex diff pane から revert します。

## RAG / MCP extension

`MrEric.RAG` は workspace 内の安全なテキストファイルだけを対象にした in-memory lexical RAG です。`Chunker`、`Index`、`Retriever`、`context_for/2` を提供し、Planner prompt に bounded context を追加できます。RAG が失敗しても Run 全体は失敗しません。

```elixir
{:ok, context} = MrEric.RAG.context_for("How does tool approval work?", workspace_root: File.cwd!())
{:ok, index} = MrEric.RAG.Index.build(workspace_root: File.cwd!())
MrEric.RAG.Retriever.search(index, "approval policy", top_k: 3)
```

`MrEric.MCP` は `ClientBehaviour` と `ToolAdapter` の extension point までです。外部 MCP server config、外部プロセス起動、MCP tool discovery、MCP UI は未実装です。

## Deterministic Evals

Phase 9 は、外部 LLM/API を呼ばずに Orchestrator、RunWorker、Tools、approval flow、patch flow を評価する基盤です。Phase 7 の高度な RAG や Phase 8 の本格 MCP 接続は前提にしていません。

- `MrEric.LLM.FakeProvider` - deterministic な provider。外部通信なし
- `priv/evals/phase9_golden_cases.json` - golden eval cases
- `MrEric.Runs.Trace` - sanitized Run trace
- `MrEric.Errors` - error classification と safe message
- `MrEric.Evals.SecretChecker` - API key、Bearer token、private key、password/token 系漏洩の検出

```bash
# 全 golden eval
mix mr_eric.evals

# 単一 case
mix mr_eric.evals --case simple_planning
```

RAG/MCP 関連 eval は、対応する module が存在する場合だけ実行されます。Fake provider は通常 UI の provider list には表示されず、テストや eval で `provider_module: MrEric.LLM.FakeProvider` と明示して使います。

## 開発とテスト

### よく使うコマンド

| 作業 | コマンド |
|------|----------|
| サーバ起動 | `mix phx.server` |
| 対話型シェル | `iex -S mix phx.server` |
| テスト | `mix test` |
| 失敗テストのみ再実行 | `mix test --failed` |
| deterministic eval | `mix mr_eric.evals` |
| コード品質チェック | `mix precommit` |
| 依存関係の取得 | `mix deps.get` |
| アセットビルド | `mix assets.build` |
| 本番アセットビルド | `mix assets.deploy` |

### テスト

```bash
mix test
mix test test/mr_eric/openai_client_test.exs
mix test --failed
mix mr_eric.evals
```

テストでは外部 API 実通信を行いません。

- OpenAI 互換 API 呼び出しは `test/support/openai_mock.ex` で mock
- Orchestrator / Run / eval は `MrEric.LLM.FakeProvider` で検証
- LiveView は `Phoenix.LiveViewTest` と `LazyHTML` を利用

### コーディングガイドライン

詳細は [AGENTS.md](./AGENTS.md) を参照してください。重要な点だけ抜粋します。

- 変更完了時は `mix precommit` を実行
- LiveView template は `<Layouts.app flash={@flash}>` で開始
- フォームは `to_form/2` と `<.input>` を使う
- HTTP request は `Req` を使う
- アイコンは `<.icon name="hero-..."/>` を使う

## アーキテクチャ

### ディレクトリ構成

```text
MrEric/
├── lib/
│   ├── mr_eric/
│   │   ├── agent.ex          # インメモリ履歴
│   │   ├── orchestrator.ex   # Planner/Drafter/Reviewer/Synthesizer orchestration
│   │   ├── runs.ex           # Run API
│   │   ├── runs/             # Run state、RunWorker、Trace、PubSub events
│   │   ├── llm/              # Provider behaviour、OpenAICompat、Router、FakeProvider
│   │   ├── tools/            # Tool、Policy、Executor、PatchValidator
│   │   ├── rag/              # Chunker、Index、Retriever
│   │   ├── mcp/              # MCP behaviour / adapter
│   │   └── evals/            # Eval runner、scorer、secret checker
│   └── mr_eric_web/
│       ├── live/             # AgentLive
│       ├── components/
│       ├── controllers/
│       └── endpoint.ex
├── assets/
├── config/
├── priv/
│   └── evals/                # Golden eval cases
└── test/
```

### 主要モジュール

| Module | 役割 |
|--------|------|
| `MrEric.Agent` | 完了 Run のインメモリ履歴 |
| `MrEric.Runs` | Run 開始、購読、キャンセル、承認 API |
| `MrEric.Runs.RunWorker` | Run state、Orchestrator task、PubSub event、tool approval を管理 |
| `MrEric.Runs.Trace` | sanitized trace、duration、error classification、changed files を記録 |
| `MrEric.Orchestrator` | Planner、Draft Agents、Reviewers、Synthesizer と tool loop を調整 |
| `MrEric.LLM.Router` | agent spec から provider/model へ routing |
| `MrEric.LLM.OpenAICompat` | OpenAI 互換 provider 実装 |
| `MrEric.LLM.FakeProvider` | deterministic test/eval provider |
| `MrEric.Tools` | built-in tools、policy、approval、patch validation |
| `MrEric.RAG` | safe workspace scan による lightweight RAG |
| `MrEric.MCP` | MCP interface-level extension point |
| `MrEricWeb.AgentLive` | メイン LiveView、Run UI、approval UI |

## デプロイ

### 本番環境のビルド

```bash
export SECRET_KEY_BASE=$(mix phx.gen.secret)
export AI_PROVIDER=openai
export OPENAI_API_KEY="your-api-key"
export PHX_HOST="your-domain.com"

MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
_build/prod/rel/mr_eric/bin/mr_eric start
```

### 必要な環境変数

| 種別 | 変数 |
|------|------|
| 共通 | `SECRET_KEY_BASE`, `PHX_HOST` |
| 任意 | `PORT` |
| OpenAI | `OPENAI_API_KEY` |
| Grok / xAI | `GROK_API_KEY` または `XAI_API_KEY` |
| OpenRouter | `OPENROUTER_API_KEY`, 任意で `OPENROUTER_SITE_URL`, `OPENROUTER_APP_NAME` |
| Ollama | 任意で `OLLAMA_BASE_URL` |
| LM Studio | 任意で `LMSTUDIO_BASE_URL` |

## トラブルシュート

### API key 未設定

```text
The selected provider is missing its API key.
```

- OpenAI/Grok/OpenRouter を使う場合は該当する API key をサーバ側環境変数へ設定
- ローカルで試す場合は provider を `ollama` または `lmstudio` に変更
- API key はブラウザ、template、PubSub event、trace、ログへ出さない

### ローカル LLM が起動していない

```text
The selected LLM provider is unavailable.
```

- Ollama は `ollama serve` を起動
- LM Studio は Local Server と OpenAI-compatible endpoint を有効化
- `OLLAMA_BASE_URL` / `LMSTUDIO_BASE_URL` の URL と port を確認

### モデル未ロード・モデル名不一致

```text
The selected model or endpoint was not found.
```

- Ollama は `ollama list` でモデル名を確認し、必要なら `ollama pull llama3.1`
- LM Studio はモデルをロードしてから再実行
- OpenAI/OpenRouter は指定モデル ID が利用可能か確認

### Run をキャンセルしても provider 側の処理がすぐ止まらない

MrEric は RunWorker の orchestration task を停止し、キャンセル後の chunk や完了通知を UI へ配信しません。ただし、すでに provider へ届いた HTTP request のサーバ側処理停止までは保証しません。

### アセットがビルドされない

```bash
mix assets.setup
mix assets.build
```

### ポートが既に使用中

```bash
PORT=4001 mix phx.server
```

### テストが失敗する

```bash
mix test --failed
mix test path/to/test_file.exs
mix precommit
```

## ライセンス

本プロジェクトは MIT License で公開されています。詳細は [LICENSE](./LICENSE) を参照してください。

## リンク

- GitHub: https://github.com/SilentMalachite/MrEric
- Phoenix Framework: https://www.phoenixframework.org/
- OpenAI API: https://platform.openai.com/docs
- Elixir: https://elixir-lang.org/

## サポート

- Issues: [GitHub Issues](https://github.com/SilentMalachite/MrEric/issues)
- Phoenix Forum: https://elixirforum.com/c/phoenix-forum

---

最終更新: 2026-05-04
バージョン: 0.1.0
