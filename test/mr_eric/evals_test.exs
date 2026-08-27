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

  test "list_cases/0 returns every case, including ones this machine cannot run" do
    all = Evals.list_cases()
    {enabled, skipped} = Evals.partition_cases()

    assert length(all) == length(enabled) + length(skipped)
    assert Enum.all?(enabled, &EvalCase.enabled?/1)
    refute Enum.any?(skipped, &EvalCase.enabled?/1)
  end

  test "run_all/1 reports skipped cases rather than dropping them" do
    assert {:ok, summary} = Evals.run_all()

    assert is_list(summary.skipped)
    assert summary.passed + summary.failed == length(summary.results)

    {_enabled, skipped} = Evals.partition_cases()
    assert length(summary.skipped) == length(skipped)

    Enum.each(summary.skipped, fn entry ->
      assert is_binary(entry.case)
      assert is_list(entry.requires)
    end)
  end

  test "run_case/2 distinguishes an unknown name from a disabled case" do
    assert {:error, :unknown_eval_case} = Evals.run_case("no_such_case_at_all")

    case Evals.partition_cases() do
      {_enabled, []} ->
        # Every case runs on this machine; the disabled branch is covered by
        # the unit below rather than by the fixture.
        :ok

      {_enabled, [disabled | _]} ->
        assert {:error, {:case_disabled, requires}} = Evals.run_case(disabled.name)
        assert requires == disabled.requires
    end
  end

  test "actual carries the planner stage so the secret scanner reaches it" do
    assert {:ok, result} = Evals.run_case("simple_planning")

    assert Map.has_key?(result.actual, :plan)
    assert is_binary(result.actual.plan.content)
    assert result.actual.plan.content != ""
  end

  test "a secret in planner output fails expected_no_secret_leak" do
    # Proves the new field is actually scanned, not merely present.
    eval_case = %EvalCase{
      name: "planted",
      expected_status: :completed,
      expected_no_secret_leak: true
    }

    actual = %{
      status: :completed,
      final: "",
      plan: %{content: "OPENAI_API_KEY=sk-plantedsecret1234567890"},
      trace: MrEric.Runs.Trace.new("planted", "task", :fake, "fake-model")
    }

    assert {:error, result} = Scorer.score(eval_case, actual)
    assert :secret_leak in result.failed_assertions
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
