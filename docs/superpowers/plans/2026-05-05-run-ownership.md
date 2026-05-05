# Spec B — Run Ownership & Approval Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add session-bound `owner_id` to every Run mutation and a 30-minute hard TTL to every approval token, surfacing expiry as an event.

**Architecture:** Phoenix `:browser` pipeline plug mints a per-session `owner_id` cookie. `AgentLive.mount/3` reads it from session and stashes it in assigns. Every event handler passes `owner_id` to `MrEric.Runs.{start_run,cancel_run,approve_tool,deny_tool}`, which forward it to `RunWorker`. `RunWorker` validates ownership via `MrEric.Runs.OwnerCheck.verify/2` before mutating state. Approval requests grow `expires_at` and `owner_id` fields; the HMAC payload includes `owner_id`; a `Process.send_after` timer fires `:tool_approval_expired` events on TTL; run terminal status drops pending approvals with the same event.

**Tech Stack:** Elixir 1.17, Phoenix 1.8, Phoenix LiveView 1.1, Plug, ExUnit. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-05-05-run-ownership-design.md`

---

## File Structure

| Path | Disposition | Responsibility |
|------|-------------|----------------|
| `lib/mr_eric/plugs/ensure_owner_id.ex` | create | Idempotent plug that mints session `owner_id` |
| `lib/mr_eric_web/router.ex` | modify | Wire `EnsureOwnerId` into `:browser` pipeline |
| `lib/mr_eric/runs/owner_check.ex` | create | Pattern-match `Run.owner_id` against caller-supplied id |
| `lib/mr_eric/runs/run.ex` | modify | Add `:owner_id` field; require in `Run.new/2` |
| `lib/mr_eric/runs.ex` | modify | API signatures: `start_run/3`, `cancel_run/2`, `approve_tool/3`, `deny_tool/3` |
| `lib/mr_eric/runs/run_worker.ex` | modify | Owner check on cancel/approve/deny; approval lifecycle (`expires_at`, timer, terminal cleanup) |
| `lib/mr_eric/runs/events.ex` | modify | Add `:tool_approval_expired` to `@event_names` |
| `lib/mr_eric/tools/executor.ex` | modify | `approval_request` map gets `requested_at`/`expires_at`/`owner_id`; HMAC payload includes `owner_id` |
| `lib/mr_eric_web/live/agent_live.ex` | modify | `mount/3` reads owner_id from session; event handlers pass to `Runs.*`; `apply_tool_event/3` clause for expired |
| `lib/mr_eric/evals/runner.ex` | modify | Hardcode `@eval_owner_id "eval-runner"` |
| `test/support/conn_case.ex` | modify | Add `with_owner_session/2` helper |
| `test/mr_eric/plugs/ensure_owner_id_test.exs` | create | Plug behavior tests |
| `test/mr_eric/runs/owner_check_test.exs` | create | OwnerCheck module tests |
| `test/mr_eric/runs_test.exs` | modify | All `Runs.*` callsites updated to new arity; add cross-owner denial tests |
| `test/mr_eric_web/live/agent_live_test.exs` | modify | Verify owner_id flows from session through mount; verify approval expiry event |
| `test/mr_eric/tools/executor_test.exs` | modify | Approval requests now include owner_id; HMAC changes |

Module boundaries:

- `MrEric.Plugs.EnsureOwnerId` — single responsibility: ensure session has a stable owner_id. No knowledge of `Runs`.
- `MrEric.Runs.OwnerCheck` — pattern-match authorisation. No I/O, no logging, no side effects. Pure function over `Run` + binary.
- `MrEric.Runs` — public API surface; owner_id is positional, not buried in opts.
- `MrEric.Runs.RunWorker` — enforces `OwnerCheck` before any mutation. Owns approval lifecycle (timer + reactive expiry + terminal cleanup).

---

## Section A — Plug + Test Infrastructure

### Task 1: Add `with_owner_session/2` helper to ConnCase

**Files:**
- Modify: `test/support/conn_case.ex`

- [ ] **Step 1: Read the current file**

Confirm current shape (37 lines, exposes `setup` returning `conn`).

- [ ] **Step 2: Add the helper inside the module**

In `test/support/conn_case.ex`, after the `setup _tags do ... end` block (right before the final `end` of `defmodule`), insert:

```elixir
  @doc """
  Initialise a test conn with a known `owner_id` in the session.

  Use when a test needs to bypass the EnsureOwnerId plug — for example unit
  tests that build a `conn` outside the `:browser` pipeline. The full
  `live(conn, "/")` integration path runs the plug naturally.
  """
  def with_owner_session(conn, owner_id \\ nil) do
    owner_id =
      owner_id || "test-owner-" <> Integer.to_string(System.unique_integer([:positive]))

    Plug.Test.init_test_session(conn, %{"owner_id" => owner_id})
  end
```

- [ ] **Step 3: Run the test suite to confirm nothing else broke**

Run: `mix test --max-failures 5`
Expected: full suite passes (existing 158 tests, 0 failures). The helper isn't called yet.

- [ ] **Step 4: Commit**

```bash
git add test/support/conn_case.ex
git commit -m "test: add with_owner_session/2 helper to ConnCase"
```

---

### Task 2: `EnsureOwnerId` plug — failing test, then implementation

**Files:**
- Create: `test/mr_eric/plugs/ensure_owner_id_test.exs`
- Create: `lib/mr_eric/plugs/ensure_owner_id.ex`

- [ ] **Step 1: Write the failing test**

Create `test/mr_eric/plugs/ensure_owner_id_test.exs`:

```elixir
defmodule MrEric.Plugs.EnsureOwnerIdTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias MrEric.Plugs.EnsureOwnerId

  @opts EnsureOwnerId.init([])

  defp conn_with_session(initial_session) do
    :get
    |> conn("/")
    |> Plug.Test.init_test_session(initial_session)
  end

  test "mints an owner_id when session is empty" do
    conn = conn_with_session(%{}) |> EnsureOwnerId.call(@opts)

    assert get_session(conn, :owner_id) |> is_binary()
    assert byte_size(get_session(conn, :owner_id)) >= 16
  end

  test "leaves an existing owner_id untouched" do
    conn = conn_with_session(%{"owner_id" => "existing"}) |> EnsureOwnerId.call(@opts)

    assert get_session(conn, :owner_id) == "existing"
  end

  test "owner_ids minted in two empty sessions differ" do
    a = conn_with_session(%{}) |> EnsureOwnerId.call(@opts) |> get_session(:owner_id)
    b = conn_with_session(%{}) |> EnsureOwnerId.call(@opts) |> get_session(:owner_id)

    assert a != b
  end

  test "session_key/0 returns :owner_id" do
    assert EnsureOwnerId.session_key() == :owner_id
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/mr_eric/plugs/ensure_owner_id_test.exs`
Expected: compile error (`MrEric.Plugs.EnsureOwnerId` not found).

- [ ] **Step 3: Implement the plug**

Create `lib/mr_eric/plugs/ensure_owner_id.ex`:

```elixir
defmodule MrEric.Plugs.EnsureOwnerId do
  @moduledoc """
  Ensures the browser session has a stable `owner_id` for Run authorisation.

  Idempotent: if the session already has one, leaves it alone. If not, mints
  a 16-byte cryptographically random base64url string and stores it.

  This is the single source of session-bound run ownership in dev/local mode.
  """

  import Plug.Conn

  @session_key :owner_id

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, @session_key) do
      nil ->
        owner_id = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        put_session(conn, @session_key, owner_id)

      _existing ->
        conn
    end
  end

  def session_key, do: @session_key
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/mr_eric/plugs/ensure_owner_id_test.exs`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/mr_eric/plugs/ensure_owner_id.ex test/mr_eric/plugs/ensure_owner_id_test.exs
git commit -m "feat(plugs): add EnsureOwnerId for session-bound run ownership

Idempotent plug that mints a 16-byte base64url owner_id on first
visit and stores it in the session. Single source of session-bound
ownership for the local-dev threat model."
```

---

### Task 3: Wire `EnsureOwnerId` into `:browser` pipeline

**Files:**
- Modify: `lib/mr_eric_web/router.ex`

- [ ] **Step 1: Read the current router pipeline**

Verify `:browser` pipeline runs `:fetch_session`, `:fetch_live_flash`, etc. Insert point: immediately after `:fetch_session`.

