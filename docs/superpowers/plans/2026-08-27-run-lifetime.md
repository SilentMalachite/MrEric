# Spec D — Run Lifetime and Resource Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cap concurrent runs, stop a `RunWorker` once its run is finished (and unconditionally at an absolute deadline), and bound both the per-run trace and the completed-run history.

**Architecture:** One new module, `MrEric.Runs.Limits`, owns every limit value; `@defaults` inside it is the single source of truth and `config :mr_eric, :run_limits` is override-only. `RunSupervisor` gains `max_children`, and `Runs.start_run/3` maps OTP's `{:error, :max_children}` to the domain error `{:error, :too_many_runs}`. `RunWorker` routes every write of `state.run` through a new `put_run/2`, which schedules a one-shot `:reap` the moment the run becomes terminal, and `init/1` arms a `:hard_deadline` that terminalises any run that outlives `max_total_runtime_ms + hard_deadline_grace_ms`. `Trace` folds `stage_chunk` into per-role counters and caps its entry list. `MrEric.Agent` and the LiveView history stream both truncate to `max_history_entries`.

**Tech Stack:** Elixir 1.17, Phoenix 1.8, LiveView 1.1, ExUnit. No new dependencies. No new event names, statuses, roles, or tool result shapes.

**Spec:** `docs/superpowers/specs/2026-08-27-run-lifetime-design.md`

## Global Constraints

- **Respond to the user in Japanese**, leading with the conclusion (`CLAUDE.md`).
- **At most 3 files per commit.** Every commit below is sized to respect this. Tasks 2 and 7 deliberately split into two commits for that reason. Do not batch commits together.
- **`mix precommit` is the gate.** It is `compile --warning-as-errors` + `deps.unlock --unused` + `test`, in `:test` env. Warnings are errors.
- **`mix mr_eric.evals` must pass with `priv/evals/phase9_golden_cases.json` unmodified.** The evals task runs in `:dev` env, so it sees production limit defaults, not the test overrides.
- **No new HTTP libraries.** `Req` only. (Not touched here, but the rule stands.)
- **No persistence.** No Ecto, no repo, no writing run state to disk.
- **Do not change** run statuses or roles (`lib/mr_eric/runs/run.ex`), event names (`lib/mr_eric/runs/events.ex` `@event_names`), the PubSub topic `"runs:#{run_id}"`, tool result shapes, the approval HMAC, or the 30-minute approval TTL.
- **Do not change** the orchestrator budgets `max_tool_calls_per_run`, `max_tool_calls_per_role`, `max_total_runtime_ms`, `max_context_chars`, `max_tool_output_chars` (`lib/mr_eric/orchestrator.ex:11-17`). Task 5 *reads* `max_total_runtime_ms`; it does not change it.
- **Never give a limit lookup a silent default.** `Limits.fetch!/1` is guard-clause-only; an unknown key must raise. This is the Spec C-1 lesson (`Map.get(table, key, [])` is what made a deny-list fail open) applied to limits.

---

## File Structure

| Path | Disposition | Responsibility |
|------|-------------|----------------|
| `lib/mr_eric/runs/limits.ex` | create | `@defaults` + `fetch!/1`; the only reader of `config :mr_eric, :run_limits` |
| `config/test.exs` | modify | Test-env overrides so the suite does not exhaust the run pool |
| `lib/mr_eric/runs/events.ex` | modify | `public_error/1` sentences for `:too_many_runs` and `:run_lifetime_exceeded` |
| `lib/mr_eric/errors.ex` | modify | `:run_limit_reached` classification + safe message |
| `lib/mr_eric/runs/run_supervisor.ex` | modify | `max_children`; `:name` / `:max_children` / supervisor-ref seams |
| `lib/mr_eric/runs.ex` | modify | Map `{:error, :max_children}` → `{:error, :too_many_runs}`; `:supervisor` internal opt |
| `lib/mr_eric/runs/run_worker.ex` | modify | `put_run/2`, `:reap`, `:hard_deadline` |
| `lib/mr_eric/orchestrator.ex` | modify | Publish `default_tool_limits/0` so the worker reads the runtime budget instead of copying it |
| `lib/mr_eric/evals/runner.ex` | modify | Short `terminal_run_ttl_ms` for eval runs |
| `lib/mr_eric/runs/trace.ex` | modify | Fold `stage_chunk`, cap `entries`, report drops |
| `lib/mr_eric/agent.ex` | modify | `max_history` truncation on both insert paths |
| `lib/mr_eric_web/live/agent_live.ex` | modify | Same bound on the history stream |
| `test/mr_eric/runs/limits_test.exs` | create | Defaults, overrides, unknown-key raise |
| `test/mr_eric/runs/events_test.exs` | modify | New `public_error/1` sentences |
| `test/mr_eric/errors_test.exs` | modify | New classification and message |
| `test/mr_eric/runs_test.exs` | modify | Concurrency cap through `Runs.start_run/3` |
| `test/mr_eric/runs/run_worker_lifetime_test.exs` | create | Reaping, slot release, hard deadline |
| `test/mr_eric/runs/trace_test.exs` | modify | Chunk folding and entry cap |
| `test/mr_eric/agent_test.exs` | create | History truncation |
| `test/mr_eric_web/live/agent_live_test.exs` | modify | History stream bound |
| `docs/superpowers/README.md` | modify | Mark Spec D implemented; point "次にやる作業" at Spec E |
| `CLAUDE.md` | modify | Record the run-limit contract |
| `CHANGELOG.md` | modify | Spec D entry |

Module boundaries: `Limits` answers *what the limit is* and nothing else — it has no dependencies, so anything may call it. `RunSupervisor` owns the pool, `RunWorker` owns one run's lifetime, `Trace` owns its own memory, `Agent` owns history. No module gains a second responsibility.

---

## Task 1: The limits contract

