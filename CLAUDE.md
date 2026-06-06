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

### Run ownership (recent "Spec B" work — note the API drift)
- Every run is bound to an `owner_id`. `MrEric.Plugs.EnsureOwnerId` (wired into the
  `:browser` pipeline in `router.ex`) mints/reads a session-scoped `owner_id`.
- `MrEric.Runs.start_run(task, owner_id, opts)` is **3-arity** and `owner_id` is required
  (the README's `start_run/2` examples are out of date). `cancel_run`, `approve_tool`, and
  `deny_tool` all require `owner_id`; `MrEric.Runs.OwnerCheck.verify/2` enforces it.
- Design/plan for this lives in `docs/superpowers/specs/2026-05-05-run-ownership-design.md`
  and `docs/superpowers/plans/2026-05-05-run-ownership.md`.

### Orchestrator tool loop — RunWorker is the only tool broker
- `MrEric.Orchestrator.stream/3` lets only `:planner`, `:critic`, `:reviewer` request tools
  (draft/synthesizer stay text-only). It emits `{:tool_requested, ...}` internally.
- **`RunWorker` is the sole broker** that calls `MrEric.Tools.Executor.request_tool/4`.
  Orchestrator must never bypass RunWorker, Registry, Policy, or the approval flow.
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
  validation (`MrEric.Tools.PatchValidator`) runs twice — before requesting approval and again
  immediately before applying — rejecting workspace escapes, protected secret paths, symlink
  escapes, binary/oversized/stale/deletion patches, and disallowed new-file extensions.
- **Never implement** `git commit`/`push`/`reset`/`clean`, force push, or auto-rollback.
  Rollback is manual via the displayed `git diff`.

### Safety boundaries (enforced, not optional)
- File access stays inside the configured workspace. `MrEric.Tools.Policy` protects `.env*`,
  private keys (`.pem`/`.key`), credential/token/secret paths, `.git`, and `.ssh`.
- `:shell_command` is restricted to a read-oriented allowlist + read-only git subcommands,
  rejects shell expansion/redirection/mutating commands, and passes only an **env-var
  allowlist** to children (config key `:shell_env_allowlist`) so secrets don't leak.
- Never put API keys, auth headers, cookies, provider secrets, or `reply_to` pids into PubSub
  events, assigns, templates, user-facing logs, traces, or eval output.

### LLM provider layer
- `MrEric.LLM.OpenAICompat` implements the `MrEric.LLM.Provider` behaviour and talks to
  `/v1/chat/completions` and `/v1/models`. `MrEric.OpenAIClient` is a backward-compat wrapper.
- `MrEric.LLM.Router` maps an agent spec → provider/model; `MrEric.LLM.Registry` holds the
  provider catalog and defaults. `config/runtime.exs` validates the required env var for the
  selected `AI_PROVIDER` in prod (Ollama/LM Studio need none).
- `MrEric.LLM.FakeProvider` is deterministic (same prompt+opts → same output) and is the
  only provider used by `mix mr_eric.evals`. It must never touch the network.

### Deterministic eval harness ("Phase 9")
- `MrEric.Evals` (runner/scorer/case) drives golden cases in
  `priv/evals/phase9_golden_cases.json` against `FakeProvider`. `MrEric.Runs.Trace` produces
  sanitized traces; `MrEric.Errors` classifies errors into safe messages;
  `MrEric.Evals.SecretChecker` scans outputs for leaked secrets. RAG/MCP evals run only when
  those modules are present.

### RAG and MCP are deliberately minimal
- `MrEric.RAG` is an in-memory **lexical** index over safe workspace text files (reusing
  `Policy` path resolution). Do not add vector DBs/embeddings/hybrid search/UI unless scoped.
  RAG failures must not fail a run.
- `MrEric.MCP` is **interface-level only** (`ClientBehaviour`, `ToolAdapter`). No external MCP
  server config, process startup, discovery, proxy, or UI — do not add them unless scoped.

## Web layer
- Single LiveView: `MrEricWeb.AgentLive` at `/` — Run UI, tool/patch approval controls.
  Keep role panels addressable by stable DOM IDs (tests rely on them).
- Follow the Phoenix 1.8 idioms in `AGENTS.md`: `<Layouts.app flash={@flash}>` wrappers,
  `<.input>`/`to_form/2` for forms, `<.icon name="hero-..."/>` for icons, daisyUI + Tailwind v4.