- [ ] **Step 2: Modify the pipeline**

In `lib/mr_eric_web/router.ex`, replace:

```elixir
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MrEricWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end
```

with:

```elixir
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug MrEric.Plugs.EnsureOwnerId
    plug :fetch_live_flash
    plug :put_root_layout, html: {MrEricWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end
```

- [ ] **Step 3: Run the LiveView test suite to confirm pipeline still loads**

Run: `mix test test/mr_eric_web/`
Expected: all existing tests pass (none of them assert owner_id yet, but nothing should break — `MrEric.Plugs.EnsureOwnerId` exists from Task 2).

- [ ] **Step 4: Commit**

```bash
git add lib/mr_eric_web/router.ex
git commit -m "feat(router): wire EnsureOwnerId into :browser pipeline"
```

---

## Section B — Internal helpers (Run + OwnerCheck)

### Task 4: Add `:owner_id` field to `Run` struct (required in `Run.new/2`)

**Files:**
- Modify: `lib/mr_eric/runs/run.ex`

This task changes the `Run.new/2` contract: the only direct callers are `Runs.start_run/2` (lib/mr_eric/runs.ex) and any tests that construct `Run` directly. We update those in this same task to keep the build green.

- [ ] **Step 1: Add a failing test for the new requirement**

Create or extend `test/mr_eric/runs/run_test.exs` (create if it does not exist; if it does, append to the existing module):

```elixir
defmodule MrEric.Runs.RunTest do
  use ExUnit.Case, async: true

  alias MrEric.Runs.Run

  describe "new/2 owner_id requirement" do
    test "raises when :owner_id is missing from opts" do
      assert_raise KeyError, fn ->
        Run.new("task", provider: :ollama, model: "x")
      end
    end

    test "stores owner_id from opts" do
      run = Run.new("task", owner_id: "alice", provider: :ollama, model: "x")

      assert run.owner_id == "alice"
      assert run.task == "task"
    end

    test "blank/1 still produces a struct without raising (uses placeholder owner_id)" do
      run = Run.blank(provider: :ollama, model: "x")

      assert run.id == nil
      assert run.task == ""
      assert is_binary(run.owner_id)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/mr_eric/runs/run_test.exs`
Expected: tests fail or compile error (no `:owner_id` key on struct yet).

- [ ] **Step 3: Modify `Run` struct and constructors**

In `lib/mr_eric/runs/run.ex`, update the `defstruct` (currently lines 37-50) to:

```elixir
  defstruct [
    :id,
    :owner_id,
    :task,
    :provider,
    :model,
    :error,
    :trace,
    status: :queued,
    stages: %{},
    changed_files: [],
    final: "",
    inserted_at: nil,
    updated_at: nil
  ]
```

Update `new/2` (currently lines 55-73) to:

```elixir
  def new(task, opts \\ []) do
    now = DateTime.utc_now()
    owner_id = Keyword.fetch!(opts, :owner_id)
    provider = Keyword.get(opts, :provider)
    model = Keyword.get(opts, :model)
    id = Keyword.get(opts, :id) || new_id()

    %__MODULE__{
      id: id,
      owner_id: owner_id,
      task: task,
      provider: provider,
      model: model,
      status: :queued,
      stages: default_stages(provider, model),
      trace: Trace.new(id, task, provider, model),
      final: "",
      inserted_at: now,
      updated_at: now
    }
  end
```

Update `blank/1` (currently lines 75-80) to use a placeholder so it does not raise:

```elixir
  def blank(opts \\ []) do
    opts = Keyword.put_new(opts, :owner_id, "(none)")

    nil
    |> new(opts)
    |> Map.put(:id, nil)
    |> Map.put(:task, "")
  end
```

The literal string `"(none)"` is intentional — `blank/1` is used only for the empty initial render in `AgentLive.mount/3` before any task has been dispatched. It is never compared against a real owner via `OwnerCheck` (the LiveView holds its own `owner_id` in assigns), so this placeholder is purely cosmetic.

- [ ] **Step 4: Update the only direct caller (`Runs.start_run/2`)**

In `lib/mr_eric/runs.ex`, the existing `start_run/2` builds `Run.new(task, opts)`. After this task it would crash if no `:owner_id` is supplied. Task 5 (next) introduces the new `start_run/3` arity and migrates callers. To keep the build green between tasks, temporarily change `start_run/2` to inject a fixed placeholder for **internal-only use during the migration window**:

In `lib/mr_eric/runs.ex` `start_run/2`, replace:

```elixir
      run = Run.new(task, opts)
```

with:

```elixir
      run = Run.new(task, Keyword.put_new(opts, :owner_id, "(legacy-no-owner)"))
```

This is removed in Task 5. The `"(legacy-no-owner)"` value is a deliberate red flag — Task 5 will fail any test that still relies on it because `OwnerCheck` will reject it as not matching any real session id.

- [ ] **Step 5: Run the new test to verify it passes**

Run: `mix test test/mr_eric/runs/run_test.exs`
Expected: 3 tests, 0 failures.

- [ ] **Step 6: Run the full suite**

Run: `mix test --max-failures 5`
Expected: full suite passes (the temporary placeholder in `start_run/2` keeps existing tests green).

- [ ] **Step 7: Commit**

```bash
git add lib/mr_eric/runs/run.ex lib/mr_eric/runs.ex test/mr_eric/runs/run_test.exs
git commit -m "feat(run): add owner_id field; require in Run.new/2

Run.new/2 now Keyword.fetch!(:owner_id) — no nil fallback. blank/1
uses a placeholder string for the empty initial-render case. The
Runs.start_run/2 wrapper temporarily injects a placeholder so the
build stays green; Task 5 removes that and migrates callers to
the new start_run/3 signature."
```

---

### Task 5: `MrEric.Runs.OwnerCheck` module

**Files:**
- Create: `lib/mr_eric/runs/owner_check.ex`
- Create: `test/mr_eric/runs/owner_check_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/mr_eric/runs/owner_check_test.exs`:

```elixir
defmodule MrEric.Runs.OwnerCheckTest do
  use ExUnit.Case, async: true

  alias MrEric.Runs.OwnerCheck
  alias MrEric.Runs.Run

  defp run(owner_id) do
    Run.new("t", owner_id: owner_id, provider: :ollama, model: "m")
  end

  test "verify/2 returns {:ok, run} when owner_id matches" do
    r = run("alice")
    assert {:ok, ^r} = OwnerCheck.verify(r, "alice")
  end

  test "verify/2 returns {:error, :not_owner} when owner_id differs" do
    r = run("alice")
    assert {:error, :not_owner} = OwnerCheck.verify(r, "bob")
  end

  test "verify/2 propagates {:error, reason} unchanged" do
    assert {:error, :not_found} = OwnerCheck.verify({:error, :not_found}, "anything")
    assert {:error, :foo} = OwnerCheck.verify({:error, :foo}, "anything")
  end

  test "verify/2 with nil owner_id on the supplied side returns :not_owner" do
    r = run("alice")
    assert {:error, :not_owner} = OwnerCheck.verify(r, nil)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/mr_eric/runs/owner_check_test.exs`
Expected: compile error (`MrEric.Runs.OwnerCheck` undefined).

- [ ] **Step 3: Implement the module**

Create `lib/mr_eric/runs/owner_check.ex`:

```elixir
defmodule MrEric.Runs.OwnerCheck do
  @moduledoc false

  alias MrEric.Runs.Run

  @spec verify(Run.t() | {:error, term()}, binary() | nil) ::
          {:ok, Run.t()} | {:error, :not_owner | term()}
  def verify({:error, reason}, _owner_id), do: {:error, reason}

  def verify(%Run{owner_id: owner_id} = run, owner_id) when is_binary(owner_id) do
    {:ok, run}
  end

  def verify(%Run{}, _other_owner_id), do: {:error, :not_owner}
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/mr_eric/runs/owner_check_test.exs`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/mr_eric/runs/owner_check.ex test/mr_eric/runs/owner_check_test.exs
git commit -m "feat(runs): add OwnerCheck.verify/2 for owner_id authorisation

