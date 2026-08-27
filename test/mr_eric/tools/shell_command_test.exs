defmodule MrEric.Tools.ShellCommandTest do
  use ExUnit.Case, async: true

  alias MrEric.Tools.ShellCommand

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "mr-eric-shell-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "runs an allowed command inside the workspace", %{workspace: workspace} do
    File.write!(Path.join(workspace, "note.txt"), "hello\n")

    assert {:ok, result} =
             ShellCommand.run(%{command: "cat note.txt"}, workspace_root: workspace)

    assert result.command == "cat note.txt"
    assert result.output == "hello\n"
    assert result.exit_status == 0
  end

  test "rejects a dangerous command when called without the Executor", %{workspace: workspace} do
    assert {:error, :dangerous_command} =
             ShellCommand.run(%{command: "rm -rf tmp"}, workspace_root: workspace)
  end

  test "a shell separator never reaches a shell", %{workspace: workspace} do
    File.write!(Path.join(workspace, "keep.txt"), "keep\n")

    assert {:error, :dangerous_command} =
             ShellCommand.run(%{command: "pwd; rm -rf keep.txt"}, workspace_root: workspace)

    assert File.read!(Path.join(workspace, "keep.txt")) == "keep\n"
  end

  test "glob characters are not expanded", %{workspace: workspace} do
    File.write!(Path.join(workspace, "a.txt"), "a\n")

    assert {:error, :dangerous_command} =
             ShellCommand.run(%{command: "cat *.txt"}, workspace_root: workspace)
  end

  test "rejects paths outside the workspace", %{workspace: workspace} do
    assert {:error, :outside_workspace} =
             ShellCommand.run(%{command: "cat ../outside.txt"}, workspace_root: workspace)
  end

  test "rejects secret paths", %{workspace: workspace} do
    assert {:error, :secret_file} =
             ShellCommand.run(%{command: "cat .env"}, workspace_root: workspace)

    assert {:error, :secret_file} =
             ShellCommand.run(%{command: "cat .GIT/config"}, workspace_root: workspace)
  end

  test "rejects a blank or missing command", %{workspace: workspace} do
    assert {:error, :invalid_args} =
             ShellCommand.run(%{command: "   "}, workspace_root: workspace)

    assert {:error, :invalid_args} = ShellCommand.run(%{}, workspace_root: workspace)
  end

  test "a non-zero exit status is returned, not raised", %{workspace: workspace} do
    assert {:ok, result} =
             ShellCommand.run(%{command: "cat missing.txt"}, workspace_root: workspace)

    assert result.exit_status != 0
  end

  test "an allow-listed program missing from PATH errors instead of raising", %{
    workspace: workspace
  } do
    result = ShellCommand.run(%{command: "rg --version"}, workspace_root: workspace)

    case System.find_executable("rg") do
      nil -> assert {:error, :dangerous_command} = result
      _path -> assert {:ok, %{exit_status: 0}} = result
    end
  end

  test "string keys are accepted", %{workspace: workspace} do
    File.write!(Path.join(workspace, "note.txt"), "hi\n")

    assert {:ok, %{output: "hi\n"}} =
             ShellCommand.run(%{"command" => "cat note.txt"}, workspace_root: workspace)
  end
end
