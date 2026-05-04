defmodule MrEric.Agent do
  @moduledoc """
  Manages the state and execution history of AI agent tasks.

  `execute/2` delegates the long-running orchestrator work to a Task running
  under `MrEric.Agent.TaskSupervisor`, so the GenServer stays responsive for
  history queries and concurrent `record/2` calls from `RunWorker`. The
  external contract (`{:ok, entry}` / `{:error, reason}`) is preserved.
  """
  use GenServer

  alias MrEric.Orchestrator

  @default_task_supervisor MrEric.Agent.TaskSupervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    task_supervisor = Keyword.get(opts, :task_supervisor, @default_task_supervisor)

    GenServer.start_link(
      __MODULE__,
      %{history: [], task_supervisor: task_supervisor, pending: %{}},
      name: name
    )
  end

  def execute(task, opts \\ [])

  def execute(task, opts) when is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    orchestrator_opts = Keyword.delete(opts, :server)

    GenServer.call(server, {:execute, task, orchestrator_opts}, :infinity)
  end

  def execute(task, server) do
    GenServer.call(server, {:execute, task, []}, :infinity)
  end

  def history(server \\ __MODULE__) do
    GenServer.call(server, :history)
  end

  def record(entry, opts \\ []) when is_map(entry) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:record, entry})
  end

  @impl true
  def init(state) when is_map(state), do: {:ok, state}

  @impl true
  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  @impl true
  def handle_call({:record, entry}, _from, state) do
    history = [entry | state.history]
    {:reply, {:ok, entry}, %{state | history: history}}
  end

  @impl true
  def handle_call({:execute, task, opts}, from, state) do
    task_struct =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Orchestrator.run(task, opts)
      end)

    pending = Map.put(state.pending, task_struct.ref, %{from: from, task: task, opts: opts})
    {:noreply, %{state | pending: pending}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from, task: task, opts: opts}, pending} ->
        Process.demonitor(ref, [:flush])
        state = %{state | pending: pending}

        case result do
          {:ok, run_result} ->
            entry = build_entry(task, opts, run_result)
            history = [entry | state.history]
            GenServer.reply(from, {:ok, entry})
            {:noreply, %{state | history: history}}

          {:error, reason} ->
            GenServer.reply(from, {:error, reason})
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, reason})
        {:noreply, %{state | pending: pending}}
    end
  end

  defp build_entry(task, opts, result) do
    %{
      id: System.unique_integer([:positive]),
      task: task,
      provider: Keyword.get(opts, :provider),
      model: Keyword.get(opts, :model),
      plan: result.plan,
      code: result.final,
      final: result.final,
      planner: result.planner,
      drafts: result.drafts,
      draft_errors: result.draft_errors,
      reviews: result.reviews,
      review_errors: result.review_errors,
      synthesizer: result.synthesizer,
      synthesis_error: result.synthesis_error,
      changed_files: [],
      inserted_at: DateTime.utc_now()
    }
  end
end
