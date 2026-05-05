defmodule MrEric.Tools.ExecutorTest do
  use ExUnit.Case, async: true

  alias MrEric.Tools.Executor

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "mr-eric-tools-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace, owner_id: "test-executor-#{System.unique_integer([:positive])}"}
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

  test "shell_command returns an approval request before execution", %{
    workspace: workspace,
    owner_id: owner_id
  } do
    assert {:approval_required, request} =
             Executor.execute(:shell_command, %{command: "pwd"},
               workspace_root: workspace,
               owner_id: owner_id
             )

    assert request.tool == :shell_command
    assert request.args.command == "pwd"
    assert request.approval_id

    assert {:ok, result} = Executor.execute_approved(request, workspace_root: workspace)
    assert result.exit_status == 0
    assert String.ends_with?(String.trim(result.output), Path.basename(workspace))
  end

  test "apply_patch requires approval and does not write before approval", %{
    workspace: workspace,
    owner_id: owner_id
  } do
    path = Path.join(workspace, "note.txt")
    File.write!(path, "old\n")
    init_git_workspace!(workspace, ["note.txt"])

    args = %{
      changes: [
        %{path: "note.txt", before: "old\n", after: "new\n"}
      ]
    }

    assert {:approval_required, request} =
             Executor.execute(:apply_patch, args,
               workspace_root: workspace,
               owner_id: owner_id
             )

    assert request.tool == :apply_patch
    assert File.read!(path) == "old\n"

    assert {:ok, result} = Executor.execute_approved(request, workspace_root: workspace)
    assert File.read!(path) == "new\n"
    assert result.changed_files == ["note.txt"]
    assert result.applied? == true
    assert result.git_diff =~ "-old"
    assert result.git_diff =~ "+new"
  end

  test "apply_patch applies approved unified diffs", %{
    workspace: workspace,
    owner_id: owner_id
  } do
    path = Path.join(workspace, "note.txt")
    File.write!(path, "old\n")

    patch = """
    --- a/note.txt
    +++ b/note.txt
    @@ -1 +1 @@
    -old
    +new from diff
    """

    assert {:approval_required, request} =
             Executor.execute(:apply_patch, %{path: "note.txt", patch: patch},
               workspace_root: workspace,
               owner_id: owner_id
             )

    assert {:ok, result} = Executor.execute_approved(request, workspace_root: workspace)
    assert File.read!(path) == "new from diff\n"
    assert result.changed_files == ["note.txt"]
  end

  test "apply_patch rejects workspace escapes", %{workspace: workspace} do
    assert {:error, :outside_workspace} =
             Executor.execute(
               :apply_patch,
               %{changes: [%{path: "../outside.txt", before: "", after: "nope\n"}]},
               workspace_root: workspace
             )
  end

  test "apply_patch rejects secret files", %{workspace: workspace} do
    File.write!(Path.join(workspace, ".env"), "OPENAI_API_KEY=sk-hidden\n")

    assert {:error, :secret_file} =
             Executor.execute(
               :apply_patch,
               %{changes: [%{path: ".env", before: "OPENAI_API_KEY=sk-hidden\n", after: ""}]},
               workspace_root: workspace
             )
  end

  test "apply_patch rejects stale before content", %{workspace: workspace} do
    File.write!(Path.join(workspace, "note.txt"), "current\n")

    assert {:error, :before_mismatch} =
             Executor.execute(
               :apply_patch,
               %{changes: [%{path: "note.txt", before: "stale\n", after: "new\n"}]},
               workspace_root: workspace
             )
  end

  test "apply_patch rejects deletion patches", %{workspace: workspace} do
    File.write!(Path.join(workspace, "note.txt"), "old\n")

    patch = """
    diff --git a/note.txt b/note.txt
    deleted file mode 100644
    --- a/note.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -old
    """

    assert {:error, :deletion_forbidden} =
             Executor.execute(:apply_patch, %{path: "note.txt", patch: patch},
               workspace_root: workspace
             )
  end

  test "apply_patch rejects git binary patches", %{workspace: workspace} do
    File.write!(Path.join(workspace, "note.txt"), "old\n")

    patch = """
    diff --git a/note.txt b/note.txt
    index 3367afd..e69de29 100644
    GIT binary patch
    literal 0
    HcmV?d00001
    """

    assert {:error, :binary_file} =
             Executor.execute(:apply_patch, %{path: "note.txt", patch: patch},
               workspace_root: workspace
             )
  end

  test "apply_patch rejects binary file diffs", %{workspace: workspace} do
    File.write!(Path.join(workspace, "note.txt"), "old\n")

    patch = """
    diff --git a/note.txt b/note.txt
    Binary files a/note.txt and b/note.txt differ
    """

    assert {:error, :binary_file} =
             Executor.execute(:apply_patch, %{path: "note.txt", patch: patch},
               workspace_root: workspace
             )
  end

  test "apply_patch rejects oversized patches", %{workspace: workspace} do
    File.write!(Path.join(workspace, "note.txt"), "old\n")

    assert {:error, :patch_too_large} =
             Executor.execute(
               :apply_patch,
               %{
                 changes: [
                   %{path: "note.txt", before: "old\n", after: String.duplicate("x", 250_000)}
                 ]
               },
               workspace_root: workspace
             )
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

  defp init_git_workspace!(workspace, paths) do
    assert {_, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["add" | paths], cd: workspace, stderr_to_stdout: true)
  end

  describe "approval request shape (Spec B)" do
    test "approval_request includes owner_id and expires_at", %{workspace: workspace} do
      owner = "alice"

      {:approval_required, request} =
        MrEric.Tools.Executor.execute(
          :shell_command,
          %{command: "pwd"}, owner_id: owner, workspace_root: workspace)

      assert %{
               approval_id: _,
               approval_token: _,
               tool_call_id: _,
               tool: :shell_command,
               owner_id: ^owner,
               requested_at: %DateTime{},
               expires_at: %DateTime{}
             } = request

      diff =
        DateTime.diff(request.expires_at, request.requested_at, :second)

      assert diff == 30 * 60
    end

    test "execute_approved/2 verifies the new HMAC binding (owner_id included)", %{
      workspace: workspace
    } do
      owner = "alice"

      {:approval_required, request} =
        MrEric.Tools.Executor.execute(
          :shell_command,
          %{command: "pwd"}, owner_id: owner, workspace_root: workspace)

      tampered = %{request | owner_id: "mallory"}

      assert {:error, :approval_required} =
               MrEric.Tools.Executor.execute_approved(tampered,
                 owner_id: "mallory",
                 workspace_root: workspace
               )

      assert {:ok, _} =
               MrEric.Tools.Executor.execute_approved(request,
                 owner_id: owner,
                 workspace_root: workspace
               )
    end
  end
end
