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
    # `--git-dir` is absent from the git entry's `long` map, so `Map.fetch/2`
    # fails and the walker refuses before any value is resolved -- whether or
    # not the argument happens to escape.
    assert {:error, :dangerous_command} =
             Policy.authorize(:shell_command, %{command: "git --git-dir=/tmp/.git status"},
               workspace_root: workspace
             )
  end

  describe "git global options and bare program names (Spec C-1)" do
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

  describe "value kinds: pattern sources and optional values (Spec C-1 rev 2)" do
    # A pattern source (-f/--file) means the program has NO pattern operand, so
    # every bare operand is a file and must be path-checked.
    test "an operand after -f/--file is a path, not the pattern", %{workspace: workspace} do
      File.write!(Path.join(workspace, "pat.txt"), "root\n")

      for command <- [
            "grep -f pat.txt /etc/passwd",
            "grep -fpat.txt /etc/passwd",
            "grep --file=pat.txt /etc/passwd",
            "grep -f pat.txt -- /etc/passwd",
            "rg -f pat.txt /etc/passwd",
            "rg --file=pat.txt /etc/passwd"
          ] do
        assert {:error, :outside_workspace} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 ),
               "expected #{command} to be refused"
      end
    end

    test "a secret path after -f is still refused", %{workspace: workspace} do
      File.write!(Path.join(workspace, "pat.txt"), "x\n")

      assert {:error, :secret_file} =
               Policy.authorize(:shell_command, %{command: "grep -f pat.txt .env"},
                 workspace_root: workspace
               )
    end

    test "-f with an in-workspace operand is still allowed", %{workspace: workspace} do
      File.write!(Path.join(workspace, "pat.txt"), "x\n")

      assert {:ok, %{approval_required?: true}} =
               Policy.authorize(:shell_command, %{command: "grep -f pat.txt note.txt"},
                 workspace_root: workspace
               )
    end

    # An optional-value option binds only in the attached / =value form. Taking
    # the next token would remove that operand from path classification.
    test "an optional-value option does not swallow the following operand", %{
      workspace: workspace
    } do
      for command <- [
            "ls --color /etc",
            "ls --color ..",
            "grep --color root /etc/passwd",
            "git status --untracked-files ..",
            "git diff --color /etc"
          ] do
        assert {:error, :outside_workspace} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 ),
               "expected #{command} to be refused"
      end
    end

    test "optional-value options still work bare and attached", %{workspace: workspace} do
      for command <- [
            "ls --color",
            "ls --color=auto",
            "ls --color .",
            "git status --untracked-files",
            "git status --untracked-files=all"
          ] do
        assert {:ok, %{approval_required?: true}} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 ),
               "expected #{command} to be allowed"
      end
    end
  end

  describe "every grammar entry behaves per its declared kind (Spec C-1 rev 2)" do
    # AR-005: the hand-written guard list covered 14 commands against ~100 table
    # entries, and all three HIGH findings lived in entries with zero coverage.
    # This derives the cases from the table so a future entry cannot land unseen.
    @grammar MrEric.Tools.Policy.__grammar__()

    defp entries do
      programs =
        for {program, g} <- @grammar.programs,
            g.operands |> is_tuple() |> Kernel.!(),
            entry <- flatten(program, g),
            do: entry

      gits =
        for {sub, g} <- @grammar.git_subcommands,
            entry <- flatten("git #{sub}", g),
            do: entry

      globals = flatten("git", %{short: @grammar.programs["git"].short, long: @grammar.programs["git"].long})

      programs ++ gits ++ globals
    end

    defp flatten(prefix, g) do
      shorts = for {c, kind} <- Map.get(g, :short, %{}), do: {prefix, {:short, c}, kind}
      longs = for {n, kind} <- Map.get(g, :long, %{}), do: {prefix, {:long, n}, kind}
      shorts ++ longs
    end

    defp auth(command, workspace),
      do: Policy.authorize(:shell_command, %{command: command}, workspace_root: workspace)

    test "every enumerated option is reachable, i.e. not refused as unknown", %{
      workspace: workspace
    } do
      for {prefix, opt, kind} <- entries() do
        command =
          case {opt, kind} do
            {{:short, c}, :flag} -> "#{prefix} -#{c}"
            {{:long, n}, :flag} -> "#{prefix} #{n}"
            {{:short, c}, _} -> "#{prefix} -#{c}value"
            {{:long, n}, _} -> "#{prefix} #{n}=value"
          end

        refute match?({:error, :dangerous_command}, auth(command, workspace)),
               "#{command} should be reachable in the grammar"
      end
    end

    test "every path-kind option refuses an escaping value in all its forms", %{
      workspace: workspace
    } do
      for {prefix, opt, kind} <- entries(), kind in [:path, :path_pattern_source] do
        commands =
          case opt do
            {:short, c} -> ["#{prefix} -#{c}../outside", "#{prefix} -#{c} ../outside"]
            {:long, n} -> ["#{prefix} #{n}=../outside", "#{prefix} #{n} ../outside"]
          end

        for command <- commands do
          assert {:error, :outside_workspace} = auth(command, workspace),
                 "#{command} should be refused as outside_workspace"
        end
      end
    end

    test "every mandatory-value option is invalid_args with no value", %{workspace: workspace} do
      for {prefix, opt, kind} <- entries(),
          kind in [:path, :path_pattern_source, :pattern, :literal] do
        command =
          case opt do
            {:short, c} -> "#{prefix} -#{c}"
            {:long, n} -> "#{prefix} #{n}"
          end

        assert {:error, :invalid_args} = auth(command, workspace),
               "#{command} should be invalid_args (value required)"
      end
    end

    test "every long :flag refuses an attached value", %{workspace: workspace} do
      for {prefix, {:long, n}, :flag} <- entries() do
        assert {:error, :dangerous_command} = auth("#{prefix} #{n}=value", workspace),
               "#{prefix} #{n}=value should be refused (flag takes no value)"
      end
    end

    test "every optional-value option works bare and attached", %{workspace: workspace} do
      for {prefix, opt, :literal_optional} <- entries() do
        commands =
          case opt do
            {:short, c} -> ["#{prefix} -#{c}", "#{prefix} -#{c}auto"]
            {:long, n} -> ["#{prefix} #{n}", "#{prefix} #{n}=auto"]
          end

        for command <- commands do
          assert {:ok, %{approval_required?: true}} = auth(command, workspace),
                 "#{command} should be allowed"
        end
      end
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
