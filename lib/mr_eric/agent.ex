defmodule MrEric.Agent do
  use GenServer

  alias MrEric.OpenAIClient

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{history: []}, name: name)
  end

  def execute(task, server \\ __MODULE__) do
    GenServer.call(server, {:execute, task})
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
  def handle_call({:execute, task}, _from, state) do
    plan_prompt = "Task: #{task}. Create a step-by-step plan to code this."
    plan = OpenAIClient.chat_completion(plan_prompt)

    code_prompt = "Based on plan: #{plan}. Generate Elixir code."
    code = OpenAIClient.chat_completion(code_prompt)

    entry = %{task: task, plan: plan, code: code, inserted_at: DateTime.utc_now()}
    history = [entry | state.history]

    {:reply, {:ok, entry}, %{state | history: history}}
  end
end
