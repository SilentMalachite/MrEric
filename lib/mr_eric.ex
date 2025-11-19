defmodule MrEric do
  @moduledoc """
  MrEric keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  alias MrEric.Agent

  @doc """
  Executes an AI agent task.

  ## Parameters

    - task: String describing the task to execute

  ## Returns

    - `{:ok, entry}` where entry contains task, plan, code, and timestamp
    - `{:error, reason}` if execution fails

  ## Examples

      iex> MrEric.execute_task("Create a simple Phoenix controller")
      {:ok, %{task: "Create a simple Phoenix controller", plan: "...", code: "...", inserted_at: ~U[2025-11-19 10:00:00Z]}}

  """
  def execute_task(task) when is_binary(task) and task != "" do
    Agent.execute(task)
  end

  def execute_task(_task) do
    {:error, :invalid_task}
  end

  @doc """
  Retrieves the execution history of AI agent tasks.

  ## Returns

    - List of task entries, each containing task, plan, code, and timestamp

  ## Examples

      iex> MrEric.get_task_history()
      [%{task: "Create a controller", plan: "...", code: "...", inserted_at: ~U[2025-11-19 10:00:00Z]}]

  """
  def get_task_history do
    Agent.history()
  end

  @doc """
  Gets the most recent task execution.

  ## Returns

    - Latest task entry or nil if no tasks have been executed

  ## Examples

      iex> MrEric.get_latest_task()
      %{task: "Create a controller", plan: "...", code: "...", inserted_at: ~U[2025-11-19 10:00:00Z]}

  """
  def get_latest_task do
    case Agent.history() do
      [latest | _] -> latest
      [] -> nil
    end
  end
end
