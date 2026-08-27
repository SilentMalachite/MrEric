defmodule MrEric.Evals.CaseTest do
  use ExUnit.Case, async: true

  alias MrEric.Evals.Case, as: EvalCase

  defp base(extra \\ %{}) do
    Map.merge(%{"name" => "demo", "task" => "do a thing", "scenario" => "simple_planning"}, extra)
  end

  test "from_map!/1 fills documented defaults when optional fields are absent" do
    eval_case = EvalCase.from_map!(base())

    assert eval_case.name == "demo"
    assert eval_case.expected_status == :completed
    assert eval_case.expected_events == []
    assert eval_case.forbidden_events == []
    assert eval_case.requires == []
    assert eval_case.expected_no_secret_leak == true
    assert eval_case.expected_approval_required == false
    assert eval_case.expected_patch_applied == nil
    assert eval_case.expected_error_classification == nil
    assert eval_case.approval_action == nil
  end

  test "from_map!/1 raises on an unrecognized expected_status" do
    assert_raise ArgumentError, ~r/expected_status.*"faield"/, fn ->
      EvalCase.from_map!(base(%{"expected_status" => "faield"}))
    end
  end

  test "from_map!/1 raises on an unrecognized expected_events entry" do
    assert_raise ArgumentError, ~r/expected_events.*"run_compelted"/, fn ->
      EvalCase.from_map!(base(%{"expected_events" => ["run_started", "run_compelted"]}))
    end
  end

  test "from_map!/1 raises on an unrecognized forbidden_events entry" do
    assert_raise ArgumentError, ~r/forbidden_events.*"run_complete"/, fn ->
      EvalCase.from_map!(base(%{"forbidden_events" => ["run_complete"]}))
    end
  end

  test "from_map!/1 raises on an unrecognized expected_error_classification" do
    assert_raise ArgumentError, ~r/expected_error_classification.*"tiemout"/, fn ->
      EvalCase.from_map!(base(%{"expected_error_classification" => "tiemout"}))
    end
  end

  test "from_map!/1 raises on an unrecognized approval_action" do
    assert_raise ArgumentError, ~r/approval_action.*"aprove"/, fn ->
      EvalCase.from_map!(base(%{"approval_action" => "aprove"}))
    end
  end

  test "from_map!/1 raises on an unrecognized requires entry" do
    assert_raise ArgumentError, ~r/requires.*"rga"/, fn ->
      EvalCase.from_map!(base(%{"requires" => ["rga"]}))
    end
  end

  test "the raised message names the case so a broken fixture is findable" do
    assert_raise ArgumentError, ~r/"demo"/, fn ->
      EvalCase.from_map!(base(%{"expected_status" => "faield"}))
    end
  end

  test "the committed golden fixture parses" do
    # This is the regression guard: strict parsing must not reject the real file.
    assert is_list(MrEric.Evals.list_cases())
    assert length(MrEric.Evals.list_cases()) > 0
  end
end