**Files:**
- Create: `lib/mr_eric/runs/limits.ex`
- Create: `test/mr_eric/runs/limits_test.exs`
- Modify: `config/test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `MrEric.Runs.Limits.fetch!(key) :: pos_integer()` for `:max_concurrent_runs`, `:terminal_run_ttl_ms`, `:hard_deadline_grace_ms`, `:max_trace_entries`, `:max_history_entries`. Raises `FunctionClauseError` for any other key. Also `MrEric.Runs.Limits.defaults/0 :: map()`.

- [ ] **Step 1: Write the failing test**

Create `test/mr_eric/runs/limits_test.exs`:

```elixir
defmodule MrEric.Runs.LimitsTest do
  # async: false — these tests mutate application env.
  use ExUnit.Case, async: false

  alias MrEric.Runs.Limits

  setup do
    original = Application.get_env(:mr_eric, :run_limits)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:mr_eric, :run_limits)
        value -> Application.put_env(:mr_eric, :run_limits, value)
      end
    end)

    :ok
  end

  test "every key falls back to its built-in default when nothing is configured" do
    Application.put_env(:mr_eric, :run_limits, [])

    assert Limits.fetch!(:max_concurrent_runs) == 8
    assert Limits.fetch!(:terminal_run_ttl_ms) == 60_000
    assert Limits.fetch!(:hard_deadline_grace_ms) == 60_000
    assert Limits.fetch!(:max_trace_entries) == 500
    assert Limits.fetch!(:max_history_entries) == 50
  end

  test "an override wins for its own key and leaves the others at their defaults" do
    Application.put_env(:mr_eric, :run_limits, max_concurrent_runs: 2)

    assert Limits.fetch!(:max_concurrent_runs) == 2
    assert Limits.fetch!(:max_trace_entries) == 500
  end

  test "an unknown key raises instead of inventing a default" do
    assert_raise FunctionClauseError, fn -> Limits.fetch!(:max_bananas) end
  end

  test "defaults/0 exposes exactly the supported keys" do
    assert Map.keys(Limits.defaults()) |> Enum.sort() == [
             :hard_deadline_grace_ms,
             :max_concurrent_runs,
             :max_history_entries,
             :max_trace_entries,
             :terminal_run_ttl_ms
           ]
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/mr_eric/runs/limits_test.exs`
Expected: FAIL — `module MrEric.Runs.Limits is not available`.

- [ ] **Step 3: Write the implementation**

Create `lib/mr_eric/runs/limits.ex`:

```elixir
defmodule MrEric.Runs.Limits do
  @moduledoc """
  Resource limits that bound a run's lifetime and memory (Spec D).

  `@defaults` is the single source of truth for every value. Configuration is
  override-only:

      config :mr_eric, :run_limits,
        max_concurrent_runs: 16,
        terminal_run_ttl_ms: 30_000

  Any key left out keeps its default, so there is never a second copy of a
  number to drift.

  `fetch!/1` has no catch-all clause and no default parameter on purpose: an
  unknown key raises at the call site rather than returning a plausible
  number. Spec C-1 established the rule the hard way — `Map.get(table, key,
  [])` on a grammar lookup is what made an earlier deny-list fail open.
  """

  @defaults %{
    # Concurrently supervised RunWorkers. Counts workers, not streaming runs:
    # a finished run holds its slot until it is reaped.
    max_concurrent_runs: 8,
    # Grace period between a run reaching a terminal status and its worker
    # stopping. Long enough for a post-completion `Runs.get_run/1`.
    terminal_run_ttl_ms: 60_000,
    # Added to the orchestrator's `max_total_runtime_ms` to form the absolute
    # deadline after which a worker terminalises itself no matter what.
    hard_deadline_grace_ms: 60_000,
    # Backstop on `MrEric.Runs.Trace` entries. Chunk folding keeps a normal
    # run well under this.
    max_trace_entries: 500,
    # Completed runs kept by `MrEric.Agent` and mirrored in the LiveView.
    max_history_entries: 50
  }

  @doc "The built-in defaults, keyed by limit name."
  def defaults, do: @defaults

  @doc """
  Returns the configured value for `key`, or its built-in default.

  Raises `FunctionClauseError` for an unsupported key.
  """
  def fetch!(key) when is_map_key(@defaults, key) do
    :mr_eric
    |> Application.get_env(:run_limits, [])
    |> Keyword.get(key, Map.fetch!(@defaults, key))
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/mr_eric/runs/limits_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Add the test-env overrides**

Append to `config/test.exs`:

```elixir
# Spec D run limits. The suite starts dozens of runs and, once reaping is in
# place, each finished worker holds its supervisor slot for the grace period.
# Raise the cap so no test is refused, and shorten the grace so workers do not
# accumulate for the whole run — while still leaving room for the
# post-completion `Runs.get_run/1` that `MrEric.Evals.Runner` performs.
config :mr_eric, :run_limits,
  max_concurrent_runs: 64,
  terminal_run_ttl_ms: 5_000
```

- [ ] **Step 6: Run the full suite to confirm nothing regressed**

Run: `mix test`
Expected: PASS. (Nothing reads `Limits` yet; this step only proves the config is well-formed.)

- [ ] **Step 7: Commit**

```bash
git add lib/mr_eric/runs/limits.ex test/mr_eric/runs/limits_test.exs config/test.exs
git commit -m "feat(spec-d): add the run limits contract"
```

---

## Task 2: Error vocabulary for the two new failures

Two commits — `Events` and `Errors` are separate modules with separate test files, and three files per commit is the ceiling.

**Files:**
- Modify: `lib/mr_eric/runs/events.ex` (add clauses next to the other atom clauses, around `events.ex:57-70`)
- Modify: `test/mr_eric/runs/events_test.exs`
- Modify: `lib/mr_eric/errors.ex` (`@classifications` at `errors.ex:6-19`, `classify/1`, `to_safe_message/1`)
- Modify: `test/mr_eric/errors_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `MrEric.Runs.Events.public_error(:too_many_runs)` and `public_error(:run_lifetime_exceeded)` return user-facing binaries. `MrEric.Errors.classify(:too_many_runs) == :run_limit_reached`, `MrEric.Errors.classify(:run_lifetime_exceeded) == :timeout`.

- [ ] **Step 1: Write the failing `Events` test**

Add to `test/mr_eric/runs/events_test.exs`:

```elixir
  test "public_error/1 explains a refused run without leaking OTP internals" do
    message = MrEric.Runs.Events.public_error(:too_many_runs)

    assert is_binary(message)
    assert message =~ "Too many runs"
    refute message =~ "max_children"
  end

  test "public_error/1 explains a run stopped at its absolute deadline" do
    message = MrEric.Runs.Events.public_error(:run_lifetime_exceeded)

    assert is_binary(message)
    assert message =~ "maximum lifetime"
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/mr_eric/runs/events_test.exs`
Expected: FAIL — the catch-all clause returns "The model request failed…", so both `=~` assertions fail.

- [ ] **Step 3: Implement**

In `lib/mr_eric/runs/events.ex`, directly after `def public_error(:rag_failed), do: "Project context lookup failed."`:

```elixir
  def public_error(:too_many_runs),
    do: "Too many runs are already in progress. Wait for one to finish, then try again."

  def public_error(:run_lifetime_exceeded),
    do: "The run exceeded its maximum lifetime and was stopped."
```

Placement matters: these are atom clauses and must sit above the `%{reason: reason}` / `{_kind, reason}` / catch-all clauses.

- [ ] **Step 4: Run it to verify it passes**

Run: `mix test test/mr_eric/runs/events_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/mr_eric/runs/events.ex test/mr_eric/runs/events_test.exs
git commit -m "feat(spec-d): add public messages for refused and over-lifetime runs"
```

- [ ] **Step 6: Write the failing `Errors` test**

Add to `test/mr_eric/errors_test.exs`:

```elixir
  test "classify/1 gives a refused run its own classification" do
    assert MrEric.Errors.classify(:too_many_runs) == :run_limit_reached
    assert :run_limit_reached in MrEric.Errors.classifications()
  end

  test "classify/1 treats an over-lifetime run as a timeout" do
    assert MrEric.Errors.classify(:run_lifetime_exceeded) == :timeout
  end

  test "to_safe_message/1 has a sentence for every classification" do
    for classification <- MrEric.Errors.classifications(), classification != :unknown do
      message = MrEric.Errors.to_safe_message(classification)
      assert is_binary(message) and message != ""
    end
  end
```

The third test is the one that matters: `to_safe_message/1` is a `case classify(reason) do` over the classification list, so adding a classification without a matching clause raises `CaseClauseError` at runtime. This test turns that into a compile-and-run failure now.

- [ ] **Step 7: Run it to verify it fails**

Run: `mix test test/mr_eric/errors_test.exs`
Expected: FAIL — `classify(:too_many_runs)` returns `:unknown`.

- [ ] **Step 8: Implement**

In `lib/mr_eric/errors.ex`:

1. Add `:run_limit_reached` to `@classifications` (after `:mcp_unavailable`).
2. Add two `classify/1` clauses, next to the other atom clauses:

```elixir
  def classify(:too_many_runs), do: :run_limit_reached
  def classify(:run_lifetime_exceeded), do: :timeout
