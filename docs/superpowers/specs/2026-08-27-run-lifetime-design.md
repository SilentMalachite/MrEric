# Spec D — Run Lifetime and Resource Limits

- **Date:** 2026-08-27
- **Status:** Designed. Not yet implemented.
- **Plan:** `docs/superpowers/plans/2026-08-27-run-lifetime.md`
- **Scope:** Fourth of six hardening specs derived from the 2026-05-05 audit report.
- **Tracks audit findings:** unbounded `RunSupervisor` children, `RunWorker` processes that outlive their run, unbounded `Runs.Trace` growth, unbounded completed-run history.
- **Threat model:** Local single-user dev tool. The adversary is not a remote attacker; it is *time and repetition* — a browser tab that keeps submitting, a model that streams for three minutes, a `iex -S mix phx.server` session left running for a week. Nothing here is an authentication boundary. Multi-user authentication remains out of scope.

## Background

Specs A–C closed the secret, ownership, and tool-execution boundaries. Every one of them constrains *what a run may do*. None of them constrains *how many runs may exist, how long their processes live, or how much memory each one accumulates*. That is the last operational hole behind the approval gate, and it is the whole of this spec.

Four concrete gaps, all of them present on `main` today:

**1. The run supervisor has no child limit.** `MrEric.Runs.RunSupervisor.init/1` is `DynamicSupervisor.init(strategy: :one_for_one)` (`lib/mr_eric/runs/run_supervisor.ex:20`) — no `max_children`. `MrEric.Runs.start_run/3` starts a child per call, and each child immediately spawns a `Task` that streams against a provider. Nothing between the "Run" button and the provider counts. A loop in the browser — or a stuck LiveView reconnect cycle — starts as many concurrent runs, and as many concurrent provider connections, as the user can click.

**2. A run's worker never stops.** `RunWorker` has no `terminate` path, no idle timeout, and no stop after a terminal event. Once `run_completed` / `run_failed` / `run_cancelled` is applied, the GenServer keeps running, keeps its `Registry` entry, and keeps its whole `%Run{}` in state — every stage's accumulated content plus the full trace — for the lifetime of the BEAM. The `child_spec/1` already sets `restart: :temporary` (`run_worker.ex:36-45`), so nothing *wants* the process alive; it simply is never told to stop.

**3. The trace grows without bound, and quadratically.** `Trace.record/3` appends with `Map.update!(:entries, &(&1 ++ [entry]))` (`lib/mr_eric/runs/trace.ex:50`). Every event is recorded, including `stage_chunk`, and `stage_chunk` carries the streamed text itself. A run streaming a few thousand chunks therefore stores the model's entire output a second time — the first copy already lives in `Run.stages[role].content` — and pays an O(n²) list append to do it.

**4. Completed-run history is an unbounded list.** `MrEric.Agent` starts with `%{history: []}` (`lib/mr_eric/agent.ex:22`) and prepends on both the `{:record, entry}` path (`agent.ex:59`) and the task-completion path (`agent.ex:87`). `RunWorker` copies every completed run into it (`run_worker.ex:674-687`). Nothing ever removes an entry. The LiveView mirrors the same unbounded list into a stream at mount (`lib/mr_eric_web/live/agent_live.ex:40`) and inserts into it on every completion (`agent_live.ex:615`).

### What is *not* broken

Two things that look like lifetime holes are already closed, and this spec does not touch them:

- **A run waiting on approval cannot hang forever.** `Orchestrator` waits for `{:tool_result, ...}` with `receive ... after remaining_runtime_ms(...)` (`lib/mr_eric/orchestrator.ex:481-491`), bounded by `max_total_runtime_ms` (default 180 s). The approval TTL is 30 minutes, so the orchestrator always gives up first, emits its terminal event, and the run finishes. The 30-minute TTL governs whether a *late* approval is honoured — not how long the run lives.
- **A crashing orchestrator task always terminalises the run.** `handle_info({:DOWN, ref, ...}, %{task: %{ref: ref}})` turns a non-normal exit into `run_failed` (`run_worker.ex:340`).

So the run *state machine* reaches a terminal status reliably. What is missing is that reaching a terminal status has no consequence for the *process*.

