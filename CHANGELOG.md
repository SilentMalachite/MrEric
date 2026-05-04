# Changelog

MrEric の主要な変更を記録します。

このファイルは [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) の形式を参考にし、
プロジェクトのバージョンは `mix.exs` の `0.1.0` を基準にしています。

## [Unreleased]

2026-05-04 時点の `main` には、初期の OpenAI LiveView UI から、
AI-agent run orchestration、承認付き tool / patch flow、軽量 RAG、MCP extension point、
deterministic eval harness までの実装が含まれています。

### Added

- OpenAI 互換 LLM 層を追加。
  - `MrEric.LLM.Provider`、`MrEric.LLM.OpenAICompat`、`MrEric.LLM.Router`、`MrEric.LLM.Registry` を導入。
  - OpenAI、Grok/xAI、OpenRouter、Ollama、LM Studio を provider として扱えるように変更。
  - `provider:` / `model:` opts を request 単位で渡せるようにし、`MrEric.OpenAIClient` は後方互換 wrapper として維持。
- Planner、Local Drafter、Cloud Drafter、Critic、Reviewer、Synthesizer による multi-stage orchestration を追加。
  - draft / review stage は `Task.async_stream/3` で並列実行。
  - 一部の draft / review が失敗しても、利用可能な結果があれば synthesis まで継続。
- realtime Run 基盤を追加。
  - `MrEric.Runs.start_run/2`、`MrEric.Runs.RunWorker`、`MrEric.Runs.RunSupervisor`、`MrEric.Runs.Events` を導入。
  - Run state、role 別 stage、cancel、completed run history、changed files を in-memory で管理。
  - PubSub topic `"runs:#{run_id}"` で sanitized run events を配信。
- LiveView の Run UI を追加。
  - provider / model selector、current run status、role 別 progress panel、final output、execution history を表示。
  - 実行中 Run の cancel 操作に対応。
  - tool approval、patch approval、tool events、patch target / summary / unified diff の表示に対応。
- built-in tool system を追加。
  - `file_read`、`file_write_proposal`、`apply_patch`、`shell_command`、`git_status`、`git_diff` を `MrEric.Tools.Registry` に登録。
  - すべての tool 実行を `MrEric.Tools.Executor` と `MrEric.Tools.Policy` 経由に統一。
  - `shell_command` と `apply_patch` は signed approval request 承認後だけ実行。
- patch apply flow を追加。
  - `%{path, patch}` の unified diff と `%{changes: [%{path, before, after}]}` の提案形式に対応。
  - 承認前と適用直前に `MrEric.Tools.PatchValidator` で再検証。
  - 適用後は `git diff` と changed file paths を返し、Run history に記録。
- orchestrator tool loop を追加。
  - Planner、Critic、Reviewer が必要に応じて tool request を出せるように変更。
  - OpenAI-compatible `tool_calls` と、local model 向けの本文全体 JSON tool request を解析。
  - `max_tool_calls_per_run`、`max_tool_calls_per_role`、`max_total_runtime_ms`、`max_context_chars`、`max_tool_output_chars` を導入。
- lightweight RAG を追加。
  - `MrEric.RAG.Chunker`、`MrEric.RAG.Index`、`MrEric.RAG.Retriever`、`MrEric.RAG.context_for/2` を導入。
  - workspace 内の safe text files を in-memory lexical index として扱い、Planner prompt に bounded context を追加。
- MCP extension point を追加。
  - `MrEric.MCP.ClientBehaviour` と `MrEric.MCP.ToolAdapter` を導入。
  - MCP tool descriptors / results を MrEric の tool-shaped map へ normalize。
- deterministic Phase 9 eval harness を追加。
  - `MrEric.LLM.FakeProvider`、`MrEric.Evals`、runner / scorer / case loader、`mix mr_eric.evals` task を導入。
  - golden eval cases を `priv/evals/phase9_golden_cases.json` に追加。
  - approval、tool denial、patch approval / rejection、cancel、RAG、MCP boundary、secret leak checks を deterministic に検証。
