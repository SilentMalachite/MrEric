defmodule MrEric.Evals.ScorerTest do
  use ExUnit.Case, async: true

  alias MrEric.Evals.Case, as: EvalCase
  alias MrEric.Evals.Scorer
  alias MrEric.Runs.Trace

  defp trace_with(events) do
    Enum.reduce(events, Trace.new("scorer-test", "task", :fake, "fake-model"), fn event, trace ->
      Trace.record(trace, event, %{})
    end)
  end

  test "a forbidden event that is absent still passes" do
    eval_case = %EvalCase{
      name: "ok",
      expected_status: :cancelled,
      forbidden_events: [:run_completed]
    }

    actual = %{status: :cancelled, final: "", trace: trace_with([:run_started, :run_cancelled])}

    assert {:ok, result} = Scorer.score(eval_case, actual)
    assert result.status == :passed
  end

  test "a forbidden event that is present fails" do
    eval_case = %EvalCase{
      name: "bad",
      expected_status: :cancelled,
      forbidden_events: [:run_completed]
    }

    actual = %{status: :cancelled, final: "", trace: trace_with([:run_started, :run_completed])}

    assert {:error, result} = Scorer.score(eval_case, actual)
    assert :forbidden_events in result.failed_assertions
  end

  test "an actual with no trace key fails with :missing_trace instead of passing" do
    eval_case = %EvalCase{
      name: "no_trace",
      expected_status: :cancelled,
      forbidden_events: [:run_completed]
    }

    assert {:error, result} = Scorer.score(eval_case, %{status: :cancelled, final: ""})
    assert result.failed_assertions == [:missing_trace]
  end

  test "an actual whose trace is nil fails with :missing_trace" do
    eval_case = %EvalCase{name: "nil_trace", expected_status: :cancelled}

    assert {:error, result} =
             Scorer.score(eval_case, %{status: :cancelled, final: "", trace: nil})

    assert result.failed_assertions == [:missing_trace]
  end

  test "the raw entries shape is still readable" do
    eval_case = %EvalCase{
      name: "entries",
      expected_status: :completed,
      expected_events: [:run_completed]
    }

    actual = %{
      status: :completed,
      final: "",
      trace: %{entries: [%{event: :run_started}, %{event: :run_completed}]}
    }

    assert {:ok, result} = Scorer.score(eval_case, actual)
    assert result.status == :passed
  end
end
