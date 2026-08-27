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
             Policy.resolve_workspace_path(".envrc", workspace_root: workspace)

    assert {:error, :secret_file} =
             Policy.resolve_workspace_path("config/prod.secret.exs", workspace_root: workspace)

    assert {:error, :secret_file} =
             Policy.resolve_workspace_path(".ssh/id_ed25519", workspace_root: workspace)
  end

  test "case-folded secret dirs are rejected by path resolution", %{workspace: workspace} do
    assert {:error, :secret_file} =
             Policy.resolve_workspace_path(".GIT/config", workspace_root: workspace)

    assert {:error, :secret_file} =
             Policy.resolve_workspace_path(".SSH/id_ed25519", workspace_root: workspace)
  end

  test "case-folded secret dirs are rejected as shell command arguments", %{
    workspace: workspace
  } do
    assert {:error, :secret_file} =
             Policy.authorize(:shell_command, %{command: "cat .GIT/config"},
               workspace_root: workspace
             )
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

  describe "option-attached paths (Spec C-1)" do
    test "rejects a relative attached short-option path", %{workspace: workspace} do
      assert {:error, :outside_workspace} =
               Policy.authorize(:shell_command, %{command: "grep -f../outside/p needle.txt"},
                 workspace_root: workspace
               )
    end

    test "rejects an absolute attached short-option path", %{workspace: workspace} do
      assert {:error, :outside_workspace} =
               Policy.authorize(:shell_command, %{command: "grep -f/etc/passwd needle.txt"},
                 workspace_root: workspace
               )
    end

    test "rejects a long-option attached path", %{workspace: workspace} do
      assert {:error, :outside_workspace} =
               Policy.authorize(
                 :shell_command,
                 %{command: "grep --file=../outside/p needle.txt"},
                 workspace_root: workspace
               )
    end

    test "rejects a secret path carried in an option value", %{workspace: workspace} do
      assert {:error, :secret_file} =
               Policy.authorize(:shell_command, %{command: "grep --file=.env needle.txt"},
                 workspace_root: workspace
               )
    end

    test "still allows a non-path option value", %{workspace: workspace} do
      assert {:ok, %{approval_required?: true}} =
               Policy.authorize(:shell_command, %{command: "ls --color=auto"},
                 workspace_root: workspace
               )
    end

    test "still allows ordinary separated arguments", %{workspace: workspace} do
      assert {:ok, %{approval_required?: true}} =
               Policy.authorize(:shell_command, %{command: "grep -rn needle lib"},
                 workspace_root: workspace
               )
    end
  end

  describe "command_argv/1 (Spec C)" do
    test "splits a command into an argv vector" do
      assert {:ok, ["grep", "-rn", "needle", "lib"]} =
               Policy.command_argv("grep -rn needle lib")
    end

    test "collapses repeated and surrounding whitespace" do
      assert {:ok, ["ls", "-la"]} = Policy.command_argv("  ls   -la  ")
    end

    test "returns invalid_args for empty or non-binary input" do
      assert {:error, :invalid_args} = Policy.command_argv("")
      assert {:error, :invalid_args} = Policy.command_argv("   ")
      assert {:error, :invalid_args} = Policy.command_argv(nil)
      assert {:error, :invalid_args} = Policy.command_argv(:pwd)
    end

    test "the argv head is the program authorize/3 allow-listed", %{workspace: workspace} do
      for {command, program} <- [
            {"pwd", "pwd"},
            {"ls -la", "ls"},
            {"cat note.txt", "cat"},
            {"git status --short", "git"}
          ] do
        assert {:ok, %{approval_required?: true}} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 )

        assert {:ok, [^program | _rest]} = Policy.command_argv(command)
      end
    end
  end

  describe "secret_path?/1 (public)" do
    test "true for .env at repo root" do
      assert MrEric.Tools.Policy.secret_path?(".env")
    end

    test "true for .env.local" do
      assert MrEric.Tools.Policy.secret_path?(".env.local")
    end

    test "true for paths under .git/" do
      assert MrEric.Tools.Policy.secret_path?(".git/config")
    end

    test "true for .git regardless of segment case" do
      assert MrEric.Tools.Policy.secret_path?(".git/config")
      assert MrEric.Tools.Policy.secret_path?(".GIT/config")
      assert MrEric.Tools.Policy.secret_path?(".Git/config")
      assert MrEric.Tools.Policy.secret_path?("nested/.GIT/config")
    end

    test "true for .ssh regardless of segment case" do
      assert MrEric.Tools.Policy.secret_path?(".ssh/id_ed25519")
      assert MrEric.Tools.Policy.secret_path?(".SSH/known_hosts")
      assert MrEric.Tools.Policy.secret_path?(".Ssh/config")
    end

    test "false for paths that merely contain the letters" do
      refute MrEric.Tools.Policy.secret_path?("lib/legit/thing.ex")
      refute MrEric.Tools.Policy.secret_path?("docs/gitignore-notes.md")
      refute MrEric.Tools.Policy.secret_path?("lib/mr_eric/ssh_helper.ex")
    end

    test "true for *.pem" do
      assert MrEric.Tools.Policy.secret_path?("priv/cert/server.pem")
    end

    test "true for paths whose name contains 'secret'" do
      assert MrEric.Tools.Policy.secret_path?("priv/secrets/foo.exs")
    end

    test "false for an ordinary lib file" do
      refute MrEric.Tools.Policy.secret_path?("lib/mr_eric/agent.ex")
    end
  end
end