Pattern-match comparison between Run.owner_id and a supplied
owner_id. Returns {:ok, run} | {:error, :not_owner}. Pure
function — no I/O, no logging."
```

---

## Section C — API migration (the breaking change)

### Task 6: Migrate `Runs.*` API and all callers to require `owner_id`

This is the largest task. It changes 4 public API signatures, 3 RunWorker handlers, the LiveView mount + 3 event handlers, the Eval Runner, and the entire `runs_test.exs` and `agent_live_test.exs` and `executor_test.exs` test suites. Doing it atomically keeps the build green at every commit boundary.

**Files:**
- Modify: `lib/mr_eric/runs.ex` (all 4 mutating functions + 1 internal)
- Modify: `lib/mr_eric/runs/run_worker.ex` (3 handle_call clauses + their public-API counterparts)
- Modify: `lib/mr_eric_web/live/agent_live.ex` (mount, 3 event handlers, blank/1 caller)
- Modify: `lib/mr_eric/evals/runner.ex` (3 callsites)
- Modify: `test/mr_eric/runs_test.exs` (every `Runs.*` call gets owner_id)
- Modify: `test/mr_eric_web/live/agent_live_test.exs` (verify owner_id flow)
- Modify: `test/mr_eric/tools/executor_test.exs` (executor opts now include owner_id where it builds approval requests; only callsites that exercise approval paths need it)

- [ ] **Step 1: Write the new tests in runs_test.exs**

Append to `test/mr_eric/runs_test.exs` (right before the closing `end` of `defmodule`):

```elixir
  describe "owner_id authorisation" do
    test "start_run/3 stores owner_id on the run" do
      run_id = unique_run_id()
      owner = "alice-#{System.unique_integer([:positive])}"

      assert {:ok, %Run{id: ^run_id, owner_id: ^owner}} =
               Runs.start_run("Build", owner, @opts ++ [id: run_id])
    end

    test "cancel_run/2 rejects a non-owner with {:error, :not_owner}" do
      run_id = unique_run_id()
      owner = "alice-#{System.unique_integer([:positive])}"

      assert {:ok, _run} =
               Runs.start_run("Long task", owner,
                 @opts ++ [id: run_id, delay_ms: 1_000])

      assert {:error, :not_owner} = Runs.cancel_run(run_id, "mallory")

      # The run is still alive — owner can still cancel
      assert :ok = Runs.cancel_run(run_id, owner)
    end

    test "approve_tool/3 rejects a non-owner with {:error, :not_owner}" do
      run_id = unique_run_id()
      owner = "alice-#{System.unique_integer([:positive])}"

      assert {:ok, _run} =
               Runs.start_run("Use tool", owner,
                 @opts ++ [id: run_id, orchestrator_module: ToolLoopOrchestrator])

      approval_id = await_pending_approval(run_id)

      assert {:error, :not_owner} = Runs.approve_tool(run_id, approval_id, "mallory")

      # State unchanged: owner can still approve
      assert :ok = Runs.approve_tool(run_id, approval_id, owner)
    end

    test "deny_tool/3 rejects a non-owner with {:error, :not_owner}" do
      run_id = unique_run_id()
      owner = "alice-#{System.unique_integer([:positive])}"

      assert {:ok, _run} =
               Runs.start_run("Use tool", owner,
                 @opts ++ [id: run_id, orchestrator_module: ToolLoopOrchestrator])

      approval_id = await_pending_approval(run_id)

      assert {:error, :not_owner} = Runs.deny_tool(run_id, approval_id, "mallory")
      assert :ok = Runs.deny_tool(run_id, approval_id, owner)
    end
  end

  defp await_pending_approval(run_id) do
    receive do
      {:tool_approval_requested, %{run_id: ^run_id, approval_id: id}} -> id
    after
      2_000 -> flunk("no approval observed for run #{run_id}")
    end
  end
```

These tests reference `await_pending_approval/1`. The existing test file already subscribes via `Runs.subscribe(run_id)` in setup or per-test; if not, prepend `:ok = Runs.subscribe(run_id)` after `start_run` in each new test before calling `await_pending_approval/1`.

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `mix test test/mr_eric/runs_test.exs`
Expected: tests in the new `describe` block all fail (compile or runtime — `start_run/3` does not exist yet).

- [ ] **Step 3: Update `lib/mr_eric/runs.ex`**

Replace the entire file body (after `alias` lines) with:

```elixir
  @internal_opts [:subscribe]

  def start_run(task, owner_id, opts \\ [])

  def start_run(task, owner_id, opts)
      when is_binary(task) and is_binary(owner_id) and is_list(opts) do
    task = String.trim(task)

    if task == "" do
      {:error, :invalid_task}
    else
      run = Run.new(task, Keyword.put(opts, :owner_id, owner_id))

      if Keyword.get(opts, :subscribe, false) do
        subscribe(run.id)
      end

      worker_opts = Keyword.drop(opts, @internal_opts)

      case RunSupervisor.start_run(run, worker_opts) do
        {:ok, _pid} -> {:ok, run}
        {:error, {:already_started, _pid}} -> {:error, :already_started}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def start_run(_task, _owner_id, _opts), do: {:error, :invalid_task}

  def cancel_run(run_id, owner_id) when is_binary(owner_id) do
    RunWorker.cancel(run_id, owner_id)
  end

  def approve_tool(run_id, approval_id, owner_id) when is_binary(owner_id) do
    RunWorker.approve_tool(run_id, approval_id, owner_id)
  end

  def deny_tool(run_id, approval_id, owner_id) when is_binary(owner_id) do
    RunWorker.deny_tool(run_id, approval_id, owner_id)
  end

  def get_run(run_id), do: RunWorker.get_run(run_id)

  def subscribe(run_id), do: Events.subscribe(run_id)

  def unsubscribe(run_id), do: Events.unsubscribe(run_id)

  def broadcast(run_id, event), do: Events.broadcast(run_id, event)
```

The temporary `"(legacy-no-owner)"` placeholder added in Task 4 is removed by this `Keyword.put` call (it now always overwrites with the real owner_id).

- [ ] **Step 4: Update `lib/mr_eric/runs/run_worker.ex`**

The public API helpers `cancel/1`, `approve_tool/2`, `deny_tool/2` become 2-arity / 3-arity respectively, and they pass owner_id through to the GenServer call.

Replace the existing `cancel/1`, `approve_tool/2`, `deny_tool/2` functions and their handle_call clauses.

Replace:

```elixir
  def cancel(pid) when is_pid(pid), do: GenServer.call(pid, :cancel)

  def cancel(run_id) do
    case lookup(run_id) do
      {:ok, pid} -> cancel(pid)
      :error -> {:error, :not_found}
    end
  end
```

with:

```elixir
  def cancel(pid, owner_id) when is_pid(pid) and is_binary(owner_id) do
    GenServer.call(pid, {:cancel, owner_id})
  end

  def cancel(run_id, owner_id) when is_binary(owner_id) do
    case lookup(run_id) do
      {:ok, pid} -> cancel(pid, owner_id)
      :error -> {:error, :not_found}
    end
  end
```

Replace:

```elixir
  def approve_tool(pid, approval_id) when is_pid(pid) do
    GenServer.call(pid, {:approve_tool, approval_id})
  end

  def approve_tool(run_id, approval_id) do
    case lookup(run_id) do
      {:ok, pid} -> approve_tool(pid, approval_id)
      :error -> {:error, :not_found}
    end
  end
```

with:

```elixir
  def approve_tool(pid, approval_id, owner_id) when is_pid(pid) and is_binary(owner_id) do
    GenServer.call(pid, {:approve_tool, approval_id, owner_id})
  end

  def approve_tool(run_id, approval_id, owner_id) when is_binary(owner_id) do
    case lookup(run_id) do
      {:ok, pid} -> approve_tool(pid, approval_id, owner_id)
      :error -> {:error, :not_found}
    end
  end
```

Replace:

```elixir
  def deny_tool(pid, approval_id) when is_pid(pid) do
    GenServer.call(pid, {:deny_tool, approval_id})
  end

  def deny_tool(run_id, approval_id) do
    case lookup(run_id) do
      {:ok, pid} -> deny_tool(pid, approval_id)
      :error -> {:error, :not_found}
    end
  end
```

with:

```elixir
  def deny_tool(pid, approval_id, owner_id) when is_pid(pid) and is_binary(owner_id) do
    GenServer.call(pid, {:deny_tool, approval_id, owner_id})
  end

  def deny_tool(run_id, approval_id, owner_id) when is_binary(owner_id) do
    case lookup(run_id) do
      {:ok, pid} -> deny_tool(pid, approval_id, owner_id)
      :error -> {:error, :not_found}
    end
  end
