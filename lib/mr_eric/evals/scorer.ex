defmodule MrEric.Evals.Scorer do
  @moduledoc """
  Rule-based deterministic scorer for Phase 9 evals.
  """

  alias MrEric.Evals.SecretChecker
  alias MrEric.Runs.Trace

  def score(eval_case, actual) do
    failures =
      []
      |> assert_status(eval_case, actual)
      |> assert_final_contains(eval_case, actual)
      |> assert_events(eval_case, actual)
      |> assert_forbidden_events(eval_case, actual)
      |> assert_secret_free(eval_case, actual)
      |> assert_approval_required(eval_case, actual)
      |> assert_tool_denied(eval_case, actual)
      |> assert_tool_rejected(eval_case, actual)
      |> assert_patch_applied(eval_case, actual)
      |> assert_error_classification(eval_case, actual)

    case failures do
      [] ->
        {:ok,
         %{
           case: eval_case.name,
           status: :passed,
           actual: actual,
           trace_summary: trace_summary(actual)
         }}

      failures ->
        {:error,
         %{
           case: eval_case.name,
           status: :failed,
           failed_assertions: Enum.reverse(failures),
           expected: expected_summary(eval_case),
           actual: actual,
           trace_summary: trace_summary(actual)
         }}
    end
  end

  defp assert_status(failures, eval_case, actual) do
    if actual.status == eval_case.expected_status do
      failures
    else
      [:status | failures]
    end
  end

  defp assert_final_contains(failures, eval_case, actual) do
    final = to_string(Map.get(actual, :final, ""))

    if Enum.all?(eval_case.expected_final_contains, &String.contains?(final, &1)) do
      failures
    else
      [:final_contains | failures]
    end
  end

  defp assert_events(failures, eval_case, actual) do
    events = trace_events(actual)

    if Enum.all?(eval_case.expected_events, &(&1 in events)) do
      failures
    else
      [:expected_events | failures]
    end
  end

  defp assert_forbidden_events(failures, eval_case, actual) do
    events = trace_events(actual)

    if Enum.any?(eval_case.forbidden_events, &(&1 in events)) do
      [:forbidden_events | failures]
    else
      failures
    end
  end

  defp assert_secret_free(failures, %{expected_no_secret_leak: true}, actual) do
    case SecretChecker.check(Map.take(actual, [:final, :trace, :drafts, :reviews, :tool_outputs])) do
      :ok -> failures
      {:error, _leaks} -> [:secret_leak | failures]
    end
  end

  defp assert_secret_free(failures, _eval_case, _actual), do: failures

  defp assert_approval_required(failures, %{expected_approval_required: true}, actual) do
    if :tool_approval_requested in trace_events(actual),
      do: failures,
      else: [:approval_required | failures]
  end

  defp assert_approval_required(failures, _eval_case, _actual), do: failures

  defp assert_tool_denied(failures, %{expected_tool_denied: true}, actual) do
    if :tool_denied in trace_events(actual), do: failures, else: [:tool_denied | failures]
  end

  defp assert_tool_denied(failures, _eval_case, _actual), do: failures

  defp assert_tool_rejected(failures, %{expected_tool_rejected: true}, actual) do
    if :tool_rejected in trace_events(actual), do: failures, else: [:tool_rejected | failures]
  end

  defp assert_tool_rejected(failures, _eval_case, _actual), do: failures

  defp assert_patch_applied(failures, %{expected_patch_applied: nil}, _actual), do: failures

  defp assert_patch_applied(failures, %{expected_patch_applied: expected}, actual) do
    summary = trace_summary(actual)

    if Map.get(summary, :patch_applied?) == expected do
      failures
    else
      [:patch_applied | failures]
    end
  end

  defp assert_error_classification(
         failures,
         %{expected_error_classification: nil},
         _actual
       ),
       do: failures

  defp assert_error_classification(failures, eval_case, actual) do
    summary = trace_summary(actual)

    if Map.get(summary, :error_classification) == eval_case.expected_error_classification do
      failures
    else
      [:error_classification | failures]
    end
  end

  defp trace_summary(%{trace: %Trace{} = trace}), do: Trace.summary(trace)
  defp trace_summary(_actual), do: %{}

  defp trace_events(%{trace: %Trace{} = trace}), do: Trace.events(trace)

  defp trace_events(%{trace: %{entries: entries}}) when is_list(entries),
    do: Enum.map(entries, & &1.event)

  defp trace_events(_actual), do: []

  defp expected_summary(eval_case) do
    eval_case
    |> Map.from_struct()
    |> Map.take([
      :expected_status,
      :expected_final_contains,
      :expected_events,
      :forbidden_events,
      :expected_no_secret_leak,
      :expected_approval_required,
      :expected_tool_denied,
      :expected_tool_rejected,
      :expected_patch_applied,
      :expected_error_classification
    ])
  end
end
