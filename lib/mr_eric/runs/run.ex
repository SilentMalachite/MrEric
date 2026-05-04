defmodule MrEric.Runs.Run do
  @moduledoc """
  In-memory state for a collaborative model run.

  MrEric currently has no Ecto repository configured, and Phase 4 runs are
  short-lived UI execution state. Keeping them in `RunWorker` GenServer state
  avoids a database migration while still letting completed runs be copied into
  the existing in-memory history.
  """

  alias MrEric.Runs.Events

  @statuses [
    :queued,
    :running,
    :waiting_for_model,
    :waiting_for_approval,
    :streaming,
    :reviewing,
    :synthesizing,
    :completed,
    :failed,
    :cancelled
  ]

  @roles [
    :planner,
    :local_drafter,
    :cloud_drafter,
    :critic,
    :reviewer,
    :synthesizer
  ]

  @derive {Inspect, except: []}
  defstruct [
    :id,
    :task,
    :provider,
    :model,
    :error,
    status: :queued,
    stages: %{},
    final: "",
    inserted_at: nil,
    updated_at: nil
  ]

  def statuses, do: @statuses
  def roles, do: @roles

  def new(task, opts \\ []) do
    now = DateTime.utc_now()
    provider = Keyword.get(opts, :provider)
    model = Keyword.get(opts, :model)

    %__MODULE__{
      id: Keyword.get(opts, :id) || new_id(),
      task: task,
      provider: provider,
      model: model,
      status: :queued,
      stages: default_stages(provider, model),
      final: "",
      inserted_at: now,
      updated_at: now
    }
  end

  def blank(opts \\ []) do
    nil
    |> new(opts)
    |> Map.put(:id, nil)
    |> Map.put(:task, "")
  end

  def terminal?(%__MODULE__{status: status}), do: status in [:completed, :failed, :cancelled]

  def apply_event(%__MODULE__{} = run, {event, payload}) do
    apply_event(run, event, payload)
  end

  def apply_event(%__MODULE__{} = run, :run_started, payload) do
    run
    |> Map.put(:status, :running)
    |> maybe_put_task(payload)
    |> touch()
  end

  def apply_event(%__MODULE__{} = run, :stage_started, payload) do
    role = role_from_payload(payload)

    run
    |> Map.put(:status, run_status_for(role, :started))
    |> update_stage(role, fn stage ->
      stage
      |> Map.merge(agent_meta(payload))
      |> Map.put(:status, run_status_for(role, :started))
      |> Map.put(:error, nil)
    end)
    |> touch()
  end

  def apply_event(%__MODULE__{} = run, :stage_chunk, payload) do
    role = role_from_payload(payload)
    chunk = Map.get(payload, :chunk, "")

    run
    |> Map.put(:status, :streaming)
    |> update_stage(role, fn stage ->
      stage
      |> Map.merge(agent_meta(payload))
      |> Map.put(:status, :streaming)
      |> Map.update!(:content, &(&1 <> to_string(chunk || "")))
    end)
    |> touch()
  end

  def apply_event(%__MODULE__{} = run, :stage_completed, payload) do
    role = role_from_payload(payload)
    content = Map.get(payload, :content, "")

    run
    |> update_stage(role, fn stage ->
      stage
      |> Map.merge(agent_meta(payload))
      |> Map.put(:status, :completed)
      |> Map.put(:content, completed_content(stage.content, content))
      |> Map.put(:error, nil)
    end)
    |> touch()
  end

  def apply_event(%__MODULE__{} = run, :stage_failed, payload) do
    role = role_from_payload(payload)
    error = Events.public_error(Map.get(payload, :error) || Map.get(payload, :reason))

    run
    |> update_stage(role, fn stage ->
      stage
      |> Map.merge(agent_meta(payload))
      |> Map.put(:status, :failed)
      |> Map.put(:error, error)
    end)
    |> touch()
  end

  def apply_event(%__MODULE__{} = run, :run_completed, payload) do
    run
    |> Map.put(:status, :completed)
    |> Map.put(:final, Map.get(payload, :final, run.final) || "")
    |> Map.put(:error, nil)
    |> touch()
  end

  def apply_event(%__MODULE__{} = run, :run_failed, payload) do
    error = Events.public_error(Map.get(payload, :error) || Map.get(payload, :reason))

    run
    |> Map.put(:status, :failed)
    |> Map.put(:error, error)
    |> touch()
  end

  def apply_event(%__MODULE__{} = run, :run_cancelled, _payload) do
    run
    |> Map.put(:status, :cancelled)
    |> touch()
  end

  def apply_event(%__MODULE__{} = run, :tool_approval_requested, _payload) do
    run
    |> Map.put(:status, :waiting_for_approval)
    |> touch()
  end

  def apply_event(%__MODULE__{} = run, :tool_approval_resolved, payload) do
    cond do
      terminal?(run) ->
        run

      Map.get(payload, :pending_approvals_count, 0) > 0 ->
        run
        |> Map.put(:status, :waiting_for_approval)
        |> touch()

      true ->
        run
        |> Map.put(:status, :running)
        |> touch()
    end
  end

  def apply_event(%__MODULE__{} = run, _event, _payload), do: run

  def stage(%__MODULE__{stages: stages}, role) do
    Map.get(stages, role, default_stage(nil, nil))
  end

  def to_history_entry(%__MODULE__{} = run) do
    %{
      id: run.id,
      task: run.task,
      provider: run.provider,
      model: run.model,
      plan: stage(run, :planner).content,
      code: run.final,
      final: run.final,
      planner: stage_result(run, :planner),
      drafts: completed_stage_results(run, [:local_drafter, :cloud_drafter]),
      draft_errors: failed_stage_results(run, [:local_drafter, :cloud_drafter]),
      reviews: completed_stage_results(run, [:critic, :reviewer]),
      review_errors: failed_stage_results(run, [:critic, :reviewer]),
      synthesizer: stage_result(run, :synthesizer),
      synthesis_error: stage(run, :synthesizer).error,
      inserted_at: run.inserted_at
    }
  end

  defp default_stages(provider, model) do
    Map.new(@roles, fn role -> {role, default_stage(provider, model)} end)
  end

  defp default_stage(provider, model) do
    %{
      status: :queued,
      content: "",
      error: nil,
      provider: provider,
      model: model,
      name: nil
    }
  end

  defp update_stage(run, nil, _fun), do: run

  defp update_stage(%__MODULE__{} = run, role, fun) do
    stages = Map.update(run.stages, role, fun.(default_stage(run.provider, run.model)), fun)
    %{run | stages: stages}
  end

  defp run_status_for(role, :started) when role in [:critic, :reviewer], do: :reviewing
  defp run_status_for(:synthesizer, :started), do: :synthesizing
  defp run_status_for(_role, :started), do: :waiting_for_model

  defp role_from_payload(%{role: role}) when role in @roles, do: role
  defp role_from_payload(_payload), do: nil

  defp agent_meta(payload) do
    agent = Map.get(payload, :agent, %{})

    %{
      name: Map.get(payload, :name) || Map.get(agent, :name),
      provider: Map.get(payload, :provider) || Map.get(agent, :provider),
      model: Map.get(payload, :model) || Map.get(agent, :model)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp completed_content(existing, content) do
    content = to_string(content || "")

    cond do
      content == "" -> existing
      existing == "" -> content
      existing == content -> existing
      String.ends_with?(existing, content) -> existing
      true -> existing <> "\n\n" <> content
    end
  end

  defp stage_result(run, role) do
    stage = stage(run, role)

    %{
      agent: %{
        name: stage.name || Atom.to_string(role),
        provider: stage.provider,
        model: stage.model
      },
      content: stage.content
    }
  end

  defp completed_stage_results(run, roles) do
    roles
    |> Enum.map(&stage_result(run, &1))
    |> Enum.reject(&(&1.content == ""))
  end

  defp failed_stage_results(run, roles) do
    roles
    |> Enum.map(fn role -> {role, stage(run, role)} end)
    |> Enum.filter(fn {_role, stage} -> stage.status == :failed end)
    |> Enum.map(fn {role, stage} ->
      %{agent: %{name: stage.name || Atom.to_string(role)}, reason: stage.error}
    end)
  end

  defp maybe_put_task(run, %{task: task}) when is_binary(task), do: %{run | task: task}
  defp maybe_put_task(run, _payload), do: run

  defp touch(run), do: %{run | updated_at: DateTime.utc_now()}

  defp new_id do
    "run-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  end
end
