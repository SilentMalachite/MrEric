defmodule MrEric.Tools.GitDiff do
  @moduledoc """
  Returns `git diff` output for the workspace.
  """

  @behaviour MrEric.Tools.Tool

  alias MrEric.Tools.Policy

  @impl true
  def name, do: :git_diff

  @impl true
  def description, do: "Show git diff for the workspace or one path."

  @impl true
  def schema do
    %{
      path: %{type: :string, required: false},
      staged: %{type: :boolean, required: false}
    }
  end

  @impl true
  def run(args, opts) do
    workspace = Policy.workspace_root(opts)
    command_args = ["diff"] ++ staged_args(args) ++ path_args(args, opts)
    {output, exit_status} = System.cmd("git", command_args, cd: workspace, stderr_to_stdout: true)

    {:ok,
     %{command: Enum.join(["git" | command_args], " "), output: output, exit_status: exit_status}}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp staged_args(args) do
    case Policy.arg(args, :staged) do
      true -> ["--cached"]
      "true" -> ["--cached"]
      _value -> []
    end
  end

  defp path_args(args, opts) do
    case Policy.arg(args, :path) do
      nil ->
        []

      "" ->
        []

      path ->
        with {:ok, full_path} <- Policy.resolve_workspace_path(path, opts) do
          ["--", Policy.relative_path(full_path, opts)]
        else
          _error -> []
        end
    end
  end
end