## Goals

- Cap the number of concurrently supervised runs, and reject the surplus with a domain error the UI can already render.
- Stop a `RunWorker` a short, configurable grace period after its run reaches a terminal status, so a finished run returns its supervisor slot and frees its state.
- Guarantee that a worker cannot outlive an absolute deadline, so a finite pool of slots cannot be permanently consumed by a leaked worker.
- Bound `Trace` memory without breaking `Trace.summary/1`, `Trace.events/1`, or the golden eval cases that read them.
- Bound the completed-run history on the server, and the mirrored history stream in the LiveView.
- Put every new limit behind one configuration key with one reader module, and make an unknown limit key raise rather than silently default.

## Non-Goals

- **Per-owner concurrency accounting.** Considered and rejected. The threat model is a single local user; a global cap already stops the runaway-tab case, and per-owner counting would require carrying run status in the `Registry` value and a pre-flight scan on every start. If MrEric ever grows real multi-user sessions, that scan is the natural place to add it, and Spec B's `owner_id` is already threaded through to make it possible.
- **Persisting runs or history.** No Ecto repo exists; `lib/mr_eric/runs/run.ex` documents in-memory state as deliberate. Reaping a worker discards live run state by design — the completed run is already in `MrEric.Agent` history before the reap timer fires.
- **Capping `Run.stages[role].content`.** Stage content is bounded indirectly by `max_total_runtime_ms`; capping it directly would truncate what the user sees in the role panels, which is the product, not the overhead. The trace's *second* copy of that text is the waste, and Section 5 removes it.
- **Changing `max_tool_calls_per_run`, `max_tool_calls_per_role`, `max_total_runtime_ms`, `max_context_chars`, or `max_tool_output_chars`.** Those are the orchestrator's per-run budgets (`orchestrator.ex:11-17`) and they stay exactly as they are. This spec adds limits *around* a run, not *inside* one.
- **Back-pressure or queueing.** A rejected run is rejected, not queued. A queue would need its own lifetime rules and would hide the very condition the cap exists to surface.
- **Eval / RAG correctness (Spec E) and production HTTP (Spec F).**

## Architecture overview

Before — three unbounded accumulators and one unbounded pool:

```
Runs.start_run/3 ──▶ RunSupervisor (no max_children)
                          │
                          ├─▶ RunWorker (never stops)
                          │      ├─ %Run{} ─▶ stages[].content   (bounded by runtime)
                          │      └─ %Trace{entries: [...]}       (UNBOUNDED, O(n²), duplicates chunks)
                          │
                          └─▶ ... one per click, forever ...

RunWorker ──(run_completed)──▶ MrEric.Agent.history [...]        (UNBOUNDED)
                                      │
                                      └─▶ AgentLive stream       (UNBOUNDED)
```

After — one limits contract, four enforcement points:

```
                    MrEric.Runs.Limits  (config :mr_eric, :run_limits)
                     │       │        │            │
        max_concurrent_runs  │  max_trace_entries  max_history_entries
                     │  terminal_run_ttl_ms
                     │  hard_deadline_grace_ms
                     ▼
Runs.start_run/3 ──▶ RunSupervisor (max_children)
                          │  └── {:error, :max_children} ─▶ {:error, :too_many_runs} ─▶ Events.public_error/1
                          ▼
                     RunWorker
                       ├─ terminal event  ─▶ send_after(:reap, terminal_run_ttl_ms) ─▶ {:stop, :normal}
                       ├─ init            ─▶ send_after(:hard_deadline, runtime + grace) ─▶ run_failed
                       └─ %Trace{}        ─▶ chunks folded per role, entries capped, drops counted
                                 │
                                 ▼
                    MrEric.Agent.history (max_history_entries) ─▶ AgentLive stream (limit:)
```

The limits module is the only place that reads configuration. Each enforcement point asks it once and then behaves deterministically.

## Section 1 — The limits contract

New module `MrEric.Runs.Limits`, holding the defaults and the single reader:

