defmodule MrEric.Runs.Trace do
  @moduledoc """
  Redacted in-memory trace for a Run.
  """

  alias MrEric.Errors
  alias MrEric.Runs.Limits

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
    chunk_counts: %{},
    dropped_entries: 0,
    entries: []
  ]

  @truncation_marker " … [truncated]"

  def new(run_id, task, provider, model, metadata \\ %{}) do
    now = DateTime.utc_now()

    %__MODULE__{
      run_id: run_id,
      task: task |> Errors.redact() |> bound_value(),
      provider: provider,
      model: model,
      started_at: now,
      status: :queued,
      metadata: metadata |> Errors.redact() |> bound_value()
    }
  end

  def record(nil, event, payload), do: new(nil, nil, nil, nil) |> record(event, payload)

  # `stage_chunk` carries the streamed text, which `Run.stages[role].content`
  # already accumulates. Keep one entry per role so the event still shows up in
  # `events/1` and in golden `expected_events`, drop the duplicated body, and
  # count the rest.
  def record(%__MODULE__{} = trace, :stage_chunk, payload) do
    payload = payload |> Errors.redact() |> bound_value()
    role = Map.get(payload, :role)

    if Map.has_key?(trace.chunk_counts, role) do
      Map.update!(trace, :chunk_counts, &Map.update!(&1, role, fn count -> count + 1 end))
    else
      entry = %{
        event: :stage_chunk,
        payload: Map.delete(payload, :chunk),
        occurred_at: DateTime.utc_now(),
        error_classification: nil
      }

      trace
      |> Map.update!(:chunk_counts, &Map.put(&1, role, 1))
      |> append_entry(entry)
    end
  end

  # `stage_completed` carries the role's whole finished text, and
  # `Run.stages[role].content` is where that text is kept -- the trace copy is
  # a duplicate, and the largest single thing that reaches a trace. Same
  # reasoning as `stage_chunk` above, and the entry still appears in
  # `events/1` and in golden `expected_events`.
  def record(%__MODULE__{} = trace, :stage_completed, payload) do
    record_entry(trace, :stage_completed, Map.delete(payload, :content))
  end

  def record(%__MODULE__{} = trace, event, payload) do
    record_entry(trace, event, payload)
  end

  defp record_entry(trace, event, payload) do
    now = DateTime.utc_now()
    payload = payload |> Errors.redact() |> bound_value()

    entry = %{
      event: event,
      payload: payload,
      occurred_at: now,
      error_classification: error_classification(event, payload)
    }

    trace
    |> append_entry(entry)
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
      dropped_entries: trace.dropped_entries,
      truncated?: trace.dropped_entries > 0,
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

  # The entry cap counts entries; this is what turns that count into a memory
  # bound. Truncation runs *after* `Errors.redact/1` on purpose -- cutting a
  # secret in half first would leave a fragment the redactor no longer matches.
  # Only strings shrink: `changed_files`, `applied?` and the other small values
  # `summary/1` is built from are left exactly as they are.
  defp bound_value(value) when is_binary(value) do
    bound_binary(value, Limits.fetch!(:max_trace_payload_chars))
  end

  defp bound_value(%_struct{} = value), do: value

  defp bound_value(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, bound_value(v)} end)

  defp bound_value(value) when is_list(value), do: Enum.map(value, &bound_value/1)
  defp bound_value(value), do: value

  defp bound_binary(value, max) do
    if String.valid?(value) do
      # Grapheme-counted, so a truncated string never ends mid-codepoint.
      if String.length(value) > max,
        do: String.slice(value, 0, max) <> @truncation_marker,
        else: value
    else
      if byte_size(value) > max,
        do: binary_part(value, 0, max) <> @truncation_marker,
        else: value
    end
  end

  # `entries ++ [entry]` is O(n), but the cap keeps n at or below
  # `max_trace_entries`, which makes the whole run's cost irrelevant. Keeping
  # the list in chronological order matters more: `MrEric.Evals.Scorer` reads
  # `%Trace{entries: ...}` directly.
  defp append_entry(trace, entry) do
    max = Limits.fetch!(:max_trace_entries)
    entries = trace.entries ++ [entry]
    overflow = length(entries) - max

    if overflow > 0 do
      %{
        trace
        | entries: Enum.drop(entries, overflow),
          dropped_entries: trace.dropped_entries + overflow
      }
    else
      %{trace | entries: entries}
    end
  end

  defp event_counts(trace) do
    counts =
      trace.entries
      |> Enum.frequencies_by(& &1.event)
      |> Map.new()

    case trace.chunk_counts |> Map.values() |> Enum.sum() do
      0 -> counts
      total -> Map.put(counts, :stage_chunk, total)
    end
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
