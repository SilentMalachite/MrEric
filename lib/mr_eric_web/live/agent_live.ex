defmodule MrEricWeb.AgentLive do
  use MrEricWeb, :live_view

  alias MrEric.Agent
  alias MrEric.LLM.Registry
  alias MrEric.Runs
  alias MrEric.Runs.Events
  alias MrEric.Runs.Run
  alias MrEricWeb.Layouts

  @run_events Events.names()

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
        <section class="rounded-lg border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="mb-5 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h1 class="text-2xl font-bold text-zinc-950">MrEric AI Agent</h1>
              <p class="mt-1 text-sm text-zinc-500">
                Planner, draft agents, reviewers, and synthesizer progress in real time.
              </p>
            </div>
            <div class="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 text-xs text-zinc-600">
              <span class="font-semibold text-zinc-900">Current Run</span>
              <span class="ml-2 font-mono">{run_id_label(@current_run)}</span>
            </div>
          </div>

          <.form for={@form} id="task-form" phx-submit="execute" class="space-y-4">
            <div class="grid gap-4 md:grid-cols-[1fr_1fr_1.4fr]">
              <div>
                <label for="provider-select" class="mb-2 block text-sm font-medium text-zinc-700">
                  Provider
                </label>
                <select
                  id="provider-select"
                  name="provider"
                  phx-change="change_provider"
                  class="w-full rounded-md border-zinc-300 text-sm transition focus:border-zinc-500 focus:ring-zinc-200"
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
                <label for="model-select" class="mb-2 block text-sm font-medium text-zinc-700">
                  Model
                </label>
                <select
                  id="model-select"
                  name="model"
                  phx-change="change_model"
                  class="w-full rounded-md border-zinc-300 text-sm transition focus:border-zinc-500 focus:ring-zinc-200"
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

              <div>
                <label class="mb-2 block text-sm font-medium text-zinc-700">
                  Task Description
                </label>
                <.input
                  field={@form[:task]}
                  type="text"
                  placeholder="Enter task for AI agent..."
                  class="w-full"
                />
              </div>
            </div>

            <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <p class="text-sm text-zinc-500">
                Using <span class="font-mono font-semibold text-zinc-800">{@selected_provider}</span>
                <span class="text-zinc-400">/</span>
                <span class="font-mono font-semibold text-zinc-800">{@selected_model}</span>
              </p>

              <div class="flex gap-2">
                <.button
                  type="submit"
                  disabled={@loading}
                  class="inline-flex items-center gap-2 rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white transition hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  <%= if @loading do %>
                    <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin" /> Running
                  <% else %>
                    <.icon name="hero-play" class="h-4 w-4" /> Execute Task
                  <% end %>
                </.button>

                <button
                  :if={cancellable?(@current_run)}
                  id="cancel-run-button"
                  type="button"
                  phx-click="cancel_run"
                  class="inline-flex items-center gap-2 rounded-md border border-red-200 bg-white px-4 py-2 text-sm font-semibold text-red-700 transition hover:border-red-300 hover:bg-red-50"
                >
                  <.icon name="hero-stop" class="h-4 w-4" /> Cancel
                </button>
              </div>
            </div>
          </.form>
        </section>

        <section id="current-run" class="space-y-4">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="text-xl font-semibold text-zinc-950">Current Run</h2>
              <p class="text-sm text-zinc-500">
                Run ID <span class="font-mono">{run_id_label(@current_run)}</span>
              </p>
            </div>
            <div id="run-status" class={status_badge_class(@current_run.status)}>
              {status_label(@current_run.status)}
            </div>
          </div>

          <.tool_activity approvals={@tool_approvals} events={@tool_events} />

          <div class="grid gap-4 lg:grid-cols-2">
            <.stage_panel
              :for={role <- @stage_roles}
              id={"stage-#{role}"}
              title={role_title(role)}
              icon={role_icon(role)}
              stage={Run.stage(@current_run, role)}
            />

            <div id="stage-final" class="rounded-lg border border-zinc-200 bg-white p-4 shadow-sm">
              <div class="mb-3 flex items-start justify-between gap-3">
                <div class="flex items-center gap-2">
                  <.icon name="hero-sparkles" class="h-5 w-5 text-blue-600" />
                  <h3 class="font-semibold text-zinc-950">Final</h3>
                </div>
                <span class={status_badge_class(final_status(@current_run))}>
                  {status_label(final_status(@current_run))}
                </span>
              </div>

              <pre class="min-h-24 whitespace-pre-wrap rounded-md border border-zinc-200 bg-zinc-950 p-3 text-sm text-zinc-50">{final_content(@current_run)}</pre>

              <p
                :if={@current_run.error}
                class="mt-3 rounded-md bg-red-50 px-3 py-2 text-sm text-red-700"
              >
                {@current_run.error}
              </p>
            </div>
          </div>
        </section>

        <section class="space-y-4">
          <h2 class="flex items-center text-xl font-semibold text-zinc-950">
            <.icon name="hero-clock" class="mr-2 h-6 w-6" /> Execution History
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
              class="rounded-lg border border-zinc-200 bg-white p-5 shadow-sm"
            >
              <div class="flex items-start gap-3">
                <.icon name="hero-chat-bubble-left-right" class="mt-0.5 h-5 w-5 text-zinc-400" />
                <div class="min-w-0 flex-1">
                  <p class="font-medium text-zinc-900">{entry.task}</p>
                  <p class="mt-1 space-x-2 text-xs text-zinc-500">
                    <span>{Calendar.strftime(entry.inserted_at, "%Y-%m-%d %H:%M:%S")}</span>
                    <span :if={provider_model_label(entry) != ""} class="font-mono">
                      {provider_model_label(entry)}
                    </span>
                  </p>
                </div>
              </div>

              <div class="mt-4 grid gap-4 lg:grid-cols-2">
                <section>
                  <h3 class="mb-2 text-sm font-semibold text-zinc-700">
                    <.icon name="hero-light-bulb" class="mr-1 inline h-4 w-4" /> Plan
                  </h3>
                  <pre class="whitespace-pre-wrap rounded-md border border-zinc-200 bg-zinc-50 p-3 text-sm">{entry.plan}</pre>
                </section>

                <section>
                  <h3 class="mb-2 text-sm font-semibold text-zinc-700">
                    <.icon name="hero-code-bracket" class="mr-1 inline h-4 w-4" /> Final
                  </h3>
                  <pre class="whitespace-pre-wrap rounded-md bg-zinc-950 p-3 text-sm text-zinc-50">{history_final(entry)}</pre>
                </section>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :approvals, :map, required: true
  attr :events, :list, required: true

  def tool_activity(assigns) do
    ~H"""
    <section
      id="tool-activity"
      class={[
        "space-y-3",
        !tool_activity_visible?(@approvals, @events) && "hidden"
      ]}
    >
      <div class="flex items-center gap-2">
        <.icon name="hero-command-line" class="h-5 w-5 text-zinc-600" />
        <h2 class="text-lg font-semibold text-zinc-950">Tool Activity</h2>
      </div>

      <div id="tool-approvals" class="grid gap-3 lg:grid-cols-2">
        <div
          :for={approval <- pending_tool_approvals(@approvals)}
          id={"tool-approval-#{dom_id(approval.tool_call_id)}"}
          class="rounded-lg border border-amber-200 bg-amber-50 p-4 shadow-sm"
        >
          <div class="mb-3 flex items-start justify-between gap-3">
            <div>
              <p class="text-sm font-semibold text-amber-950">
                {tool_name(approval.tool)} requires approval
              </p>
              <p class="mt-1 text-xs text-amber-800">{approval.reason}</p>
            </div>
            <span class={status_badge_class(:reviewing)}>pending</span>
          </div>

          <pre class="max-h-40 overflow-auto whitespace-pre-wrap rounded-md border border-amber-200 bg-white p-3 text-xs text-zinc-800">{format_tool_payload(approval.args)}</pre>

          <div class="mt-3 flex gap-2">
            <button
              id={"approve-tool-#{dom_id(approval.tool_call_id)}"}
              type="button"
              phx-click="approve_tool"
              phx-value-approval-id={approval.approval_id}
              class="inline-flex items-center gap-2 rounded-md bg-emerald-600 px-3 py-2 text-sm font-semibold text-white transition hover:bg-emerald-700"
            >
              <.icon name="hero-check" class="h-4 w-4" /> Approve
            </button>

            <button
              id={"deny-tool-#{dom_id(approval.tool_call_id)}"}
              type="button"
              phx-click="deny_tool"
              phx-value-approval-id={approval.approval_id}
              class="inline-flex items-center gap-2 rounded-md border border-red-200 bg-white px-3 py-2 text-sm font-semibold text-red-700 transition hover:border-red-300 hover:bg-red-50"
            >
              <.icon name="hero-x-mark" class="h-4 w-4" /> Deny
            </button>
          </div>
        </div>
      </div>

      <div id="tool-events" class="space-y-2">
        <div
          :for={event <- @events}
          id={"tool-event-#{dom_id(event.tool_call_id)}-#{event.status}"}
          class="rounded-lg border border-zinc-200 bg-white p-3 shadow-sm"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="text-sm font-semibold text-zinc-900">{tool_name(event.tool)}</p>
              <p class="mt-1 font-mono text-xs text-zinc-500">{event.tool_call_id}</p>
            </div>
            <span class={status_badge_class(event.status)}>{status_label(event.status)}</span>
          </div>

          <pre
            :if={tool_event_body(event) != ""}
            class="mt-3 max-h-40 overflow-auto whitespace-pre-wrap rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs text-zinc-800"
          >{tool_event_body(event)}</pre>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :stage, :map, required: true

  def stage_panel(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="mb-3 flex items-start justify-between gap-3">
        <div class="flex items-center gap-2">
          <.icon name={@icon} class="h-5 w-5 text-zinc-600" />
          <div>
            <h3 class="font-semibold text-zinc-950">{@title}</h3>
            <p :if={stage_agent_label(@stage) != ""} class="text-xs font-mono text-zinc-500">
              {stage_agent_label(@stage)}
            </p>
          </div>
        </div>
        <span class={status_badge_class(@stage.status)}>{status_label(@stage.status)}</span>
      </div>

      <pre class="min-h-24 whitespace-pre-wrap rounded-md border border-zinc-200 bg-zinc-50 p-3 text-sm text-zinc-800">{stage_content(@stage)}</pre>

      <p :if={@stage.error} class="mt-3 rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">
        {@stage.error}
      </p>

      <p
        :if={@stage.status == :completed}
        class="mt-3 flex items-center gap-1 text-xs font-semibold text-emerald-700"
      >
        <.icon name="hero-check-circle" class="h-4 w-4" /> completed
      </p>
    </div>
    """
  end

  @impl true
  def handle_event("change_provider", %{"provider" => provider}, socket) do
    available_models = Registry.models_for_provider(provider)
    selected_model = selected_model(available_models, Registry.default_model(provider))

    {:noreply,
     socket
     |> assign(
       selected_provider: provider,
       selected_model: selected_model,
       available_models: available_models
     )
     |> refresh_blank_run()}
  end

  @impl true
  def handle_event("change_model", %{"model" => model}, socket) do
    {:noreply,
     socket
     |> assign(selected_model: model)
     |> refresh_blank_run()}
  end

  @impl true
  def handle_event("execute", %{"task" => raw_task}, socket) do
    task = String.trim(raw_task || "")

    if task == "" do
      {:noreply, socket}
    else
      socket = unsubscribe_current_run(socket)

      opts =
        socket.assigns.selected_provider
        |> run_opts(socket.assigns.selected_model)
        |> Keyword.put(:subscribe, true)

      case Runs.start_run(task, opts) do
        {:ok, run} ->
          {:noreply,
           assign(socket,
             loading: true,
             response: "",
             current_run: run,
             tool_approvals: %{},
             tool_events: [],
             form: to_form(%{"task" => task})
           )}

        {:error, reason} ->
          run =
            Run.blank(
              provider: socket.assigns.selected_provider,
              model: socket.assigns.selected_model
            )
            |> Run.apply_event({:run_failed, %{error: reason}})

          {:noreply,
           assign(socket,
             loading: false,
             current_run: run,
             response: run.error,
             tool_approvals: %{},
             tool_events: []
           )}
      end
    end
  end

  @impl true
  def handle_event("approve_tool", %{"approval-id" => approval_id}, socket) do
    case socket.assigns.current_run.id do
      nil ->
        {:noreply, socket}

      run_id ->
        _result = Runs.approve_tool(run_id, approval_id)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("deny_tool", %{"approval-id" => approval_id}, socket) do
    case socket.assigns.current_run.id do
      nil ->
        {:noreply, socket}

      run_id ->
        _result = Runs.deny_tool(run_id, approval_id)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_run", _params, socket) do
    case socket.assigns.current_run.id do
      nil ->
        {:noreply, socket}

      run_id ->
        case Runs.cancel_run(run_id) do
          :ok ->
            {:noreply, socket}

          {:error, reason} ->
            run = Run.apply_event(socket.assigns.current_run, {:run_failed, %{error: reason}})
            {:noreply, assign(socket, loading: false, current_run: run, response: run.error)}
        end
    end
  end

  @impl true
  def handle_info({event, payload}, socket) when event in @run_events do
    if current_run_event?(socket.assigns.current_run, payload) do
      {event, payload} = Events.normalize_event(socket.assigns.current_run.id, {event, payload})
      run = Run.apply_event(socket.assigns.current_run, {event, payload})

      socket =
        socket
        |> assign(
          loading: !Run.terminal?(run),
          current_run: run,
          response: run.error || run.final
        )
        |> maybe_insert_history(event, run)
        |> apply_tool_event(event, payload)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    unsubscribe_current_run(socket)
    :ok
  end

  defp run_opts(provider, model) do
    :mr_eric
    |> Application.get_env(:live_run_opts, [])
    |> Keyword.merge(provider: provider, model: model)
  end

  defp selected_model([%{id: id} | _models], fallback), do: fallback || id
  defp selected_model([], fallback), do: fallback

  defp refresh_blank_run(socket) do
    if socket.assigns.current_run.id || socket.assigns.loading do
      socket
    else
      assign(
        socket,
        current_run:
          Run.blank(
            provider: socket.assigns.selected_provider,
            model: socket.assigns.selected_model
          )
      )
    end
  end

  defp unsubscribe_current_run(socket) do
    if socket.assigns.current_run.id do
      Runs.unsubscribe(socket.assigns.current_run.id)
    end

    socket
  end

  defp current_run_event?(%Run{id: nil}, %{run_id: nil}), do: true
  defp current_run_event?(%Run{id: nil}, _payload), do: true
  defp current_run_event?(%Run{id: run_id}, %{run_id: run_id}), do: true
  defp current_run_event?(_run, _payload), do: false

  defp maybe_insert_history(socket, :run_completed, run) do
    stream_insert(socket, :history, Run.to_history_entry(run), at: 0)
  end

  defp maybe_insert_history(socket, _event, _run), do: socket

  defp apply_tool_event(socket, :tool_approval_requested, payload) do
    approval =
      payload
      |> Map.take([:approval_id, :tool_call_id, :tool, :args, :reason, :requested_at])
      |> Map.put_new(:args, %{})

    assign(
      socket,
      :tool_approvals,
      Map.put(socket.assigns.tool_approvals, approval.approval_id, approval)
    )
  end

  defp apply_tool_event(socket, :tool_approval_resolved, payload) do
    status = if Map.get(payload, :approved), do: :approved, else: :denied

    socket
    |> assign(:tool_approvals, Map.delete(socket.assigns.tool_approvals, payload.approval_id))
    |> upsert_tool_event(payload, status)
  end

  defp apply_tool_event(socket, :tool_started, payload),
    do: upsert_tool_event(socket, payload, :running)

  defp apply_tool_event(socket, :tool_completed, payload),
    do: upsert_tool_event(socket, payload, :completed)

  defp apply_tool_event(socket, :tool_failed, payload),
    do: upsert_tool_event(socket, payload, :failed)

  defp apply_tool_event(socket, _event, _payload), do: socket

  defp upsert_tool_event(socket, payload, status) do
    event =
      payload
      |> Map.take([:tool_call_id, :tool, :args, :result, :error, :approved, :reason])
      |> Map.put(:status, status)
      |> Map.put_new(:args, %{})

    key = {event.tool_call_id, event.status}

    events = [
      event | Enum.reject(socket.assigns.tool_events, &({&1.tool_call_id, &1.status} == key))
    ]

    assign(socket, :tool_events, Enum.take(events, 20))
  end

  defp cancellable?(%Run{id: nil}), do: false
  defp cancellable?(%Run{} = run), do: !Run.terminal?(run)

  defp run_id_label(%Run{id: nil}), do: "Not started"
  defp run_id_label(%Run{id: id}), do: id

  defp final_status(%Run{status: :completed}), do: :completed
  defp final_status(%Run{status: :failed}), do: :failed
  defp final_status(%Run{status: :cancelled}), do: :cancelled
  defp final_status(_run), do: :queued

  defp final_content(%Run{final: final}) when is_binary(final) and final != "", do: final
  defp final_content(%Run{status: :failed, error: error}) when is_binary(error), do: error
  defp final_content(_run), do: "Final output appears here."

  defp stage_content(%{content: content}) when is_binary(content) and content != "", do: content
  defp stage_content(%{status: :failed, error: error}) when is_binary(error), do: error
  defp stage_content(_stage), do: "Waiting for output."

  defp stage_agent_label(stage) do
    [stage.name, stage.provider, stage.model]
    |> Enum.map(&format_value/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" / ")
  end

  defp role_title(:planner), do: "Planner"
  defp role_title(:local_drafter), do: "Local Drafter"
  defp role_title(:cloud_drafter), do: "Cloud Drafter"
  defp role_title(:critic), do: "Critic"
  defp role_title(:reviewer), do: "Reviewer"
  defp role_title(:synthesizer), do: "Synthesizer"

  defp role_icon(:planner), do: "hero-light-bulb"
  defp role_icon(:local_drafter), do: "hero-computer-desktop"
  defp role_icon(:cloud_drafter), do: "hero-cloud"
  defp role_icon(:critic), do: "hero-magnifying-glass"
  defp role_icon(:reviewer), do: "hero-check-badge"
  defp role_icon(:synthesizer), do: "hero-sparkles"

  defp status_label(status) when is_atom(status), do: Atom.to_string(status)
  defp status_label(status), do: to_string(status)

  defp tool_activity_visible?(approvals, events), do: map_size(approvals) > 0 or events != []

  defp pending_tool_approvals(approvals) do
    approvals
    |> Map.values()
    |> Enum.sort_by(&to_string(&1.tool_call_id))
  end

  defp tool_name(tool) when is_atom(tool), do: Atom.to_string(tool)
  defp tool_name(tool) when is_binary(tool), do: tool
  defp tool_name(_tool), do: "tool"

  defp tool_event_body(%{status: :completed, result: result}), do: format_tool_payload(result)
  defp tool_event_body(%{status: :failed, error: error}), do: to_string(error)

  defp tool_event_body(%{status: status} = event) when status in [:approved, :denied] do
    format_tool_payload(Map.take(event, [:approved, :reason]))
  end

  defp tool_event_body(%{args: args}), do: format_tool_payload(args)
  defp tool_event_body(_event), do: ""

  defp format_tool_payload(payload) when payload in [%{}, nil], do: ""

  defp format_tool_payload(payload) do
    inspect(payload, pretty: true, limit: 20, printable_limit: 1_000)
  end

  defp dom_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
  end

  defp status_badge_class(status) do
    [
      "inline-flex shrink-0 items-center rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ring-inset",
      case status do
        :completed -> "bg-emerald-50 text-emerald-700 ring-emerald-200"
        :failed -> "bg-red-50 text-red-700 ring-red-200"
        :cancelled -> "bg-zinc-100 text-zinc-700 ring-zinc-300"
        :streaming -> "bg-blue-50 text-blue-700 ring-blue-200"
        :reviewing -> "bg-amber-50 text-amber-700 ring-amber-200"
        :synthesizing -> "bg-violet-50 text-violet-700 ring-violet-200"
        :waiting_for_model -> "bg-sky-50 text-sky-700 ring-sky-200"
        :running -> "bg-blue-50 text-blue-700 ring-blue-200"
        _ -> "bg-zinc-50 text-zinc-600 ring-zinc-200"
      end
    ]
  end

  defp history_final(entry), do: Map.get(entry, :final) || Map.get(entry, :code) || ""

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
end
