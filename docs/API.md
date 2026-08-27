# API ドキュメント

MrEric のプログラマティック API リファレンスです。セットアップと UI の使い方は [README](../README.md) を参照してください。

Run 状態と履歴は **in-memory** です。プロセス再起動で消えます。破壊的な Run API はすべて `owner_id` を要求します。

## 目次

- [MrEric](#mreric)
- [MrEric.Runs](#mrericruns)
- [Run events](#run-events)
- [MrEric.OpenAIClient](#mrericopenaiclient)
- [MrEric.LLM](#mrericllm)
- [MrEric.Tools.Executor](#mrerictoolsexecutor)
- [MrEric.RAG](#mrericrag)
- [MrEric.Evals](#mrericevals)
- [MrEric.MCP](#mrericmcp)
- [設定](#設定)

---

## MrEric

高レベル API。同期的に Orchestrator を走らせ、完了エントリを in-memory 履歴へ保存します。リアルタイム UI 向けには `MrEric.Runs.start_run/3` を使います。

### execute_task/2

```elixir
execute_task(task :: String.t(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
```

空でないタスク文字列を `MrEric.Agent.execute/2` に渡します。`opts` はそのまま Orchestrator へ転送されます。

よく使う opts:

- `:provider` — `:openai`、`:grok`、`:openrouter`、`:ollama`、`:lmstudio` など
- `:model` — provider 側のモデル ID

成功時の entry には少なくとも次が含まれます。

- `task`、`plan`、`final`（後方互換のため `code` も `final` と同じ値）
- `provider`、`model`
- `planner`、`drafts`、`reviews`、`synthesizer`
- `draft_errors`、`review_errors`、`synthesis_error`
- `inserted_at`

```elixir
{:ok, result} = MrEric.execute_task("Create a simple Phoenix controller")
{:ok, result} = MrEric.execute_task("Summarize the orchestrator", provider: :ollama, model: "llama3.1")

case MrEric.execute_task("") do
  {:error, :invalid_task} -> :ok
end
```

### get_task_history/0

```elixir
get_task_history() :: [map()]
```

新しい順の履歴リストです。

### get_latest_task/0

```elixir
get_latest_task() :: map() | nil
```

履歴が空なら `nil` です。

---

## MrEric.Runs

1 Run = 1 `RunWorker` GenServer。PubSub topic は `"runs:#{run_id}"` です。

### start_run/3

```elixir
start_run(task :: String.t(), owner_id :: String.t(), opts :: keyword()) ::
  {:ok, MrEric.Runs.Run.t()} | {:error, term()}
```

`owner_id` は必須です。Web UI では `MrEric.Plugs.EnsureOwnerId` が session に発行します。IEx やテストでは呼び出し側が用意します。eval harness は `"eval-runner"` を使います。

よく使う opts:

- `:provider`、`:model`
- `:id` — Run ID を固定したいとき
- `:subscribe` — `true` なら開始前に呼び出しプロセスを topic へ subscribe

```elixir
owner_id = "owner-123"
{:ok, run} = MrEric.Runs.start_run("Build a feature", owner_id, provider: :ollama, model: "llama3.1")
```

### cancel_run/2 · approve_tool/3 · deny_tool/3

```elixir
cancel_run(run_id, owner_id) :: :ok | {:error, :not_owner | :not_found | term()}
approve_tool(run_id, approval_id, owner_id) :: :ok | {:error, :not_owner | :approval_expired | term()}
deny_tool(run_id, approval_id, owner_id) :: :ok | {:error, :not_owner | :approval_expired | term()}
```

別の `owner_id` では状態は変わりません。期限切れ承認は `{:error, :approval_expired}` になり、`:tool_approval_expired` が配信されます。

### get_run/1 · subscribe/1 · unsubscribe/1

読み取り系は owner チェックしません（ローカル単一ユーザー前提）。

```elixir
MrEric.Runs.subscribe(run.id)
{:ok, %MrEric.Runs.Run{}} = MrEric.Runs.get_run(run.id)
MrEric.Runs.unsubscribe(run.id)
```

`Run` の主なフィールドは `id`、`owner_id`、`task`、`provider`、`model`、`status`、`stages`、`final`、`changed_files`、`error`、`trace` です。

status: `:queued`、`:running`、`:waiting_for_model`、`:waiting_for_approval`、`:streaming`、`:reviewing`、`:synthesizing`、`:completed`、`:failed`、`:cancelled`

---

## Run events

購読プロセスには `{event_name, payload}` が届きます。payload は redaction 済みです。API キー、Authorization、cookie、`reply_to` pid は入りません。

Run 進行:

- `:run_started`、`:stage_started`、`:stage_chunk`、`:stage_completed`、`:stage_failed`
- `:run_completed`、`:run_failed`、`:run_cancelled`

Tool:

- `:tool_started`、`:tool_approval_requested`、`:tool_approval_resolved`、`:tool_approval_expired`
- `:tool_completed`、`:tool_failed`、`:tool_denied`、`:tool_rejected`

```elixir
receive do
  {:stage_chunk, %{role: role, chunk: chunk}} -> IO.write("#{role}: #{chunk}")
  {:tool_approval_requested, payload} -> inspect(payload.approval_id)
  {:run_completed, %{final: final}} -> IO.puts(final)
end
```

---

## MrEric.OpenAIClient

`MrEric.LLM.OpenAICompat` への後方互換 wrapper です。新しいコードは LLM 層を直接使っても構いません。

### chat_completion/2

```elixir
chat_completion(prompt :: String.t(), opts :: keyword()) :: {:ok, String.t()} | {:error, term()}
```

opts: `:provider`、`:model`、`:tools`、`:tool_choice`。`return_message?: true` のときは content 文字列ではなく message map を返します。

```elixir
{:ok, text} = MrEric.OpenAIClient.chat_completion("Hello")
{:ok, text} = MrEric.OpenAIClient.chat_completion("Write a haiku", provider: :ollama, model: "llama3.1")
```

### stream_completion/3

```elixir
stream_completion(prompt, pid, opts \\ []) :: :ok | term()
```

受信メッセージ:

- `{:chunk, text}`
- `{:complete, :ok}`
- `{:agent_error, reason}` — 接続失敗や HTTP エラー

```elixir
MrEric.OpenAIClient.stream_completion("Tell me a story", self(), model: "gpt-4o")

receive do
  {:chunk, text} -> IO.write(text)
  {:complete, :ok} -> IO.puts("\nDone!")
  {:agent_error, reason} -> IO.inspect(reason)
end
```

### list_models/2

```elixir
list_models(provider, opts \\ []) :: {:ok, list()} | {:error, term()}
```

OpenAI 互換 `/v1/models` の `data` 配列を返します。

```elixir
{:ok, models} = MrEric.OpenAIClient.list_models(:openai)
```

---

## MrEric.LLM

| Module | 役割 |
|--------|------|
| `MrEric.LLM.OpenAICompat` | `/v1/chat/completions` と `/v1/models` |
| `MrEric.LLM.Registry` | provider / model catalog、role ごとの agent spec |
| `MrEric.LLM.Router` | agent spec から provider/model へ |
| `MrEric.LLM.ProviderResolver` | 起動時の local-first 既定 provider |
| `MrEric.LLM.FakeProvider` | テスト / eval 専用。ネットワーク禁止 |

`AI_PROVIDER` も `:ai_provider` も無いとき、起動時に LM Studio → Ollama → OpenAI の順で判定します。test ではヘルスチェックが無効で既定は `:openai` です。

```elixir
MrEric.LLM.Registry.default_provider()
MrEric.LLM.Registry.models_for_provider("ollama")
MrEric.LLM.ProviderResolver.default_provider()
```

---

## MrEric.Tools.Executor

すべての tool 実行の入口です。Registry と Policy を必ず通ります。

```elixir
execute(tool, args, opts \\ [])
request_tool(tool, args, reason, opts)
execute_approved(request, opts \\ [])
```

承認必須 tool は `:apply_patch` と `:shell_command` です。承認リクエストを作るには `opts` に `:owner_id` が必要です。HMAC は `{tool, args, approval_id, tool_call_id, owner_id}` を署名し、リクエストには `expires_at`（30 分後）が付きます。TTL の強制は `RunWorker` の approve/deny 経路です。`execute_approved/2` は署名検証のうえで tool を実行します。

```elixir
owner_id = "owner-123"

{:approval_required, request} =
  MrEric.Tools.Executor.execute(
    :apply_patch,
    %{changes: [%{path: "README.md", before: "old\n", after: "new\n"}]},
    owner_id: owner_id
  )

MrEric.Tools.Executor.execute_approved(request)
```

承認を Bypass してはいけません。`approved?: true` を呼び出し側で付ける正規ルートは `execute_approved/2` だけです。

built-in: `:file_read`、`:file_write_proposal`、`:apply_patch`、`:shell_command`、`:git_status`、`:git_diff`

---

## MrEric.RAG

workspace 内の安全なテキストを in-memory の lexical index にします。Planner が最初の model call の前に bounded context を受け取れます。失敗しても Run 全体は失敗しません。

```elixir
{:ok, context} = MrEric.RAG.context_for("How does tool approval work?", workspace_root: File.cwd!())
{:ok, index} = MrEric.RAG.Index.build(workspace_root: File.cwd!())
MrEric.RAG.Retriever.search(index, "approval policy", top_k: 3)
```

既定で `config/`、`.env*`、secret-bearing path、`.git` などは index しません。vector DB や embeddings は未実装です。

---

## MrEric.Evals

`MrEric.LLM.FakeProvider` に対する決定的 golden eval です。外部 LLM は呼びません。

```elixir
MrEric.Evals.list_cases()
{:ok, result} = MrEric.Evals.run_case("simple_planning")
{:ok, %{passed: _, failed: _, results: _}} = MrEric.Evals.run_all()
```

CLI:

```bash
mix mr_eric.evals
mix mr_eric.evals --case simple_planning
```

cases は `priv/evals/phase9_golden_cases.json` です。

---

## MrEric.MCP

interface のみです。`MrEric.MCP.ClientBehaviour` と `MrEric.MCP.ToolAdapter` があります。外部 MCP server の起動、discovery、UI はありません。

---

## 設定

provider 既定値とモデル catalog は application env です。本番では `config/runtime.exs` が選択中 provider の必須環境変数を検証します。

```elixir
# config/runtime.exs 相当のイメージ
config :mr_eric,
  ai_provider: System.get_env("AI_PROVIDER"),
  provider_fallback_chain: [:lmstudio, :ollama, :openai],
  provider_health_check: Mix.env() != :test,
  shell_env_allowlist: [
    names: ~w(PATH HOME USER LANG LC_ALL TERM TZ TMPDIR SHELL),
    patterns: [~r/^LC_/]
  ]
```

テストの OpenAI 互換 HTTP は `test/support/openai_mock.ex` で mock します。Orchestrator / Run / eval は `FakeProvider` を使います。

---

## エラー

`MrEric.Errors.classify/1` が内部エラーを分類し、`MrEric.Runs.Events.public_error/1` がユーザー向け短文にします。原文に secret が混ざる可能性があるため、UI / PubSub / trace / eval に出す前に redaction します。

代表的な分類: `:missing_api_key`、`:provider_unavailable`、`:model_unavailable`、`:timeout`、`:tool_denied`、`:approval_required`、`:approval_rejected`、`:patch_rejected`、`:rag_failed`、`:mcp_unavailable`、`:cancelled`、`:unknown`

---

## 参考

- [README](../README.md)
- [AGENTS.md](../AGENTS.md) — 安全境界と実装規約
- [監査 spec の進捗](./superpowers/README.md)
- [Req](https://hexdocs.pm/req)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view)