```

3. Add the message clause inside `to_safe_message/1`'s `case`, after the `:mcp_unavailable` branch:

```elixir
      :run_limit_reached ->
        "Too many runs are already in progress."
```

- [ ] **Step 9: Run it to verify it passes**

Run: `mix test test/mr_eric/errors_test.exs`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/mr_eric/errors.ex test/mr_eric/errors_test.exs
git commit -m "feat(spec-d): classify a refused run as run_limit_reached"
```

---

## Task 3: Concurrency cap

**Files:**
- Modify: `lib/mr_eric/runs/run_supervisor.ex` (whole file)
- Modify: `lib/mr_eric/runs.ex` (`@internal_opts` at `runs.ex:11`, `start_run/3` at `runs.ex:15-37`)
- Modify: `test/mr_eric/runs_test.exs`

**Interfaces:**
- Consumes: `MrEric.Runs.Limits.fetch!(:max_concurrent_runs)` from Task 1.
- Produces: `RunSupervisor.start_link(name: atom(), max_children: pos_integer())`; `RunSupervisor.start_run(run, opts, supervisor \\ __MODULE__)`; `Runs.start_run/3` returns `{:error, :too_many_runs}` at the cap; `opts[:supervisor]` is an internal option consumed by `Runs.start_run/3` and never forwarded to the worker.

- [ ] **Step 1: Write the failing test**

Add to `test/mr_eric/runs_test.exs`. Put the stub module next to the existing `ToolLoopOrchestrator` at the top of the file:

```elixir
  defmodule IdleOrchestrator do
    @moduledoc false
    # Never emits a terminal event, so the run stays non-terminal and its
    # worker keeps holding its supervisor slot.
    def stream(_task, _pid, _opts), do: Process.sleep(:infinity)
  end
```

and the test itself:

```elixir
  test "start_run/3 refuses a run once the concurrency cap is reached" do
    sup_name = :"run_sup_#{System.unique_integer([:positive])}"
    start_supervised!({MrEric.Runs.RunSupervisor, name: sup_name, max_children: 1})

    opts = [
      orchestrator_module: IdleOrchestrator,
      supervisor: sup_name,
      skip_history: true
    ]

    assert {:ok, %Run{}} =
             Runs.start_run("first", "test-owner", opts ++ [id: unique_run_id()])

    assert {:error, :too_many_runs} =
             Runs.start_run("second", "test-owner", opts ++ [id: unique_run_id()])
  end

  test "start_run/3 does not forward the :supervisor option to the worker" do
    sup_name = :"run_sup_#{System.unique_integer([:positive])}"
    start_supervised!({MrEric.Runs.RunSupervisor, name: sup_name, max_children: 1})
    run_id = unique_run_id()

    assert {:ok, %Run{}} =
             Runs.start_run("only", "test-owner",
               orchestrator_module: IdleOrchestrator,
               supervisor: sup_name,
               skip_history: true,
               id: run_id
             )

    state = :sys.get_state(RunWorker.test_pid(run_id))
    refute Keyword.has_key?(state.opts, :supervisor)
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/mr_eric/runs_test.exs`
Expected: FAIL — `RunSupervisor.start_link/1` does not accept `:name`/`:max_children`, and `start_run/2` has the wrong arity.

- [ ] **Step 3: Implement the supervisor**

Replace `lib/mr_eric/runs/run_supervisor.ex` with:

```elixir
defmodule MrEric.Runs.RunSupervisor do
  @moduledoc """
  DynamicSupervisor for one RunWorker per collaborative run.

  `max_children` caps how many run workers may exist at once (Spec D).
  `DynamicSupervisor.start_child/2` returns `{:error, :max_children}` at the
  cap; `MrEric.Runs.start_run/3` translates that into the domain error
  `{:error, :too_many_runs}`.

  The cap counts *workers*, not streaming runs: a finished run keeps its slot
  until `RunWorker` reaps itself after `terminal_run_ttl_ms`.
  """

  use DynamicSupervisor

  alias MrEric.Runs.Limits
  alias MrEric.Runs.RunWorker

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  def start_run(run, opts, supervisor \\ __MODULE__) do
    DynamicSupervisor.start_child(supervisor, {RunWorker, run: run, opts: opts})
  end

  @impl true
  def init(opts) do
    max_children = Keyword.get(opts, :max_children, Limits.fetch!(:max_concurrent_runs))

    DynamicSupervisor.init(strategy: :one_for_one, max_children: max_children)
  end
end
```

`Keyword.get/3` with a default is correct here — `:max_children` is an explicit caller-supplied seam, and its fallback is `Limits.fetch!/1`, which itself cannot fall open.

- [ ] **Step 4: Implement the error mapping**

In `lib/mr_eric/runs.ex`, widen the internal options and map the cap error:

```elixir
  @internal_opts [:subscribe, :supervisor]
```

and inside `start_run/3`, replace the supervisor call block with:

```elixir
      supervisor = Keyword.get(opts, :supervisor, RunSupervisor)
      worker_opts = Keyword.drop(opts, @internal_opts)

      case RunSupervisor.start_run(run, worker_opts, supervisor) do
        {:ok, _pid} -> {:ok, run}
        {:error, :max_children} -> {:error, :too_many_runs}
        {:error, {:already_started, _pid}} -> {:error, :already_started}
        {:error, reason} -> {:error, reason}
      end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/mr_eric/runs_test.exs`
Expected: PASS.

- [ ] **Step 6: Run the whole suite**

Run: `mix test`
Expected: PASS. `AgentLive` needs no change — `agent_live.ex:468` already renders `{:error, reason}` from `start_run/3` through a blank run's `run_failed`, which resolves via `Events.public_error/1` (Task 2).

- [ ] **Step 7: Commit**

```bash
git add lib/mr_eric/runs/run_supervisor.ex lib/mr_eric/runs.ex test/mr_eric/runs_test.exs
git commit -m "feat(spec-d): cap concurrent runs with max_children"
```

---

## Task 4: Reap terminal workers

**Files:**
- Modify: `lib/mr_eric/runs/run_worker.ex` (`init/1`, `handle_continue(:start, …)`, the cancel call, the `@run_events` clause, the `:DOWN` clause at `run_worker.ex:340`, `broadcast_and_apply/3`)
- Modify: `lib/mr_eric/evals/runner.ex` (`run_opts` at `runner.ex:38-53`)
- Create: `test/mr_eric/runs/run_worker_lifetime_test.exs`

**Interfaces:**
- Consumes: `MrEric.Runs.Limits.fetch!(:terminal_run_ttl_ms)`; `RunSupervisor.start_link(name:, max_children:)` and `Runs.start_run/3`'s `:supervisor` option from Task 3.
- Produces: worker state gains `reap_scheduled?: boolean()`; the worker accepts `opts[:terminal_run_ttl_ms]` as a per-run override; a worker whose run is terminal exits with reason `:normal`.

- [ ] **Step 1: Write the failing tests**

Create `test/mr_eric/runs/run_worker_lifetime_test.exs`:

