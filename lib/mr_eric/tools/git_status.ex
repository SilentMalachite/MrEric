defmodule MrEric.Tools.GitStatus do
  @moduledoc """
  Returns `git status --short` for the workspace.
  """

  @behaviour MrEric.Tools.Tool

  alias MrEric.Tools.Policy

  @impl true
  def name, do: :git_status

  @impl true
  def description, do: "Show short git status for the workspace."

  @impl true
  def schema, do: %{}

  @impl true
  def run(_args, opts) do
    workspace = Policy.workspace_root(opts)

    {output, exit_status} =
      System.cmd("git", ["status", "--short"], cd: workspace, stderr_to_stdout: true)

    {:ok, %{command: "git status --short", output: output, exit_status: exit_status}}
  rescue
    error -> {:error, Exception.message(error)}
  end
end
