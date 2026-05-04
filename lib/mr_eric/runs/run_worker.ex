defmodule MrEric.Runs.RunWorker do
  @moduledoc """
  Owns one run, receives Orchestrator.stream/3 events, and rebroadcasts them.
  """

  use GenServer

  alias MrEric.Agent
  alias MrEric.Orchestrator
  alias MrEric.Runs.Events
  alias MrEric.Runs.Run

  @registry MrEric.Runs.Registry

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

  def cancel(pid) when is_pid(pid), do: GenServer.call(pid, :cancel)

  def cancel(run_id) do
    case lookup(run_id) do
      {:ok, pid} -> cancel(pid)
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
      history_recorded?: false
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
  def handle_call(:get_run, _from, state) do
    {:reply, {:ok, state.run}, state}
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    state =
      if Run.terminal?(state.run) do
        state
      else
        shutdown_task(state.task)

        {event, payload} = Events.normalize_event(state.run.id, {:run_cancelled, %{}})
        run = Run.apply_event(state.run, {event, payload})
        Events.broadcast(run.id, {event, payload})

        %{state | run: run, task: nil, cancelled?: true}
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({event, payload}, state)
      when event in [
             :run_started,
             :stage_started,
             :stage_chunk,
             :stage_completed,
             :stage_failed,
             :run_completed,
             :run_failed,
             :run_cancelled
           ] do
    if state.cancelled? and event != :run_cancelled do
      {:noreply, state}
    else
      {event, payload} = Events.normalize_event(state.run.id, {event, payload})

      run =
        state.run
        |> Run.apply_event({event, payload})

      Events.broadcast(run.id, {event, payload})

      state =
        state
        |> Map.put(:run, run)
        |> maybe_record_history(event)

      {:noreply, state}
    end
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
          Events.broadcast(run.id, {event, payload})
          %{state | run: run, task: nil}
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