```elixir
@defaults %{
  max_concurrent_runs: 8,
  terminal_run_ttl_ms: 60_000,
  hard_deadline_grace_ms: 60_000,
  max_trace_entries: 500,
  max_history_entries: 50
}

def fetch!(key) when is_map_key(@defaults, key) do
  :mr_eric
  |> Application.get_env(:run_limits, [])
  |> Keyword.get(key, Map.fetch!(@defaults, key))
end
```

Two properties matter, and both are deliberate:

- **`fetch!/1` has no default parameter and no catch-all clause.** A typo'd key raises `FunctionClauseError` at the call site instead of returning a plausible number. Spec C-1 established this rule the hard way: `Map.get(table, key, [])` on a grammar lookup is what made the earlier deny-list fail open. Limits fail closed in a different direction — a wrong default here is a *missing* limit — so the same discipline applies.
- **Callers may override per-run through `opts`,** using the seam that already exists. `RunWorker` reads `Keyword.get(state.opts, :terminal_run_ttl_ms, Limits.fetch!(:terminal_run_ttl_ms))`, exactly as it already reads `:orchestrator_module`, `:agent_server`, and `:skip_history`. Tests set milliseconds; production reads config. No `Application.put_env` gymnastics in the worker tests.

Defaults are declared in `config/config.exs` so the values are discoverable where every other tunable lives, with `@defaults` as the fallback if the key is absent entirely.

**Chosen values and why:**

| Key | Default | Reasoning |
|-----|---------|-----------|
| `max_concurrent_runs` | 8 | A single user driving one browser tab runs one or two at a time. Eight leaves room for deliberate parallel comparison while still stopping a runaway loop within a second. |
| `terminal_run_ttl_ms` | 60_000 | Long enough that `Evals.Runner`'s post-completion `Runs.get_run/1` (`lib/mr_eric/evals/runner.ex:59`) and a LiveView reconnect both still find the run; short enough that a finished run's slot returns while the user is still reading the output. |
| `hard_deadline_grace_ms` | 60_000 | Added to `max_total_runtime_ms` (180 s default) → 240 s absolute. Three times the orchestrator's own budget, so it can only fire when something is genuinely wrong. |
| `max_trace_entries` | 500 | A legitimate run produces well under 100 entries once chunks are folded (Section 5). This is a backstop, not a working limit. |
| `max_history_entries` | 50 | The history panel is a scan-back list, not an archive. Fifty completed runs is more than a session's worth. |

### Tests

- `fetch!/1` returns each default with no application env set.
- `fetch!/1` honours `Application.put_env(:mr_eric, :run_limits, ...)` for a subset of keys and falls back to defaults for the rest.
- `fetch!/1` raises for an unknown key.

## Section 2 — Concurrency cap

`RunSupervisor.init/1` becomes:

```elixir
DynamicSupervisor.init(strategy: :one_for_one, max_children: Limits.fetch!(:max_concurrent_runs))
```

`DynamicSupervisor.start_child/2` returns `{:error, :max_children}` when the limit is reached. That is authoritative and race-free — there is no pre-flight count to lose a race against — but `:max_children` is an OTP-internal name. `Runs.start_run/3` maps it:

```elixir
{:error, :max_children} -> {:error, :too_many_runs}
```

`Events.public_error(:too_many_runs)` returns a user-facing sentence. `AgentLive` needs **no change**: `agent_live.ex:468` already funnels `{:error, reason}` from `start_run/3` into a blank run with `run_failed`, which renders through `Events.public_error/1`. `Errors.classify(:too_many_runs) → :run_limit_reached` is added alongside, with a message in `to_safe_message/1`, so the rejection classifies as itself rather than `:unknown` if it ever reaches a trace or an eval.

**Test seam.** The application-wide `RunSupervisor` is started under the supervision tree with the production cap; a test cannot cheaply reconfigure it. So `RunSupervisor.start_link/1` gains `:name` and `:max_children` options, `start_run/3` takes an optional supervisor reference, and `Runs.start_run/3` reads `:supervisor` from `opts` (added to `@internal_opts` so it is dropped before reaching the worker). A test then starts its own supervisor with `max_children: 1` and asserts the second start is refused. This is the same shape as the `:orchestrator_module` and `:agent_server` seams already in the codebase.

### Tests

