defmodule MrEric.Tools.ExecutorTest do
  use ExUnit.Case, async: true

  alias MrEric.Tools.Executor

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "mr-eric-tools-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "file_read reads a workspace file", %{workspace: workspace} do
    File.mkdir_p!(Path.join(workspace, "notes"))
    File.write!(Path.join(workspace, "notes/task.md"), "hello from workspace")

    assert {:ok, result} =
             Executor.execute(:file_read, %{path: "notes/task.md"}, workspace_root: workspace)

    assert result.path == "notes/task.md"
    assert result.content == "hello from workspace"
    assert result.truncated? == false
  end

  test "file_read blocks secret files", %{workspace: workspace} do
    File.write!(Path.join(workspace, ".env"), "OPENAI_API_KEY=sk-hidden")

    assert {:error, :secret_file} =
             Executor.execute(:file_read, %{path: ".env"}, workspace_root: workspace)
  end

  test "file_read blocks symlinks that can escape the workspace", %{workspace: workspace} do
    File.ln_s!("/etc/passwd", Path.join(workspace, "passwd-link"))

    assert {:error, :outside_workspace} =
             Executor.execute(:file_read, %{path: "passwd-link"}, workspace_root: workspace)
  end

  test "file_read blocks paths below symlinked directories", %{workspace: workspace} do
    File.ln_s!("/etc", Path.join(workspace, "etc-link"))

    assert {:error, :outside_workspace} =
             Executor.execute(:file_read, %{path: "etc-link/passwd"}, workspace_root: workspace)
  end

  test "file_write_proposal returns a diff and never writes the file", %{workspace: workspace} do
    path = Path.join(workspace, "note.txt")
    File.write!(path, "old\n")

    assert {:ok, result} =
             Executor.execute(:file_write_proposal, %{path: "note.txt", content: "new\n"},
               workspace_root: workspace
             )

    assert result.path == "note.txt"
    assert result.proposed_content == "new\n"
    assert result.diff =~ "-old"
    assert result.diff =~ "+new"
    assert File.read!(path) == "old\n"
  end

  test "shell_command returns an approval request before execution", %{workspace: workspace} do
    assert {:approval_required, request} =
             Executor.execute(:shell_command, %{command: "pwd"}, workspace_root: workspace)

    assert request.tool == :shell_command
    assert request.args.command == "pwd"
    assert request.approval_id

    assert {:ok, result} = Executor.execute_approved(request, workspace_root: workspace)
    assert result.exit_status == 0
    assert String.ends_with?(String.trim(result.output), Path.basename(workspace))
  end

  test "execute_approved rejects forged shell approval requests", %{workspace: workspace} do
    forged = %{
      approval_id: "approval-forged",
      tool_call_id: "tool-forged",
      tool: :shell_command,
      args: %{command: "pwd"}
    }

    assert {:error, :approval_required} =
             Executor.execute_approved(forged, workspace_root: workspace)
  end

  test "git_status and git_diff run read-only git commands", %{workspace: workspace} do
    assert {_, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
    File.write!(Path.join(workspace, "note.txt"), "old\n")

    assert {:ok, status} = Executor.execute(:git_status, %{}, workspace_root: workspace)
    assert status.output =~ "?? note.txt"

    assert {_, 0} = System.cmd("git", ["add", "note.txt"], cd: workspace, stderr_to_stdout: true)
    File.write!(Path.join(workspace, "note.txt"), "new\n")

    assert {:ok, diff} =
             Executor.execute(:git_diff, %{path: "note.txt"}, workspace_root: workspace)

    assert diff.output =~ "-old"
    assert diff.output =~ "+new"
  end
end