```elixir
defmodule MrEric.Runs.RunWorkerLifetimeTest do
  use ExUnit.Case, async: false

  alias MrEric.Runs
  alias MrEric.Runs.Run
  alias MrEric.Runs.RunSupervisor
  alias MrEric.Runs.RunWorker

  defmodule IdleOrchestrator do
    @moduledoc false
    def stream(_task, _pid, _opts), do: Process.sleep(:infinity)
  end

  defp start_worker(opts) do
    run =
      Run.new("lifetime",
        owner_id: "lifetime-owner",
        id: "run-life-#{System.unique_integer([:positive])}"
      )

    {:ok, pid} =
      RunWorker.start_link(run: run, opts: opts, auto_start: false, name: nil)

    {run, pid}
  end

  @reap_opts [terminal_run_ttl_ms: 30, skip_history: true]

  test "stops the worker after a completed run's grace period" do
    {_run, pid} = start_worker(@reap_opts)
    ref = Process.monitor(pid)

    send(pid, {:run_completed, %{final: "done"}})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "stops the worker after a failed run's grace period" do
    {_run, pid} = start_worker(@reap_opts)
    ref = Process.monitor(pid)

    send(pid, {:run_failed, %{error: :boom}})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "stops the worker after a cancelled run's grace period" do
    {_run, pid} = start_worker(@reap_opts)
    ref = Process.monitor(pid)

    assert :ok = RunWorker.cancel(pid, "lifetime-owner")

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "never reaps a run that has not reached a terminal status" do
    {_run, pid} = start_worker(@reap_opts)
    ref = Process.monitor(pid)

    send(pid, {:stage_completed, %{role: :planner, content: "partial"}})

    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 300
    assert Process.alive?(pid)
  end

  test "schedules the stop exactly once, even when late events arrive" do
    {_run, pid} = start_worker(terminal_run_ttl_ms: 5_000, skip_history: true)

    send(pid, {:run_completed, %{final: "done"}})
    send(pid, {:tool_completed, %{tool: :file_read, tool_call_id: "late", result: %{}}})

    state = :sys.get_state(pid)
    assert state.reap_scheduled?
    assert Run.terminal?(state.run)
    assert Process.alive?(pid)
  end

  test "records history before the worker exits" do
    agent_name = :"history_agent_#{System.unique_integer([:positive])}"
    start_supervised!({MrEric.Agent, name: agent_name})

    {_run, pid} =
      start_worker(terminal_run_ttl_ms: 30, agent_server: agent_name)

    ref = Process.monitor(pid)
    send(pid, {:run_completed, %{final: "recorded"}})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert [%{final: "recorded"}] = MrEric.Agent.history(agent_name)
  end

  test "releases the supervisor slot for the next run" do
    sup_name = :"run_sup_life_#{System.unique_integer([:positive])}"
    start_supervised!({RunSupervisor, name: sup_name, max_children: 1})

    opts = [
      orchestrator_module: IdleOrchestrator,
      supervisor: sup_name,
      skip_history: true,
      terminal_run_ttl_ms: 30
    ]

    first_id = "run-slot-#{System.unique_integer([:positive])}"
    assert {:ok, _run} = Runs.start_run("first", "lifetime-owner", opts ++ [id: first_id])

    assert {:error, :too_many_runs} =
             Runs.start_run("second", "lifetime-owner",
               opts ++ [id: "run-slot-#{System.unique_integer([:positive])}"]
             )

    pid = RunWorker.test_pid(first_id)
    ref = Process.monitor(pid)
    assert :ok = Runs.cancel_run(first_id, "lifetime-owner")
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    assert {:ok, _run} =
             Runs.start_run("third", "lifetime-owner",
               opts ++ [id: "run-slot-#{System.unique_integer([:positive])}"]
             )
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `mix test test/mr_eric/runs/run_worker_lifetime_test.exs`
Expected: FAIL — no `:DOWN` message arrives (the worker never stops), and `:sys.get_state(pid).reap_scheduled?` raises `KeyError`.

- [ ] **Step 3: Add the reap machinery to `RunWorker`**

In `lib/mr_eric/runs/run_worker.ex`:

1. Alias the limits module next to the existing aliases:

```elixir
  alias MrEric.Runs.Limits
```

2. Add `reap_scheduled?: false` to the state map built in `init/1`:

```elixir
    state = %{
      run: run,
      opts: worker_opts,
      task: nil,
      cancelled?: false,
      history_recorded?: false,
      reap_scheduled?: false,
      pending_tool_approvals: %{}
    }
```

3. Add the private helpers (put them next to `shutdown_task/1`):

```elixir
  # Every write of state.run goes through here, so "terminal implies a
  # scheduled stop" holds by construction rather than by remembering to call
  # the scheduler at each of the four terminal sites.
  defp put_run(state, %Run{} = run) do
    state
    |> Map.put(:run, run)
    |> maybe_schedule_reap()
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

  defp reap_ttl(state) do
    Keyword.get(state.opts, :terminal_run_ttl_ms, Limits.fetch!(:terminal_run_ttl_ms))
  end
```

4. Add the handler. Put it directly above `handle_info({ref, _result}, %{task: %{ref: ref}} = state)`:

```elixir
  @impl true
  def handle_info(:reap, state) do
    if Run.terminal?(state.run) do
      # The task is normally already finished; shutting it down defensively
      # keeps a stray orchestrator Task from outliving its worker, since a
      # :normal exit does not take linked processes with it.
      shutdown_task(state.task)
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end
```

5. Route every `state.run` write through `put_run/2`. There are five sites:

```elixir
  # handle_continue(:start, state)
    {:noreply, state |> put_run(run) |> Map.put(:task, task)}
```

```elixir
  # handle_call({:cancel, owner_id}, ...) — inside the {:ok, _} branch
            state =
              state
              |> put_run(run)
              |> Map.put(:task, nil)
              |> Map.put(:cancelled?, true)
              |> maybe_resolve_pending_tool_approvals(:run_cancelled)
```

```elixir
  # handle_info({event, payload}, state) when event in @run_events
      state =
        state
        |> put_run(run)
        |> maybe_resolve_pending_tool_approvals(event)
```

```elixir
  # handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state)
          state =
            state
            |> put_run(run)
            |> Map.put(:task, nil)
            |> maybe_resolve_pending_tool_approvals(:run_failed)
```

```elixir
  # broadcast_and_apply/3
  defp broadcast_and_apply(state, event, payload) do
    {event, payload} = Events.normalize_event(state.run.id, {event, payload})
    run = Run.apply_event(state.run, {event, payload})
    Events.broadcast(run.id, {event, payload})
    put_run(state, run)
  end
```

- [ ] **Step 4: Verify no assignment site was missed**

Run: `grep -nE 'run: run|Map\.put\(:run' lib/mr_eric/runs/run_worker.ex`
Expected: exactly two hits — `run: run` in `init/1`'s initial state map, and `Map.put(:run, run)` inside `put_run/2`. Any other hit is a site that writes `state.run` without scheduling a reap; fix it before continuing.

- [ ] **Step 5: Run the lifetime tests**

Run: `mix test test/mr_eric/runs/run_worker_lifetime_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 6: Keep the eval harness independent of worker lifetime**

In `lib/mr_eric/evals/runner.ex`, add one option to the `run_opts` keyword list, next to `skip_history: true`:

```elixir
          skip_history: true,
          # Spec D: evals read the run immediately after `run_completed`, so
          # the worker can go straight away. `mix mr_eric.evals` runs in :dev,
          # where the default grace is a minute — long enough for a batch of
          # cases to exhaust the run pool.
          terminal_run_ttl_ms: 1_000,
```

- [ ] **Step 7: Run the full suite and the evals**

Run: `mix test`
Expected: PASS.

