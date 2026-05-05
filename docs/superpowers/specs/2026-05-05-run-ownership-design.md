# Spec B — Run Ownership & Approval Lifecycle

- **Date:** 2026-05-05
- **Status:** Draft (awaiting user review)
- **Scope:** Second of six security-hardening specs derived from the 2026-05-05 audit report.
- **Tracks audit findings:** Run ownership model gap, HMAC TTL gap (medium-severity).
- **Threat model:** Local single-user dev tool. Protect against accidental cross-tab/cross-browser hijack and stale approval replay. No multi-user authentication is in scope.

## Background

The `MrEric.Runs` context exposes mutating operations (`start_run`, `cancel_run`, `approve_tool`, `deny_tool`) that take only `run_id` as the addressing argument. Anyone who learns a `run_id` — for example through a shared log line, a leaked URL, or a second tab on the same machine — can cancel or approve another caller's run. The `MrEric.Tools.Executor` HMAC-signs an approval token bound to `(tool, args, approval_id, tool_call_id)`, but does not bind the token to a caller identity and does not enforce a time-to-live. A pending approval can therefore live forever in a paused-run worker, and there is no signal in the event stream when a long-pending approval is conceptually stale.

This spec adds session-bound run ownership end-to-end, gives every approval a 30-minute hard TTL on top of run-lifecycle binding, and emits an explicit `tool_approval_expired` event so the LiveView UI can deactivate the button.

## Goals

- Ensure that only the originating browser session can cancel, approve, or deny a run.
- Surface a deterministic `:not_owner` error when a non-owner attempts a mutation. The Run state must not change in that case.
- Bind every approval token to a hard 30-minute expiration on top of run-lifecycle invalidation, with a `tool_approval_expired` event when expiry fires.
- Keep read-side APIs (`get_run`, `subscribe`) unrestricted in the local-dev threat model — they are useful for IEx debugging and impose no real risk on a single-user host.
- Update the eval harness to use a fixed internal owner id (`"eval-runner"`) so it shares the same code path.

## Non-Goals

- Multi-user authentication, login flow, or `current_user` plumbing.
- Replacing or rotating the HMAC secret beyond its existing per-boot `:persistent_term` initialisation.
- Audit logging of ownership-check failures (one `Logger.warning` per failure is enough; structured audit log is a future Spec).
- Gating PubSub subscriptions on owner_id. The LiveView only subscribes to its own `run_id`, and the broadcast topics are not enumerable in production. Local single-user threat model does not require this.
- Rewriting the existing approval token signing algorithm. The `:crypto.mac(:sha256, ...)` HMAC stays; we only extend the signed tuple to include `owner_id` and add an `expires_at` field to the request map.
- Changing the LiveView rendering structure. UI updates are localised to disabling the approve/deny buttons when an approval expires.

## Architecture overview

```
                  ┌─────────────────────────┐
Browser session   │  Phoenix session cookie │  owner_id (16 bytes random, base64url)
                  └────────────┬────────────┘
                               │ Plug: EnsureOwnerId
                               ↓
                  ┌─────────────────────────┐
LiveView          │  AgentLive.mount        │  reads session["owner_id"] → assigns
                  └────────────┬────────────┘
                               │ each event handler
                               ↓
                  ┌─────────────────────────┐
Context API       │  MrEric.Runs            │  cancel_run(run_id, owner_id)
                  └────────────┬────────────┘                 ^
                               │ owner check                  │ argument is required
                               ↓                              │
                  ┌─────────────────────────┐
Worker            │  RunWorker (per run)    │  Run struct holds owner_id
                  │   + Approval queue      │  Approval has requested_at + 30min hard TTL
                  └─────────────────────────┘
```

Four new components sit on top of the existing flow. None of them rewrite existing logic; they wrap or extend it.

1. `MrEric.Plugs.EnsureOwnerId` — `:browser` pipeline plug that mints and persists a per-session owner id.
2. `MrEric.Runs.OwnerCheck` (private module) — single helper that compares a `Run.owner_id` to a supplied owner id and returns `{:ok, run} | {:error, :not_owner}`.
3. Updated `MrEric.Runs` API — owner_id required argument on the four mutating functions; stored on the `Run` struct at `start_run`.
4. `RunWorker` approval lifecycle — `expires_at` on every pending approval; reactive expiry on approve/deny; proactive `Process.send_after` timer; `tool_approval_expired` event; pending approvals drop on terminal run status.

