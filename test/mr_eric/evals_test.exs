defmodule MrEric.EvalsTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias MrEric.Evals
  alias MrEric.Evals.Case, as: EvalCase
  alias MrEric.Evals.Scorer

  # `Scorer` refuses to score an entry-less trace, so a hand-built `actual`
  # has to look like something a run could actually have produced. Every real
  # run records `run_started` before anything else.
  defp started_trace(id) do
    id
    |> MrEric.Runs.Trace.new("task", :fake, "fake-model")
    |> MrEric.Runs.Trace.record(:run_started, %{})
  end

  test "list_cases/0 returns deterministic golden cases" do
    names = Evals.list_cases() |> Enum.map(& &1.name)

    assert "simple_planning" in names
    assert "patch_apply_after_approval" in names
    assert "secret_leak_check" in names
    # Spec E's case. Without naming it, deleting it from the fixture leaves
    # `failed == 0` and the suite green -- the silent shrink to green that
    # strict parsing and `skipped` reporting exist to prevent.
    assert "rag_default_index" in names
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
      trace: started_trace("bad")
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
      trace: started_trace("leaky")
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

    {enabled, skipped} = Evals.partition_cases()

    # A total split, whichever branch this machine takes: nothing may vanish
    # between `list_cases/0` and the two buckets.
    assert length(enabled) + length(skipped) == length(Evals.list_cases())
    assert Enum.all?(enabled, &EvalCase.enabled?/1)
    refute Enum.any?(skipped, &EvalCase.enabled?/1)

    case skipped do
      [] ->
        # `requires` is the closed vocabulary ~w(rag mcp), and both are
        # satisfied by modules that ship in this repository, so no fixture
        # case can be disabled here and `{:case_disabled, _}` is unreachable.
        # It cannot be reached by a unit test either: `run_case/2` with a
        # `%Case{}` takes the struct clause, which goes straight to the runner
        # and never consults `enabled?/1`. What is assertable is that the
        # empty `skipped` is the truth and not an omission.
        assert Enum.all?(Evals.list_cases(), &EvalCase.enabled?/1)

      [disabled | _] ->
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
      trace: started_trace("planted")
    }

    assert {:error, result} = Scorer.score(eval_case, actual)
    assert :secret_leak in result.failed_assertions
  end

  test "only a canary Events does not redact can fail rag_default_index" do
    # `rag_default_index` seeds three secret-shaped files. Two of them cannot
    # fail the case even if the index handed them to the planner:
    # `Events.normalize_event/2` masks `sk-...` and `API_KEY=...` before
    # `Run.stages` holds the text, so `SecretChecker` has nothing left to
    # report. The PEM header matches none of `redact_secrets/1`'s patterns and
    # survives, so it is the one canary with teeth.
    #
    # This is pinned rather than assumed because the fixture reads as though
    # all three were assertions. They are guards; `expected_status` is what
    # actually proves the marker reached the planner through the real index.
    eval_case = %EvalCase{
      name: "canary",
      expected_status: :completed,
      expected_no_secret_leak: true
    }

    scan = fn seeded ->
      {:stage_completed, payload} =
        MrEric.Runs.Events.normalize_event(
          "canary",
          {:stage_completed, %{role: :planner, content: seeded}}
        )

      Scorer.score(eval_case, %{
        status: :completed,
        final: "",
        plan: %{content: payload.content},
        trace: started_trace("canary")
      })
    end

    assert {:ok, _} = scan.("OPENAI_API_KEY=sk-phase9dummysecret123456789")
    assert {:ok, _} = scan.(~s(config :mr_eric, secret: "sk-phase9dummysecret123456789"))

    assert {:error, leaked} =
             scan.("-----BEGIN RSA PRIVATE KEY-----\nphase9dummy\n-----END RSA PRIVATE KEY-----")

    assert :secret_leak in leaked.failed_assertions
  end

  test "mix mr_eric.evals task can run a single case" do
    output =
      capture_io(fn ->
        Mix.Tasks.MrEric.Evals.run(["--case", "simple_planning"])
      end)

    assert output =~ "simple_planning"
    assert output =~ "passed"
    # The summary line always carries `skipped=`; asserting only "passed"
    # cannot tell a run that skipped everything from one that ran it.
    assert output =~ "skipped="
  end

  test "run_all/1 runs the rag_default_index case rather than skipping it" do
    assert {:ok, summary} = Evals.run_all()
    names = Enum.map(summary.results, & &1.case)

    assert "rag_default_index" in names
    refute "rag_default_index" in Enum.map(summary.skipped, & &1.case)
  end
end
