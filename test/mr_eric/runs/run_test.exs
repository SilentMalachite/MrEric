defmodule MrEric.Runs.RunTest do
  use ExUnit.Case, async: true

  alias MrEric.Runs.Run

  describe "new/2 owner_id requirement" do
    test "raises when :owner_id is missing from opts" do
      assert_raise KeyError, fn ->
        Run.new("task", provider: :ollama, model: "x")
      end
    end

    test "stores owner_id from opts" do
      run = Run.new("task", owner_id: "alice", provider: :ollama, model: "x")

      assert run.owner_id == "alice"
      assert run.task == "task"
    end

    test "blank/1 still produces a struct without raising (uses placeholder owner_id)" do
      run = Run.blank(provider: :ollama, model: "x")

      assert run.id == nil
      assert run.task == ""
      assert is_binary(run.owner_id)
    end
  end
end