- With a test supervisor at `max_children: 1`, the first `start_run/3` returns `{:ok, %Run{}}` and the second returns `{:error, :too_many_runs}` — not `{:error, :max_children}`.
- After the first run is reaped (Section 3), a subsequent `start_run/3` succeeds — the slot is genuinely released, not merely marked.
- `Events.public_error(:too_many_runs)` is a non-empty binary that does not contain `max_children`.
- `Errors.classify(:too_many_runs) == :run_limit_reached`.

## Section 3 — Terminal worker reaping

When a run reaches a terminal status, the worker schedules its own stop:

```elixir
defp put_run(state, run) do
  state |> Map.put(:run, run) |> maybe_schedule_reap()
end

defp maybe_schedule_reap(%{reap_scheduled?: true} = state), do: state

defp maybe_schedule_reap(state) do
  if Run.terminal?(state.run) do
    Process.send_after(self(), :reap, reap_ttl(state))
    %{state | reap_scheduled?: true}
  else
    state
  end
end

def handle_info(:reap, state) do
  if Run.terminal?(state.run), do: {:stop, :normal, state}, else: {:noreply, state}
end
```

Every site that writes `state.run` routes through `put_run/2`: the `@run_events` clause, the cancel call, the `:DOWN` clause, and `broadcast_and_apply/3`. Centralising the write is what makes "terminal ⇒ scheduled" true by construction rather than by remembering to add a call at four sites. `reap_scheduled?` makes it idempotent — a run that emits `run_completed` and then a late `tool_completed` schedules one timer, not two.

`restart: :temporary` is already set, so `{:stop, :normal, state}` ends the child for good and the `Registry` entry disappears with the process. `Runs.get_run/1` on a reaped run returns `{:error, :not_found}`, which is the existing contract for an unknown id.

**Ordering guarantee.** History recording happens synchronously inside the `run_completed` handling (`run_worker.ex:677-687`), before the reap timer is even scheduled — the completed run is in `MrEric.Agent` history long before the worker dies. Reaping never loses a result.

**Cancellation.** `handle_call({:cancel, ...})` applies `run_cancelled` directly and is one of the `put_run/2` sites, so a cancelled run is reaped on the same schedule as a completed one.

### Tests

- A worker started with `terminal_run_ttl_ms: 50` and driven to `run_completed` is no longer alive shortly after, and its `Registry` entry is gone.
- The same holds for `run_cancelled` and for `run_failed`.
- A worker driven only to `stage_completed` is still alive after the same interval — non-terminal runs are never reaped.
- History is recorded before the process exits: after the reap, `Agent.history/1` contains the entry.
- Two terminal events in a row (`run_completed` then a late `tool_completed`) schedule exactly one stop.

## Section 4 — Hard deadline

This section exists *because* of Section 2. With an unbounded pool, a worker that never terminalises is a memory leak; with a pool of eight, it is one-eighth of a denial of service against the application itself, permanently. The cap converts a slow leak into a hard failure, so the pool needs a guarantee that every slot is eventually returned.

At `init/1`:

```elixir
hard_ms = Keyword.get(opts, :max_total_runtime_ms, 180_000) + Limits.fetch!(:hard_deadline_grace_ms)
Process.send_after(self(), :hard_deadline, hard_ms)
```

On `:hard_deadline`, if the run is already terminal the message is ignored (the reap timer owns the stop). Otherwise the worker shuts the orchestrator task down with the existing `shutdown_task/1` and applies `run_failed` with `%{error: :run_lifetime_exceeded}` through the normal path — which broadcasts the event, records history, and, via `put_run/2`, schedules the reap. No new event name, no new status, no new code path: the safety net *terminates into the machinery that already exists*.

`Events.public_error(:run_lifetime_exceeded)` and `Errors.classify(:run_lifetime_exceeded) → :timeout` give it a user-facing sentence and an existing classification — a run that exceeded its absolute lifetime is a timeout by any useful definition.

The deadline is scheduled in `init/1` unconditionally, including when `auto_start: false`. That is harmless for the manual-worker tests (240 s default, tests finish in milliseconds) and means the guarantee does not depend on which construction path was used.

### Tests

