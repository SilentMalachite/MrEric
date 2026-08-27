# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

MrEric is a Phoenix 1.8 / LiveView 1.1 app that orchestrates multi-role AI-agent "runs"
(Planner → Draft Agents → Reviewers → Synthesizer) over OpenAI-compatible providers
(OpenAI, Grok/xAI, OpenRouter, Ollama, LM Studio) and streams progress to the browser in
real time. There is **no database** — all run state is in-memory (see below).

`AGENTS.md` is the authoritative coding-guideline document (safety boundaries, provider
rules, tool/patch flow, Phoenix/LiveView/HEEx idioms). Read it before non-trivial work;
this file covers the big picture and the few things that override defaults.

## Commands

| Task | Command |
|------|---------|
| Install deps + build assets | `mix setup` |
| Run server | `mix phx.server` (or `iex -S mix phx.server`) |
| All tests | `mix test` |
| Single test file | `mix test test/mr_eric/openai_client_test.exs` |
| Single test by line | `mix test test/mr_eric/runs_test.exs:42` |
| Re-run only failures | `mix test --failed` |
| **Pre-commit gate (run when done)** | `mix precommit` |
| Deterministic evals (all) | `mix mr_eric.evals` |
| Single eval case | `mix mr_eric.evals --case simple_planning` |
| Build assets | `mix assets.build` · prod: `mix assets.deploy` |

`mix precommit` = `compile --warning-as-errors` + `deps.unlock --unused` + `test`. It runs
in `:test` env. **Run it after completing changes and fix everything it reports** — warnings
are errors here.

No external network is touched in tests: OpenAI-compatible HTTP is mocked
(`test/support/openai_mock.ex`); orchestrator/run/eval paths use `MrEric.LLM.FakeProvider`.

## Behavioral overrides (from AGENTS.md — these win over defaults)

- **Respond to the user in Japanese**, and lead with the conclusion.
- **Do not modify more than 3 files in one change** unless the user explicitly allows it.
- **HTTP must use `Req`.** Never add `httpoison`, `tesla`, or `httpc`.
- **Never** implement ChatGPT Web UI automation, cookie reuse, scraping, or anything that
  exposes browser/session secrets.

## Architecture (the parts that span multiple files)

### Run lifecycle = one GenServer per run, in-memory only
- `MrEric.Runs` (context) → `RunSupervisor` (DynamicSupervisor) → one `RunWorker` GenServer
  per run, keyed in `MrEric.Runs.Registry`. Supervision tree is in `lib/mr_eric/application.ex`.
- `RunWorker` holds `MrEric.Runs.Run` state, runs `Orchestrator.stream(task, self(), opts)`
  in a Task, applies events, broadcasts **sanitized** PubSub events, copies completed runs
  into `MrEric.Agent` (in-memory history), and **ignores late chunks after cancellation**.
- **State is intentionally in-memory** — no Ecto repo exists. Do not add persistence unless
  the data layer changes (this is documented at the top of `lib/mr_eric/runs/run.ex`).
- PubSub topic is always `"runs:#{run_id}"`. Run statuses and roles are the closed lists in
  `lib/mr_eric/runs/run.ex`; event names live in `lib/mr_eric/runs/events.ex`.
- **Run limits are one contract.** `MrEric.Runs.Limits` owns `max_concurrent_runs`,
  `terminal_run_ttl_ms`, `hard_deadline_grace_ms`, `max_trace_entries`,
  `max_trace_payload_chars`, and `max_history_entries`; `@defaults` in that module is the
  only place a default is written, and `config :mr_eric, :run_limits` is override-only.
  `fetch!/1` raises on an unknown key — never give a limit lookup a silent default.