```

Add the alias near the top (just after the existing aliases):

```elixir
  alias MrEric.Runs.OwnerCheck
```

Replace the existing `handle_call(:cancel, _from, state)` clause:

```elixir
  @impl true
  def handle_call(:cancel, _from, state) do
    state =
      if Run.terminal?(state.run) do
        state
      else
        shutdown_task(state.task)
        ...
      end
    {:reply, :ok, state}
  end
```

with:

```elixir
  @impl true
  def handle_call({:cancel, owner_id}, _from, state) do
    case OwnerCheck.verify(state.run, owner_id) do
      {:ok, _} ->
        state =
          if Run.terminal?(state.run) do
            state
          else
            shutdown_task(state.task)

            {event, payload} = Events.normalize_event(state.run.id, {:run_cancelled, %{}})
            run = Run.apply_event(state.run, {event, payload})

            state =
              state
              |> Map.put(:run, run)
              |> Map.put(:task, nil)
              |> Map.put(:cancelled?, true)
              |> maybe_resolve_pending_tool_approvals(:run_cancelled)

            Events.broadcast(run.id, {event, payload})
            state
          end

        {:reply, :ok, state}

      {:error, :not_owner} = err ->
        require Logger
        Logger.warning("run #{state.run.id}: cancel attempted by non-owner")
        {:reply, err, state}
    end
  end
```

Replace `handle_call({:approve_tool, approval_id}, _from, state)`:

```elixir
  @impl true
  def handle_call({:approve_tool, approval_id, owner_id}, _from, state) do
    with {:ok, _} <- OwnerCheck.verify(state.run, owner_id) do
      if Run.terminal?(state.run) do
        {:reply, {:error, :not_found}, %{state | pending_tool_approvals: %{}}}
      else
        case Map.pop(state.pending_tool_approvals, approval_id) do
          {nil, _pending} ->
            {:reply, {:error, :not_found}, state}

          {request, pending} ->
            state =
              state
              |> Map.put(:pending_tool_approvals, pending)
              |> broadcast_tool_approval_resolved(request, true, "Tool request approved.")

            {:reply, :ok, state, {:continue, {:execute_approved_tool, request}}}
        end
      end
    else
      {:error, :not_owner} = err ->
        require Logger
        Logger.warning("run #{state.run.id}: approve attempted by non-owner")
        {:reply, err, state}
    end
  end
```

Replace `handle_call({:deny_tool, approval_id}, _from, state)`:

```elixir
  @impl true
  def handle_call({:deny_tool, approval_id, owner_id}, _from, state) do
    with {:ok, _} <- OwnerCheck.verify(state.run, owner_id) do
      case Map.pop(state.pending_tool_approvals, approval_id) do
        {nil, _pending} ->
          {:reply, {:error, :not_found}, state}

        {request, pending} ->
          state =
            state
            |> Map.put(:pending_tool_approvals, pending)
            |> broadcast_tool_approval_resolved(request, false, "Tool request denied.")
            |> broadcast_tool_rejected(request, :tool_denied)

          {:reply, :ok, state}
      end
    else
      {:error, :not_owner} = err ->
        require Logger
        Logger.warning("run #{state.run.id}: deny attempted by non-owner")
        {:reply, err, state}
    end
  end
```

- [ ] **Step 5: Update `lib/mr_eric_web/live/agent_live.ex`**

In `mount/3` (currently lines 13-35), replace:

```elixir
  @impl true
  def mount(_params, _session, socket) do
    selected_provider = Registry.default_provider()
    available_models = Registry.models_for_provider(selected_provider)
    selected_model = Registry.default_model(selected_provider)

    {:ok,
     socket
     |> assign(
       loading: false,
       response: "",
       selected_provider: selected_provider,
       selected_model: selected_model,
       available_providers: Registry.providers(),
       available_models: available_models,
       current_run: Run.blank(provider: selected_provider, model: selected_model),
       stage_roles: Run.roles(),
       tool_approvals: %{},
       tool_events: [],
       form: to_form(%{"task" => ""})
     )
     |> stream(:history, Agent.history())}
  end
```

with:

```elixir
  @impl true
  def mount(_params, session, socket) do
    owner_id =
      Map.get(session, "owner_id") ||
        raise "owner_id missing from session — EnsureOwnerId plug not in pipeline?"

    selected_provider = Registry.default_provider()
    available_models = Registry.models_for_provider(selected_provider)
    selected_model = Registry.default_model(selected_provider)

    {:ok,
     socket
     |> assign(
       owner_id: owner_id,
       loading: false,
       response: "",
       selected_provider: selected_provider,
       selected_model: selected_model,
       available_providers: Registry.providers(),
       available_models: available_models,
       current_run: Run.blank(provider: selected_provider, model: selected_model),
       stage_roles: Run.roles(),
       tool_approvals: %{},
       expired_approvals: [],
       tool_events: [],
       form: to_form(%{"task" => ""})
     )
     |> stream(:history, Agent.history())}
  end
```

(Adds `owner_id: owner_id` and `expired_approvals: []` to assigns. The latter is referenced later by Task 12.)

In `handle_event("execute", ...)` (around line 437), replace the `Runs.start_run(task, opts)` line with:

```elixir
      case Runs.start_run(task, socket.assigns.owner_id, opts) do
```

In `handle_event("approve_tool", ...)` (around line 483), replace `Runs.approve_tool(run_id, approval_id)` with:

```elixir
        case Runs.approve_tool(run_id, approval_id, socket.assigns.owner_id) do
          :ok ->
            {:noreply, socket}

          {:error, :not_owner} ->
            {:noreply, put_flash(socket, :error, "このRunの操作権限がありません")}

          {:error, _reason} ->
            {:noreply, socket}
        end
```

In `handle_event("deny_tool", ...)` (around line 495), replace `Runs.deny_tool(run_id, approval_id)` with:

```elixir
        case Runs.deny_tool(run_id, approval_id, socket.assigns.owner_id) do
          :ok ->
            {:noreply, socket}

          {:error, :not_owner} ->
            {:noreply, put_flash(socket, :error, "このRunの操作権限がありません")}

          {:error, _reason} ->
            {:noreply, socket}
        end
```

In `handle_event("cancel_run", ...)` (around line 507), replace `Runs.cancel_run(run_id)` with:

```elixir
        case Runs.cancel_run(run_id, socket.assigns.owner_id) do
          :ok ->
            {:noreply, socket}

          {:error, :not_owner} ->
            {:noreply, put_flash(socket, :error, "このRunの操作権限がありません")}

          {:error, reason} ->
            run = Run.apply_event(socket.assigns.current_run, {:run_failed, %{error: reason}})
            {:noreply, assign(socket, loading: false, current_run: run, response: run.error)}
        end
```

- [ ] **Step 6: Update `lib/mr_eric/evals/runner.ex`**

Add a module attribute near the top (after the existing `alias` lines):

```elixir
  @eval_owner_id "eval-runner"
```

Replace `Runs.start_run(eval_case.task, run_opts)` (around line 55):

```elixir
      with {:ok, %Run{id: ^run_id}} <-
             Runs.start_run(eval_case.task, @eval_owner_id, run_opts),
```

Replace `Runs.approve_tool(run_id, approval_id)` (line 120):

```elixir
      :approve -> Runs.approve_tool(run_id, approval_id, @eval_owner_id)
```

Replace `Runs.deny_tool(run_id, approval_id)` (line 121):

```elixir
      :reject -> Runs.deny_tool(run_id, approval_id, @eval_owner_id)
```

Replace `Runs.cancel_run(run_id)` (line 169):

```elixir
      Runs.cancel_run(run_id, @eval_owner_id)