Run: `mix mr_eric.evals`
Expected: PASS, all golden cases, with `git status --short priv/evals/` clean.

- [ ] **Step 8: Commit**

```bash
git add lib/mr_eric/runs/run_worker.ex lib/mr_eric/evals/runner.ex test/mr_eric/runs/run_worker_lifetime_test.exs
git commit -m "feat(spec-d): stop run workers once their run is terminal"
```

---

## Task 5: Absolute deadline

**Files:**
- Modify: `lib/mr_eric/orchestrator.ex` (publish the default budgets; `@default_tool_limits` is at `orchestrator.ex:11-17`)
- Modify: `lib/mr_eric/runs/run_worker.ex` (`init/1` and a new `handle_info(:hard_deadline, …)`)
- Modify: `test/mr_eric/runs/run_worker_lifetime_test.exs`

**Interfaces:**
- Consumes: `put_run/2`, `reap_ttl/1`, `shutdown_task/1` from Task 4; `Limits.fetch!(:hard_deadline_grace_ms)` from Task 1.
- Produces: `MrEric.Orchestrator.default_tool_limits/0 :: map()` with keys `:max_tool_calls_per_run`, `:max_tool_calls_per_role`, `:max_total_runtime_ms`, `:max_context_chars`, `:max_tool_output_chars`. The worker accepts `opts[:hard_deadline_grace_ms]` as a per-run override.

- [ ] **Step 1: Write the failing tests**

Add to `test/mr_eric/runs/run_worker_lifetime_test.exs`:

```elixir
  test "terminalises a run that never finishes, at the absolute deadline" do
    run_id = "run-deadline-#{System.unique_integer([:positive])}"
    run = Run.new("stuck", owner_id: "lifetime-owner", id: run_id)

    :ok = Runs.subscribe(run_id)

    {:ok, pid} =
      RunWorker.start_link(
        run: run,
        opts: [
          orchestrator_module: IdleOrchestrator,
          max_total_runtime_ms: 20,
          hard_deadline_grace_ms: 10,
          terminal_run_ttl_ms: 5_000,
          skip_history: true
        ],
        auto_start: true,
        name: nil
      )

    assert_receive {:run_failed, %{run_id: ^run_id, error: message}}, 1_000
    assert message =~ "maximum lifetime"

    assert {:ok, %Run{status: :failed}} = RunWorker.get_run(pid)
  end

  test "the deadline is inert once the run has already finished" do
    run_id = "run-deadline-ok-#{System.unique_integer([:positive])}"
    run = Run.new("quick", owner_id: "lifetime-owner", id: run_id)

    :ok = Runs.subscribe(run_id)

    {:ok, pid} =
      RunWorker.start_link(
        run: run,
        opts: [
          max_total_runtime_ms: 20,
          hard_deadline_grace_ms: 10,
          terminal_run_ttl_ms: 5_000,
          skip_history: true
        ],
        auto_start: false,
        name: nil
      )

    send(pid, {:run_completed, %{final: "fast"}})
    assert_receive {:run_completed, %{run_id: ^run_id}}, 1_000

    refute_receive {:run_failed, %{run_id: ^run_id}}, 300
    assert {:ok, %Run{status: :completed}} = RunWorker.get_run(pid)
  end

  test "a hard-deadline failure also releases the supervisor slot" do
    sup_name = :"run_sup_deadline_#{System.unique_integer([:positive])}"
    start_supervised!({RunSupervisor, name: sup_name, max_children: 1})

    opts = [
      orchestrator_module: IdleOrchestrator,
      supervisor: sup_name,
      skip_history: true,
      max_total_runtime_ms: 20,
      hard_deadline_grace_ms: 10,
      terminal_run_ttl_ms: 30
    ]

    first_id = "run-deadline-slot-#{System.unique_integer([:positive])}"
    assert {:ok, _run} = Runs.start_run("stuck", "lifetime-owner", opts ++ [id: first_id])

    pid = RunWorker.test_pid(first_id)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    assert {:ok, _run} =
             Runs.start_run("next", "lifetime-owner",
               opts ++ [id: "run-deadline-slot-#{System.unique_integer([:positive])}"]
             )
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `mix test test/mr_eric/runs/run_worker_lifetime_test.exs`
Expected: FAIL on the first and third tests — no `run_failed` ever arrives, because nothing arms a deadline.

- [ ] **Step 3: Publish the orchestrator's default budgets**

In `lib/mr_eric/orchestrator.ex`, directly below the `@default_tool_limits` attribute:

```elixir
  @doc """
  The default per-run tool budgets.

  Public so `MrEric.Runs.RunWorker` can derive its absolute deadline from
  `max_total_runtime_ms` instead of keeping a second copy of the number.
  """
  def default_tool_limits, do: @default_tool_limits
```

- [ ] **Step 4: Arm the deadline in `RunWorker.init/1`**

In `init/1`, after `worker_opts` is bound and before the `state` map is built:

```elixir
    Process.send_after(self(), :hard_deadline, hard_deadline_ms(worker_opts))
```

and add the helper next to `reap_ttl/1`:

```elixir
  # The absolute ceiling on a worker's life: the orchestrator's own runtime
  # budget plus a grace period. With a finite supervisor pool, a worker that
  # never terminalises is not a slow leak — it is one slot of the pool, gone
  # for good.
  defp hard_deadline_ms(opts) do
    max_total_runtime_ms =
      Keyword.get(
        opts,
        :max_total_runtime_ms,
        Orchestrator.default_tool_limits().max_total_runtime_ms
      )

    grace =
      Keyword.get(opts, :hard_deadline_grace_ms, Limits.fetch!(:hard_deadline_grace_ms))

    max_total_runtime_ms + grace
  end
```

`Orchestrator` is already aliased in `RunWorker`.

- [ ] **Step 5: Handle the deadline**

Add directly below `handle_info(:reap, state)`:

```elixir
  @impl true
  def handle_info(:hard_deadline, state) do
    if Run.terminal?(state.run) do
      # The reap timer owns the stop from here.
      {:noreply, state}
    else
      shutdown_task(state.task)

      {event, payload} =
        Events.normalize_event(state.run.id, {:run_failed, %{error: :run_lifetime_exceeded}})

      run = Run.apply_event(state.run, {event, payload})

      state =
        state
        |> put_run(run)
        |> Map.put(:task, nil)
        |> maybe_resolve_pending_tool_approvals(:run_failed)

      Events.broadcast(run.id, {event, payload})

      {:noreply, state}
    end
  end