- `RunSupervisor` caps concurrent workers with `max_children`; `Runs.start_run/3` returns
  `{:error, :too_many_runs}` at the cap. The cap counts **workers, not streaming runs** — a
  finished run holds its slot until it is reaped, so a refusal can arrive when nothing is
  actually running. `RunWorker` stops itself `terminal_run_ttl_ms`
  after its run becomes terminal (every write of `state.run` goes through `put_run/2`, so
  "terminal implies scheduled stop" holds by construction), and terminalises itself with
  `:run_lifetime_exceeded` at `max_total_runtime_ms + hard_deadline_grace_ms` no matter
  what. **Terminalising is not stopping**: a stuck worker releases its slot one
  `terminal_run_ttl_ms` after that, so the absolute ceiling on a worker's life is
  `max_total_runtime_ms + hard_deadline_grace_ms + terminal_run_ttl_ms` — 300 s on the
  defaults, not 240 s. That ceiling only holds because **tool execution runs in its own
  Task**: both `Executor.request_tool/4` and `Executor.execute_approved/2` used to run
  inside the GenServer, and `System.cmd/3` has no timeout, so a hung `shell_command`
  blocked `:hard_deadline` itself. `put_run/2` also shuts those tasks down the moment the
  run goes terminal.
- **The trace is bounded by size, not only by entry count.** `Trace` folds `stage_chunk`
  into per-role counters and drops `stage_completed`'s `content` — both bodies already
  live in `Run.stages[role].content` — caps `entries` (reporting overflow as
  `dropped_entries`), and truncates every remaining string to `max_trace_payload_chars`.
  Truncation runs **after** `Errors.redact/1`, never before: half a secret is a secret the
  redactor no longer matches.
- **Error classification is taken once, at `Events.normalize_event/2`.** That is the last
  place the raw reason exists; afterwards `:error` is a sentence written for a human.
  Normalization carries `:error_class` (always a member of `Errors.classifications/0`)
  and `Trace` reads it. Never re-derive a classification by keyword-matching a sanitized
  message — that is what made `:run_lifetime_exceeded` classify as `:unknown`.
- **`Runs.get_run/1` is time-dependent since Spec D**: reaping stops the worker, so once a
  finished run's `terminal_run_ttl_ms` has elapsed the same run id returns
  `{:error, :not_found}`. Read a completed run's state inside that window, or take it from
  `MrEric.Agent` history, which outlives the worker.

### Run ownership (Spec B — implemented)
- Every run is bound to an `owner_id`. `MrEric.Plugs.EnsureOwnerId` (wired into the
  `:browser` pipeline in `router.ex`) mints/reads a session-scoped `owner_id`.
- `MrEric.Runs.start_run(task, owner_id, opts)` is **3-arity** and `owner_id` is required.
  `cancel_run/2`, `approve_tool/3`, and `deny_tool/3` also require `owner_id`.
  `MrEric.Runs.OwnerCheck.verify/2` enforces it.
- Design/plan (historical): `docs/superpowers/specs/2026-05-05-run-ownership-design.md`
  and `docs/superpowers/plans/2026-05-05-run-ownership.md`. Remaining audit specs C–F
  are tracked in `docs/superpowers/README.md`.

### Orchestrator tool loop — RunWorker is the only tool broker
- `MrEric.Orchestrator.stream/3` lets only `:planner`, `:critic`, `:reviewer` request tools
  (draft/synthesizer stay text-only). It emits `{:tool_requested, ...}` internally.
- **`RunWorker` is the sole broker** that calls `MrEric.Tools.Executor.request_tool/4`.
  Orchestrator must never bypass RunWorker, Registry, Policy, or the approval flow. The
  call itself runs in a `Task` the worker owns (`state.tool_tasks`), so the worker stays
  responsive to `:hard_deadline`, `:reap` and `cancel/2` while a tool runs; the result
  comes back as a message and is dropped if the run went terminal meanwhile.
- While an approval is pending, RunWorker sets run status `:waiting_for_approval`.
- Two tool-call formats are accepted (`lib/mr_eric/orchestrator/tool_call_parser.ex`):
  OpenAI `choices[0].message.tool_calls`, or — for local LLMs — the **entire** assistant
  message being a JSON object `{"tool", "input", "reason"}`. Never scrape arbitrary prose.
- Limits enforced: `max_tool_calls_per_run`, `max_tool_calls_per_role`,
  `max_total_runtime_ms`, `max_context_chars`, `max_tool_output_chars`.

### Tools, approval signing, and patch flow
- All tools live under `lib/mr_eric/tools/`, implement `MrEric.Tools.Tool`, are registered in
  `Registry`, and run **only** through `MrEric.Tools.Executor` (which consults `Policy` first).
  Built-ins: `:file_read`, `:file_write_proposal`, `:apply_patch`, `:shell_command`,
  `:git_status`, `:git_diff`.