```

- [ ] **Step 7: Update existing tests in `test/mr_eric/runs_test.exs`**

The file has many `Runs.start_run/2`, `Runs.cancel_run/1`, `Runs.approve_tool/2`, `Runs.deny_tool/2` callsites (~10-15 total based on the file). For each:

- `Runs.start_run("...", @opts ++ [id: run_id])` → `Runs.start_run("...", "test-owner-#{run_id}", @opts ++ [id: run_id])`
- `Runs.cancel_run(run_id)` → `Runs.cancel_run(run_id, "test-owner-#{run_id}")`
- `Runs.approve_tool(run_id, approval_id)` → `Runs.approve_tool(run_id, approval_id, "test-owner-#{run_id}")`
- `Runs.deny_tool(run_id, approval_id)` → `Runs.deny_tool(run_id, approval_id, "test-owner-#{run_id}")`

Use the literal pattern `"test-owner-" <> run_id` so the same owner string is used consistently within a single test. Replace ALL occurrences mechanically — do not selectively skip any.

If the test file has a setup helper that constructs runs, update the helper rather than each call.

- [ ] **Step 8: Update `test/mr_eric_web/live/agent_live_test.exs`**

The existing tests use `live(conn, "/")`, which goes through the `:browser` pipeline and so the `EnsureOwnerId` plug naturally mints an owner_id for the session. No change needed to existing assertions — they continue to work.

Add **one new test** at the end of the existing `describe`/module (before the final `end`):

```elixir
  test "mount injects an owner_id from the browser session", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    # The owner_id is internal — we don't render it. But we can verify
    # the plug ran by checking the session.
    session_owner_id = conn |> Plug.Test.init_test_session(%{}) |> get_session(:owner_id)
    # session_owner_id will be nil here because we built a fresh conn —
    # the assertion below proves the LiveView mounted without raising,
    # which is the meaningful guard. If EnsureOwnerId failed to wire,
    # mount/3 raises.
    assert html =~ "MrEric AI Agent"
    refute is_nil(session_owner_id) or true
  end
```

(The test is structured so the meaningful assertion is `html =~ "MrEric AI Agent"` — if `mount/3` raises because owner_id is missing, `live(conn, "/")` would crash.)

Actually replace the test body with a simpler version:

```elixir
  test "mount succeeds when EnsureOwnerId plug supplies owner_id", %{conn: conn} do
    # If EnsureOwnerId is not wired into :browser, mount/3 raises and
    # live/2 propagates the error.
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "MrEric AI Agent"
  end

  test "mount/3 raises when session has no owner_id" do
    # `live(conn, "/")` always goes through the :browser pipeline, which
    # would mint an owner_id. To verify the defensive raise we call
    # mount/3 directly with an empty session map.
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}}
    }

    assert_raise RuntimeError, ~r/owner_id missing from session/, fn ->
      MrEricWeb.AgentLive.mount(%{}, %{}, socket)
    end
  end
```

- [ ] **Step 9: Update `test/mr_eric/tools/executor_test.exs`**

The Executor itself doesn't directly take `owner_id` as input until Task 8 — the executor's `execute/3` is unchanged here. Only callsites that EXERCISE approval paths need to be aware that approval requests now include `owner_id`. After Task 8, `Executor.execute(tool, args, opts)` will require `:owner_id` in opts when an approval is required.

In Task 6 we don't change Executor yet. Tests in `executor_test.exs` keep working as long as their existing approval-flow tests still trigger the legacy approval shape. **However**, since Task 8 will require `:owner_id` in opts for any approval path, we'll add a `setup` block now that injects a synthetic `owner_id` into opts for every test:

Locate the `setup` block (or `setup_all`) at the top of the test module. If a setup block exists that returns opts, modify it. If none, add:

```elixir
  setup do
    {:ok, owner_id: "test-executor-#{System.unique_integer([:positive])}"}
  end
```

Then in each test that calls `Executor.execute(tool, args, opts)` with an empty or partial `opts`, append `owner_id: ctx.owner_id`. (This will be enforced by Task 8.)

For Task 6, this is a no-op preparation step — the file compiles and runs fine without the addition. If the file already has a setup block, **leave it** and do this prep-work in Task 8 instead. **Skip Step 9 if the file does not need changes for Task 6 to pass.** Verify by running `mix test test/mr_eric/tools/executor_test.exs` after Step 7 — if it passes, skip this step.

- [ ] **Step 10: Run the full test suite**

Run: `mix test`
Expected: full suite passes. The owner-id authorisation tests added in Step 1 now pass; legacy tests pass with the new signatures.

If any test fails:
- Compile errors → check that all 4 `Runs.*` callsites use the new arity.
- `KeyError` on `:owner_id` in `Run.new` → check that all `Runs.start_run/3` callsites supply owner_id.
- LiveView test failure on `mount` raise → check that `:browser` pipeline includes `EnsureOwnerId` (Task 3).

- [ ] **Step 11: Commit**

```bash
git add lib/mr_eric/runs.ex \
        lib/mr_eric/runs/run_worker.ex \
        lib/mr_eric_web/live/agent_live.ex \
        lib/mr_eric/evals/runner.ex \
        test/mr_eric/runs_test.exs \
        test/mr_eric_web/live/agent_live_test.exs

git commit -m "feat(runs): require owner_id on cancel/approve/deny

Runs.start_run/3, cancel_run/2, approve_tool/3, deny_tool/3 now
require an owner_id positional argument. RunWorker validates via
OwnerCheck.verify/2 before mutating state. LiveView reads
session['owner_id'] in mount and threads it through every event
handler. Eval Runner uses a fixed 'eval-runner' constant.

Cross-owner mutations return {:error, :not_owner} with a
Logger.warning and leave the run state unchanged."
```

---

## Section D — Approval lifecycle (TTL + expiry event)

### Task 7: Add `:tool_approval_expired` to `Events.@event_names`

**Files:**
- Modify: `lib/mr_eric/runs/events.ex`

- [ ] **Step 1: Write a failing assertion**

In `test/mr_eric/runs_test.exs` (or a new file `test/mr_eric/runs/events_test.exs` if it doesn't exist), append:

```elixir
defmodule MrEric.Runs.EventsTest do
  use ExUnit.Case, async: true

  alias MrEric.Runs.Events

  test "tool_approval_expired is a recognised event name" do
    assert :tool_approval_expired in Events.names()
  end

  test "normalize_event accepts tool_approval_expired" do
    {event, payload} =
      Events.normalize_event("run-1",
        {:tool_approval_expired, %{approval_id: "a", reason: :ttl}})

    assert event == :tool_approval_expired
    assert payload.run_id == "run-1"
    assert payload.approval_id == "a"
    assert payload.reason == :ttl
  end
end
```

(If `events_test.exs` already exists, append to it instead.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/mr_eric/runs/events_test.exs`
Expected: 2 tests fail (event name not in list).

- [ ] **Step 3: Add `:tool_approval_expired` to `@event_names`**

In `lib/mr_eric/runs/events.ex`, replace the `@event_names` list (lines 6-22) with:

```elixir
  @event_names [
    :run_started,
    :stage_started,
    :stage_chunk,
    :stage_completed,
    :stage_failed,
    :run_completed,
    :run_failed,
    :run_cancelled,
    :tool_started,
    :tool_approval_requested,
    :tool_approval_resolved,
    :tool_approval_expired,
    :tool_completed,
    :tool_failed,
    :tool_denied,
    :tool_rejected
  ]
```

- [ ] **Step 4: Run the tests**

Run: `mix test test/mr_eric/runs/events_test.exs`
Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/mr_eric/runs/events.ex test/mr_eric/runs/events_test.exs
git commit -m "feat(events): register tool_approval_expired event"
```

---

### Task 8: Extend `approval_request` with `expires_at` + `owner_id`; bind owner_id into HMAC

**Files:**
- Modify: `lib/mr_eric/tools/executor.ex`
- Modify: `test/mr_eric/tools/executor_test.exs`

- [ ] **Step 1: Add a failing test**

Append to `test/mr_eric/tools/executor_test.exs`:

```elixir
  describe "approval request shape (Spec B)" do
    test "approval_request includes owner_id and expires_at" do
      owner = "alice"

      {:approval_required, request} =
        MrEric.Tools.Executor.execute(:apply_patch,
          %{path: "x.txt", patch: "@@"},
          owner_id: owner, workspace_root: System.tmp_dir!())

      assert %{
               approval_id: _,
               approval_token: _,
               tool_call_id: _,
               tool: :apply_patch,
               owner_id: ^owner,
               requested_at: %DateTime{},
               expires_at: %DateTime{}
             } = request

      diff =
        DateTime.diff(request.expires_at, request.requested_at, :second)

      assert diff == 30 * 60
    end

    test "execute_approved/2 verifies the new HMAC binding (owner_id included)" do
      owner = "alice"

      {:approval_required, request} =
        MrEric.Tools.Executor.execute(:apply_patch,
          %{path: "x.txt", patch: "@@"},
          owner_id: owner, workspace_root: System.tmp_dir!())

      # Tampering: change owner_id but keep the (now-invalid) HMAC token
      tampered = %{request | owner_id: "mallory"}

      assert {:error, :approval_required} =
               MrEric.Tools.Executor.execute_approved(tampered,
                 owner_id: "mallory", workspace_root: System.tmp_dir!())

      # Original request still verifies
      assert {:ok, _} =
               MrEric.Tools.Executor.execute_approved(request,
                 owner_id: owner, workspace_root: System.tmp_dir!())
    end
  end
