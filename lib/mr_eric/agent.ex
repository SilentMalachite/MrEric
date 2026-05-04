defmodule MrEric.Agent do
  @moduledoc """
  Manages the state and execution history of AI agent tasks.
  """
  use GenServer

  alias MrEric.Orchestrator

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{history: []}, name: name)
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

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  @impl true
  def handle_call({:execute, task, opts}, _from, state) do
    with {:ok, result} <- Orchestrator.run(task, opts) do
      entry = %{
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
        inserted_at: DateTime.utc_now()
      }

      history = [entry | state.history]

      {:reply, {:ok, entry}, %{state | history: history}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
end
