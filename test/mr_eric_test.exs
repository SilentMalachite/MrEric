defmodule MrEricTest do
  use ExUnit.Case
  alias MrEric

  test "execute_task/1 runs a task and returns result" do
    assert {:ok, result} = MrEric.execute_task("Create a simple Phoenix controller")
    assert result.task == "Create a simple Phoenix controller"
    assert is_binary(result.plan)
    assert is_binary(result.code)
  end

  test "execute_task/1 with invalid input returns error" do
    assert {:error, :invalid_task} = MrEric.execute_task(123)
    assert {:error, :invalid_task} = MrEric.execute_task("")
  end

  test "get_task_history/0 returns history" do
    # Ensure at least one task is executed
    MrEric.execute_task("Task for history")
    history = MrEric.get_task_history()
    assert is_list(history)
    assert length(history) > 0
    assert hd(history).task == "Task for history"
  end

  test "get_latest_task/0 returns the most recent task" do
    MrEric.execute_task("Latest task")
    latest = MrEric.get_latest_task()
    assert latest.task == "Latest task"
  end
end
