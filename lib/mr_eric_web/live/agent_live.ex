defmodule MrEricWeb.AgentLive do
  use MrEricWeb, :live_view

  alias MrEric.Agent
  alias MrEric.LLM.Registry
  alias MrEric.OpenAIClient
  alias MrEricWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    selected_provider = Registry.default_provider()
    available_models = Registry.models_for_provider(selected_provider)

    {:ok,
     socket
     |> assign(
       loading: false,
       response: "",
       selected_provider: selected_provider,
       selected_model: Registry.default_model(selected_provider),
       available_providers: Registry.providers(),
       available_models: available_models,
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
            <div class="grid gap-4 sm:grid-cols-2">
              <div>
                <label for="provider-select" class="block text-sm font-medium text-zinc-700 mb-2">
                  Provider
                </label>
                <select
                  id="provider-select"
                  name="provider"
                  phx-change="change_provider"
                  class="w-full rounded-lg border-zinc-300 focus:border-zinc-400 focus:ring focus:ring-zinc-200 focus:ring-opacity-50"
                >
                  <option
                    :for={provider <- @available_providers}
                    value={provider.id}
                    selected={provider.id == @selected_provider}
                  >
                    {provider.label}
                  </option>
                </select>
              </div>

              <div>
                <label for="model-select" class="block text-sm font-medium text-zinc-700 mb-2">
                  Model
                </label>
                <select
                  id="model-select"
                  name="model"
                  phx-change="change_model"
                  class="w-full rounded-lg border-zinc-300 focus:border-zinc-400 focus:ring focus:ring-zinc-200 focus:ring-opacity-50"
                >
                  <option
                    :for={model <- @available_models}
                    value={model.id}
                    selected={model.id == @selected_model}
                  >
                    {model.label}
                  </option>
                </select>
              </div>
            </div>

            <p class="text-sm text-zinc-500">
              Currently using: <span class="font-mono font-semibold">{@selected_provider}</span>
              <span class="text-zinc-400">/</span>
              <span class="font-mono font-semibold">{@selected_model}</span>
            </p>

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
                  <.icon name="hero-arrow-path" class="w-5 h-5 mr-2 animate-spin" /> Processing...
                </span>
              <% else %>
                Execute Task
              <% end %>
            </.button>
          </.form>
        </div>

        <div :if={@response != ""} class="rounded-lg border border-blue-200 bg-blue-50 p-6 shadow-sm">
          <h2 class="font-semibold text-lg mb-3 text-blue-900">
            <.icon name="hero-sparkles" class="w-5 h-5 inline mr-2" /> Streaming Response
          </h2>
          <pre class="whitespace-pre-wrap text-sm font-mono text-zinc-800 bg-white p-4 rounded border">{@response}</pre>
        </div>

        <div class="space-y-4">
          <h2 class="font-semibold text-xl flex items-center">
            <.icon name="hero-clock" class="w-6 h-6 mr-2" /> Execution History
          </h2>
          <div id="history" phx-update="stream" class="space-y-4">
            <div
              id="history-empty"
              class="hidden only:block rounded-lg border border-dashed border-zinc-300 bg-zinc-50 p-6 text-center text-sm text-zinc-500"
            >
              No executions yet.
            </div>
            <div
              :for={{id, entry} <- @streams.history}
              id={id}
              class="rounded-lg border border-zinc-200 bg-white p-5 shadow-sm space-y-5"
            >
              <div class="flex items-start gap-2">
                <.icon name="hero-chat-bubble-left-right" class="w-5 h-5 mt-0.5 mr-2 text-zinc-400" />
                <div class="flex-1">
                  <p class="font-medium text-zinc-900">{entry.task}</p>
                  <p class="text-xs text-zinc-500 mt-1 space-x-2">
                    <span>{Calendar.strftime(entry.inserted_at, "%Y-%m-%d %H:%M:%S")}</span>
                    <span :if={provider_model_label(entry) != ""} class="font-mono">
                      {provider_model_label(entry)}
                    </span>
                  </p>
                </div>
              </div>

              <div class="pl-7 space-y-4">
                <section class="border-t border-zinc-100 pt-4">
                  <h3 class="text-sm font-semibold text-zinc-700 mb-2">
                    <.icon name="hero-light-bulb" class="w-4 h-4 inline mr-1" /> Plan
                  </h3>
                  <pre class="whitespace-pre-wrap text-sm bg-zinc-50 p-3 rounded border border-zinc-200">{entry.plan}</pre>
                </section>

                <section class="border-t border-zinc-100 pt-4">
                  <h3 class="text-sm font-semibold text-zinc-700 mb-2">
                    <.icon name="hero-document-duplicate" class="w-4 h-4 inline mr-1" /> Drafts
                  </h3>
                  <div class="space-y-3">
                    <div
                      :for={draft <- history_items(entry, :drafts)}
                      class="border-l-2 border-blue-200 pl-3"
                    >
                      <p class="text-xs font-semibold text-zinc-500 mb-1">{agent_label(draft)}</p>
                      <pre class="whitespace-pre-wrap text-sm bg-white p-3 rounded border border-zinc-200">{result_content(draft)}</pre>
                    </div>
                    <p
                      :if={history_items(entry, :drafts) == []}
                      class="text-sm text-zinc-500 bg-zinc-50 p-3 rounded border border-zinc-200"
                    >
                      No successful drafts.
                    </p>
                  </div>
                </section>

                <section class="border-t border-zinc-100 pt-4">
                  <h3 class="text-sm font-semibold text-zinc-700 mb-2">
                    <.icon name="hero-check-badge" class="w-4 h-4 inline mr-1" /> Review
                  </h3>
                  <div class="space-y-3">
                    <div
                      :for={review <- history_items(entry, :reviews)}
                      class="border-l-2 border-amber-200 pl-3"
                    >
                      <p class="text-xs font-semibold text-zinc-500 mb-1">{agent_label(review)}</p>
                      <pre class="whitespace-pre-wrap text-sm bg-white p-3 rounded border border-zinc-200">{result_content(review)}</pre>
                    </div>
                    <p
                      :if={history_items(entry, :reviews) == []}
                      class="text-sm text-zinc-500 bg-zinc-50 p-3 rounded border border-zinc-200"
                    >
                      No reviews returned.
                    </p>
                  </div>
                </section>

                <section class="border-t border-zinc-100 pt-4">
                  <h3 class="text-sm font-semibold text-zinc-700 mb-2">
                    <.icon name="hero-code-bracket" class="w-4 h-4 inline mr-1" /> Final
                  </h3>
                  <pre class="whitespace-pre-wrap text-sm bg-zinc-900 text-zinc-100 p-3 rounded font-mono">{history_final(entry)}</pre>
                </section>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("change_provider", %{"provider" => provider}, socket) do
    available_models = Registry.models_for_provider(provider)
    selected_model = selected_model(available_models, Registry.default_model(provider))

    {:noreply,
     assign(socket,
       selected_provider: provider,
       selected_model: selected_model,
       available_models: available_models
     )}
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
      execute_task(task, socket.assigns.selected_provider, socket.assigns.selected_model)

      {:noreply,
       assign(socket,
         loading: true,
         response: "",
         form: to_form(%{"task" => task})
       )}
    end
  end

  defp execute_task(task, provider, model) do
    pid = self()
    opts = [provider: provider, model: model]

    Task.start(fn ->
      case Agent.execute(task, opts) do
        {:ok, entry} -> send(pid, {:history_updated, entry})
        {:error, reason} -> send(pid, {:agent_error, reason})
      end
    end)

    Task.start(fn -> OpenAIClient.stream_completion(task, pid, opts) end)
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
    {:noreply, assign(socket, loading: false, response: format_error(reason))}
  end

  defp selected_model([%{id: id} | _models], fallback), do: fallback || id
  defp selected_model([], fallback), do: fallback

  defp history_items(entry, key) do
    entry
    |> Map.get(key, [])
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
  end

  defp history_final(entry), do: Map.get(entry, :final) || Map.get(entry, :code) || ""

  defp result_content(%{content: content}) when is_binary(content), do: content
  defp result_content(content) when is_binary(content), do: content
  defp result_content(_content), do: ""

  defp agent_label(%{agent: agent}) when is_map(agent) do
    name = Map.get(agent, :name, "agent")
    provider = format_value(Map.get(agent, :provider))
    model = format_value(Map.get(agent, :model))

    [name, provider, model]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" / ")
  end

  defp agent_label(_result), do: "agent"

  defp provider_model_label(entry) do
    provider = format_value(Map.get(entry, :provider))
    model = format_value(Map.get(entry, :model))

    [provider, model]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" / ")
  end

  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(_value), do: ""

  defp format_error(:econnrefused) do
    "The selected LLM provider is unavailable. Start the local server or choose another provider."
  end

  defp format_error(:missing_api_key) do
    "The selected provider is not configured. Set the API key in the environment or choose a local provider."
  end

  defp format_error(%{reason: reason}), do: "Agent error: #{inspect(reason)}"
  defp format_error(reason), do: "Agent error: #{inspect(reason)}"
end
