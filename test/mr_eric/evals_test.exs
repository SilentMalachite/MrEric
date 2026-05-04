defmodule MrEric.EvalsTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias MrEric.Evals
  alias MrEric.Evals.Case, as: EvalCase
  alias MrEric.Evals.Scorer

  test "list_cases/0 returns deterministic golden cases" do
    names = Evals.list_cases() |> Enum.map(& &1.name)

    assert "simple_planning" in names
    assert "patch_apply_after_approval" in names
    assert "secret_leak_check" in names
  end

  test "run_case/2 evaluates a single fake-provider case" do
    assert {:ok, result} = Evals.run_case("simple_planning")

    assert result.case == "simple_planning"
    assert result.status == :passed
    assert result.actual.status == :completed
    assert result.actual.final =~ "implementation"
  end

  test "run_all/1 evaluates all enabled cases without external APIs" do
    assert {:ok, summary} = Evals.run_all()

    assert summary.failed == 0
    assert summary.passed == length(summary.results)
    assert Enum.any?(summary.results, &(&1.case == "tool_denied"))
  end

  test "scorer reports failed assertions with trace summary" do
    eval_case = %EvalCase{
      name: "bad_case",
      expected_status: :completed,
      expected_final_contains: ["missing"],
      expected_events: [:run_started]
    }

    actual = %{
      status: :failed,
      final: "different",
      trace: MrEric.Runs.Trace.new("bad", "task", :fake, "fake")
    }

    assert {:error, failure} = Scorer.score(eval_case, actual)
    assert failure.case == "bad_case"
    assert failure.failed_assertions != []
    assert Map.has_key?(failure, :trace_summary)
  end

  test "scorer fails if final or trace leaks a secret" do
    eval_case = %EvalCase{
      name: "leaky",
      expected_status: :completed,
      expected_no_secret_leak: true
    }

    actual = %{
      status: :completed,
      final: "OPENAI_API_KEY=sk-dummysecret123456789",
      trace: MrEric.Runs.Trace.new("leaky", "task", :fake, "fake")
    }

    assert {:error, failure} = Scorer.score(eval_case, actual)
    assert :secret_leak in failure.failed_assertions
  end

  test "mix mr_eric.evals task can run a single case" do
    output =
      capture_io(fn ->
        Mix.Tasks.MrEric.Evals.run(["--case", "simple_planning"])
      end)

    assert output =~ "simple_planning"
    assert output =~ "passed"
  end
end
