defmodule MrEric.Runs.Trace do
  @moduledoc """
  Redacted in-memory trace for a Run.
  """

  alias MrEric.Errors

  defstruct [
    :run_id,
    :task,
    :provider,
    :model,
    :started_at,
    :completed_at,
    :duration_ms,
    :status,
    :error_classification,
    metadata: %{},
    entries: []
  ]

  def new(run_id, task, provider, model, metadata \\ %{}) do
    now = DateTime.utc_now()

    %__MODULE__{
      run_id: run_id,
      task: Errors.redact(task),
      provider: provider,
      model: model,
      started_at: now,
      status: :queued,
      metadata: Errors.redact(metadata)
    }
  end

  def record(nil, event, payload), do: new(nil, nil, nil, nil) |> record(event, payload)

  def record(%__MODULE__{} = trace, event, payload) do
    now = DateTime.utc_now()
    payload = Errors.redact(payload)

    entry = %{
      event: event,
      payload: payload,
      occurred_at: now,
      error_classification: error_classification(event, payload)
    }

    trace
    |> Map.update!(:entries, &(&1 ++ [entry]))
    |> update_from_event(event, payload, now)
  end

  def summary(%__MODULE__{} = trace) do
    %{
      run_id: trace.run_id,
      status: trace.status,
      duration_ms: trace.duration_ms,
      error_classification: trace.error_classification,
      event_counts: event_counts(trace),
      changed_files: changed_files(trace),
      approval_required?: has_event?(trace, :tool_approval_requested),
      tool_denied?: has_event?(trace, :tool_denied),
      tool_rejected?: has_event?(trace, :tool_rejected),
      patch_applied?: patch_applied?(trace),
      events: Enum.map(trace.entries, & &1.event)
    }
  end

  def events(%__MODULE__{} = trace), do: Enum.map(trace.entries, & &1.event)

  def has_event?(%__MODULE__{} = trace, event), do: event in events(trace)

  defp update_from_event(trace, :run_started, payload, now) do
    %{
      trace
      | task: Map.get(payload, :task, trace.task),
        started_at: trace.started_at || now,
        status: :running
    }
  end

  defp update_from_event(trace, :run_completed, _payload, now),
    do: complete(trace, :completed, now)

  defp update_from_event(trace, :run_cancelled, _payload, now),
    do: complete(trace, :cancelled, now)

  defp update_from_event(trace, :run_failed, payload, now) do
    trace
    |> complete(:failed, now)
    |> Map.put(:error_classification, Errors.classify(Map.get(payload, :error) || payload))
  end

  defp update_from_event(trace, :stage_failed, payload, _now) do
    Map.put(trace, :error_classification, Errors.classify(Map.get(payload, :error) || payload))
  end

  defp update_from_event(trace, :tool_denied, payload, _now) do
    Map.put(
      trace,
      :error_classification,
      Errors.classify(Map.get(payload, :error) || :tool_denied)
    )
  end

  defp update_from_event(trace, :tool_rejected, payload, _now) do
    Map.put(
      trace,
      :error_classification,
      Errors.classify(Map.get(payload, :error) || :approval_rejected)
    )
  end

  defp update_from_event(trace, _event, _payload, _now), do: trace

  defp complete(trace, status, now) do
    %{
      trace
      | status: status,
        completed_at: now,
        duration_ms: DateTime.diff(now, trace.started_at, :millisecond)
    }
  end

  defp error_classification(event, payload)
       when event in [:run_failed, :stage_failed, :tool_failed, :tool_denied, :tool_rejected] do
    Errors.classify(Map.get(payload, :error) || payload)
  end

  defp error_classification(_event, _payload), do: nil

  defp event_counts(trace) do
    trace.entries
    |> Enum.frequencies_by(& &1.event)
    |> Map.new()
  end

  defp changed_files(trace) do
    trace.entries
    |> Enum.flat_map(fn entry ->
      entry.payload
      |> Map.get(:result, %{})
      |> changed_files_from_result()
    end)
    |> Enum.uniq()
  end

  defp changed_files_from_result(%{} = result) do
    result
    |> Map.get(:changed_files, Map.get(result, "changed_files", []))
    |> case do
      files when is_list(files) -> Enum.filter(files, &is_binary/1)
      _other -> []
    end
  end

  defp changed_files_from_result(_result), do: []

  defp patch_applied?(trace) do
    Enum.any?(trace.entries, fn entry ->
      tool = Map.get(entry.payload, :tool) || Map.get(entry.payload, "tool")
      result = Map.get(entry.payload, :result) || Map.get(entry.payload, "result") || %{}
      applied? = Map.get(result, :applied?) || Map.get(result, "applied?")

      entry.event == :tool_completed and tool in [:apply_patch, "apply_patch"] and
        applied? == true
    end)
  end
end
