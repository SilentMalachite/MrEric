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
  def mount(_params, session, socket) do
    owner_id =
      Map.get(session, "owner_id") ||
        raise "owner_id missing from session — EnsureOwnerId plug not in pipeline?"

    selected_provider = Registry.default_provider()
    available_models = Registry.models_for_provider(selected_provider)
    selected_model = Registry.default_model(selected_provider)

    {:ok,
     socket
     |> assign(
       owner_id: owner_id,
       loading: false,
       response: "",
       selected_provider: selected_provider,
       selected_model: selected_model,
       available_providers: Registry.providers(),
       available_models: available_models,
       current_run: Run.blank(provider: selected_provider, model: selected_model),
       stage_roles: Run.roles(),
       tool_approvals: %{},
       expired_approvals: [],
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
                  <p
                    :if={history_changed_files(entry) != ""}
                    id={"history-changed-files-#{dom_id(entry.id)}"}
                    class="mt-2 rounded-md bg-emerald-50 px-2 py-1 text-xs font-semibold text-emerald-700"
                  >
                    Changed files: {history_changed_files(entry)}
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
          class={[
            "rounded-lg p-4 shadow-sm",
            patch_tool?(approval.tool) && "border border-red-200 bg-red-50",
            !patch_tool?(approval.tool) && "border border-amber-200 bg-amber-50"
          ]}
        >
          <div class="mb-3 flex items-start justify-between gap-3">
            <div>
              <p class={[
                "text-sm font-semibold",
                patch_tool?(approval.tool) && "text-red-950",
                !patch_tool?(approval.tool) && "text-amber-950"
              ]}>
                <%= if patch_tool?(approval.tool) do %>
                  Pending Patch Approval
                <% else %>
                  {tool_name(approval.tool)} requires approval
                <% end %>
              </p>
              <p class={[
                "mt-1 text-xs font-semibold uppercase tracking-wide",
                patch_tool?(approval.tool) && "text-red-700",
                !patch_tool?(approval.tool) && "text-amber-700"
              ]}>
                {format_tool_role(approval.role)} / risk: {format_value(approval.risk_level)}
              </p>
              <p class={[
                "mt-1 text-xs",
                patch_tool?(approval.tool) && "text-red-800",
                !patch_tool?(approval.tool) && "text-amber-800"
              ]}>
                {approval.reason}
              </p>
            </div>
            <span class={status_badge_class(:reviewing)}>pending</span>
          </div>

          <%= if patch_tool?(approval.tool) do %>
            <div class="mb-3 grid gap-2 rounded-md border border-red-200 bg-white p-3 text-xs text-zinc-800 sm:grid-cols-2">
              <div>
                <p class="font-semibold text-red-900">Target file</p>
                <p class="mt-1 font-mono">{patch_target_files(approval.args)}</p>
              </div>
              <div>
                <p class="font-semibold text-red-900">Summary</p>
                <p class="mt-1">{patch_summary(approval.args)}</p>
              </div>
            </div>

            <p class="mb-1 text-xs font-semibold text-red-900">Unified diff</p>
            <pre class="max-h-64 overflow-auto whitespace-pre-wrap rounded-md border border-red-200 bg-white p-3 text-xs text-zinc-800">{patch_diff(approval.args)}</pre>
          <% else %>
            <p class="mb-1 text-xs font-semibold text-amber-900">Input</p>
            <pre class="max-h-40 overflow-auto whitespace-pre-wrap rounded-md border border-amber-200 bg-white p-3 text-xs text-zinc-800">{format_tool_payload(approval.args)}</pre>
          <% end %>

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

      case Runs.start_run(task, socket.assigns.owner_id, opts) do
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
        case Runs.approve_tool(run_id, approval_id, socket.assigns.owner_id) do
          :ok ->
            {:noreply, socket}

          {:error, :not_owner} ->
            {:noreply, put_flash(socket, :error, "このRunの操作権限がありません")}

          {:error, _reason} ->
            {:noreply, socket}
        end
    end
  end

  @impl true
  def handle_event("deny_tool", %{"approval-id" => approval_id}, socket) do
    case socket.assigns.current_run.id do
      nil ->
        {:noreply, socket}

      run_id ->
        case Runs.deny_tool(run_id, approval_id, socket.assigns.owner_id) do
          :ok ->
            {:noreply, socket}

          {:error, :not_owner} ->
            {:noreply, put_flash(socket, :error, "このRunの操作権限がありません")}

          {:error, _reason} ->
            {:noreply, socket}
        end
    end
  end

  @impl true
  def handle_event("cancel_run", _params, socket) do
    case socket.assigns.current_run.id do
      nil ->
        {:noreply, socket}

      run_id ->
        case Runs.cancel_run(run_id, socket.assigns.owner_id) do
          :ok ->
            {:noreply, socket}

          {:error, :not_owner} ->
            {:noreply, put_flash(socket, :error, "このRunの操作権限がありません")}

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
      |> Map.take([
        :approval_id,
        :tool_call_id,
        :tool,
        :args,
        :role,
        :reason,
        :risk_level,
        :requested_at
      ])
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

  defp apply_tool_event(socket, :tool_approval_expired, payload) do
    socket
    |> assign(:tool_approvals,
              Map.delete(socket.assigns.tool_approvals, payload.approval_id))
    |> assign(:expired_approvals,
              [payload | socket.assigns.expired_approvals])
  end

  defp apply_tool_event(socket, :tool_started, payload),
    do: upsert_tool_event(socket, payload, :running)

  defp apply_tool_event(socket, :tool_completed, payload),
    do: upsert_tool_event(socket, payload, :completed)

  defp apply_tool_event(socket, :tool_failed, payload),
    do: upsert_tool_event(socket, payload, :failed)

  defp apply_tool_event(socket, :tool_denied, payload),
    do: upsert_tool_event(socket, payload, :denied)

  defp apply_tool_event(socket, :tool_rejected, payload),
    do: upsert_tool_event(socket, payload, :rejected)

  defp apply_tool_event(socket, _event, _payload), do: socket

  defp upsert_tool_event(socket, payload, status) do
    event =
      payload
      |> Map.take([
        :tool_call_id,
        :tool,
        :args,
        :role,
        :risk_level,
        :result,
        :error,
        :approved,
        :reason
      ])
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

  defp format_tool_role(nil), do: "unknown role"
  defp format_tool_role(role), do: format_value(role)

  defp tool_event_body(%{tool: tool, status: :completed, result: result})
       when tool in [:apply_patch, "apply_patch"] do
    format_patch_result(result)
  end

  defp tool_event_body(%{tool: tool, status: :completed, result: result})
       when tool in [:file_write_proposal, "file_write_proposal"] do
    format_patch_proposal_result(result)
  end

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

  defp patch_tool?(tool), do: tool in [:apply_patch, "apply_patch"]

  defp patch_target_files(args) do
    args
    |> patch_files()
    |> case do
      [] -> "unknown"
      files -> Enum.join(files, ", ")
    end
  end

  defp patch_summary(args) do
    args
    |> patch_files()
    |> case do
      [file] -> "1 file will change: #{file}"
      files -> "#{length(files)} files will change"
    end
  end

  defp patch_diff(args) when is_map(args) do
    cond do
      is_binary(Map.get(args, :patch)) ->
        Map.get(args, :patch)

      is_binary(Map.get(args, "patch")) ->
        Map.get(args, "patch")

      is_list(Map.get(args, :changes)) ->
        args |> Map.get(:changes) |> Enum.map_join("\n", &change_diff_preview/1)

      is_list(Map.get(args, "changes")) ->
        args |> Map.get("changes") |> Enum.map_join("\n", &change_diff_preview/1)

      true ->
        format_tool_payload(args)
    end
  end

  defp patch_diff(args), do: format_tool_payload(args)

  defp patch_files(args) when is_map(args) do
    cond do
      is_list(Map.get(args, :changes)) ->
        args |> Map.get(:changes) |> Enum.map(&patch_change_path/1) |> Enum.reject(&(&1 == ""))

      is_list(Map.get(args, "changes")) ->
        args |> Map.get("changes") |> Enum.map(&patch_change_path/1) |> Enum.reject(&(&1 == ""))

      is_binary(Map.get(args, :path)) ->
        [Map.get(args, :path)]

      is_binary(Map.get(args, "path")) ->
        [Map.get(args, "path")]

      is_binary(Map.get(args, :patch)) ->
        patch_paths(Map.get(args, :patch))

      is_binary(Map.get(args, "patch")) ->
        patch_paths(Map.get(args, "patch"))

      true ->
        []
    end
  end

  defp patch_files(_args), do: []

  defp patch_change_path(change) when is_map(change),
    do: Map.get(change, :path) || Map.get(change, "path") || ""

  defp patch_change_path(_change), do: ""

  defp patch_paths(patch) do
    patch
    |> String.split("\n")
    |> Enum.flat_map(&patch_line_paths/1)
    |> Enum.reject(&(&1 in [nil, "", "/dev/null"]))
    |> Enum.map(&strip_patch_prefix/1)
    |> Enum.uniq()
  end

  defp patch_line_paths("--- " <> rest), do: [patch_header_path(rest)]
  defp patch_line_paths("+++ " <> rest), do: [patch_header_path(rest)]

  defp patch_line_paths("diff --git " <> rest) do
    rest
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
  end

  defp patch_line_paths(_line), do: []

  defp patch_header_path(rest) do
    rest
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
  end

  defp strip_patch_prefix(path) do
    path
    |> String.trim()
    |> String.replace_prefix("a/", "")
    |> String.replace_prefix("b/", "")
  end

  defp change_diff_preview(change) when is_map(change) do
    path = patch_change_path(change)
    before = Map.get(change, :before) || Map.get(change, "before") || ""
    proposed = Map.get(change, :after) || Map.get(change, "after") || ""

    Enum.join(
      ["--- a/#{path}", "+++ b/#{path}", "@@ -1 +1 @@"]
      |> Kernel.++(Enum.map(diff_preview_lines(before), &("-" <> &1)))
      |> Kernel.++(Enum.map(diff_preview_lines(proposed), &("+" <> &1))),
      "\n"
    )
  end

  defp change_diff_preview(change), do: inspect(change, printable_limit: 1_000)

  defp diff_preview_lines(""), do: []
  defp diff_preview_lines(content), do: String.split(to_string(content), "\n", trim: true)

  defp format_patch_result(result) when is_map(result) do
    changed_files =
      result
      |> Map.get(:changed_files, Map.get(result, "changed_files", []))
      |> normalize_file_list()
      |> Enum.join(", ")

    diff =
      Map.get(result, :git_diff) || Map.get(result, "git_diff") || Map.get(result, :diff) || ""

    [
      "Patch applied",
      if(changed_files == "", do: nil, else: "Changed files: #{changed_files}"),
      "git diff",
      diff
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp format_patch_result(result), do: format_tool_payload(result)

  defp format_patch_proposal_result(result) when is_map(result) do
    path = Map.get(result, :path) || Map.get(result, "path") || "unknown"
    diff = Map.get(result, :diff) || Map.get(result, "diff") || ""

    [
      "Patch proposal",
      "Target file: #{path}",
      "Unified diff",
      diff
    ]
    |> Enum.join("\n\n")
  end

  defp format_patch_proposal_result(result), do: format_tool_payload(result)

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
        :waiting_for_approval -> "bg-amber-50 text-amber-700 ring-amber-200"
        :waiting_for_model -> "bg-sky-50 text-sky-700 ring-sky-200"
        :running -> "bg-blue-50 text-blue-700 ring-blue-200"
        :denied -> "bg-red-50 text-red-700 ring-red-200"
        :rejected -> "bg-red-50 text-red-700 ring-red-200"
        _ -> "bg-zinc-50 text-zinc-600 ring-zinc-200"
      end
    ]
  end

  defp history_final(entry), do: Map.get(entry, :final) || Map.get(entry, :code) || ""

  defp history_changed_files(entry) do
    entry
    |> Map.get(:changed_files, [])
    |> normalize_file_list()
    |> Enum.join(", ")
  end

  defp normalize_file_list(files) when is_list(files), do: Enum.filter(files, &is_binary/1)
  defp normalize_file_list(_files), do: []

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
