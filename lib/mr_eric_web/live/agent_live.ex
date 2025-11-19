defmodule MrEricWeb.AgentLive do
  use MrEricWeb, :live_view

  alias MrEric.Agent
  alias MrEric.OpenAIClient
  alias MrEricWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       loading: false,
       response: "",
       history: Agent.history(),
       form: to_form(%{"task" => ""})
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-3xl mx-auto space-y-6">
        <.form for={@form} id="task-form" phx-submit="execute" class="space-y-3">
          <.input field={@form[:task]} type="text" placeholder="Enter task for AI agent" />
          <.button type="submit" disabled={@loading}>Execute</.button>
        </.form>

        <div :if={@response != ""} class="rounded-md border p-4 bg-zinc-50">
          <h2 class="font-semibold mb-2">Streaming Response</h2>
          <pre class="whitespace-pre-wrap text-sm">{@response}</pre>
        </div>

        <div :if={@history != []} class="space-y-4">
          <h2 class="font-semibold text-lg">History</h2>
          <div :for={entry <- @history} class="rounded-lg border p-3 space-y-2">
            <p><strong>Task:</strong> {entry.task}</p>
            <div>
              <strong>Plan:</strong>
              <pre class="whitespace-pre-wrap text-sm">{entry.plan}</pre>
            </div>
            <div>
              <strong>Code:</strong>
              <pre class="whitespace-pre-wrap text-sm">{entry.code}</pre>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("execute", %{"task" => raw_task}, socket) do
    task = String.trim(raw_task || "")

    if task == "" do
      {:noreply, socket}
    else
      pid = self()

      Task.start(fn ->
        case Agent.execute(task) do
          {:ok, entry} -> send(pid, {:history_updated, entry})
          {:error, reason} -> send(pid, {:agent_error, reason})
        end
      end)

      Task.start(fn -> OpenAIClient.stream_completion(task, pid) end)

      {:noreply, assign(socket, loading: true, response: "", form: to_form(%{"task" => task}))}
    end
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
  def handle_info({:history_updated, _entry}, socket) do
    {:noreply, assign(socket, history: Agent.history())}
  end

  @impl true
  def handle_info({:agent_error, reason}, socket) do
    {:noreply, assign(socket, loading: false, response: "Agent error: #{inspect(reason)}")}
  end
end