- A worker with `max_total_runtime_ms: 20` and `hard_deadline_grace_ms: 10` whose orchestrator stub never emits a terminal event ends up `status: :failed` with the `:run_lifetime_exceeded` message, and is then reaped.
- A run that completes normally well inside the deadline is unaffected: no `run_failed` is broadcast when the deadline later elapses (the message hits a terminal run and is ignored).
- The supervisor slot is released after a hard-deadline failure — a subsequent `start_run/3` against a `max_children: 1` test supervisor succeeds.

## Section 5 — Trace bounds

Two changes to `MrEric.Runs.Trace`, plus two new struct fields (`chunk_counts: %{}`, `dropped_entries: 0`).

**Fold `stage_chunk`.** The first `stage_chunk` for a given role is recorded as an entry with the `chunk` body removed; every subsequent chunk for that role increments `chunk_counts[role]` and records no entry. The body is dropped because it is a *duplicate* — the same text is already accumulated in `Run.stages[role].content` by `Run.do_apply_event/3` (`run.ex:118-131`).

This preserves everything the eval harness reads:

- `Trace.events/1` still contains `:stage_chunk` (one per streaming role), so a golden case may still list it in `expected_events`. None of the six current cases do, but the option survives.
- `summary/1`'s `event_counts[:stage_chunk]` adds the folded counts back, so the number is the true number of chunks, not the number of retained entries.

It also does not weaken leak detection. `Evals.SecretChecker` walks the trace, but `Evals.Runner` hands it the stage maps as `drafts` and `reviews` too (`evals/runner.ex:64-77`), and those still carry the full streamed text. The scanned surface for chunk content is unchanged; only the duplicate copy is gone. Section 7's acceptance criteria pin this with a test rather than leaving it as an assertion in prose.

**Cap the entries.** When `length(entries) >= max_trace_entries`, the oldest entry is dropped and `dropped_entries` is incremented. `summary/1` gains `dropped_entries` and `truncated?`.

**The O(n²) append is left alone.** `entries ++ [entry]` on a list capped at 500 is at most ~125k cons cells over an entire run — irrelevant. Restructuring the struct to prepend-and-reverse would change the meaning of `%Trace{entries: ...}`, which `Evals.Scorer` reads directly in its fallback clause (`evals/scorer.ex:149`) and which `trace_test.exs` asserts on. The cap removes the pathology; the shape stays.

**Honest limitation.** Drop-oldest can, in principle, evict `run_started` from a trace that exceeds 500 entries, which would change `summary/1`'s `events` list. With chunks folded, a legitimate run produces under 100 entries — the tool-call budget alone caps tool events at `max_tool_calls_per_run` × 4 — so the cap should never engage. `dropped_entries` exists precisely so that a scorer, or a human reading a trace, can tell that it did. This spec chooses the simple rule and reports when it bites, rather than a priority-retention scheme whose complexity would exceed the problem.

### Tests

- Recording 1_000 `stage_chunk` events for `:planner` yields exactly one `:stage_chunk` entry, that entry carries no `chunk` key, and `summary/1`'s `event_counts[:stage_chunk] == 1_000`.
- Chunks for two different roles yield one entry each.
- `Trace.events/1` still includes `:stage_chunk` after folding.
- Recording more than `max_trace_entries` non-chunk events keeps the list at the cap and sets `dropped_entries` / `truncated?`.
- A trace built from a full simulated run round-trips through `Evals.Scorer` with the same verdict as before the change.
- `SecretChecker` still reports a leak planted in stage content via the `drafts` path.

## Section 6 — History bounds

`MrEric.Agent` takes `max_history` at `start_link/1` (defaulting to `Limits.fetch!(:max_history_entries)`) and truncates on both insertion paths:

```elixir
history = [entry | state.history] |> Enum.take(state.max_history)
```

`Enum.take/2` on a newest-first list keeps the newest N, which is what the panel shows. `Agent.history/1`'s contract — newest first — is unchanged.

`AgentLive` mirrors the same bound in the DOM: `stream(:history, Agent.history(), limit: N)` at mount and `stream_insert(socket, :history, entry, at: 0, limit: N)` on completion (`agent_live.ex:40` and `agent_live.ex:615`). Without this, a long-lived LiveView accumulates history cards the server has already forgotten — the server-side cap alone would not bound the browser.