## Section 1 — Owner identity flow (Plug + Session + LiveView)

### `MrEric.Plugs.EnsureOwnerId`

Idempotent plug placed immediately after `:fetch_session` in the `:browser` pipeline. Generates an owner id only when the session does not already carry one.

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

### Router pipeline

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug MrEric.Plugs.EnsureOwnerId      # ← added immediately after :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {MrEricWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
end
```

### `AgentLive.mount/3`

```elixir
def mount(_params, session, socket) do
  owner_id =
    Map.get(session, "owner_id") ||
      raise "owner_id missing from session — EnsureOwnerId plug not in pipeline?"

  socket =
    socket
    |> assign(owner_id: owner_id)
    # ... existing assigns ...

  {:ok, socket}
end
```

`raise` on missing owner_id is intentional. A nil fallback would silently strip ownership in any code path that bypasses the `:browser` pipeline. With a hard raise, mis-wired pipelines surface in the test suite or first browser visit instead of in production.

### Test helper

`test/support/conn_case.ex` adds a small helper that injects a known owner_id without requiring the full HTTP plug chain in unit tests:

```elixir
def with_owner_session(conn, owner_id \\ "test-owner-#{System.unique_integer([:positive])}") do
  conn |> Plug.Test.init_test_session(%{"owner_id" => owner_id})
end
```

## Section 2 — Runs API + Run struct + RunWorker

### `Run` struct change

`lib/mr_eric/runs/run.ex`:

```elixir
defstruct [
  :id,
  :owner_id,         # ← added. binary, must be set at construction time
  :task,
  :status,
  # ... existing fields ...
]
```

`Run.new/2` requires `:owner_id` in `opts` (`Keyword.fetch!`). No nil fallback, no test-mode bypass. Eval/internal callers pass an explicit synthetic id (`"eval-runner"`).

### `MrEric.Runs.OwnerCheck`

```elixir
defmodule MrEric.Runs.OwnerCheck do
  @moduledoc false

  alias MrEric.Runs.Run

  @spec verify(Run.t() | {:error, term()}, binary()) ::
          {:ok, Run.t()} | {:error, :not_owner | :not_found | term()}
  def verify({:error, reason}, _owner_id), do: {:error, reason}

  def verify(%Run{owner_id: owner_id} = run, owner_id) when is_binary(owner_id) do
    {:ok, run}
  end

  def verify(%Run{}, _other_owner_id), do: {:error, :not_owner}
end
```

A direct pattern match is sufficient — both sides are server-internal binaries of equal length. The local-dev threat model does not require constant-time comparison.

### `MrEric.Runs` API signatures

| Before                                       | After                                                |
|----------------------------------------------|------------------------------------------------------|
| `start_run(task, opts)`                      | `start_run(task, owner_id, opts)`                    |
| `cancel_run(run_id)`                         | `cancel_run(run_id, owner_id)`                       |
| `approve_tool(run_id, approval_id)`          | `approve_tool(run_id, approval_id, owner_id)`        |
| `deny_tool(run_id, approval_id)`             | `deny_tool(run_id, approval_id, owner_id)`           |
| `get_run(run_id)`                            | unchanged                                            |
| `subscribe(run_id)` / `unsubscribe(run_id)`  | unchanged                                            |
| `broadcast(run_id, event)`                   | unchanged (server-internal)                          |

`get_run` and `subscribe` are unrestricted by design. In local-dev mode they help debugging from IEx, and the LiveView only subscribes to its own run.

### `RunWorker` enforcement

Every mutation in the GenServer call hierarchy validates ownership before touching state:

```elixir
def handle_call({:cancel, owner_id}, _from, state) do
  case OwnerCheck.verify(state.run, owner_id) do
    {:ok, _run} ->
      {:reply, :ok, do_cancel(state)}

    {:error, :not_owner} = err ->
      Logger.warning("run #{state.run.id}: cancel attempted by non-owner")
      {:reply, err, state}
  end
