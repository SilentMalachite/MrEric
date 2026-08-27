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

    # Spec C-1 delta: still refused, but now as an option rather than as a path.
    # `ensure_program_options_allowed/1` runs ahead of the path check so that
    # --git-dir is rejected whether or not its argument happens to escape.
    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "git --git-dir=/tmp/.git status"},
               workspace_root: workspace
             )
  end

  describe "root-repointing options and bare program names (Spec C-1)" do
    test "rejects git options that re-point the repository", %{workspace: workspace} do
      for command <- [
            "git --git-dir=../store status --short",
            "git --work-tree=../outside status --short",
            "git -c core.fsmonitor=evil status",
            "git --exec-path=../bin status"
          ] do
        assert {:error, :dangerous_command} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 )
      end
    end

    test "still allows git -C, which Policy resolves as a separate token", %{
      workspace: workspace
    } do
      File.mkdir_p!(Path.join(workspace, "sub"))

      assert {:ok, %{approval_required?: true}} =
               Policy.authorize(:shell_command, %{command: "git -C sub status --short"},
                 workspace_root: workspace
               )
    end

    test "still allows a plain git subcommand", %{workspace: workspace} do
      assert {:ok, %{approval_required?: true}} =
               Policy.authorize(:shell_command, %{command: "git status --short"},
                 workspace_root: workspace
               )
    end

    test "rejects a program token that is a path", %{workspace: workspace} do
      for command <- ["./pwd", "tmp/pwd", "bin/git status"] do
        assert {:error, :dangerous_command} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 )
      end
    end

    test "still allows a bare program name", %{workspace: workspace} do
      assert {:ok, %{approval_required?: true}} =
               Policy.authorize(:shell_command, %{command: "pwd"}, workspace_root: workspace)
    end
  end

  describe "sed is off the allow-list (Spec C-1 rev 2)" do
    # sed is a scripting language: its scripts can write (`w`), read (`r`) and,
    # on GNU sed, execute (`e`), and `-f` loads a script from a file. Bounding
    # it means parsing sed scripts, so it is refused outright. grep/rg cover
    # the read-oriented use cases the allow-list exists for.
    test "every sed form is refused, bundled -i included", %{workspace: workspace} do
      for command <- [
            "sed -E -i.bak s/foo/bar/ README.md",
            "sed -Ei.bak s/foo/bar/ README.md",
            "sed -ni.bak s/foo/bar/p README.md",
            "sed --in-place=.bak s/foo/bar/ README.md",
            "sed -i.bak s/foo/bar/ README.md",
            "sed -n -i s/foo/bar/ README.md",
            "sed -n 1,5p README.md",
            "sed -nf../outside/script README.md"
          ] do
        assert {:error, :dangerous_command} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 ),
               "expected #{command} to be refused"
      end
    end
  end

  describe "unknown options and value kinds (Spec C-1 rev 2)" do
    test "an option the grammar does not name is refused", %{workspace: workspace} do
      for command <- [
            "rg --pre=./hook needle f.txt",
            "rg --hostname-bin=./hook needle f.txt",
            "rg -L needle .",
            "rg --follow needle .",
            "ls -LR .",
            # -R dereferences symlinks on GNU grep / ugrep; -r does not.
            "grep -R needle .",
            "grep --dereference-recursive needle .",
            "git --config-env=core.pager=X status",
            "git diff --output=target.txt",
            "cat --show-all note.txt",
            "grep --devices=read needle f.txt"
          ] do
        assert {:error, :dangerous_command} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 ),
               "expected #{command} to be refused"
      end
    end

    test "a bundled short option resolves its real value", %{workspace: workspace} do
      for command <- [
            "grep -nf../outside/patterns f.txt",
            "grep -f../outside/patterns f.txt",
            "grep -f ../outside/patterns f.txt",
            "grep --file=../outside/patterns f.txt",
            "rg -nf../outside/patterns f.txt"
          ] do
        assert {:error, :outside_workspace} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 ),
               "expected #{command} to be refused"
      end
    end

    test "a value-taking option with no value is invalid_args", %{workspace: workspace} do
      assert {:error, :invalid_args} =
               Policy.authorize(:shell_command, %{command: "grep -f"},
                 workspace_root: workspace
               )
    end

    test "a pattern value is not resolved as a path", %{workspace: workspace} do
      for command <- [
            "grep -e/etc/passwd f.txt",
            "grep --regexp=/etc/passwd f.txt",
            "grep -- -f../needle f.txt"
          ] do
        assert {:ok, %{approval_required?: true}} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 ),
               "expected #{command} to be allowed"
      end
    end

    test "an operand after the pattern is still a path", %{workspace: workspace} do
      assert {:error, :outside_workspace} =
               Policy.authorize(:shell_command, %{command: "grep needle /etc/passwd"},
                 workspace_root: workspace
               )
    end

    test "operands: :none rejects any operand", %{workspace: workspace} do
      assert {:ok, %{approval_required?: true}} =
               Policy.authorize(:shell_command, %{command: "pwd -P"}, workspace_root: workspace)

      assert {:error, :dangerous_command} =
               Policy.authorize(:shell_command, %{command: "pwd extra"},
                 workspace_root: workspace
               )
    end

    test "the common read-only forms are still allowed", %{workspace: workspace} do
      File.mkdir_p!(Path.join(workspace, "sub"))

      for command <- [
            "pwd",
            "pwd -P",
            "ls -la",
            "ls --color=auto",
            "cat note.txt",
            "cat -n note.txt",
            "grep -rn needle lib",
            "rg --version",
            "rg -n needle .",
            "git status --short",
            "git -C sub status --short",
            "git diff --stat",
            "git log --oneline",
            "git show --stat"
          ] do
        assert {:ok, %{approval_required?: true}} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 ),
               "expected #{command} to be allowed"
      end
    end
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