- **Approval gate:** `:apply_patch` and `:shell_command` always require approval. Approval
  requests are **HMAC-SHA256 signed** with a per-boot secret (`Executor.init_approval_secret/0`,
  called once from `Application.start/2`, stored in `:persistent_term`). The signature binds
  `{tool, args, approval_id, tool_call_id, owner_id}`, and requests carry an `expires_at` TTL
  (30 min). Approved execution goes only through `Executor.execute_approved/2`.
- **Real filesystem writes happen only via `:apply_patch`, only after approval.** Patch
  validation (`MrEric.Tools.PatchValidator`) runs three times — at `Policy.authorize/3`,
  again in `ApplyPatch.run/2` before applying, and a final `Policy.resolve_workspace_path/2`
  re-resolution immediately before each write — rejecting workspace escapes, protected secret
  paths, symlink escapes (including ones swapped in after validation), binary/oversized/stale/
  deletion patches, and disallowed new-file extensions.
- **Never implement** `git commit`/`push`/`reset`/`clean`, force push, or auto-rollback.
  Rollback is manual via the displayed `git diff`.

### Safety boundaries (enforced, not optional)
- File access stays inside the configured workspace. `MrEric.Tools.Policy` protects `.env*`,
  private keys (`.pem`/`.key`), credential/token/secret paths, `.git`, and `.ssh`.
- `:shell_command` is restricted to a read-oriented allowlist (`pwd ls cat grep rg git` —
  `sed` is deliberately excluded, its script language can read/write/execute) + read-only git
  subcommands,
  rejects shell expansion/redirection/mutating commands, and passes only an **env-var
  allowlist** to children (config key `:shell_env_allowlist`) so secrets don't leak.
  Approved commands are executed as a **direct argv vector** (`Policy.command_argv/1` →
  `System.cmd/3`) — there is no shell process, so nothing re-parses the validated string and
  no login-shell profile is sourced. `ShellCommand.run/2` re-runs `Policy.authorize/3` itself,
  so the boundary holds even when the tool is called without `Executor`.
  Argument grammar is bounded by `@program_grammar`: an option is accepted **only if the
  program's table names it**, so unknown options (`rg --pre`, `git --config-env`,
  `git diff --output`, `rg -L`) are refused by absence rather than by having been predicted.
  `short` is keyed by single characters so bundles decompose (`-nf../x` is `-n` then
  `-f ../x`). Each value is classified `:path` (resolved through `Policy`), `:pattern`, or
  `:literal`; `--` stops option parsing. The program token must be a bare allow-listed name.
  **Never give a grammar lookup a default** — `Map.get(table, key, [])` is what made the
  earlier deny-list fail open. `@allowed_shell_commands` is pinned to `Map.keys(@program_grammar)`
  by a compile-time check.
- Never put API keys, auth headers, cookies, provider secrets, or `reply_to` pids into PubSub
  events, assigns, templates, user-facing logs, traces, or eval output.

### LLM provider layer
- `MrEric.LLM.OpenAICompat` implements the `MrEric.LLM.Provider` behaviour and talks to
  `/v1/chat/completions` and `/v1/models`. `MrEric.OpenAIClient` is a backward-compat wrapper.
- `MrEric.LLM.Router` maps an agent spec → provider/model; `MrEric.LLM.Registry` holds the
  provider catalog and defaults. `config/runtime.exs` validates the required env var for the
  selected `AI_PROVIDER` in prod (Ollama/LM Studio need none).
- **Default provider resolution is local-first.** When neither `:ai_provider` config nor
  `AI_PROVIDER` is set, `MrEric.LLM.ProviderResolver` runs a boot-time fallback chain
  (`:provider_fallback_chain`, default `[:lmstudio, :ollama, :openai]`): it health-checks each
  provider's `/v1/models` and caches the first reachable one in `:resolved_default_provider`.
  `Registry`/`OpenAICompat` read that cache when no provider is pinned. The chain is probed
  from `Application.start/2` (after Finch boots) and skipped when a provider is explicit. The
  terminal entry (`:openai`) is the unconditional fallback and is never probed. Health checks
  are disabled in test (`config :mr_eric, :provider_health_check, false`) so the default
  resolves to `:openai` offline.