### Tests

- Recording `max_history_entries + 10` entries leaves exactly `max_history_entries`, newest first, oldest dropped.
- The limit is configurable per-server through `start_link/1`.
- A LiveView mounted against a history longer than the limit renders at most that many history entries.

## Section 7 — What is *not* addressed, and why

- **A run rejected by the cap is not retried or queued.** The user sees the rejection and clicks again. Queueing would need its own lifetime rules and would mask the runaway condition.
- **The cap counts supervised children, not active runs.** During the reap grace period a finished run still holds a slot, so the effective concurrency limit is "started within the last `terminal_run_ttl_ms`", not "currently streaming". With 8 and 60 s this is the intended behaviour and the simplest thing that works; Section "Non-Goals" records what would change if per-owner or active-only accounting were ever needed.
- **Nothing bounds PubSub subscriber counts or LiveView socket lifetime.** Phoenix owns those; no audit finding pointed at them.
- **Reaping discards live run state.** By design — the completed run is in history, and there is no repository to persist to.

## Risks and follow-ups

| Risk | Assessment |
|------|------------|
| A slow eval or a slow reconnect races the 60 s reap and sees `{:error, :not_found}` | `Evals.Runner` reads the run immediately after `run_completed` (`runner.ex:55-59`); 60 s is three orders of magnitude of headroom. The acceptance criteria require `mix mr_eric.evals` to pass unchanged. |
| `max_concurrent_runs: 8` is too low for a user who deliberately fans out | It is configurable, and the rejection message says what happened. Eight is a default, not a boundary. |
| The hard deadline fires on a legitimately long run | It sits at `max_total_runtime_ms + 60 s`. A run legitimately exceeding its own orchestrator budget by a minute is already broken. If a provider ever needs more, `max_total_runtime_ms` is the knob, and the deadline follows it automatically. |
| Trace drop-oldest evicts `run_started` | Only above 500 entries, which folding makes unreachable in practice. `dropped_entries` reports it. |
| Centralising `state.run` writes through `put_run/2` misses a site | Caught by construction: after the refactor, `%{state \| run: ...}` should appear nowhere else in `run_worker.ex`. Made an explicit verification step in the plan. |

## Acceptance criteria

1. `RunSupervisor` refuses to start more than `max_concurrent_runs` children, and `Runs.start_run/3` surfaces `{:error, :too_many_runs}` — never `{:error, :max_children}`.
2. A run reaching `completed`, `failed`, or `cancelled` has its worker stopped within `terminal_run_ttl_ms`, its `Registry` entry removed, and its supervisor slot available to a new run.
3. A non-terminal run is never reaped.
4. Every worker stops no later than `max_total_runtime_ms + hard_deadline_grace_ms` after start, terminalising as `run_failed` with `:run_lifetime_exceeded` if it had not finished.
5. A completed run is present in `MrEric.Agent` history before its worker exits.
6. `Trace` retains at most one `:stage_chunk` entry per role, stores no chunk bodies, and reports true chunk counts in `summary/1`.
7. `Trace.entries` never exceeds `max_trace_entries`; overflow is counted in `dropped_entries` and reported by `summary/1`.
8. `MrEric.Agent` history never exceeds `max_history_entries`, and the LiveView history stream carries the same bound.
9. `MrEric.Runs.Limits.fetch!/1` raises on an unknown key and honours `config :mr_eric, :run_limits`.
10. `mix precommit` passes.
11. `mix mr_eric.evals` passes with `priv/evals/phase9_golden_cases.json` unmodified.
12. No change to run statuses, role lists, event names, PubSub topic, tool result shapes, or the approval flow.

## Out of scope (tracked elsewhere)

- Spec E — eval / RAG correctness (scorer early-pass, RAG cache, `rag_default_index` golden case).
- Spec F — production HTTP (`force_ssl`, HSTS, CSP, `PHX_HOST` hard-fail).
- Phase 7 advanced RAG, Phase 8 real MCP connections, Ecto persistence, multi-user authentication.
