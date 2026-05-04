defmodule MrEric.Tools.PolicyTest do
  use ExUnit.Case, async: true

  alias MrEric.Tools.Policy

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "mr-eric-policy-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "resolves paths only inside the workspace", %{workspace: workspace} do
    assert {:ok, path} =
             Policy.resolve_workspace_path("notes/task.md", workspace_root: workspace)

    assert path == Path.join(workspace, "notes/task.md")

    assert {:error, :outside_workspace} =
             Policy.resolve_workspace_path("../outside.md", workspace_root: workspace)

    assert {:error, :outside_workspace} =
             Policy.resolve_workspace_path("/etc/passwd", workspace_root: workspace)
  end

  test "protects likely secret files", %{workspace: workspace} do
    assert {:error, :secret_file} =
             Policy.resolve_workspace_path(".env", workspace_root: workspace)

    assert {:error, :secret_file} =
             Policy.resolve_workspace_path("config/prod.secret.exs", workspace_root: workspace)

    assert {:error, :secret_file} =
             Policy.resolve_workspace_path(".ssh/id_ed25519", workspace_root: workspace)
  end

  test "shell commands always require approval", %{workspace: workspace} do
    assert {:ok, %{approval_required?: true}} =
             Policy.authorize(:shell_command, %{command: "pwd"}, workspace_root: workspace)

    assert {:ok, %{approval_required?: true}} =
             Policy.authorize(:shell_command, %{command: "git status --short"},
               workspace_root: workspace
             )
  end

  test "rejects dangerous shell commands", %{workspace: workspace} do
    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "rm -rf tmp"}, workspace_root: workspace)

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "git reset --hard"},
               workspace_root: workspace
             )

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "git push origin main"},
               workspace_root: workspace
             )

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "git add ."}, workspace_root: workspace)

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "git restore README.md"},
               workspace_root: workspace
             )

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "pwd;rm -rf tmp"},
               workspace_root: workspace
             )

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "pwd && rm -rf tmp"},
               workspace_root: workspace
             )

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "git -C . reset --hard"},
               workspace_root: workspace
             )

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "echo $(rm -rf tmp)"},
               workspace_root: workspace
             )

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "rm${IFS}-rf${IFS}tmp"},
               workspace_root: workspace
             )

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "cp${IFS}README.md${IFS}/tmp/x"},
               workspace_root: workspace
             )

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "curl${IFS}https://example.com"},
               workspace_root: workspace
             )

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "cat${IFS}/etc/passwd"},
               workspace_root: workspace
             )

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "find tmp -delete"},
               workspace_root: workspace
             )

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "git apply patch.diff"},
               workspace_root: workspace
             )

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "git stash"}, workspace_root: workspace)

    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "git worktree remove tmp"},
               workspace_root: workspace
             )
  end

  test "rejects shell commands that reference paths outside the workspace", %{
    workspace: workspace
  } do
    assert {:error, :outside_workspace} =
             Policy.authorize(:shell_command, %{command: "cat /etc/passwd"},
               workspace_root: workspace
             )

    assert {:error, :outside_workspace} =
             Policy.authorize(:shell_command, %{command: "cat ../secret.txt"},
               workspace_root: workspace
             )

    assert {:error, :outside_workspace} =
             Policy.authorize(:shell_command, %{command: "git --git-dir=/tmp/.git status"},
               workspace_root: workspace
             )
  end
end