- safe error and trace layer を追加。
  - `MrEric.Errors` に error classification と user-facing safe messages を追加。
  - `MrEric.Runs.Trace` に redacted run trace、duration、event summary、changed files summary を追加。
  - `MrEric.Evals.SecretChecker` で output / trace / tool result の secret leak を検出。

### Changed

- Phoenix LiveView UI を、単発の OpenAI response 表示から realtime Run orchestration UI へ再構成。
- production runtime config を provider 別の必須環境変数チェックに更新。
- model selection を OpenAI 固定から provider-specific model catalog に変更。
- README を現行 architecture、provider 設定、safe tool execution、RAG / MCP、deterministic evals に合わせて更新。
- `mix precommit` は `compile --warning-as-errors`、`deps.unlock --unused`、`test` を実行する品質チェックとして整理。

### Security

- PubSub events、LiveView assigns/templates、Run trace、eval output、tool output、user-facing errors で secret redaction を適用。
- workspace 外パス、protected secret paths、`.git`、`.ssh`、`.env*`、private key、credential / token / secret 系 path を tool policy で拒否。
- symlink escape、binary patch、deletion patch、stale `before` content、oversized patch、許可されていない新規拡張子を patch validation で拒否。
- shell command は read-oriented allowlist と read-only git subcommands に制限。
- app 内には `git commit`、`git push`、`git reset`、`git clean`、force push、destructive rollback を実装しない方針を明確化。

### Boundaries

- Run state と history は現時点では in-memory のまま。Ecto persistence は未導入。
- RAG は lexical / in-memory の basic implementation。vector DB、mandatory embeddings、hybrid search、metadata indexing は未導入。
- MCP は interface-level extension point まで。外部 MCP server config、外部 process startup、tool discovery、MCP UI は未導入。
- evals と tests は fake provider / mocks を使い、real OpenAI、OpenRouter、Grok、Ollama、LM Studio、external MCP servers を必須にしない。

### Tests

- Orchestrator、Runs、RunWorker、LiveView、LLM provider layer、Tools、Policy、PatchValidator、RAG、MCP adapter、Evals、SecretChecker、Errors のテストを追加。
- `mix mr_eric.evals` で deterministic golden eval cases を実行可能にした。
- LiveView tests で provider / model selection、run progress、cancel、tool approval、patch approval / rejection、secret redaction を検証。

## [0.1.0] - 2025-11-19

### Added

- Phoenix LiveView ベースの MrEric 初期アプリケーションを追加。
- database / Ecto を使わない構成に変更し、in-memory history で task result を保持。
- `Req` を使った OpenAI chat completion / streaming client を追加。
- OpenAI model selection UI を追加。
  - `gpt-4o`、`gpt-4o-mini`、`gpt-4-turbo`、`gpt-4`、`gpt-3.5-turbo`、`o1-preview`、`o1-mini` を選択可能にした。
- Tailwind CSS v4、daisyUI、Heroicons、Bandit を使った Phoenix UI / runtime を構成。
- `MrEric.execute_task/1`、task history、latest task 取得 API を追加。
- OpenAI client と LiveView の基礎テストを追加。

### Changed

- README、API docs、setup / usage documentation を追加。
- OpenRouter support と optional `HTTP-Referer` / `X-Title` headers を追加。
- agent messages の auto-scroll と Table of Contents links を調整。

### Known Limitations

- 永続化、認証、multi-user support、conversation context management は未実装。
- 当初の対象 provider は OpenAI / OpenRouter が中心で、現在の LLM provider layer より単純な構成。

## Development Notes

- 2026-05-04 の `main` には Phase 2 LLM orchestration、Phase 5A tool approval、Phase 5B RAG / MCP interface、Phase 5C tool loop、Phase 6 patch apply flow、Phase 9 eval harness までが含まれます。
- repository には現時点で release tag がないため、`Unreleased` は `mix.exs` version `0.1.0` 以降の main branch の状態を表します。