```

(`apply_patch` is used because it triggers an approval-required decision in `Policy`. If the local policy rules differ, swap to a tool whose policy decision returns `approval_required?: true`.)

- [ ] **Step 2: Run the test**

Run: `mix test test/mr_eric/tools/executor_test.exs`
Expected: tests fail — `owner_id`/`expires_at` keys absent from the returned map.

- [ ] **Step 3: Update `lib/mr_eric/tools/executor.ex`**

Add a module attribute near the top (after the existing aliases):

```elixir
  @approval_ttl_seconds 30 * 60
```

Replace `approval_request/4` (currently around lines 43-56):

```elixir
  defp approval_request(module, args, decision, opts) do
    approval_id = Keyword.get(opts, :approval_id) || new_id("approval")
    tool_call_id = Keyword.get(opts, :tool_call_id) || new_id("tool")
    owner_id = Keyword.fetch!(opts, :owner_id)
    requested_at = DateTime.utc_now()
    expires_at = DateTime.add(requested_at, @approval_ttl_seconds, :second)

    %{
      approval_id: approval_id,
      approval_token: approval_token(module.name(), args, approval_id, tool_call_id, owner_id),
      tool_call_id: tool_call_id,
      tool: module.name(),
      args: args,
      reason: Map.get(decision, :reason, "Tool execution requires approval."),
      requested_at: requested_at,
      expires_at: expires_at,
      owner_id: owner_id
    }
  end
```

Replace `approval_token/4` with:

```elixir
  defp approval_token(tool, args, approval_id, tool_call_id, owner_id) do
    data = :erlang.term_to_binary({tool, args, approval_id, tool_call_id, owner_id})

    :hmac
    |> :crypto.mac(:sha256, approval_secret(), data)
    |> Base.url_encode64(padding: false)
  end
```

Replace `verify_approval_request/1`:

```elixir
  defp verify_approval_request(%{
         tool: tool,
         args: args,
         approval_id: approval_id,
         tool_call_id: tool_call_id,
         owner_id: owner_id,
         approval_token: token
       })
       when is_binary(approval_id) and is_binary(tool_call_id)
       and is_binary(owner_id) and is_binary(token) do
    expected = approval_token(tool, args, approval_id, tool_call_id, owner_id)

    if Plug.Crypto.secure_compare(token, expected) do
      :ok
    else
      {:error, :approval_required}
    end
  end

  defp verify_approval_request(_request), do: {:error, :approval_required}
```

- [ ] **Step 4: Update `tool_opts/3` callsite in RunWorker**

`RunWorker.tool_opts/3` (currently around line 524) builds the opts passed to `Executor`. It must now include `:owner_id`.

In `lib/mr_eric/runs/run_worker.ex`, replace:

```elixir
  defp tool_opts(state, tool_call_id, nil) do
    state.opts
    |> Keyword.put(:tool_call_id, tool_call_id)
    |> Keyword.put_new(:workspace_root, File.cwd!())
  end
```

with:

```elixir
  defp tool_opts(state, tool_call_id, nil) do
    state.opts
    |> Keyword.put(:tool_call_id, tool_call_id)
    |> Keyword.put(:owner_id, state.run.owner_id)
    |> Keyword.put_new(:workspace_root, File.cwd!())
  end
```

(`tool_opts/3` with non-nil `approval_id` chains to this clause, so this single change covers both call sites.)

- [ ] **Step 5: Update existing executor tests' setup if not already done**

If `test/mr_eric/tools/executor_test.exs` setup did not already inject `owner_id` (the optional Task 6 Step 9 prep), add it now. Locate the test file's `setup` block; if there isn't one, add at the top of the `describe`/module:

```elixir
  setup do
    {:ok, owner_id: "test-executor-#{System.unique_integer([:positive])}"}
  end
```

Modify any existing test that calls `Executor.execute(...)` with an `opts` keyword list to merge the owner_id from `ctx`:

Example:
```elixir
test "...", ctx do
  result = Executor.execute(:tool, %{}, owner_id: ctx.owner_id, workspace_root: ...)
end
```

Tests that don't go through approval-required paths need not change.

- [ ] **Step 6: Run the test suite**

Run: `mix test test/mr_eric/tools/executor_test.exs`
Expected: 0 failures.

- [ ] **Step 7: Run the full suite**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 8: Commit**

```bash
git add lib/mr_eric/tools/executor.ex \
        lib/mr_eric/runs/run_worker.ex \
        test/mr_eric/tools/executor_test.exs

git commit -m "feat(executor): bind owner_id into approval HMAC; add expires_at

Approval requests now include owner_id and a 30-minute hard
expires_at timestamp. The HMAC payload is the 5-tuple
(tool, args, approval_id, tool_call_id, owner_id), so any
tampering with owner_id invalidates the token."
```

---

### Task 9: RunWorker — reactive TTL check on approve/deny

**Files:**
- Modify: `lib/mr_eric/runs/run_worker.ex`
- Modify: `test/mr_eric/runs_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/mr_eric/runs_test.exs`:

```elixir
  describe "approval TTL — reactive" do
    test "approve_tool/3 returns :approval_expired and broadcasts when past expires_at" do
      run_id = unique_run_id()
      owner = "alice-#{System.unique_integer([:positive])}"
      :ok = Runs.subscribe(run_id)

      assert {:ok, _run} =
               Runs.start_run("Use tool", owner,
                 @opts ++ [id: run_id, orchestrator_module: ToolLoopOrchestrator])

      approval_id = await_pending_approval(run_id)

      # Force the pending approval to be already-expired by reaching
      # into the worker state. RunWorker exposes a test-only helper
      # for this.
      :ok = MrEric.Runs.RunWorker.test_expire_approval(run_id, approval_id)

      assert {:error, :approval_expired} =
               Runs.approve_tool(run_id, approval_id, owner)

      assert_receive {:tool_approval_expired,
                      %{run_id: ^run_id, approval_id: ^approval_id, reason: :ttl}}, 500
    end
  end
```

This test depends on a new test helper `RunWorker.test_expire_approval/2` that mutates the pending approval's `expires_at` to a past time. We add it in Step 3.

- [ ] **Step 2: Run the test**

Run: `mix test test/mr_eric/runs_test.exs`
Expected: test fails (`test_expire_approval/2` undefined; reactive expiry check not present).

- [ ] **Step 3: Add test helper + reactive check**

In `lib/mr_eric/runs/run_worker.ex`, add a public test-only helper after the existing public `deny_tool` functions (around line 85):

```elixir
  @doc false
  # Test-only: forces the pending approval's expires_at to be in the past
  # so the next approve/deny call exercises the reactive expiry branch.
  def test_expire_approval(run_id, approval_id) do
    case lookup(run_id) do
      {:ok, pid} -> GenServer.call(pid, {:test_expire_approval, approval_id})
      :error -> {:error, :not_found}
    end
  end