```

This deliberately reuses the existing terminal machinery: normalize → apply → `put_run/2` (which schedules the reap) → broadcast. No new event name, no new status.

- [ ] **Step 6: Run the lifetime tests**

Run: `mix test test/mr_eric/runs/run_worker_lifetime_test.exs`
Expected: PASS (10 tests).

- [ ] **Step 7: Run the full suite and the evals**

Run: `mix test`
Expected: PASS. Manually-constructed workers in `runs_test.exs` use `auto_start: false` and finish in milliseconds, so the 240 s default deadline never fires for them.

Run: `mix mr_eric.evals`
Expected: PASS. Eval runs set `max_total_runtime_ms: 1_500`, so their deadline is 61.5 s — far beyond the case timeout.

- [ ] **Step 8: Commit**

```bash
git add lib/mr_eric/orchestrator.ex lib/mr_eric/runs/run_worker.ex test/mr_eric/runs/run_worker_lifetime_test.exs
git commit -m "feat(spec-d): bound every run worker by an absolute deadline"
```

---

## Task 6: Trace bounds

**Files:**
- Modify: `lib/mr_eric/runs/trace.ex` (`defstruct` at `trace.ex:8-21`, `record/3` at `trace.ex:36-52`, `summary/1` at `trace.ex:54-68`, `event_counts/1`)
- Modify: `test/mr_eric/runs/trace_test.exs`
- Modify: `test/mr_eric/evals/secret_checker_test.exs`

**Interfaces:**
- Consumes: `MrEric.Runs.Limits.fetch!(:max_trace_entries)` from Task 1.
- Produces: `%Trace{}` gains `chunk_counts: %{atom() => pos_integer()}` and `dropped_entries: non_neg_integer()`. `Trace.summary/1` gains `:dropped_entries` and `:truncated?`. `Trace.record/3` and `Trace.events/1` keep their existing signatures and semantics.

- [ ] **Step 1: Write the failing tests**

Add to `test/mr_eric/runs/trace_test.exs`:

```elixir
  test "folds repeated stage chunks into one entry per role and counts the rest" do
    trace =
      Enum.reduce(1..1_000, Trace.new("run-fold", "task", :ollama, "m"), fn n, acc ->
        Trace.record(acc, :stage_chunk, %{role: :planner, chunk: "chunk #{n}"})
      end)

    chunk_entries = Enum.filter(trace.entries, &(&1.event == :stage_chunk))

    assert length(chunk_entries) == 1
    assert Trace.summary(trace).event_counts[:stage_chunk] == 1_000
    assert :stage_chunk in Trace.events(trace)
  end

  test "never keeps the streamed chunk text, which already lives in the stage" do
    trace =
      Trace.new("run-nochunk", "task", :ollama, "m")
      |> Trace.record(:stage_chunk, %{role: :planner, chunk: "secret-looking text"})

    [entry] = Enum.filter(trace.entries, &(&1.event == :stage_chunk))

    refute Map.has_key?(entry.payload, :chunk)
    assert entry.payload.role == :planner
  end

  test "counts chunks per role" do
    trace =
      Trace.new("run-roles", "task", :ollama, "m")
      |> Trace.record(:stage_chunk, %{role: :planner, chunk: "a"})
      |> Trace.record(:stage_chunk, %{role: :planner, chunk: "b"})
      |> Trace.record(:stage_chunk, %{role: :critic, chunk: "c"})

    chunk_entries = Enum.filter(trace.entries, &(&1.event == :stage_chunk))

    assert length(chunk_entries) == 2
    assert trace.chunk_counts == %{planner: 2, critic: 1}
    assert Trace.summary(trace).event_counts[:stage_chunk] == 3
  end

  test "caps entries and reports how many were dropped" do
    max = MrEric.Runs.Limits.fetch!(:max_trace_entries)

    trace =
      Enum.reduce(1..(max + 25), Trace.new("run-cap", "task", :ollama, "m"), fn n, acc ->
        Trace.record(acc, :stage_started, %{role: :planner, name: "agent-#{n}"})
      end)

    assert length(trace.entries) == max
    assert trace.dropped_entries == 25

    summary = Trace.summary(trace)
    assert summary.dropped_entries == 25
    assert summary.truncated?
  end

  test "an untruncated trace reports no drops" do
    trace =
      Trace.new("run-nodrop", "task", :ollama, "m")
      |> Trace.record(:run_started, %{task: "task"})
      |> Trace.record(:run_completed, %{final: "done"})

    summary = Trace.summary(trace)

    assert summary.dropped_entries == 0
    refute summary.truncated?
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `mix test test/mr_eric/runs/trace_test.exs`
Expected: FAIL — 1_000 chunk entries are retained, `trace.chunk_counts` raises `KeyError`, and `summary/1` has no `:dropped_entries`.

- [ ] **Step 3: Implement**

In `lib/mr_eric/runs/trace.ex`:

1. Alias the limits module below the existing `alias MrEric.Errors`:

```elixir
  alias MrEric.Runs.Limits
```

2. Extend the struct — add the two fields alongside `metadata` and `entries`:

```elixir
    metadata: %{},
    chunk_counts: %{},
    dropped_entries: 0,
    entries: []
```

3. Add the folding clause. It must sit **after** `record(nil, event, payload)` and **before** the general `record(%__MODULE__{} = trace, event, payload)` clause:

```elixir
  # `stage_chunk` carries the streamed text, which `Run.stages[role].content`
  # already accumulates. Keep one entry per role so the event still shows up in
  # `events/1` and in golden `expected_events`, drop the duplicated body, and
  # count the rest.
  def record(%__MODULE__{} = trace, :stage_chunk, payload) do
    payload = Errors.redact(payload)
    role = Map.get(payload, :role)

    if Map.has_key?(trace.chunk_counts, role) do
      Map.update!(trace, :chunk_counts, &Map.update!(&1, role, fn count -> count + 1 end))
    else
      entry = %{
        event: :stage_chunk,
        payload: Map.delete(payload, :chunk),
        occurred_at: DateTime.utc_now(),
        error_classification: nil
      }

      trace
      |> Map.update!(:chunk_counts, &Map.put(&1, role, 1))
      |> append_entry(entry)
    end
  end
```

4. Route the general clause through `append_entry/2` — replace `|> Map.update!(:entries, &(&1 ++ [entry]))` with `|> append_entry(entry)`, and add:

```elixir
  # `entries ++ [entry]` is O(n), but the cap keeps n at or below
  # `max_trace_entries`, which makes the whole run's cost irrelevant. Keeping
  # the list in chronological order matters more: `MrEric.Evals.Scorer` reads
  # `%Trace{entries: ...}` directly.
  defp append_entry(trace, entry) do
    max = Limits.fetch!(:max_trace_entries)
    entries = trace.entries ++ [entry]
    overflow = length(entries) - max

    if overflow > 0 do
      %{
        trace
        | entries: Enum.drop(entries, overflow),
          dropped_entries: trace.dropped_entries + overflow
      }
    else
      %{trace | entries: entries}
    end
  end
```

5. Report the drops in `summary/1` — add two keys to the returned map:

```elixir
      dropped_entries: trace.dropped_entries,
      truncated?: trace.dropped_entries > 0,
```

6. Make `event_counts/1` tell the truth about folded chunks:

```elixir
  defp event_counts(trace) do
    counts =
      trace.entries
      |> Enum.frequencies_by(& &1.event)
      |> Map.new()

    case trace.chunk_counts |> Map.values() |> Enum.sum() do
      0 -> counts
      total -> Map.put(counts, :stage_chunk, total)
    end
  end
```

`chunk_counts` holds the true total per role — including the chunk whose entry was kept — so the folded total *replaces* the entry-derived count rather than adding to it.

- [ ] **Step 4: Run the trace tests**

Run: `mix test test/mr_eric/runs/trace_test.exs`
Expected: PASS.

- [ ] **Step 5: Prove the leak-detection surface did not shrink**

Folding removes chunk bodies from the trace, so pin down that the checker still sees streamed text through the stage maps. Add to `test/mr_eric/evals/secret_checker_test.exs`:

```elixir
  test "a secret streamed into a stage is caught through the stage, not the trace" do
    actual = %{
      trace: MrEric.Runs.Trace.new("run-leak", "task", :ollama, "m"),
      drafts: [
        %{status: :completed, content: "OPENAI_API_KEY=sk-abcdefghijklmno", error: nil}
      ]
    }

    assert %MrEric.Evals.SecretChecker.Result{status: :leak} =
             MrEric.Evals.SecretChecker.scan(actual)
  end
```