end
```

`approve_tool` and `deny_tool` follow the same shape. On `:not_owner`, the state is unchanged, no event is broadcast (no leakage signal to the attacker), and a `Logger.warning` is emitted for ops visibility.

### Eval harness

`MrEric.Evals.Runner` hardcodes its owner id:

```elixir
@eval_owner_id "eval-runner"
```

All `start_run` / `approve_tool` / `cancel_run` calls inside the eval module pass `@eval_owner_id`. The eval has no LiveView session; this fixed binary is the canonical "I am the eval harness" id.

### LiveView event handler shape

```elixir
def handle_event("cancel_run", _params, socket) do
  case Runs.cancel_run(current_run_id!(socket), socket.assigns.owner_id) do
    :ok ->
      {:noreply, socket}

    {:error, :not_owner} ->
      {:noreply, socket |> put_flash(:error, "このRunの操作権限がありません")}

    {:error, reason} ->
      {:noreply, socket |> put_flash(:error, "Cancel failed: #{inspect(reason)}")}
  end
end
```

`approve_tool` / `deny_tool` handlers receive the same treatment.

## Section 3 — Approval lifecycle (TTL + expiry event)

### Approval request shape

`lib/mr_eric/tools/executor.ex` augments the request map and HMAC payload:

```elixir
@approval_ttl_seconds 30 * 60   # 30 minutes hard cap

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

defp approval_token(tool, args, approval_id, tool_call_id, owner_id) do
  data = :erlang.term_to_binary({tool, args, approval_id, tool_call_id, owner_id})

  :hmac
  |> :crypto.mac(:sha256, approval_secret(), data)
  |> Base.url_encode64(padding: false)
end
```

`verify_approval_request/1` recomputes the HMAC with the new 5-tuple. The owner_id is read from the request map itself (it never leaves the server, so tampering is not a threat); the HMAC binding is defence-in-depth.

### Two-stage TTL enforcement

The worker uses both a **reactive** check (on each approve/deny) and a **proactive** timer.

#### Reactive (on approve_tool / deny_tool)

```elixir
defp resolve_approval(state, approval_id, owner_id, action)
    when action in [:approve, :deny] do
  with {:ok, request} <- find_pending_approval(state, approval_id),
       {:ok, _run} <- OwnerCheck.verify(state.run, owner_id),
       :ok <- check_expiry(request) do
    # existing approve/deny processing
  else
    {:error, :expired} ->
      state = drop_pending(state, approval_id)
      Events.broadcast(state.run.id,
        {:tool_approval_expired, %{approval_id: approval_id, reason: :ttl}})
      {:reply, {:error, :approval_expired}, state}

    err ->
      {:reply, err, state}
  end
end

defp check_expiry(%{expires_at: expires_at}) do
  if DateTime.compare(DateTime.utc_now(), expires_at) == :gt do
    {:error, :expired}
  else
    :ok
  end
end
```

#### Proactive (timer)

When pushing an approval into `state.pending_approvals`, schedule expiry:

```elixir
Process.send_after(self(), {:expire_approval, approval_id}, @approval_ttl_seconds * 1000)
```

```elixir
def handle_info({:expire_approval, approval_id}, state) do
  case Map.get(state.pending_approvals, approval_id) do
    nil ->
      {:noreply, state}        # already approved/denied

    request ->
      if DateTime.compare(DateTime.utc_now(), request.expires_at) == :gt do
        Events.broadcast(state.run.id,
          {:tool_approval_expired, %{approval_id: approval_id, reason: :ttl}})
        {:noreply, drop_pending(state, approval_id)}
      else
        # Clock skew or manual reschedule — defer
        delay = DateTime.diff(request.expires_at, DateTime.utc_now(), :millisecond)
        Process.send_after(self(), {:expire_approval, approval_id}, max(delay, 1_000))
        {:noreply, state}
      end
  end
end
```

### Run-lifecycle invalidation

When a run transitions to `:cancelled` / `:failed` / `:completed`, the worker drops every pending approval and broadcasts `tool_approval_expired` with `reason: :run_terminated` so subscribers can retire the UI cards in one pass:

```elixir
defp on_run_terminal(state) do
  Enum.each(state.pending_approvals, fn {approval_id, _request} ->
    Events.broadcast(state.run.id,
      {:tool_approval_expired, %{approval_id: approval_id, reason: :run_terminated}})
  end)

  %{state | pending_approvals: %{}}