- `MrEric.LLM.FakeProvider` is deterministic (same prompt+opts → same output) and is the
  only provider used by `mix mr_eric.evals`. It must never touch the network.

### Deterministic eval harness ("Phase 9")
- `MrEric.Evals` (runner/scorer/case) drives golden cases in
  `priv/evals/phase9_golden_cases.json` against `FakeProvider`. `MrEric.Runs.Trace` produces
  sanitized traces; `MrEric.Errors` classifies errors into safe messages;
  `MrEric.Evals.SecretChecker` scans outputs for leaked secrets. RAG/MCP evals run only when
  those modules are present.
- **A golden case cannot assert less than it reads.** `Evals.Case.from_map!/1`
  raises on an unrecognized status, event name, classification, approval action,
  or requirement — an absent optional field means "does not assert that", a
  present-but-unrecognized one means the fixture is wrong. `Scorer.score/2`
  refuses to score an `actual` without a readable `%Trace{}`, reporting
  `:missing_trace`, because `Enum.any?([], _)` is `false` and used to make
  `forbidden_events` pass precisely when nothing was observable. `Evals.run_all/1`
  reports `skipped` by name and reason; `list_cases/0` no longer filters.
- **`actual` carries the planner stage.** `SecretChecker` walks `actual` by
  denylist, so a field that is not there is never scanned — and the planner
  prompt is where RAG context lands. Note that this is a *second* line of
  defence, not the first: `Events.normalize_event/2` runs `redact_secrets/1`
  over every binary in a `stage_completed` payload, so a secret-shaped string
  is already masked by the time `Run.stages` holds it.

### RAG and MCP are deliberately minimal
- `MrEric.RAG` is an in-memory **lexical** index over safe workspace text files (reusing
  `Policy` path resolution). Do not add vector DBs/embeddings/hybrid search/UI unless scoped.
  RAG failures must not fail a run.
- `MrEric.MCP` is **interface-level only** (`ClientBehaviour`, `ToolAdapter`). No external MCP
  server config, process startup, discovery, proxy, or UI — do not add them unless scoped.
- **The RAG index is cached, bounded by bytes.** `MrEric.RAG.Cache` owns an ETS
  table; reads run in the calling process and building stays in the caller, never
  in the GenServer. `Index.fingerprint/1` identifies the tree with an lstat-only
  walk, so an unchanged workspace is never rebuilt and a changed one always is.
  **`allow_secret_paths` is part of the cache key** — it is the only way a cache
  could serve a secret-inclusive index to a caller that asked for the safe one.
  The bound is `max_cached_index_bytes` / `max_cached_total_bytes`, not a chunk
  count: measured, the term maps are 75 % of an index, so a count is not a memory
  bound — the same lesson `max_trace_entries` taught in Spec D.
- **`Retriever` scores from precomputed `:terms` and applies `exact_bonus` only to
  chunks that already scored.** That is sound because `exact_bonus > 0` implies
  `lexical_score > 0`. Note that `tokenize/1` uniqs before frequencies are taken,
  so every term count is `1` and the score counts *distinct* query tokens; do not
  "fix" that into occurrence counting without treating it as a ranking change.
- **RAG failure is visible.** The orchestrator emits `:rag_failed` and continues
  with empty context. It still never fails a run. The payload's `:error` carries
  the `:rag_failed` sentinel, never the raw reason: the reason can hold a secret
  and `send_event/4` does not sanitize, and `Errors.classify/1` on an arbitrary
  string keyword-matches English and answers `:unknown`.

## Web layer
- Single LiveView: `MrEricWeb.AgentLive` at `/` — Run UI, tool/patch approval controls.
  Keep role panels addressable by stable DOM IDs (tests rely on them).
- Follow the Phoenix 1.8 idioms in `AGENTS.md`: `<Layouts.app flash={@flash}>` wrappers,
  `<.input>`/`to_form/2` for forms, `<.icon name="hero-..."/>` for icons, daisyUI + Tailwind v4.