`scan/1` returning `%SecretChecker.Result{status: :clean | :leak}` is the shape `MrEric.Evals.Scorer` itself consumes (`scorer.ex:87-89`). `MrEric.Evals.Runner` hands the checker `drafts` and `reviews` alongside the trace (`runner.ex:64-77`), which is why folding costs no coverage.

Run: `mix test test/mr_eric/evals/secret_checker_test.exs`
Expected: PASS.

- [ ] **Step 6: Run the full suite and the evals**

Run: `mix test`
Expected: PASS.

Run: `mix mr_eric.evals`
Expected: PASS with `priv/evals/phase9_golden_cases.json` unmodified. None of the six golden cases lists `stage_chunk` in `expected_events`, and folding keeps it available for any that later do.

- [ ] **Step 7: Commit**

```bash
git add lib/mr_eric/runs/trace.ex test/mr_eric/runs/trace_test.exs test/mr_eric/evals/secret_checker_test.exs
git commit -m "feat(spec-d): bound trace memory by folding chunks and capping entries"
```

---

## Task 7: History bounds

Two commits — the server-side cap and the LiveView mirror have separate test files.

**Files:**
- Modify: `lib/mr_eric/agent.ex` (`start_link/1` at `agent.ex:16-27`, `handle_call({:record, entry}, …)` at `agent.ex:57-61`, `handle_info({ref, result}, …)` at `agent.ex:84-92`)
- Create: `test/mr_eric/agent_test.exs`
- Modify: `lib/mr_eric_web/live/agent_live.ex` (`mount/3` at `agent_live.ex:40`, `maybe_insert_history/3` at `agent_live.ex:614-616`)
- Modify: `test/mr_eric_web/live/agent_live_test.exs`

**Interfaces:**
- Consumes: `MrEric.Runs.Limits.fetch!(:max_history_entries)` from Task 1.
- Produces: `MrEric.Agent.start_link(max_history: pos_integer())`; `MrEric.Agent.history/1` still returns newest-first and now never exceeds the limit.

- [ ] **Step 1: Write the failing test**

Create `test/mr_eric/agent_test.exs`:

```elixir
defmodule MrEric.AgentTest do
  use ExUnit.Case, async: false

  alias MrEric.Agent

  defp start_agent(opts) do
    name = :"agent_#{System.unique_integer([:positive])}"
    start_supervised!({Agent, Keyword.put(opts, :name, name)})
    name
  end

  test "keeps only the newest max_history entries" do
    name = start_agent(max_history: 3)

    for n <- 1..10 do
      {:ok, _entry} = Agent.record(%{id: n, final: "run #{n}"}, server: name)
    end

    history = Agent.history(name)

    assert length(history) == 3
    assert Enum.map(history, & &1.id) == [10, 9, 8]
  end

  test "defaults to the configured run limit" do
    name = start_agent([])
    limit = MrEric.Runs.Limits.fetch!(:max_history_entries)

    for n <- 1..(limit + 5) do
      {:ok, _entry} = Agent.record(%{id: n, final: "run #{n}"}, server: name)
    end

    assert length(Agent.history(name)) == limit
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/mr_eric/agent_test.exs`
Expected: FAIL — history has 10 entries, not 3.

- [ ] **Step 3: Implement**

In `lib/mr_eric/agent.ex`:

1. Alias the limits module below `alias MrEric.Orchestrator`:

```elixir
  alias MrEric.Runs.Limits
```

2. Read the limit in `start_link/1` and put it in the initial state:

```elixir
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    task_supervisor = Keyword.get(opts, :task_supervisor, @default_task_supervisor)
    max_history = Keyword.get(opts, :max_history, Limits.fetch!(:max_history_entries))

    GenServer.start_link(
      __MODULE__,
      %{history: [], task_supervisor: task_supervisor, pending: %{}, max_history: max_history},
      name: name
    )
  end
```

3. Truncate on **both** insert paths. In `handle_call({:record, entry}, …)`:

```elixir
    history = [entry | state.history] |> Enum.take(state.max_history)
```

and in the `handle_info({ref, result}, …)` `{:ok, run_result}` branch:

```elixir
            history = [entry | state.history] |> Enum.take(state.max_history)
```

`Enum.take/2` on a newest-first list keeps the newest N, which is exactly the panel's order — `history/1`'s contract is unchanged.

- [ ] **Step 4: Run it to verify it passes**

Run: `mix test test/mr_eric/agent_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/mr_eric/agent.ex test/mr_eric/agent_test.exs
git commit -m "feat(spec-d): bound the completed-run history"
```

- [ ] **Step 6: Write the failing LiveView test**

Add to `test/mr_eric_web/live/agent_live_test.exs`:

```elixir
  test "the history panel keeps at most max_history_entries cards", %{conn: conn} do
    limit = MrEric.Runs.Limits.fetch!(:max_history_entries)

    for n <- 1..(limit + 5) do
      entry =
        "history task #{n}"
        |> MrEric.Runs.Run.new(owner_id: "history-owner", id: "h#{n}")
        |> MrEric.Runs.Run.to_history_entry()

      {:ok, _entry} = MrEric.Agent.record(entry)
    end

    {:ok, _view, html} = live(conn, "/")

    # Stream dom ids are "history-<entry.id>", so "history-h<n>" matches a card
    # and nothing else — not "history-empty", not "history-changed-files-…".
    card_count = length(Regex.scan(~r/id="history-h\d+"/, html))

    assert card_count <= limit
  end
```

Three things this test depends on, all deliberate: `Run.to_history_entry/1` fills every field the card template reads (notably `inserted_at`, which `Calendar.strftime/2` needs); the entry ids are `h1`…`hN` so the dom-id regex is unambiguous; and there is no Floki in this project — LiveView 1.1 uses LazyHTML — so the count is a regex over the rendered HTML rather than a document query.

`AgentLive.mount/3` reads the global `MrEric.Agent`, so this test uses it directly rather than an isolated server. `MrEricWeb.ConnCase` is not async, and no other test asserts on history contents, so the recorded entries do not leak into another test's expectations.

- [ ] **Step 7: Run it and read the result honestly**

Run: `mix test test/mr_eric_web/live/agent_live_test.exs`
Expected: PASS — **this is not a red step.** The server-side cap from Step 3 already keeps `Agent.history/1` at the limit, so the mount path is bounded before the LiveView changes at all. The test is a regression lock on the panel size, not a driver for Step 8.

Step 8 bounds a case the suite cannot cheaply reach: a socket that stays open across more than `max_history_entries` completions accumulates a `stream_insert` per completion, and those DOM nodes are never pruned by the server-side cap. Driving that would mean starting dozens of real runs through the form. The change is small, defensive, and verified by reading plus the regression lock above — say so rather than inventing a failing test for it.

- [ ] **Step 8: Bound the stream**

In `lib/mr_eric_web/live/agent_live.ex`:

1. Alias the limits module with the other aliases:

```elixir
  alias MrEric.Runs.Limits
```

2. In `mount/3`, replace the stream call:

```elixir
     |> stream(:history, Agent.history(), at: 0, limit: Limits.fetch!(:max_history_entries))}
```

3. In `maybe_insert_history/3`:

```elixir
  defp maybe_insert_history(socket, :run_completed, run) do
    stream_insert(socket, :history, Run.to_history_entry(run),
      at: 0,
      limit: Limits.fetch!(:max_history_entries)
    )
  end
```