end
```

### Where `tool_approval_expired` is consumed

The `Run` struct does **not** track pending approvals — only `:status` and event-derived stage data. Pending approval data lives in two places:

- `RunWorker.state.pending_approvals` (map of `approval_id => request`).
- `AgentLive` socket `assigns.tool_approvals` (map of `approval_id => request`), populated from the `:tool_approval_requested` event and removed on `:tool_approval_resolved`.

Therefore `Run.apply_event/2` needs **no** new clause for `:tool_approval_expired` — the existing catch-all clause leaves the run unchanged, which is correct (status does not change). The new event is handled in two new places:

1. `AgentLive` — extend `apply_tool_event/3` to remove the approval from `assigns.tool_approvals` and append it to a new `assigns.expired_approvals` list (for the "Expired" badge to render):

   ```elixir
   defp apply_tool_event(socket, :tool_approval_expired, payload) do
     socket
     |> assign(:tool_approvals,
                Map.delete(socket.assigns.tool_approvals, payload.approval_id))
     |> assign(:expired_approvals,
                [payload | socket.assigns.expired_approvals])
   end
   ```

   `expired_approvals` is initialised to `[]` in `mount/3`.

2. UI template — approval cards keyed by `approval_id` in `assigns.tool_approvals` continue to render Approve/Deny buttons; entries in `assigns.expired_approvals` render an "Expired" badge with no buttons. The LLM can re-request the same tool through its existing error path — a fresh approval with a new `approval_id` and `expires_at` is generated.

This keeps the `Run` struct minimal and event-sourcing clean: the `:tool_approval_expired` event is informational at the Run level (no struct change) and is the LiveView's responsibility to render.

## Acceptance criteria

A reviewer of the merged branch should be able to verify each of the following:

1. **Plug correctness.** A first browser visit (no prior session cookie) reaches the LiveView mount with a non-nil `session["owner_id"]`. A second visit in the same browser session reaches mount with the *same* owner_id.
2. **Run-API tightness.** `MrEric.Runs.start_run/3`, `cancel_run/2`, `approve_tool/3`, `deny_tool/3` all require `owner_id` and refuse `nil`. Running `mix test` against a stub call without `owner_id` is a compile error or `FunctionClauseError`.
3. **Cross-owner denial.** A test that calls `Runs.cancel_run(run_id, "other-owner")` returns `{:error, :not_owner}` and the underlying run remains in its prior status. `Logger.warning` was emitted.
4. **HMAC TTL — reactive.** A test that fast-forwards the system clock past `expires_at` (or spawns the request with a fixed `requested_at` 31 minutes ago) and then calls `approve_tool/3` returns `{:error, :approval_expired}` and a `tool_approval_expired` event with `reason: :ttl` is observed by a subscribed PubSub listener.
5. **HMAC TTL — proactive.** A test that puts an approval and then waits past TTL (using `Process.send/3` to fire the timer) observes `tool_approval_expired` without any explicit approve/deny call.
6. **Run-lifecycle invalidation.** A test that cancels a run with one pending approval observes one `tool_approval_expired` event with `reason: :run_terminated`. The pending approval map is empty.
7. **Eval harness compatibility.** `mix test test/mr_eric/evals/` passes after the API changes — eval calls use the fixed `"eval-runner"` owner id throughout.
8. **LiveView regression.** A LiveView test (`Phoenix.LiveViewTest`) that mounts the page, starts a run, simulates an approval prompt, clicks "Approve", and observes the tool result — passes end-to-end through the new owner-bound API.
9. **No public-API surface for ownership bypass.** `git grep -nE "owner_id" lib/` shows no `nil` defaults or `|| nil` fallbacks in any production code path. Tests opt in explicitly via `with_owner_session` or the eval constant.

## Out of scope (tracked elsewhere)

- Tool boundary hardening (Spec C): `sh -lc` removal, `.git/.ssh` case-fold, TOCTOU re-validation.
- Run lifetime / resources (Spec D): max_children, brutal_kill cleanup, trace bounds.
- Eval / RAG correctness (Spec E): scorer early-pass, RAG caching, `rag_default_index` scenario fixture.
- Production HTTP config (Spec F): force_ssl, HSTS, CSP, PHX_HOST hard-fail.
