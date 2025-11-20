defmodule MrEricWeb.AgentLive do
  use MrEricWeb, :live_view

  alias MrEric.Agent
  alias MrEric.OpenAIClient
  alias MrEricWeb.Layouts

  @available_models [
    {"GPT-4o (Recommended)", "gpt-4o"},
    {"GPT-4o Mini", "gpt-4o-mini"},
    {"GPT-4 Turbo", "gpt-4-turbo"},
    {"GPT-4", "gpt-4"},
    {"GPT-3.5 Turbo", "gpt-3.5-turbo"},
    {"O1 Preview", "o1-preview"},
    {"O1 Mini", "o1-mini"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    default_model = Application.get_env(:mr_eric, :openai_model, "gpt-4o")

    {:ok,
     socket
     |> assign(
       loading: false,
       response: "",
       selected_model: default_model,
       available_models: @available_models,
       form: to_form(%{"task" => ""})
     )
     |> stream(:history, Agent.history())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-4xl mx-auto space-y-6">
        <div class="rounded-lg border border-zinc-200 bg-white p-6 shadow-sm">
          <h1 class="text-2xl font-bold mb-4">MrEric AI Agent</h1>

          <.form for={@form} id="task-form" phx-submit="execute" class="space-y-4">
            <div>
              <label class="block text-sm font-medium text-zinc-700 mb-2">
                OpenAI Model
              </label>
              <select
                name="model"
                phx-change="change_model"
                class="w-full rounded-lg border-zinc-300 focus:border-zinc-400 focus:ring focus:ring-zinc-200 focus:ring-opacity-50"
              >
                <option
                  :for={{label, value} <- @available_models}
                  value={value}
                  selected={value == @selected_model}
                >
                  {label}
                </option>
              </select>
              <p class="mt-1 text-sm text-zinc-500">
                Currently using: <span class="font-mono font-semibold">{@selected_model}</span>
              </p>
            </div>

            <div>
              <label class="block text-sm font-medium text-zinc-700 mb-2">
                Task Description
              </label>
              <.input
                field={@form[:task]}
                type="text"
                placeholder="Enter task for AI agent..."
                class="w-full"
              />
            </div>

            <.button
              type="submit"
              disabled={@loading}
              class="w-full bg-blue-600 hover:bg-blue-700 text-white font-semibold py-2 px-4 rounded-lg disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <%= if @loading do %>
                <span class="flex items-center justify-center">
                  <.icon name="hero-arrow-path" class="w-5 h-5 mr-2 animate-spin" />
                  Processing...
                </span>
              <% else %>
                Execute Task
              <% end %>
            </.button>
          </.form>
        </div>

        <div :if={@response != ""} class="rounded-lg border border-blue-200 bg-blue-50 p-6 shadow-sm">
          <h2 class="font-semibold text-lg mb-3 text-blue-900">
            <.icon name="hero-sparkles" class="w-5 h-5 inline mr-2" />
            Streaming Response
          </h2>
          <pre class="whitespace-pre-wrap text-sm font-mono text-zinc-800 bg-white p-4 rounded border">{@response}</pre>
        </div>

        <div class="space-y-4">
          <h2 class="font-semibold text-xl flex items-center">
            <.icon name="hero-clock" class="w-6 h-6 mr-2" />
            Execution History
          </h2>
          <div id="history" phx-update="stream" class="space-y-4">
            <div :for={{id, entry} <- @streams.history} id={id} class="rounded-lg border border-zinc-200 bg-white p-5 shadow-sm space-y-3">
            <div class="flex items-start">
              <.icon name="hero-chat-bubble-left-right" class="w-5 h-5 mt-0.5 mr-2 text-zinc-400" />
              <div class="flex-1">
                <p class="font-medium text-zinc-900">{entry.task}</p>
                <p class="text-xs text-zinc-500 mt-1">
                  {Calendar.strftime(entry.inserted_at, "%Y-%m-%d %H:%M:%S")}
                </p>
              </div>
            </div>

            <div class="pl-7">
              <div class="mb-3">
                <p class="text-sm font-semibold text-zinc-700 mb-1">
                  <.icon name="hero-light-bulb" class="w-4 h-4 inline mr-1" />
                  Plan:
                </p>
                <pre class="whitespace-pre-wrap text-sm bg-zinc-50 p-3 rounded border border-zinc-200">{entry.plan}</pre>
              </div>

              <div>
                <p class="text-sm font-semibold text-zinc-700 mb-1">
                  <.icon name="hero-code-bracket" class="w-4 h-4 inline mr-1" />
                  Code:
                </p>
                <pre class="whitespace-pre-wrap text-sm bg-zinc-900 text-zinc-100 p-3 rounded font-mono">{entry.code}</pre>
              </div>
            </div>
          </div>
        </div>
      </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("change_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, selected_model: model)}
  end

  @impl true
  def handle_event("execute", %{"task" => raw_task}, socket) do
    task = String.trim(raw_task || "")

    if task == "" do
      {:noreply, socket}
    else
      execute_task(task, socket.assigns.selected_model)
      {:noreply, assign(socket, loading: true, response: "", form: to_form(%{"task" => task}))}
    end
  end

  defp execute_task(task, model) do
    pid = self()

    Task.start(fn ->
      case Agent.execute(task) do
        {:ok, entry} -> send(pid, {:history_updated, entry})
        {:error, reason} -> send(pid, {:agent_error, reason})
      end
    end)

    Task.start(fn -> OpenAIClient.stream_completion(task, pid, model: model) end)
  end

  @impl true
  def handle_info({:chunk, text}, socket) do
    {:noreply, update(socket, :response, &(&1 <> text))}
  end

  @impl true
  def handle_info({:complete, :ok}, socket) do
    {:noreply, assign(socket, loading: false)}
  end

  @impl true
  def handle_info({:history_updated, entry}, socket) do
    {:noreply, stream_insert(socket, :history, entry, at: 0)}
  end

  @impl true
  def handle_info({:agent_error, reason}, socket) do
    {:noreply, assign(socket, loading: false, response: "Agent error: #{inspect(reason)}")}
  end
end
