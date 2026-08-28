defmodule MrEric.Evals.Scorer do
  @moduledoc """
  Rule-based deterministic scorer for Phase 9 evals.
  """

  alias MrEric.Evals.SecretChecker
  alias MrEric.Runs.Trace

  @doc """
  Scores `actual` against `eval_case`.

  The trace is read once, up front. An `actual` without a readable trace is
  not scored assertion-by-assertion: their verdicts on a missing trace are
  meaningless, and one of them -- `assert_forbidden_events/3`, on an empty
  event list -- used to come back *satisfied*.
  """
  def score(eval_case, actual) do
    case trace_view(actual) do
      {:ok, events, summary} ->
        failures =
          []
          |> assert_status(eval_case, actual)
          |> assert_final_contains(eval_case, actual)
          |> assert_events(eval_case, events)
          |> assert_forbidden_events(eval_case, events)
          |> assert_secret_free(eval_case, actual)
          |> assert_approval_required(eval_case, events)
          |> assert_tool_denied(eval_case, events)
          |> assert_tool_rejected(eval_case, events)
          |> assert_patch_applied(eval_case, summary)
          |> assert_error_classification(eval_case, summary)

        result(eval_case, actual, summary, failures)

      {:error, reason} ->
        result(eval_case, actual, %{}, [reason])
    end
  end

  defp result(eval_case, actual, summary, []) do
    {:ok,
     %{
       case: eval_case.name,
       status: :passed,
       actual: actual,
       trace_summary: summary
     }}
  end

  defp result(eval_case, actual, summary, failures) do
    {:error,
     %{
       case: eval_case.name,
       status: :failed,
       failed_assertions: Enum.reverse(failures),
       expected: expected_summary(eval_case),
       actual: actual,
       trace_summary: summary
     }}
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

  defp assert_events(failures, eval_case, events) do
    if Enum.all?(eval_case.expected_events, &(&1 in events)) do
      failures
    else
      [:expected_events | failures]
    end
  end

  defp assert_forbidden_events(failures, eval_case, events) do
    if Enum.any?(eval_case.forbidden_events, &(&1 in events)) do
      [:forbidden_events | failures]
    else
      failures
    end
  end

  # Always run the scanner against the *full* actual map (minus pure metadata).
  # The eval case flag controls whether a finding fails the case.
  defp assert_secret_free(failures, %{expected_no_secret_leak: true}, actual) do
    case SecretChecker.scan(actual) do
      %SecretChecker.Result{status: :clean} -> failures
      %SecretChecker.Result{status: :leak} -> [:secret_leak | failures]
    end
  end

  defp assert_secret_free(failures, _eval_case, _actual), do: failures

  defp assert_approval_required(failures, %{expected_approval_required: true}, events) do
    if :tool_approval_requested in events, do: failures, else: [:approval_required | failures]
  end

  defp assert_approval_required(failures, _eval_case, _events), do: failures

  defp assert_tool_denied(failures, %{expected_tool_denied: true}, events) do
    if :tool_denied in events, do: failures, else: [:tool_denied | failures]
  end

  defp assert_tool_denied(failures, _eval_case, _events), do: failures

  defp assert_tool_rejected(failures, %{expected_tool_rejected: true}, events) do
    if :tool_rejected in events, do: failures, else: [:tool_rejected | failures]
  end

  defp assert_tool_rejected(failures, _eval_case, _events), do: failures

  defp assert_patch_applied(failures, %{expected_patch_applied: nil}, _summary), do: failures

  defp assert_patch_applied(failures, %{expected_patch_applied: expected}, summary) do
    if Map.get(summary, :patch_applied?) == expected do
      failures
    else
      [:patch_applied | failures]
    end
  end

  defp assert_error_classification(
         failures,
         %{expected_error_classification: nil},
         _summary
       ),
       do: failures

  defp assert_error_classification(failures, eval_case, summary) do
    if Map.get(summary, :error_classification) == eval_case.expected_error_classification do
      failures
    else
      [:error_classification | failures]
    end
  end

  # No catch-all. An `actual` this cannot read is reported as `:missing_trace`,
  # not scored against an empty event list -- `Enum.any?([], …)` is `false`, so
  # the "this event must not have happened" assertion used to pass precisely
  # when nothing could be observed.
  #
  # A trace that *is* readable but holds no entries is the same vacuum wearing
  # a struct, and closing only the first half left it open: `Trace.new/4` with
  # nothing recorded scored as a clean pass. No real run produces one --
  # `RunWorker` records `run_started` from `handle_continue(:start, …)`, and
  # the runner's failure branch records `run_failed` -- so an empty trace means
  # the harness, not the run, is broken. It is reported separately from
  # `:missing_trace` because the two say different things about what went
  # wrong.
  defp trace_view(%{trace: %Trace{entries: []}}), do: {:error, :empty_trace}

  defp trace_view(%{trace: %Trace{} = trace}),
    do: {:ok, Trace.events(trace), Trace.summary(trace)}

  defp trace_view(%{trace: %{entries: []}}), do: {:error, :empty_trace}

  defp trace_view(%{trace: %{entries: entries}}) when is_list(entries),
    do: {:ok, Enum.map(entries, & &1.event), %{}}

  defp trace_view(_actual), do: {:error, :missing_trace}

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
