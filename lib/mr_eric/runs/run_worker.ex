defmodule MrEric.Runs.RunWorker do
  @moduledoc """
  Owns one run, receives Orchestrator.stream/3 events, and rebroadcasts them.
  """

  use GenServer

  alias MrEric.Agent
  alias MrEric.Orchestrator
  alias MrEric.Runs.Events
  alias MrEric.Runs.OwnerCheck
  alias MrEric.Runs.Run
  alias MrEric.Tools.Executor

  @registry MrEric.Runs.Registry
  @run_events Events.names()
  @public_tool_keys [
    :approval_id,
    :tool_call_id,
    :tool,
    :args,
    :role,
    :reason,
    :risk_level,
    :requested_at
  ]

  def start_link(opts) do
    run = Keyword.fetch!(opts, :run)

    opts
    |> Keyword.get(:name, :registry)
    |> start_link_with_name(run, opts)
  end

  def child_spec(opts) do
    run = Keyword.fetch!(opts, :run)

    %{
      id: {__MODULE__, run.id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  def get_run(pid) when is_pid(pid), do: GenServer.call(pid, :get_run)

  def get_run(run_id) do
    case lookup(run_id) do
      {:ok, pid} -> get_run(pid)
      :error -> {:error, :not_found}
    end
  end

  def cancel(pid, owner_id) when is_pid(pid) and is_binary(owner_id) do
    GenServer.call(pid, {:cancel, owner_id})
  end

  def cancel(run_id, owner_id) when is_binary(owner_id) do
    case lookup(run_id) do
      {:ok, pid} -> cancel(pid, owner_id)
      :error -> {:error, :not_found}
    end
  end

  def approve_tool(pid, approval_id, owner_id) when is_pid(pid) and is_binary(owner_id) do
    GenServer.call(pid, {:approve_tool, approval_id, owner_id})
  end

  def approve_tool(run_id, approval_id, owner_id) when is_binary(owner_id) do
    case lookup(run_id) do
      {:ok, pid} -> approve_tool(pid, approval_id, owner_id)
      :error -> {:error, :not_found}
    end
  end

  def deny_tool(pid, approval_id, owner_id) when is_pid(pid) and is_binary(owner_id) do
    GenServer.call(pid, {:deny_tool, approval_id, owner_id})
  end

  def deny_tool(run_id, approval_id, owner_id) when is_binary(owner_id) do
    case lookup(run_id) do
      {:ok, pid} -> deny_tool(pid, approval_id, owner_id)
      :error -> {:error, :not_found}
    end
  end

  def via(run_id), do: {:via, Registry, {@registry, run_id}}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    run = Keyword.fetch!(opts, :run)
    worker_opts = Keyword.get(opts, :opts, [])
    auto_start = Keyword.get(opts, :auto_start, true)

    state = %{
      run: run,
      opts: worker_opts,
      task: nil,
      cancelled?: false,
      history_recorded?: false,
      pending_tool_approvals: %{}
    }

    if auto_start do
      {:ok, state, {:continue, :start}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:start, state) do
    {event, payload} =
      Events.normalize_event(state.run.id, {:run_started, %{task: state.run.task}})

    run =
      state.run
      |> Run.apply_event({event, payload})

    Events.broadcast(run.id, {event, payload})

    worker = self()
    orchestrator = Keyword.get(state.opts, :orchestrator_module, Orchestrator)
    stream_opts = Keyword.put(state.opts, :run_id, run.id)

    task =
      Task.async(fn ->
        orchestrator.stream(run.task, worker, stream_opts)
      end)

    {:noreply, %{state | run: run, task: task}}
  end

  @impl true
  def handle_continue({:execute_approved_tool, request}, state) do
    {:noreply, execute_tool_request(request, state)}
  end

  @impl true
  def handle_call(:get_run, _from, state) do
    {:reply, {:ok, state.run}, state}
  end

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

  @impl true
  def handle_info({event, payload}, state) when event in @run_events do
    if state.cancelled? and event != :run_cancelled do
      {:noreply, state}
    else
      {event, payload} = Events.normalize_event(state.run.id, {event, payload})

      run = Run.apply_event(state.run, {event, payload})

      state =
        state
        |> Map.put(:run, run)
        |> maybe_resolve_pending_tool_approvals(event)

      state =
        state
        |> maybe_record_history(event)

      Events.broadcast(run.id, {event, payload})

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tool_call, payload}, state) do
    handle_tool_request(payload, state)
  end

  @impl true
  def handle_info({:tool_requested, payload}, state) do
    handle_tool_request(payload, state)
  end

  @impl true
  def handle_info({ref, _result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task: nil}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    state =
      cond do
        state.cancelled? ->
          %{state | task: nil}

        reason == :normal ->
          %{state | task: nil}

        true ->
          {event, payload} = Events.normalize_event(state.run.id, {:run_failed, %{error: reason}})
          run = Run.apply_event(state.run, {event, payload})

          state =
            state
            |> Map.put(:run, run)
            |> Map.put(:task, nil)
            |> maybe_resolve_pending_tool_approvals(:run_failed)

          Events.broadcast(run.id, {event, payload})
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp handle_tool_request(payload, state) do
    cond do
      state.cancelled? ->
        {:noreply, state}

      Run.terminal?(state.run) ->
        {:noreply, state}

      true ->
        {:noreply, prepare_tool_call(payload, state)}
    end
  end

  defp start_link_with_name(nil, _run, opts), do: GenServer.start_link(__MODULE__, opts)
  defp start_link_with_name(false, _run, opts), do: GenServer.start_link(__MODULE__, opts)

  defp start_link_with_name(:registry, run, opts) do
    GenServer.start_link(__MODULE__, opts, name: via(run.id))
  end

  defp start_link_with_name(name, _run, opts),
    do: GenServer.start_link(__MODULE__, opts, name: name)

  defp lookup(run_id) do
    case Registry.lookup(@registry, run_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp shutdown_task(nil), do: :ok
  defp shutdown_task(task), do: Task.shutdown(task, :brutal_kill)

  defp maybe_resolve_pending_tool_approvals(state, event)
       when event in [:run_completed, :run_failed, :run_cancelled] do
    Enum.each(state.pending_tool_approvals, fn {_approval_id, request} ->
      broadcast_tool_approval_resolved(state, request, false, "Run finished before approval.")
    end)

    %{state | pending_tool_approvals: %{}}
  end

  defp maybe_resolve_pending_tool_approvals(state, _event), do: state

  defp broadcast_tool_approval_resolved(state, request, approved, reason) do
    broadcast_and_apply(
      state,
      :tool_approval_resolved,
      public_tool_payload(request, %{
        approved: approved,
        reason: reason,
        pending_approvals_count: map_size(state.pending_tool_approvals)
      })
    )
  end

  defp prepare_tool_call(payload, state) when is_map(payload) do
    tool =
      Map.get(payload, :tool_name) || Map.get(payload, "tool_name") ||
        Map.get(payload, :tool) || Map.get(payload, "tool")

    args =
      Map.get(payload, :input) || Map.get(payload, "input") ||
        Map.get(payload, :args) || Map.get(payload, "args") || %{}

    reply_to = reply_to(payload)
    role = Map.get(payload, :role) || Map.get(payload, "role")
    reason = Map.get(payload, :reason) || Map.get(payload, "reason")

    tool_call_id =
      Map.get(payload, :tool_call_id) || Map.get(payload, "tool_call_id") || new_id("tool-call")

    approval_id = Map.get(payload, :approval_id) || Map.get(payload, "approval_id")
    opts = tool_opts(state, tool_call_id, approval_id)

    case Executor.request_tool(tool, args, reason, opts) do
      {:ok, result} ->
        request =
          %{tool: tool, args: args, tool_call_id: tool_call_id, role: role}
          |> put_risk_level()
          |> put_reply_to(reply_to)

        state
        |> broadcast_tool_started(request)
        |> broadcast_tool_completed(request, result)

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

      {:error, reason} ->
        request =
          %{tool: tool, args: args, tool_call_id: tool_call_id, role: role}
          |> put_risk_level()
          |> put_reply_to(reply_to)

        broadcast_tool_denied(state, request, reason)
    end
  end

  defp prepare_tool_call(_payload, state), do: state

  defp execute_tool_request(request, state) do
    state
    |> broadcast_tool_started(request)
    |> do_execute_tool_request(request)
  end

  defp do_execute_tool_request(state, request) do
    case Executor.execute_approved(request, tool_opts(state, request.tool_call_id, nil)) do
      {:ok, result} -> broadcast_tool_completed(state, request, result)
      {:error, reason} -> broadcast_tool_failed(state, request, reason)
    end
  end

  defp broadcast_tool_started(state, request) do
    broadcast_and_apply(state, :tool_started, tool_event_payload(request))
  end

  defp broadcast_tool_completed(state, request, result) do
    state =
      broadcast_and_apply(
        state,
        :tool_completed,
        Map.merge(tool_event_payload(request), %{result: result})
      )

    reply_tool_result(request, :completed, %{result: result})

    state
  end

  defp broadcast_tool_failed(state, request, reason) do
    state =
      broadcast_and_apply(
        state,
        :tool_failed,
        Map.merge(tool_event_payload(request), %{error: reason})
      )

    reply_tool_result(request, :failed, %{error: reason})

    state
  end

  defp broadcast_tool_denied(state, request, reason) do
    state =
      broadcast_and_apply(
        state,
        :tool_denied,
        Map.merge(tool_event_payload(request), %{error: reason})
      )

    reply_tool_result(request, :denied, %{error: reason})

    state
  end

  defp broadcast_tool_rejected(state, request, reason) do
    state =
      broadcast_and_apply(
        state,
        :tool_rejected,
        Map.merge(tool_event_payload(request), %{error: reason})
      )

    reply_tool_result(request, :rejected, %{error: reason})

    state
  end

  defp broadcast_and_apply(state, event, payload) do
    {event, payload} = Events.normalize_event(state.run.id, {event, payload})
    run = Run.apply_event(state.run, {event, payload})
    Events.broadcast(run.id, {event, payload})
    %{state | run: run}
  end

  defp tool_event_payload(request) do
    Map.take(request, [:tool, :args, :tool_call_id, :role, :risk_level])
  end

  defp public_tool_payload(request, extra \\ %{}) do
    request
    |> Map.take(@public_tool_keys)
    |> Map.merge(extra)
  end

  defp reply_to(payload) do
    case Map.get(payload, :reply_to) || Map.get(payload, "reply_to") do
      pid when is_pid(pid) -> pid
      _other -> nil
    end
  end

  defp put_reply_to(request, nil), do: request
  defp put_reply_to(request, reply_to), do: Map.put(request, :reply_to, reply_to)

  defp put_risk_level(request) do
    Map.put(request, :risk_level, risk_level_for(Map.get(request, :tool)))
  end

  defp risk_level_for(tool)
       when tool in [:shell_command, "shell_command", :apply_patch, "apply_patch"],
       do: :high

  defp risk_level_for(tool)
       when tool in [:file_write_proposal, "file_write_proposal", :git_diff, "git_diff"],
       do: :medium

  defp risk_level_for(_tool), do: :low

  defp reply_tool_result(request, status, fields) do
    case Map.get(request, :reply_to) do
      pid when is_pid(pid) ->
        send(
          pid,
          {:tool_result,
           request
           |> Map.take([:tool_call_id, :tool, :args])
           |> Map.merge(%{status: status})
           |> Map.merge(fields)}
        )

      _other ->
        :ok
    end
  end

  defp tool_opts(state, tool_call_id, nil) do
    state.opts
    |> Keyword.put(:tool_call_id, tool_call_id)
    |> Keyword.put_new(:workspace_root, File.cwd!())
  end

  defp tool_opts(state, tool_call_id, approval_id) do
    state
    |> tool_opts(tool_call_id, nil)
    |> Keyword.put(:approval_id, approval_id)
  end

  defp new_id(prefix) do
    prefix <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end

  defp maybe_record_history(%{history_recorded?: true} = state, _event), do: state
  defp maybe_record_history(state, event) when event != :run_completed, do: state

  defp maybe_record_history(state, :run_completed) do
    if Keyword.get(state.opts, :skip_history, false) do
      %{state | history_recorded?: true}
    else
      Agent.record(Run.to_history_entry(state.run),
        server: Keyword.get(state.opts, :agent_server, Agent)
      )

      %{state | history_recorded?: true}
    end
  end
end