A **positive** limit with `at: 0` is what LiveView documents for "keep the first N while prepending" (`deps/phoenix_live_view/lib/phoenix_live_view.ex:1729-1732`); `stream/4`'s limit does not carry over to `stream_insert/4`, so it must be passed at both sites.

- [ ] **Step 9: Run the LiveView tests**

Run: `mix test test/mr_eric_web/live/agent_live_test.exs`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/mr_eric_web/live/agent_live.ex test/mr_eric_web/live/agent_live_test.exs
git commit -m "feat(spec-d): bound the LiveView history stream"
```

---

## Task 8: Documentation sync

**Files:**
- Modify: `docs/superpowers/README.md`
- Modify: `CLAUDE.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing code-facing.

- [ ] **Step 1: Update the audit progress table**

In `docs/superpowers/README.md`, replace the Spec D row with:

```markdown
| D | Run 寿命と資源（`max_children`、worker の回収と絶対期限、trace / 履歴上限） | **Implemented**（2026-08-27, `main`） | [spec](./specs/2026-08-27-run-lifetime-design.md) · [plan](./plans/2026-08-27-run-lifetime.md) |
```

and replace the "次にやる作業" section with:

```markdown
## 次にやる作業

**Spec E** が次です。Spec D で run の同時実行数・worker 寿命・trace / 履歴の上限が閉じたので、
承認ゲートの後ろに残る運用面の穴はありません。残りは eval / RAG の正しさ（scorer の early-pass、
RAG キャッシュ、`rag_default_index` golden case）です。

Spec A から先送りされた `rag_default_index` golden case は Spec E の所有です。
```

- [ ] **Step 2: Record the contract in `CLAUDE.md`**

Add to the "Run lifecycle" section:

```markdown
- **Run limits are one contract.** `MrEric.Runs.Limits` owns `max_concurrent_runs`,
  `terminal_run_ttl_ms`, `hard_deadline_grace_ms`, `max_trace_entries`, and
  `max_history_entries`; `@defaults` in that module is the only place a default is
  written, and `config :mr_eric, :run_limits` is override-only. `fetch!/1` raises on an
  unknown key — never give a limit lookup a silent default.
- `RunSupervisor` caps concurrent workers with `max_children`; `Runs.start_run/3` returns
  `{:error, :too_many_runs}` at the cap. `RunWorker` stops itself `terminal_run_ttl_ms`
  after its run becomes terminal (every write of `state.run` goes through `put_run/2`, so
  "terminal implies scheduled stop" holds by construction), and terminalises itself with
  `:run_lifetime_exceeded` at `max_total_runtime_ms + hard_deadline_grace_ms` no matter
  what. `Trace` folds `stage_chunk` into per-role counters — the chunk body already lives
  in `Run.stages[role].content` — and caps `entries`, reporting overflow as
  `dropped_entries`.
```

- [ ] **Step 3: Add the changelog entry**

In `CHANGELOG.md`, add this as the first bullet under `## [Unreleased]` → `### Added`, and update the "監査由来のセキュリティ hardening は Spec A–C と Spec C-1 まで…" paragraph to say Spec A–D は `main` に入っている / 残りは Spec E–F です:

```markdown
- run 寿命と資源上限を追加（Spec D、2026-08-27）。
  - `MrEric.Runs.Limits` が `max_concurrent_runs` / `terminal_run_ttl_ms` /
    `hard_deadline_grace_ms` / `max_trace_entries` / `max_history_entries` を所有。
    既定値はこのモジュールの `@defaults` のみに書き、`config :mr_eric, :run_limits` は上書き専用。
    未知キーは `fetch!/1` が例外にする。
  - `RunSupervisor` に `max_children` を設定し、上限到達時は `MrEric.Runs.start_run/3` が
    `{:error, :too_many_runs}` を返す。
  - `RunWorker` は terminal 到達から `terminal_run_ttl_ms` 後に自身を停止し、
    `max_total_runtime_ms + hard_deadline_grace_ms` の絶対期限で
    `:run_lifetime_exceeded` として必ず terminal になる。
  - `MrEric.Runs.Trace` は `stage_chunk` を role ごとのカウンタに畳み（本文は
    `Run.stages[role].content` に残る）、`entries` を上限で切って `dropped_entries` に記録。
  - 完了 run 履歴は `MrEric.Agent` と LiveView の history stream の双方で上限を持つ。
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/README.md CLAUDE.md CHANGELOG.md
git commit -m "docs(spec-d): record run lifetime and resource limits"
```

---

## Task 9: Full verification

**Files:** none — this task only runs and reads.

- [ ] **Step 1: Confirm every `state.run` write is centralised**

Run: `grep -nE 'run: run|Map\.put\(:run' lib/mr_eric/runs/run_worker.ex`
Expected: exactly two hits — `init/1`'s initial state map and `put_run/2`.

- [ ] **Step 2: Confirm the limits module has no fail-open path**

Run: `grep -n 'Map.get\|Keyword.get' lib/mr_eric/runs/limits.ex`
Expected: exactly one `Keyword.get/3`, whose default is `Map.fetch!(@defaults, key)`. No `Map.get/3`.

- [ ] **Step 3: Confirm the frozen surfaces are untouched**

Run: `git diff main...HEAD --stat`
Expected: no changes to `lib/mr_eric/tools/`, `priv/evals/phase9_golden_cases.json`, `lib/mr_eric/runs/events.ex`'s `@event_names`, or `lib/mr_eric/runs/run.ex`'s `@statuses` / `@roles`.

Run: `git diff main...HEAD -- lib/mr_eric/runs/run.ex lib/mr_eric/tools/ priv/evals/`
Expected: empty.

- [ ] **Step 4: Run the gate**

Run: `mix precommit`
Expected: PASS with no warnings.

- [ ] **Step 5: Run the evals**

Run: `mix mr_eric.evals`
Expected: PASS.

Run: `git status --short priv/evals/`
Expected: empty.

- [ ] **Step 6: Walk the acceptance criteria**

Check each of the twelve criteria in `docs/superpowers/specs/2026-08-27-run-lifetime-design.md` against a test that proves it, and note any that rest on inspection rather than a test.

---

## Verification checklist

- [ ] Task 1 — `Limits.fetch!/1` returns defaults, honours overrides, raises on unknown keys; `config/test.exs` carries the test overrides.
- [ ] Task 2 — `:too_many_runs` and `:run_lifetime_exceeded` have public sentences; `:run_limit_reached` is a classification with a safe message.
- [ ] Task 3 — `Runs.start_run/3` returns `{:error, :too_many_runs}` at the cap and never leaks `:max_children`.
- [ ] Task 4 — completed, failed, and cancelled runs are reaped; non-terminal runs are not; history is written before the exit; the slot is released.
- [ ] Task 5 — a stuck run fails with `:run_lifetime_exceeded` at the absolute deadline, a finished run is unaffected, and the slot is released either way.
- [ ] Task 6 — one `stage_chunk` entry per role, no chunk bodies, true counts in `summary/1`, entries capped with `dropped_entries` reported, secret detection unchanged.
- [ ] Task 7 — `MrEric.Agent` history and the LiveView stream both stop at `max_history_entries`.
- [ ] Task 8 — README, `CLAUDE.md`, and `CHANGELOG.md` reflect the new contract.
- [ ] Task 9 — `mix precommit` and `mix mr_eric.evals` both pass; frozen surfaces are untouched.