```

Add a handler for the test message:

```elixir
  @impl true
  def handle_call({:test_expire_approval, approval_id}, _from, state) do
    case Map.get(state.pending_tool_approvals, approval_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      request ->
        past = DateTime.add(DateTime.utc_now(), -1, :second)
        updated = %{request | expires_at: past}
        state = put_in(state.pending_tool_approvals[approval_id], updated)
        {:reply, :ok, state}
    end
  end
```

Update `handle_call({:approve_tool, approval_id, owner_id}, ...)` (the clause from Task 6) to add the expiry check **inside** the with-chain:

```elixir
  @impl true
  def handle_call({:approve_tool, approval_id, owner_id}, _from, state) do
    with {:ok, _} <- OwnerCheck.verify(state.run, owner_id),
         {:ok, request} <- find_pending_approval(state, approval_id),
         :ok <- check_expiry(request) do
      if Run.terminal?(state.run) do
        {:reply, {:error, :not_found}, %{state | pending_tool_approvals: %{}}}
      else
        pending = Map.delete(state.pending_tool_approvals, approval_id)

        state =
          state
          |> Map.put(:pending_tool_approvals, pending)
          |> broadcast_tool_approval_resolved(request, true, "Tool request approved.")

        {:reply, :ok, state, {:continue, {:execute_approved_tool, request}}}
      end
    else
      {:error, :not_owner} = err ->
        require Logger
        Logger.warning("run #{state.run.id}: approve attempted by non-owner")
        {:reply, err, state}

      {:error, :pending_not_found} ->
        {:reply, {:error, :not_found}, state}

      {:error, :expired} ->
        state = drop_expired_approval(state, approval_id, :ttl)
        {:reply, {:error, :approval_expired}, state}
    end
  end
```

Add the same expiry check to `handle_call({:deny_tool, ...})`:

```elixir
  @impl true
  def handle_call({:deny_tool, approval_id, owner_id}, _from, state) do
    with {:ok, _} <- OwnerCheck.verify(state.run, owner_id),
         {:ok, request} <- find_pending_approval(state, approval_id),
         :ok <- check_expiry(request) do
      pending = Map.delete(state.pending_tool_approvals, approval_id)

      state =
        state
        |> Map.put(:pending_tool_approvals, pending)
        |> broadcast_tool_approval_resolved(request, false, "Tool request denied.")
        |> broadcast_tool_rejected(request, :tool_denied)

      {:reply, :ok, state}
    else
      {:error, :not_owner} = err ->
        require Logger
        Logger.warning("run #{state.run.id}: deny attempted by non-owner")
        {:reply, err, state}

      {:error, :pending_not_found} ->
        {:reply, {:error, :not_found}, state}

      {:error, :expired} ->
        state = drop_expired_approval(state, approval_id, :ttl)
        {:reply, {:error, :approval_expired}, state}
    end
  end
```

Add the four helpers near the bottom of the module (just before `defp new_id/1`):

```elixir
  defp find_pending_approval(state, approval_id) do
    case Map.get(state.pending_tool_approvals, approval_id) do
      nil -> {:error, :pending_not_found}
      request -> {:ok, request}
    end
  end

  defp check_expiry(%{expires_at: %DateTime{} = expires_at}) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :gt do
      {:error, :expired}
    else
      :ok
    end
  end

  defp check_expiry(_request), do: :ok

  defp drop_expired_approval(state, approval_id, reason) do
    pending = Map.delete(state.pending_tool_approvals, approval_id)

    {event, payload} =
      Events.normalize_event(state.run.id,
        {:tool_approval_expired, %{approval_id: approval_id, reason: reason}})

    Events.broadcast(state.run.id, {event, payload})
    %{state | pending_tool_approvals: pending}
  end
```

- [ ] **Step 4: Run the new test**

Run: `mix test test/mr_eric/runs_test.exs`
Expected: 0 failures (including the new `:approval_expired` test).

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric/runs/run_worker.ex test/mr_eric/runs_test.exs
git commit -m "feat(run_worker): reactive TTL check on approve/deny

approve_tool/3 and deny_tool/3 now check expires_at on the
pending approval. If past expiry, returns {:error, :approval_expired}
and broadcasts :tool_approval_expired with reason :ttl.

Adds RunWorker.test_expire_approval/2 helper for tests."
```

---

### Task 10: RunWorker — proactive `Process.send_after` timer

**Files:**
- Modify: `lib/mr_eric/runs/run_worker.ex`
- Modify: `test/mr_eric/runs_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/mr_eric/runs_test.exs`:

```elixir
  describe "approval TTL — proactive timer" do
    test "an unattended approval auto-expires when its timer fires" do
      run_id = unique_run_id()
      owner = "alice-#{System.unique_integer([:positive])}"
      :ok = Runs.subscribe(run_id)

      assert {:ok, _run} =
               Runs.start_run("Use tool", owner,
                 @opts ++ [id: run_id, orchestrator_module: ToolLoopOrchestrator])

      approval_id = await_pending_approval(run_id)

      # Make expires_at past, then send the timer message manually.
      :ok = MrEric.Runs.RunWorker.test_expire_approval(run_id, approval_id)
      pid = MrEric.Runs.RunWorker.test_pid(run_id)
      send(pid, {:expire_approval, approval_id})

      assert_receive {:tool_approval_expired,
                      %{run_id: ^run_id, approval_id: ^approval_id, reason: :ttl}}, 500
    end
  end
```

Add a small public test helper:

```elixir
  # Test-only: returns the GenServer pid for this run.
  def test_pid(run_id) do
    {:ok, pid} = lookup(run_id)
    pid
  end
```

(Place after `test_expire_approval/2` from Task 9.)

- [ ] **Step 2: Run the test**

Run: `mix test test/mr_eric/runs_test.exs`
Expected: test fails — `:expire_approval` is unhandled by `handle_info`.

- [ ] **Step 3: Schedule the timer when an approval is added**

In `prepare_tool_call/2` (around line 372), find the `:approval_required` branch:

```elixir
      {:approval_required, request} ->
        request =
          request
          |> Map.put(:role, role)
          |> put_risk_level()
          |> put_reply_to(reply_to)

        state =
          state
          |> broadcast_and_apply(:tool_approval_requested, public_tool_payload(request))

        put_in(state.pending_tool_approvals[request.approval_id], request)
```

Replace it with:

```elixir
      {:approval_required, request} ->
        request =
          request
          |> Map.put(:role, role)
          |> put_risk_level()
          |> put_reply_to(reply_to)

        state =
          state
          |> broadcast_and_apply(:tool_approval_requested, public_tool_payload(request))

        schedule_approval_expiry(request)

        put_in(state.pending_tool_approvals[request.approval_id], request)
```

Add the helper near the bottom of the module:

```elixir
  @approval_ttl_ms 30 * 60 * 1_000

  defp schedule_approval_expiry(%{approval_id: approval_id}) do
    Process.send_after(self(), {:expire_approval, approval_id}, @approval_ttl_ms)
  end
```

- [ ] **Step 4: Add the `handle_info` for `{:expire_approval, _}`**

Add after the existing `handle_info` clauses (around line 280):

```elixir
  @impl true
  def handle_info({:expire_approval, approval_id}, state) do
    case Map.get(state.pending_tool_approvals, approval_id) do
      nil ->
        # Already approved/denied — nothing to do
        {:noreply, state}

      request ->
        case check_expiry(request) do
          {:error, :expired} ->
            {:noreply, drop_expired_approval(state, approval_id, :ttl)}

          :ok ->
            # Clock skew or test manipulation — defer
            delay =
              DateTime.diff(request.expires_at, DateTime.utc_now(), :millisecond)
              |> max(1_000)

            Process.send_after(self(), {:expire_approval, approval_id}, delay)
            {:noreply, state}
        end
    end
  end
```

- [ ] **Step 5: Run the new test**

Run: `mix test test/mr_eric/runs_test.exs`
Expected: 0 failures.

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 7: Commit**

```bash
git add lib/mr_eric/runs/run_worker.ex test/mr_eric/runs_test.exs
git commit -m "feat(run_worker): proactive approval expiry timer

Scheduling Process.send_after for the 30-min TTL on approval
push. handle_info({:expire_approval, _}, state) clears stale
pending approvals and broadcasts :tool_approval_expired."
```

---

### Task 11: Run-lifecycle invalidation broadcasts `:tool_approval_expired`

**Files:**
- Modify: `lib/mr_eric/runs/run_worker.ex`
- Modify: `test/mr_eric/runs_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/mr_eric/runs_test.exs`:

```elixir
  describe "approval cleanup on run termination" do
    test "cancelling a run with a pending approval emits :tool_approval_expired" do
      run_id = unique_run_id()
      owner = "alice-#{System.unique_integer([:positive])}"
      :ok = Runs.subscribe(run_id)

      assert {:ok, _run} =
               Runs.start_run("Use tool", owner,
                 @opts ++ [id: run_id, orchestrator_module: ToolLoopOrchestrator])

      approval_id = await_pending_approval(run_id)

      :ok = Runs.cancel_run(run_id, owner)

      assert_receive {:tool_approval_expired,
                      %{run_id: ^run_id,
                        approval_id: ^approval_id,
                        reason: :run_terminated}}, 500
    end
  end
```

- [ ] **Step 2: Run the test**

Run: `mix test test/mr_eric/runs_test.exs`
Expected: test fails — current `maybe_resolve_pending_tool_approvals/2` only emits `:tool_approval_resolved`, not the new `:tool_approval_expired`.

- [ ] **Step 3: Update `maybe_resolve_pending_tool_approvals/2`**

In `lib/mr_eric/runs/run_worker.ex`, replace:

```elixir
  defp maybe_resolve_pending_tool_approvals(state, event)
       when event in [:run_completed, :run_failed, :run_cancelled] do
    Enum.each(state.pending_tool_approvals, fn {_approval_id, request} ->
      broadcast_tool_approval_resolved(state, request, false, "Run finished before approval.")
    end)

    %{state | pending_tool_approvals: %{}}
  end

  defp maybe_resolve_pending_tool_approvals(state, _event), do: state
```

with:

```elixir
  defp maybe_resolve_pending_tool_approvals(state, event)
       when event in [:run_completed, :run_failed, :run_cancelled] do
    Enum.each(state.pending_tool_approvals, fn {approval_id, request} ->
      broadcast_tool_approval_resolved(state, request, false, "Run finished before approval.")

      {ev, payload} =
        Events.normalize_event(state.run.id,
          {:tool_approval_expired,
           %{approval_id: approval_id, reason: :run_terminated}})

      Events.broadcast(state.run.id, {ev, payload})
    end)

    %{state | pending_tool_approvals: %{}}
  end

  defp maybe_resolve_pending_tool_approvals(state, _event), do: state
```

- [ ] **Step 4: Run the new test**

Run: `mix test test/mr_eric/runs_test.exs`
Expected: 0 failures.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric/runs/run_worker.ex test/mr_eric/runs_test.exs
git commit -m "feat(run_worker): run termination broadcasts tool_approval_expired

When a run becomes :completed/:failed/:cancelled, every pending
approval now receives both :tool_approval_resolved (existing
denied event for legacy listeners) and :tool_approval_expired
with reason :run_terminated for the new UI path."
```

---

### Task 12: LiveView `apply_tool_event/3` clause for `:tool_approval_expired`

**Files:**
- Modify: `lib/mr_eric_web/live/agent_live.ex`
- Modify: `test/mr_eric_web/live/agent_live_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/mr_eric_web/live/agent_live_test.exs`:

```elixir
  test ":tool_approval_expired removes the approval from the LiveView state",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # Drive the LiveView event loop directly with a synthetic expired event.
    # We simulate as if PubSub delivered it.
    send(view.pid, {:tool_approval_expired,
                    %{run_id: "test-run", approval_id: "ap-1", reason: :ttl}})

    # The current_run is blank, so the event is filtered out — but the
    # handler must not crash.
    assert render(view) =~ "MrEric AI Agent"
  end
```

This test is permissive — it asserts only that the event handler does not crash. A more comprehensive integration test (showing the "Expired" badge) is deferred to Spec E or a dedicated future test, since the rendering is conditional on a real run with a pending approval, which requires more LiveView setup.

- [ ] **Step 2: Run the test**

Run: `mix test test/mr_eric_web/live/agent_live_test.exs`
Expected: the new test fails because `apply_tool_event/3` does not handle `:tool_approval_expired` (the existing catch-all returns the socket unchanged, but the test sends the event raw — it will only be delivered to `handle_info({event, payload}, socket) when event in @run_events`, which now includes `:tool_approval_expired` after Task 7. So actually the event reaches `apply_tool_event/3`, hits the catch-all, and the socket is unchanged. The test should already pass.).

If the test passes without changes — that's still a meaningful regression guard. **Verify by running it before Step 3.**

If the test passes already, skip to Step 4 below.

- [ ] **Step 3: Add the new clause to `apply_tool_event/3`**

In `lib/mr_eric_web/live/agent_live.ex`, locate `apply_tool_event/3` (around line 595). Insert a new clause after the `:tool_approval_resolved` clause and before the catch-all `_event` clause:

```elixir
  defp apply_tool_event(socket, :tool_approval_expired, payload) do
    socket
    |> assign(:tool_approvals,
              Map.delete(socket.assigns.tool_approvals, payload.approval_id))
    |> assign(:expired_approvals,
              [payload | socket.assigns.expired_approvals])
  end
```

- [ ] **Step 4: Run the test**

Run: `mix test test/mr_eric_web/live/agent_live_test.exs`
Expected: 0 failures.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric_web/live/agent_live.ex test/mr_eric_web/live/agent_live_test.exs
git commit -m "feat(live): handle :tool_approval_expired event

apply_tool_event/3 removes the approval from assigns.tool_approvals
and appends the payload to assigns.expired_approvals. Rendering
of the 'Expired' badge is left to a future UI task — this is the
data-flow plumbing only."
```

---

## Section E — Verification

### Task 13: Final verification

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 2: Confirm no `Runs.start_run/2` callers remain**

Run:
```bash
git grep -nE "Runs\.(start_run|cancel_run|approve_tool|deny_tool)\(" lib/ test/
```

Every match must be the new arity:
- `Runs.start_run(task, owner_id, opts)` (3 args)
- `Runs.cancel_run(run_id, owner_id)` (2 args)
- `Runs.approve_tool(run_id, approval_id, owner_id)` (3 args)
- `Runs.deny_tool(run_id, approval_id, owner_id)` (3 args)

- [ ] **Step 3: Confirm no nil owner_id fallbacks**

Run:
```bash
git grep -nE "owner_id.*\|\|" lib/
```

Expected: zero matches in production code under `lib/` (test fixtures may use `||` for default test owner ids — that's fine).

- [ ] **Step 4: Confirm OwnerCheck is the only secret-path arbiter**

Run:
```bash
git grep -nE "owner_id\s*==" lib/
```

Expected: zero or one match (only inside `MrEric.Runs.OwnerCheck`). Any other equality check on owner_id is a bypass — investigate.

- [ ] **Step 5: Confirm `:tool_approval_expired` is wired**

Run:
```bash
git grep -nE "tool_approval_expired" lib/ test/
```

Expected: matches in:
- `lib/mr_eric/runs/events.ex` (event registration)
- `lib/mr_eric/runs/run_worker.ex` (broadcast call sites: reactive expiry, proactive timer, run termination)
- `lib/mr_eric_web/live/agent_live.ex` (apply_tool_event clause)
- `test/mr_eric/runs_test.exs` (3 test assertions)
- `test/mr_eric/runs/events_test.exs` (event registration test)

- [ ] **Step 6: Smoke test the LiveView via dev server**

This is a manual verification, useful when validating UI behaviour:

```bash
SECRET_KEY_BASE=$(mix phx.gen.secret) mix phx.server
```

Open `http://localhost:4000` in a browser. Open dev tools → Application → Cookies. Confirm a `_mr_eric_key` (or the configured session key) cookie is set; it contains a signed session including `owner_id`. This is sanity-only — no automated assertion needed.

If the dev server fails to start, check `config/runtime.exs` (Spec A) for `SECRET_KEY_BASE` resolution — Spec A should have made dev/test fall back to a per-boot random.

- [ ] **Step 7: Commit any docstring or README touches uncovered during verification**

If verification surfaces stale comments (e.g. references to `Runs.cancel_run/1` in module docs), fix them and commit:

```bash
git add lib/
git commit -m "docs(runs): refresh stale references to legacy 1-arity Runs API"
```

If nothing is stale, skip this commit.

---

## Follow-ups (out of scope for this plan)

- **Spec C** will revisit shell command boundary (drop `sh -lc`, case-fold `.git/.ssh`, TOCTOU re-validation).
- **Spec D** will harden RunSupervisor (max_children, brutal_kill cleanup, trace bounds, history caps).
- **Spec E** will fix the `rag_default_index` scenario fixture deferred from Spec A and add scorer early-pass + RAG caching.
- **Spec F** will set production HTTP config (force_ssl, HSTS, CSP, PHX_HOST hard-fail).
- **UI polish (future)** — render an "Expired" badge for entries in `assigns.expired_approvals`. The data flow is wired by Task 12; the visual treatment is intentionally deferred until a UI-focused spec.
- **Multi-user migration (out of any current spec)** — the `Runs.subscribe/1` and `Runs.get_run/1` APIs remain unrestricted. If multi-user becomes a goal, gate them on owner_id and add a `current_user` plug in front of `:browser`.
